//===-- PPCPPE42ConstSpill.cpp - Fold actual PPE42 constant spills ----------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "MCTargetDesc/PPCMCTargetDesc.h"
#include "PPC.h"
#include "PPCInstrInfo.h"
#include "PPCSubtarget.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/CodeGen/LiveRegUnits.h"
#include "llvm/CodeGen/LiveStacks.h"
#include "llvm/CodeGen/MachineFrameInfo.h"
#include "llvm/CodeGen/MachineFunctionPass.h"
#include "llvm/CodeGen/MachineInstrBuilder.h"
#include "llvm/CodeGen/MachineRegisterInfo.h"
#include "llvm/CodeGen/SlotIndexes.h"
#include <optional>

using namespace llvm;

namespace {
struct Constant {
  uint32_t Value;
  SmallVector<MachineInstr *, 4> Defs;
};
struct Load {
  MachineInstr *MI;
  DenseMap<Register, unsigned> Widths;
};
struct Slot {
  std::optional<uint32_t> Value;
  bool Invalid = false;
  SmallVector<MachineInstr *, 4> Stores;
  SmallVector<Load, 4> Loads;
  SmallPtrSet<MachineInstr *, 8> Defs;
};
struct Op {
  unsigned Opcode;
  Register Source;
  int64_t A, B = 0, C = 0;
};
struct Fold {
  MachineInstr *Reload;
  MachineInstr *User;
  SmallVector<Op, 2> Ops;
};

// At most two immediate operations may replace a reload plus one register
// operation. All forms are non-recording and use only the original destination.
static bool plan(MachineInstr &MI, Register Temp, uint32_t K, unsigned Width,
                 SmallVectorImpl<Op> &Ops) {
  if (MI.getNumOperands() != 3 || !MI.getOperand(0).isReg() ||
      !MI.getOperand(1).isReg() || !MI.getOperand(2).isReg() ||
      MI.getOperand(0).getSubReg() || MI.getOperand(1).getSubReg() ||
      MI.getOperand(2).getSubReg() || MI.isBundledWithPred() ||
      MI.isBundledWithSucc() ||
      MI.getFlag(MachineInstr::FrameSetup) ||
      MI.getFlag(MachineInstr::FrameDestroy))
    return false;
  Register Dst = MI.getOperand(0).getReg();
  Register A = MI.getOperand(1).getReg(), B = MI.getOperand(2).getReg();
  if (!PPC::GPRCRegClass.contains(Dst) || Dst == PPC::R1 || Dst == PPC::R13 ||
      (A == Temp) == (B == Temp))
    return false;
  Register Src = A == Temp ? B : A;
  if (!PPC::GPRCRegClass.contains(Src))
    return false;
  switch (MI.getOpcode()) {
  default:
    return false;
  case PPC::OR:
  case PPC::XOR: {
    bool IsOr = MI.getOpcode() == PPC::OR;
    if (K >> 16)
      Ops.push_back({IsOr ? PPC::ORIS : PPC::XORIS, Src, K >> 16});
    if (K & 0xffff)
      Ops.push_back({IsOr ? PPC::ORI : PPC::XORI,
                     Ops.empty() ? Src : Dst, K & 0xffff});
    break;
  }
  case PPC::ADD4: {
    // D-form arithmetic treats RA=0 as zero, unlike register ADD.
    if (Src == PPC::R0 || Dst == PPC::R0)
      return false;
    int16_t Lo = K & 0xffff;
    int16_t Hi = (K - uint32_t(int32_t(Lo))) >> 16;
    if (Hi)
      Ops.push_back({PPC::ADDIS, Src, Hi});
    if (Lo)
      Ops.push_back({PPC::ADDI, Ops.empty() ? Src : Dst, Lo});
    break;
  }
  case PPC::AND: {
    if (!K) {
      Ops.push_back({PPC::LI, Register(), 0});
      break;
    }
    uint32_t Zeroes = ~K;
    while (Zeroes) {
      // Find one circular run of zero bits, including an MSB/LSB wrap.
      unsigned Start = 0;
      while (!(Zeroes & (uint32_t(1) << Start)) ||
             (Zeroes & (uint32_t(1) << ((Start + 31) % 32))))
        ++Start;
      uint32_t Run = 0;
      unsigned Bit = Start;
      do {
        Run |= uint32_t(1) << Bit;
        Bit = (Bit + 1) % 32;
      } while (Zeroes & (uint32_t(1) << Bit));
      unsigned MB, ME;
      if (!isRunOfOnes(~Run, MB, ME) || Ops.size() == 2)
        return false;
      Ops.push_back({PPC::RLWINM, Ops.empty() ? Src : Dst, 0, MB, ME});
      Zeroes &= ~Run;
    }
    break;
  }
  case PPC::MULLW: {
    // If K=2^L+2^H and the input occupies at most H-L low bits, its two
    // shifted copies cannot carry into one another. Insert the second copy
    // by rotating the first result; no scratch register or CR0 is needed.
    if (llvm::popcount(K) != 2)
      return false;
    unsigned L = llvm::countr_zero(K), H = llvm::Log2_32(K);
    if (Width > H - L)
      return false;
    Ops.push_back({PPC::RLWINM, Src, L, 0, 31 - L});
    Ops.push_back({PPC::RLWIMI, Dst, H - L, 0, 31 - H});
    break;
  }
  }
  return !Ops.empty() && Ops.size() <= 2;
}

class PPCPPE42ConstSpill : public MachineFunctionPass {
public:
  static char ID;
  PPCPPE42ConstSpill() : MachineFunctionPass(ID) {}
  StringRef getPassName() const override {
    return "PPE42 arithmetic from constant spill slots";
  }
  void getAnalysisUsage(AnalysisUsage &AU) const override {
    AU.setPreservesCFG();
    AU.addPreserved<LiveStacksWrapperLegacy>();
    AU.addPreserved<SlotIndexesWrapperPass>();
    MachineFunctionPass::getAnalysisUsage(AU);
  }
  bool runOnMachineFunction(MachineFunction &MF) override {
    const auto &ST = MF.getSubtarget<PPCSubtarget>();
    if (skipFunction(MF.getFunction()) || !ST.isPPE42() ||
        !MF.getFunction().hasOptSize() ||
        !MF.getProperties().hasProperty(
            MachineFunctionProperties::Property::NoVRegs) ||
        !MF.getRegInfo().tracksLiveness())
      return false;
    auto &MFI = MF.getFrameInfo();
    const auto &TII = *ST.getInstrInfo();
    const auto &TRI = *ST.getRegisterInfo();
    SlotIndexes *Indexes = nullptr;
    if (auto *P = getAnalysisIfAvailable<SlotIndexesWrapperPass>())
      Indexes = &P->getSI();
    auto Erase = [&](MachineInstr *MI) {
      if (Indexes && Indexes->hasIndex(*MI))
        Indexes->removeMachineInstrFromMaps(*MI);
      MI->eraseFromParent();
    };
    DenseMap<int, Slot> Slots;
    for (MachineBasicBlock &MBB : MF) {
      DenseMap<Register, Constant> Known;
      DenseMap<Register, unsigned> Widths;
      for (MachineInstr &MI : MBB) {
        for (const MachineOperand &MO : MI.operands()) {
          if (!MO.isFI())
            continue;
          int FI = MO.getIndex();
          if (FI < 0 || MFI.isDeadObjectIndex(FI) ||
              !MFI.isSpillSlotObjectIndex(FI) || MFI.getObjectSize(FI) != 4)
            continue;
          Slot &S = Slots[FI];
          if (MI.isDebugInstr() || MI.getNumOperands() != 3 ||
              !MI.getOperand(0).isReg() ||
              !PPC::GPRCRegClass.contains(MI.getOperand(0).getReg()) ||
              !MI.getOperand(1).isImm() || MI.getOperand(1).getImm() ||
              !MI.getOperand(2).isFI() || MI.getOperand(2).getIndex() != FI ||
              !MI.hasOneMemOperand() || MI.hasOrderedMemoryRef() ||
              MI.isBundledWithPred() || MI.isBundledWithSucc() ||
              MI.getFlag(MachineInstr::FrameSetup) ||
              MI.getFlag(MachineInstr::FrameDestroy)) {
            S.Invalid = true;
            continue;
          }
          if (MI.getOpcode() == PPC::STW) {
            auto It = Known.find(MI.getOperand(0).getReg());
            if (It == Known.end() ||
                (S.Value && *S.Value != It->second.Value)) {
              S.Invalid = true;
              continue;
            }
            S.Value = It->second.Value;
            S.Stores.push_back(&MI);
            S.Defs.insert(It->second.Defs.begin(), It->second.Defs.end());
          } else if (MI.getOpcode() == PPC::LWZ)
            S.Loads.push_back({&MI, Widths});
          else
            S.Invalid = true;
        }
        if (MI.isDebugInstr())
          continue;
        std::optional<Constant> New;
        unsigned Width = 32;
        Register Dst;
        if (MI.getNumOperands() >= 2 && MI.getOperand(0).isReg() &&
            MI.getOperand(0).isDef() &&
            PPC::GPRCRegClass.contains(MI.getOperand(0).getReg())) {
          Dst = MI.getOperand(0).getReg();
          if ((MI.getOpcode() == PPC::LI || MI.getOpcode() == PPC::LIS) &&
              MI.getOperand(1).isImm()) {
            uint32_t V = MI.getOperand(1).getImm();
            New = Constant{MI.getOpcode() == PPC::LIS
                               ? V << 16
                               : uint32_t(int32_t(int16_t(V))),
                           {&MI}};
          } else if ((MI.getOpcode() == PPC::ORI ||
                      MI.getOpcode() == PPC::ORIS) &&
                     MI.getOperand(1).isReg() && MI.getOperand(2).isImm()) {
            auto It = Known.find(MI.getOperand(1).getReg());
            if (It != Known.end()) {
              New = It->second;
              uint32_t V = MI.getOperand(2).getImm() & 0xffff;
              New->Value |= MI.getOpcode() == PPC::ORIS ? V << 16 : V;
              New->Defs.push_back(&MI);
            }
          }
          if (MI.getOpcode() == PPC::RLWINM && MI.getOperand(3).isImm() &&
              MI.getOperand(4).isImm() &&
              MI.getOperand(3).getImm() <= MI.getOperand(4).getImm())
            Width = 32 - MI.getOperand(3).getImm();
        }
        // Include tuple aliases, explicit clobbers, and call regmasks.
        for (MCPhysReg R : PPC::GPRCRegClass.getRegisters())
          if (MI.modifiesRegister(R, &TRI)) {
            Known.erase(R);
            Widths.erase(R);
          }
        if (Dst) {
          Widths[Dst] = Width;
          if (New)
            Known.insert_or_assign(Dst, std::move(*New));
        }
      }
    }

    bool Changed = false;
    SmallPtrSet<MachineInstr *, 32> DeadCandidates;
    for (auto &[FI, S] : Slots) {
      if (S.Invalid || !S.Value || S.Loads.empty() || S.Stores.empty())
        continue;
      SmallVector<Fold, 8> Folds;
      for (const Load &L : S.Loads) {
        if (L.MI->peekDebugInstrNum())
          break;
        auto I = std::next(L.MI->getIterator());
        while (I != L.MI->getParent()->end() && I->isDebugInstr())
          ++I;
        if (I == L.MI->getParent()->end())
          break;
        Register Temp = L.MI->getOperand(0).getReg();
        LiveRegUnits Live(TRI);
        Live.addLiveOuts(*I->getParent());
        for (auto R = I->getParent()->rbegin(); &*R != &*I; ++R)
          if (!R->isDebugInstr())
            Live.stepBackward(*R);
        if (!I->definesRegister(Temp, &TRI) && !Live.available(Temp))
          break;
        // plan() validates the explicit operands before they are inspected.
        SmallVector<Op, 2> Ops;
        unsigned Width = 32;
        if (I->getNumOperands() == 3 && I->getOperand(1).isReg() &&
            I->getOperand(2).isReg()) {
          Register Src = I->getOperand(1).getReg() == Temp
                             ? I->getOperand(2).getReg()
                             : I->getOperand(1).getReg();
          Width = L.Widths.lookup(Src);
          if (!L.Widths.count(Src))
            Width = 32;
        }
        if (!plan(*I, Temp, *S.Value, Width, Ops))
          break;
        Folds.push_back({L.MI, &*I, std::move(Ops)});
      }
      // Require every reload to fold before dropping the stores and frame
      // object. Each replacement costs no more than its old reload+user pair.
      if (Folds.size() != S.Loads.size())
        continue;
      for (Fold &F : Folds) {
        Register Dst = F.User->getOperand(0).getReg();
        MachineInstr *Last = nullptr;
        for (const Op &O : F.Ops) {
          auto B = BuildMI(*F.User->getParent(), *F.User, F.User->getDebugLoc(),
                           TII.get(O.Opcode), Dst);
          if (O.Opcode == PPC::RLWIMI)
            B.addReg(Dst);
          if (O.Source)
            B.addReg(O.Source);
          B.addImm(O.A);
          if (O.Opcode == PPC::RLWINM || O.Opcode == PPC::RLWIMI)
            B.addImm(O.B).addImm(O.C);
          Last = B;
          Last->getOperand(0).setIsRenamable(
              F.User->getOperand(0).isRenamable());
          for (MachineOperand &MO : Last->operands()) {
            if (!MO.isReg() || !MO.isUse())
              continue;
            for (const MachineOperand &Old : F.User->operands())
              if (Old.isReg() && Old.getReg() == MO.getReg() &&
                  Old.isRenamable())
                MO.setIsRenamable(true);
          }
          if (Indexes)
            Indexes->insertMachineInstrInMaps(*Last);
        }
        Last->getOperand(0).setIsDead(F.User->getOperand(0).isDead());
        MF.substituteDebugValuesForInst(*F.User, *Last, 1);
        Erase(F.Reload);
        Erase(F.User);
      }
      for (MachineInstr *Store : S.Stores)
        Erase(Store);
      DeadCandidates.insert(S.Defs.begin(), S.Defs.end());
      MFI.RemoveStackObject(FI);
      Changed = true;
    }
    // Delete only the now-dead constant materializers that fed removed stores.
    // Physical register-unit liveness also accounts for tuple aliases.
    for (MachineBasicBlock &MBB : MF) {
      LiveRegUnits Live(TRI);
      Live.addLiveOuts(MBB);
      for (auto I = MBB.end(); I != MBB.begin();) {
        MachineInstr &MI = *--I;
        if (DeadCandidates.contains(&MI) && !MI.peekDebugInstrNum() &&
            !MI.getFlag(MachineInstr::FrameSetup) &&
            !MI.getFlag(MachineInstr::FrameDestroy) &&
            MI.getOperand(0).getReg() != PPC::R1 &&
            MI.getOperand(0).getReg() != PPC::R13 &&
            Live.available(MI.getOperand(0).getReg())) {
          if (Indexes && Indexes->hasIndex(MI))
            Indexes->removeMachineInstrFromMaps(MI);
          I = MBB.erase(I);
          continue;
        }
        if (!MI.isDebugInstr())
          Live.stepBackward(MI);
      }
    }
    return Changed;
  }
};
} // namespace

char PPCPPE42ConstSpill::ID = 0;
INITIALIZE_PASS(PPCPPE42ConstSpill, "ppc-ppe42-const-spill",
                "PPE42 arithmetic from constant spill slots", false, false)

FunctionPass *llvm::createPPCPPE42ConstSpillPass() {
  return new PPCPPE42ConstSpill();
}
