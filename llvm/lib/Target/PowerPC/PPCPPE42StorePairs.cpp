//===-- PPCPPE42StorePairs.cpp - Form PPE42 VDR pairs before allocation ---===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "PPC.h"
#include "PPCInstrInfo.h"
#include "PPCSubtarget.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/CodeGen/MachineFunctionPass.h"
#include "llvm/CodeGen/MachineInstrBuilder.h"
#include "llvm/CodeGen/MachineRegisterInfo.h"
#include "llvm/IR/DataLayout.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/Support/MathExtras.h"
#include <iterator>

using namespace llvm;

#define DEBUG_TYPE "ppc-ppe42-store-pairs"

namespace {
class PPCPPE42StorePairs : public MachineFunctionPass {
public:
  static char ID;
  PPCPPE42StorePairs() : MachineFunctionPass(ID) {}

  StringRef getPassName() const override {
    return "PPE42 virtual doubleword load and store pairs";
  }

  bool runOnMachineFunction(MachineFunction &MF) override {
    const auto &ST = MF.getSubtarget<PPCSubtarget>();
    if (!ST.isPPE42() || !MF.getFunction().hasOptSize())
      return false;

    MachineRegisterInfo &MRI = MF.getRegInfo();
    const auto &TII = *ST.getInstrInfo();
    const auto &TRI = *ST.getRegisterInfo();
    bool Changed = false;
    // R13 is an ABI-invariant SDA base. Fold an SSA address into each memory
    // operand before allocation can spill the cached pointer across calls.
    // Do not infer this invariant for functions explicitly changing R13.
    bool StableSDA = true;
    for (MachineBasicBlock &MBB : MF)
      for (MachineInstr &MI : MBB)
        if (MI.modifiesRegister(PPC::R13, &TRI) &&
            (!MI.isCall() || MI.definesRegister(PPC::R13, &TRI)))
          StableSDA = false;
    SmallVector<Register, 32> OldAddresses;
    if (StableSDA)
      for (MachineBasicBlock &MBB : MF)
        for (MachineInstr &MI : MBB) {
          if ((MI.getOpcode() != PPC::LWZ && MI.getOpcode() != PPC::STW &&
               MI.getOpcode() != PPC::LVD && MI.getOpcode() != PPC::STVD) ||
              MI.getNumOperands() != 3 || !MI.getOperand(1).isImm() ||
              !MI.getOperand(2).isReg() || MI.getOperand(2).getSubReg() ||
              MI.getOperand(2).isUndef())
            continue;
          Register Address = MI.getOperand(2).getReg();
          Register Reg = Address;
          int64_t Offset = MI.getOperand(1).getImm();
          MachineInstr *Root = nullptr;
          for (unsigned Steps = 0; Steps != 8 && Reg.isVirtual(); ++Steps) {
            MachineInstr *Def = MRI.getVRegDef(Reg);
            if (!Def || !MRI.hasOneDef(Reg) || Def->getNumOperands() < 2)
              break;
            if (Def->getOpcode() == PPC::LA &&
                Def->getOperand(1).getReg() == PPC::R13 &&
                !Def->getOperand(1).isUndef() &&
                Def->getOperand(2).isGlobal() &&
                Def->getOperand(2).getTargetFlags() == PPCII::MO_SDA21) {
              Root = Def;
              break;
            }
            if (Def->isCopy() && !Def->getOperand(1).getSubReg() &&
                !Def->getOperand(1).isUndef()) {
              Reg = Def->getOperand(1).getReg();
              continue;
            }
            if (Def->getOpcode() == PPC::ADDI &&
                Def->getOperand(1).isReg() &&
                !Def->getOperand(1).getSubReg() &&
                !Def->getOperand(1).isUndef() &&
                Def->getOperand(2).isImm() &&
                !AddOverflow(Offset, Def->getOperand(2).getImm(), Offset)) {
              Reg = Def->getOperand(1).getReg();
              continue;
            }
            break;
          }
          if (!Root || AddOverflow(Offset, Root->getOperand(2).getOffset(),
                                   Offset))
            continue;
          const auto *GV = dyn_cast<GlobalVariable>(
              Root->getOperand(2).getGlobal());
          if (!GV || !GV->getValueType()->isSized() || Offset < 0 ||
              !isInt<16>(Offset))
            continue;
          TypeSize Size = MF.getDataLayout().getTypeAllocSize(GV->getValueType());
          unsigned Bytes = MI.getOpcode() == PPC::LVD ||
                                   MI.getOpcode() == PPC::STVD
                               ? 8
                               : 4;
          // Keep new SDA relocation addends inside the declared object. An
          // arbitrary pointer offset can require materialized address arithmetic
          // even though the symbol itself fits the small-data addressing range.
          if (Size.isScalable() || uint64_t(Offset) > Size.getFixedValue() ||
              Bytes > Size.getFixedValue() - uint64_t(Offset))
            continue;
          MI.getOperand(1).ChangeToGA(Root->getOperand(2).getGlobal(), Offset,
                                      PPCII::MO_SDA21);
          MI.getOperand(2).setReg(PPC::R13);
          MI.getOperand(2).setIsKill(false);
          MI.getOperand(2).setIsRenamable(false);
          OldAddresses.push_back(Address);
          Changed = true;
        }
    // Remove only the pure address/copy chain that became unused. In
    // particular, do not extend this into memory-value or spill-slot reasoning.
    while (!OldAddresses.empty()) {
      Register Reg = OldAddresses.pop_back_val();
      if (!Reg.isVirtual() || !MRI.use_nodbg_empty(Reg))
        continue;
      MachineInstr *Def = MRI.getVRegDef(Reg);
      if (!Def || (Def->getOpcode() != PPC::LA &&
                   Def->getOpcode() != PPC::ADDI && !Def->isCopy()))
        continue;
      Register Input = Def->getOperand(1).getReg();
      MRI.markUsesInDebugValueAsUndef(Reg);
      Def->eraseFromParent();
      OldAddresses.push_back(Input);
    }
    // A 64-bit call result is returned in r3:r4. Keeping its two COPY
    // results as unrelated GPRs lets allocation spill them into independent
    // four-byte slots, often in reverse address order. Keep the value in a
    // VDR when both halves survive another call; this gives allocation an
    // aligned doubleword spill slot and permits LVD/STVD reloads.
    for (MachineBasicBlock &MBB : MF) {
      for (auto I = MBB.begin(); I != MBB.end();) {
        MachineInstr &HiCopy = *I++;
        if (HiCopy.getOpcode() != TargetOpcode::COPY ||
            HiCopy.getNumOperands() != 2 ||
            !HiCopy.getOperand(0).getReg().isVirtual() ||
            HiCopy.getOperand(1).getReg() != PPC::R3)
          continue;
        auto Next = I;
        while (Next != MBB.end() && Next->isDebugInstr())
          ++Next;
        if (Next == MBB.end() || Next->getOpcode() != TargetOpcode::COPY ||
            Next->getNumOperands() != 2 ||
            !Next->getOperand(0).getReg().isVirtual() ||
            Next->getOperand(1).getReg() != PPC::R4)
          continue;
        bool IsCallResult = false;
        auto Prev = HiCopy.getIterator();
        for (unsigned Steps = 0; Prev != MBB.begin() && Steps < 4; ++Steps) {
          --Prev;
          if (Prev->isDebugInstr())
            continue;
          if (Prev->isCall()) {
            IsCallResult = Prev->definesRegister(PPC::R3, &TRI) &&
                           Prev->definesRegister(PPC::R4, &TRI);
            break;
          }
          if (Prev->modifiesRegister(PPC::R3, &TRI) ||
              Prev->modifiesRegister(PPC::R4, &TRI) || Prev->isTerminator() ||
              Prev->isInlineAsm())
            break;
        }
        if (!IsCallResult)
          continue;
        Register Hi = HiCopy.getOperand(0).getReg();
        Register Lo = Next->getOperand(0).getReg();
        if (Hi == Lo || !MRI.hasOneDef(Hi) || !MRI.hasOneDef(Lo))
          continue;
        SmallVector<MachineInstr *, 4> RedundantCopies;
        auto FollowCopyChain = [&](Register &Reg) {
          while (MRI.hasOneNonDBGUse(Reg)) {
            MachineInstr *Use = &*MRI.use_nodbg_instructions(Reg).begin();
            if (Use->getParent() != &MBB ||
                Use->getOpcode() != TargetOpcode::COPY ||
                Use->getNumOperands() != 2 ||
                !Use->getOperand(0).getReg().isVirtual() ||
                Use->getOperand(1).getReg() != Reg ||
                Use->getOperand(0).getSubReg() ||
                Use->getOperand(1).getSubReg())
              break;
            Reg = Use->getOperand(0).getReg();
            RedundantCopies.push_back(Use);
          }
        };
        FollowCopyChain(Hi);
        FollowCopyChain(Lo);
        bool SawCall = false, HiUsedAfterCall = false, LoUsedAfterCall = false;
        for (auto Scan = std::next(Next); Scan != MBB.end(); ++Scan) {
          if (Scan->isCall())
            SawCall = true;
          if (!SawCall)
            continue;
          HiUsedAfterCall |= Scan->readsRegister(Hi, &TRI);
          LoUsedAfterCall |= Scan->readsRegister(Lo, &TRI);
        }
        if (SawCall) {
          for (const MachineInstr &Use : MRI.use_nodbg_instructions(Hi))
            HiUsedAfterCall |= Use.getParent() != &MBB;
          for (const MachineInstr &Use : MRI.use_nodbg_instructions(Lo))
            LoUsedAfterCall |= Use.getParent() != &MBB;
        }
        if (!HiUsedAfterCall || !LoUsedAfterCall)
          continue;

        Register Pair = MRI.createVirtualRegister(&PPC::VDRCRegClass);
        BuildMI(MBB, HiCopy, HiCopy.getDebugLoc(),
                TII.get(TargetOpcode::REG_SEQUENCE), Pair)
            .addReg(PPC::R3)
            .addImm(PPC::sub_gpr_hi)
            .addReg(PPC::R4)
            .addImm(PPC::sub_gpr_lo);
        for (MachineOperand &Use : make_early_inc_range(MRI.use_operands(Hi))) {
          Use.setReg(Pair);
          Use.setSubReg(PPC::sub_gpr_hi);
          Use.setIsKill(false);
        }
        for (MachineOperand &Use : make_early_inc_range(MRI.use_operands(Lo))) {
          Use.setReg(Pair);
          Use.setSubReg(PPC::sub_gpr_lo);
          Use.setIsKill(false);
        }
        for (MachineInstr *Copy : RedundantCopies)
          Copy->eraseFromParent();
        HiCopy.eraseFromParent();
        Next->eraseFromParent();
        I = MBB.begin();
        Changed = true;
      }
    }
    auto IsLoadDisplacement = [](const MachineOperand &MO) {
      return MO.isImm() ||
             (MO.isGlobal() && (MO.getTargetFlags() == PPCII::MO_LO ||
                                MO.getTargetFlags() == PPCII::MO_SDA21));
    };
    for (MachineBasicBlock &MBB : MF) {
      for (auto I = MBB.begin(); I != MBB.end();) {
        MachineInstr &First = *I++;
        if (First.getOpcode() != PPC::LWZ || First.getNumOperands() != 3 ||
            !First.hasOneMemOperand() || !First.getOperand(0).isReg() ||
            !First.getOperand(0).getReg().isVirtual() ||
            !IsLoadDisplacement(First.getOperand(1)) ||
            (!First.getOperand(2).isReg() && !First.getOperand(2).isFI()))
          continue;

        auto Next = I;
        SmallVector<MachineInstr *, 4> Between;
        while (Next != MBB.end()) {
          if (Next->isDebugInstr()) {
            ++Next;
            continue;
          }
          if (Next->getOpcode() == PPC::LWZ || Between.size() == 4 ||
              Next->mayLoad() || Next->mayStore() || Next->isCall() ||
              Next->isTerminator() || Next->isInlineAsm() ||
              Next->hasUnmodeledSideEffects())
            break;
          Between.push_back(&*Next++);
        }
        if (Next == MBB.end())
          continue;
        MachineInstr &Second = *Next;
        if (Second.getOpcode() != PPC::LWZ || Second.getNumOperands() != 3 ||
            !Second.hasOneMemOperand() || !Second.getOperand(0).isReg() ||
            !Second.getOperand(0).getReg().isVirtual() ||
            !IsLoadDisplacement(Second.getOperand(1)) ||
            (!Second.getOperand(2).isReg() && !Second.getOperand(2).isFI()))
          continue;

        const MachineOperand &FirstDisp = First.getOperand(1);
        const MachineOperand &SecondDisp = Second.getOperand(1);
        bool Numeric = FirstDisp.isImm() && SecondDisp.isImm();
        MachineInstr &HiLoad =
            (Numeric ? FirstDisp.getImm() <= SecondDisp.getImm()
                     : FirstDisp.isGlobal() &&
                           (!SecondDisp.isGlobal() ||
                            FirstDisp.getOffset() <= SecondDisp.getOffset()))
                ? First
                : Second;
        MachineInstr &LoLoad = &HiLoad == &First ? Second : First;
        const MachineOperand &HiDisp = HiLoad.getOperand(1);
        const MachineOperand &LoDisp = LoLoad.getOperand(1);
        Register Hi = HiLoad.getOperand(0).getReg();
        Register Lo = LoLoad.getOperand(0).getReg();
        const MachineOperand &Base = HiLoad.getOperand(2);
        auto SameBase = [](const MachineOperand &A, const MachineOperand &B) {
          return (A.isReg() && B.isReg() && A.getReg() == B.getReg()) ||
                 (A.isFI() && B.isFI() && A.getIndex() == B.getIndex());
        };
        if (Hi == Lo ||
            (Base.isReg() && (Base.getReg() == Hi || Base.getReg() == Lo)))
          continue;

        MachineInstr *Address = nullptr;
        if (Numeric) {
          int64_t Offset = HiDisp.getImm();
          if (!isInt<16>(Offset) || !isInt<16>(Offset + 4) ||
              LoDisp.getImm() != Offset + 4 ||
              !SameBase(Base, LoLoad.getOperand(2)))
            continue;
        } else {
          // A split global load often has a symbolic high word and an
          // address materialization for the low word:
          //   hi = LWZ @g@lo, base
          //   addr = LA base, @g@lo
          //   lo = LWZ 4, addr
          // Match the exact relocation and root register, including SDA21.
          // Pair before allocation so a return can use r3:r4 directly.
          const MachineOperand &LoBase = LoLoad.getOperand(2);
          bool DirectSDA = HiDisp.isGlobal() && LoDisp.isGlobal() &&
                           Base.isReg() && Base.getReg() == PPC::R13 &&
                           SameBase(Base, LoBase) &&
                           HiDisp.getTargetFlags() == PPCII::MO_SDA21 &&
                           LoDisp.getTargetFlags() == PPCII::MO_SDA21 &&
                           HiDisp.getGlobal() == LoDisp.getGlobal() &&
                           HiDisp.getOffset() <= INT64_MAX - 4 &&
                           LoDisp.getOffset() == HiDisp.getOffset() + 4;
          if (!DirectSDA) {
            if (!HiDisp.isGlobal() || !LoDisp.isImm() || LoDisp.getImm() != 4 ||
                !Base.isReg() || Base.getReg() == PPC::R0 || !LoBase.isReg() ||
                !LoBase.getReg().isVirtual())
              continue;
            Address = MRI.getVRegDef(LoBase.getReg());
            if (!Address || Address->getParent() != &MBB ||
                Address->getOpcode() != PPC::LA ||
                Address->getNumOperands() != 3 ||
                !SameBase(Base, Address->getOperand(1)) ||
                !HiDisp.isIdenticalTo(Address->getOperand(2)))
              continue;
            // A virtual root is SSA. Also check physical roots for changes
            // between the address computation and its low-word load.
            bool RootChanged = false;
            for (auto It = std::next(Address->getIterator());
                 It != LoLoad.getIterator(); ++It)
              if (It->modifiesRegister(Base.getReg(), &TRI)) {
                RootChanged = true;
                break;
              }
            if (RootChanged)
              continue;
          }
        }

        MachineMemOperand *HiMem = *HiLoad.memoperands_begin();
        MachineMemOperand *LoMem = *LoLoad.memoperands_begin();
        if (!HiMem->isLoad() || !LoMem->isLoad() || HiMem->isVolatile() ||
            LoMem->isVolatile() || HiMem->isAtomic() || LoMem->isAtomic() ||
            HiMem->getAlign() < Align(8) || LoMem->getAlign() < Align(4))
          continue;

        if (llvm::any_of(Between, [&](const MachineInstr *MI) {
              return MI->readsRegister(Hi, &TRI) ||
                     MI->modifiesRegister(Hi, &TRI) ||
                     MI->readsRegister(Lo, &TRI) ||
                     MI->modifiesRegister(Lo, &TRI) ||
                     (Base.isReg() &&
                      MI->modifiesRegister(Base.getReg(), &TRI));
            }))
          continue;

        Register Pair = MRI.createVirtualRegister(&PPC::VDRCRegClass);
        MachineInstrBuilder Load =
            BuildMI(MBB, First, First.getDebugLoc(), TII.get(PPC::LVD), Pair)
                .add(HiDisp);
        if (Base.isFI())
          Load.addFrameIndex(Base.getIndex());
        else
          Load.addReg(Base.getReg());
        Load.addMemOperand(HiMem).addMemOperand(LoMem);

        // Keep the scalar users, but let allocation assign their subregisters
        // together as one VDR. No two extra COPY instructions are needed.
        for (MachineOperand &Use : make_early_inc_range(MRI.use_operands(Hi))) {
          Use.setReg(Pair);
          Use.setSubReg(PPC::sub_gpr_hi);
          Use.setIsKill(false);
        }
        for (MachineOperand &Use : make_early_inc_range(MRI.use_operands(Lo))) {
          Use.setReg(Pair);
          Use.setSubReg(PPC::sub_gpr_lo);
          Use.setIsKill(false);
        }
        I = std::next(Next);
        First.eraseFromParent();
        Second.eraseFromParent();
        if (Address && MRI.use_nodbg_empty(Address->getOperand(0).getReg())) {
          MRI.markUsesInDebugValueAsUndef(Address->getOperand(0).getReg());
          Address->eraseFromParent();
        }
        Changed = true;
      }
    }
    for (MachineBasicBlock &MBB : MF) {
      for (auto I = MBB.begin(); I != MBB.end();) {
        MachineInstr &FirstStore = *I++;
        if (FirstStore.getOpcode() != PPC::STW ||
            FirstStore.getNumOperands() != 3 ||
            !FirstStore.hasOneMemOperand() ||
            !FirstStore.getOperand(0).isReg() ||
            !FirstStore.getOperand(1).isImm() ||
            (!FirstStore.getOperand(2).isReg() &&
             !FirstStore.getOperand(2).isFI()))
          continue;

        auto Next = I;
        SmallVector<MachineInstr *, 4> Between;
        while (Next != MBB.end()) {
          if (Next->isDebugInstr()) {
            ++Next;
            continue;
          }
          if (Next->getOpcode() == PPC::STW || Between.size() == 4 ||
              Next->mayLoad() || Next->mayStore() || Next->isCall() ||
              Next->isTerminator() || Next->isInlineAsm() ||
              Next->hasUnmodeledSideEffects())
            break;
          Between.push_back(&*Next++);
        }
        if (Next == MBB.end())
          continue;
        MachineInstr &SecondStore = *Next;
        if (SecondStore.getOpcode() != PPC::STW ||
            SecondStore.getNumOperands() != 3 ||
            !SecondStore.hasOneMemOperand() ||
            !SecondStore.getOperand(0).isReg() ||
            !SecondStore.getOperand(1).isImm() ||
            (!SecondStore.getOperand(2).isReg() &&
             !SecondStore.getOperand(2).isFI()))
          continue;

        // Either memory order is legal. The lower address holds the high word
        // of the PPE42 virtual doubleword.
        MachineInstr &HiStore = FirstStore.getOperand(1).getImm() <=
                                        SecondStore.getOperand(1).getImm()
                                    ? FirstStore
                                    : SecondStore;
        MachineInstr &LoStore =
            &HiStore == &FirstStore ? SecondStore : FirstStore;
        Register Hi = HiStore.getOperand(0).getReg();
        Register Lo = LoStore.getOperand(0).getReg();
        bool ExistingPair =
            Hi == Lo && Hi.isVirtual() &&
            PPC::VDRCRegClass.hasSubClassEq(MRI.getRegClass(Hi)) &&
            HiStore.getOperand(0).getSubReg() == PPC::sub_gpr_hi &&
            LoStore.getOperand(0).getSubReg() == PPC::sub_gpr_lo;
        int64_t Offset = HiStore.getOperand(1).getImm();
        const MachineOperand &Base = HiStore.getOperand(2);
        auto SameBaseOperands = [&](const MachineOperand &A,
                                    const MachineOperand &B) {
          return (A.isReg() && B.isReg() && A.getReg() == B.getReg()) ||
                 (A.isFI() && B.isFI() && A.getIndex() == B.getIndex());
        };
        if (!Hi.isVirtual() || !Lo.isVirtual() ||
            ((HiStore.getOperand(0).getSubReg() ||
              LoStore.getOperand(0).getSubReg()) &&
             !ExistingPair) ||
            (!ExistingPair && Hi != Lo &&
             (!MRI.hasOneNonDBGUse(Hi) || !MRI.hasOneNonDBGUse(Lo))) ||
            !isInt<16>(Offset) || !isInt<16>(Offset + 4) ||
            LoStore.getOperand(1).getImm() != Offset + 4 ||
            !SameBaseOperands(Base, LoStore.getOperand(2)))
          continue;
        if (llvm::any_of(Between, [&](const MachineInstr *MI) {
              return MI->modifiesRegister(Hi, &TRI) ||
                     MI->modifiesRegister(Lo, &TRI) ||
                     (Base.isReg() &&
                      MI->modifiesRegister(Base.getReg(), &TRI));
            }))
          continue;

        MachineMemOperand *HiMem = *HiStore.memoperands_begin();
        MachineMemOperand *LoMem = *LoStore.memoperands_begin();
        if (!HiMem->isStore() || !LoMem->isStore() || HiMem->isVolatile() ||
            LoMem->isVolatile() || HiMem->isAtomic() || LoMem->isAtomic() ||
            HiMem->getAlign() < Align(8) || LoMem->getAlign() < Align(4))
          continue;

        if (ExistingPair) {
          // Both words already come from the two halves of one VDR. Reuse it
          // directly, even when other instructions also use either half.
          MachineInstrBuilder Store =
              BuildMI(MBB, FirstStore, FirstStore.getDebugLoc(),
                      TII.get(PPC::STVD))
                  .addReg(Hi)
                  .addImm(Offset);
          if (Base.isFI())
            Store.addFrameIndex(Base.getIndex());
          else
            Store.addReg(Base.getReg());
          Store.addMemOperand(HiMem).addMemOperand(LoMem);
          I = std::next(Next);
          FirstStore.eraseFromParent();
          SecondStore.eraseFromParent();
          Changed = true;
          continue;
        }

        if (Hi == Lo) {
          // A single zero pair can also pay for its setup in a counted loop:
          // folding the two stores, the early pointer increment and its PHI
          // copy into STVDU removes three loop instructions. Keep this narrow:
          // a canonical self-loop, an immutable zero and no other body effects.
          MachineBasicBlock *Preheader = nullptr;
          MachineInstr *PointerPhi = nullptr, *Advance = nullptr;
          MachineInstr *Zero = MRI.getVRegDef(Hi);
          if (Between.empty() && Base.isReg() && Base.getReg().isVirtual() &&
              Offset && !MBB.isEHPad() && MBB.pred_size() == 2 &&
              MBB.succ_size() == 2 &&
              MBB.isSuccessor(&MBB) &&
              Zero && Zero->getOpcode() == PPC::LI &&
              Zero->getOperand(1).isImm() && !Zero->getOperand(1).getImm()) {
            for (MachineBasicBlock *Pred : MBB.predecessors())
              if (Pred != &MBB)
                Preheader = Pred;
            PointerPhi = MRI.getVRegDef(Base.getReg());
            if (!PointerPhi || PointerPhi->getParent() != &MBB ||
                !PointerPhi->isPHI() || PointerPhi->getNumOperands() != 5 ||
                !Preheader || Preheader->succ_size() != 1 ||
                *Preheader->succ_begin() != &MBB)
              Preheader = nullptr;
          }
          if (Preheader) {
            bool Valid = true, Counted = false, SawAdvance = false;
            for (MachineInstr &MI : MBB) {
              if (MI.isDebugInstr() || &MI == PointerPhi)
                continue;
              if (&MI == &FirstStore || &MI == &SecondStore) {
                Valid &= SawAdvance;
                continue;
              }
              if (MI.getOpcode() == PPC::ADDI && !Advance &&
                  MI.getOperand(1).getReg() == Base.getReg() &&
                  MI.getOperand(2).isImm() &&
                  MI.getOperand(2).getImm() == Offset) {
                Advance = &MI;
                SawAdvance = true;
                continue;
              }
              if (MI.getOpcode() == PPC::BDNZ) {
                Counted = MI.getOperand(0).isMBB() &&
                          MI.getOperand(0).getMBB() == &MBB;
                continue;
              }
              if (MI.getOpcode() == PPC::B && MI.isTerminator())
                continue;
              Valid = false;
            }
            if (Advance) {
              Register NextPointer = Advance->getOperand(0).getReg();
              bool Backedge = false;
              for (unsigned Op = 1; Op < 5; Op += 2)
                if (PointerPhi->getOperand(Op + 1).getMBB() == &MBB)
                  Backedge = PointerPhi->getOperand(Op).getReg() == NextPointer;
              Valid &= NextPointer.isVirtual() && Backedge &&
                       MRI.hasOneNonDBGUse(NextPointer);
              for (MachineInstr &Use : MRI.use_nodbg_instructions(Base.getReg()))
                Valid &= &Use == Advance || &Use == &FirstStore ||
                         &Use == &SecondStore;
            }
            if (Valid && Counted && Advance &&
                MRI.constrainRegClass(Base.getReg(),
                                      &PPC::GPRC_NOR0RegClass) &&
                MRI.constrainRegClass(Advance->getOperand(0).getReg(),
                                      &PPC::GPRC_NOR0RegClass)) {
              Register Fresh = MRI.createVirtualRegister(&PPC::GPRCRegClass);
              Register Pair = MRI.createVirtualRegister(&PPC::VDRCRegClass);
              auto Insert = Preheader->getFirstTerminator();
              BuildMI(*Preheader, Insert, FirstStore.getDebugLoc(),
                      TII.get(PPC::LI), Fresh).addImm(0);
              BuildMI(*Preheader, Insert, FirstStore.getDebugLoc(),
                      TII.get(TargetOpcode::REG_SEQUENCE), Pair)
                  .addReg(Fresh).addImm(PPC::sub_gpr_hi)
                  .addReg(Fresh).addImm(PPC::sub_gpr_lo);
              BuildMI(MBB, FirstStore, FirstStore.getDebugLoc(),
                      TII.get(PPC::STVDU), Advance->getOperand(0).getReg())
                  .addReg(Pair).addImm(Offset).addReg(Base.getReg())
                  .addMemOperand(HiMem).addMemOperand(LoMem);
              I = std::next(Next);
              MRI.clearKillFlags(Hi);
              MRI.clearKillFlags(Base.getReg());
              MRI.markUsesInDebugValueAsUndef(Advance->getOperand(0).getReg());
              Advance->eraseFromParent();
              FirstStore.eraseFromParent();
              SecondStore.eraseFromParent();
              if (MRI.use_nodbg_empty(Hi) && Zero->getNumOperands() == 2 &&
                  !Zero->getFlag(MachineInstr::FrameSetup) &&
                  !Zero->getFlag(MachineInstr::FrameDestroy)) {
                MRI.markUsesInDebugValueAsUndef(Hi);
                Zero->eraseFromParent();
              }
              Changed = true;
              continue;
            }
          }
          // A pair of stores of one value needs a copy into the other half
          // of a VDR.  That copy only pays for itself when the resulting VDR
          // can serve several pairs. Also admit short gaps between pairs:
          // scalar struct initializers often interleave byte/halfword stores.
          // Each pair stays at its original memory position, so those memory
          // operations are not reordered. Never extend the tuple across calls.
          if (!Between.empty())
            continue;
          SmallVector<std::pair<MachineInstr *, MachineInstr *>, 4> Pairs;
          Pairs.emplace_back(&HiStore, &LoStore);
          auto After = std::next(Next);
          bool HadGap = false, SincePair = false;
          unsigned Budget = 32;
          while (After != MBB.end() && Budget) {
            if (After->isDebugInstr()) {
              ++After;
              continue;
            }
            --Budget;
            if (After->isCall() || After->isTerminator() ||
                After->isInlineAsm() || After->hasUnmodeledSideEffects() ||
                After->modifiesRegister(Hi, &TRI))
              break;
            auto Other = std::next(After);
            while (Other != MBB.end() && Other->isDebugInstr())
              ++Other;
            if (Other == MBB.end() || After->getOpcode() != PPC::STW ||
                Other->getOpcode() != PPC::STW || !After->hasOneMemOperand() ||
                !Other->hasOneMemOperand() || After->getNumOperands() != 3 ||
                Other->getNumOperands() != 3 || !After->getOperand(0).isReg() ||
                !Other->getOperand(0).isReg() ||
                !After->getOperand(1).isImm() ||
                !Other->getOperand(1).isImm() ||
                (!After->getOperand(2).isReg() &&
                 !After->getOperand(2).isFI()) ||
                (!Other->getOperand(2).isReg() && !Other->getOperand(2).isFI())) {
              SincePair = true;
              ++After;
              continue;
            }
            MachineInstr *High = &*After;
            MachineInstr *Low = &*Other;
            if (High->getOperand(1).getImm() > Low->getOperand(1).getImm())
              std::swap(High, Low);
            int64_t PairOffset = High->getOperand(1).getImm();
            MachineMemOperand *HighMem = *High->memoperands_begin();
            MachineMemOperand *LowMem = *Low->memoperands_begin();
            if (High->getOperand(0).getReg() != Hi ||
                Low->getOperand(0).getReg() != Hi ||
                !SameBaseOperands(High->getOperand(2), Low->getOperand(2)) ||
                !isInt<16>(PairOffset) || !isInt<16>(PairOffset + 4) ||
                Low->getOperand(1).getImm() != PairOffset + 4 ||
                !HighMem->isStore() || !LowMem->isStore() ||
                HighMem->isVolatile() || LowMem->isVolatile() ||
                HighMem->isAtomic() || LowMem->isAtomic() ||
                HighMem->getAlign() < Align(8) || LowMem->getAlign() < Align(4)) {
              SincePair = true;
              ++After;
              continue;
            }
            HadGap |= SincePair;
            SincePair = false;
            Pairs.emplace_back(High, Low);
            After = std::next(Other);
          }
          // Gapped initializers can keep the scalar live for other fields;
          // budget two setup instructions rather than assuming coalescing.
          if (Pairs.size() < (HadGap ? 3u : 2u))
            continue;

          Register Pair = MRI.createVirtualRegister(&PPC::VDRCRegClass);
          BuildMI(MBB, FirstStore, FirstStore.getDebugLoc(),
                  TII.get(TargetOpcode::REG_SEQUENCE), Pair)
              .addReg(Hi)
              .addImm(PPC::sub_gpr_hi)
              .addReg(Hi)
              .addImm(PPC::sub_gpr_lo);
          for (auto [High, Low] : Pairs) {
            MachineInstrBuilder Store =
                BuildMI(MBB, *High, High->getDebugLoc(), TII.get(PPC::STVD))
                    .addReg(Pair,
                            High == Pairs.back().first ? RegState::Kill : 0)
                    .addImm(High->getOperand(1).getImm());
            const MachineOperand &PairBase = High->getOperand(2);
            if (PairBase.isFI())
              Store.addFrameIndex(PairBase.getIndex());
            else
              Store.addReg(PairBase.getReg());
            Store.addMemOperand(*High->memoperands_begin())
                .addMemOperand(*Low->memoperands_begin());
            High->eraseFromParent();
            Low->eraseFromParent();
          }
          I = After;
          Changed = true;
          continue;
        }

        // A REG_SEQUENCE gives the allocator a chance to place both source
        // words in one VDR tuple. Restrict this to their final uses: otherwise
        // the extra copies could outweigh the saved store instruction.
        Register Pair = MRI.createVirtualRegister(&PPC::VDRCRegClass);
        BuildMI(MBB, FirstStore, FirstStore.getDebugLoc(),
                TII.get(TargetOpcode::REG_SEQUENCE), Pair)
            .addReg(Hi)
            .addImm(PPC::sub_gpr_hi)
            .addReg(Lo)
            .addImm(PPC::sub_gpr_lo);
        MachineInstrBuilder Store =
            BuildMI(MBB, FirstStore, FirstStore.getDebugLoc(),
                    TII.get(PPC::STVD))
                .addReg(Pair, RegState::Kill)
                .addImm(Offset);
        if (Base.isFI())
          Store.addFrameIndex(Base.getIndex());
        else
          Store.addReg(Base.getReg(),
                       SecondStore.getOperand(2).isKill() ? RegState::Kill : 0);
        Store.addMemOperand(HiMem).addMemOperand(LoMem);
        I = std::next(Next);
        HiStore.eraseFromParent();
        LoStore.eraseFromParent();
        Changed = true;
      }
    }
    // Do not let tuple coalescing turn a shared, rematerializable scalar
    // constant into a partial VDR definition that lives across calls. Keep a
    // tuple-only copy of the materializer so its unrelated scalar uses remain
    // ordinary GPR values. This matters for zero-initialized buffers followed
    // by calls that need the same scalar zero.
    for (MachineBasicBlock &MBB : MF) {
      for (MachineInstr &MI : MBB) {
        if (MI.getOpcode() != TargetOpcode::REG_SEQUENCE ||
            MI.getNumOperands() != 5 ||
            !MI.getOperand(0).getReg().isVirtual() ||
            !PPC::VDRCRegClass.hasSubClassEq(
                MRI.getRegClass(MI.getOperand(0).getReg())))
          continue;
        SmallVector<std::pair<Register, Register>, 2> Cloned;
        for (unsigned Op : {1u, 3u}) {
          MachineOperand &Use = MI.getOperand(Op);
          if (!Use.isReg() || !Use.getReg().isVirtual() || Use.getSubReg())
            continue;
          Register Src = Use.getReg();
          auto It = llvm::find_if(Cloned, [&](auto P) { return P.first == Src; });
          if (It != Cloned.end()) {
            Use.setReg(It->second);
            Use.setIsKill(false);
            continue;
          }
          if (!MRI.hasOneDef(Src))
            continue;
          MachineInstr *Def = MRI.getVRegDef(Src);
          if ((Def->getOpcode() != PPC::LI && Def->getOpcode() != PPC::LIS) ||
              Def->getNumOperands() != 2 || !Def->getOperand(1).isImm() ||
              Def->getOperand(0).getSubReg() ||
              Def->getFlag(MachineInstr::FrameSetup) ||
              Def->getFlag(MachineInstr::FrameDestroy))
            continue;
          bool SawCall = false, AcrossCall = false;
          for (auto I = std::next(Def->getIterator());
               I != Def->getParent()->end(); ++I) {
            SawCall |= I->isCall();
            if (SawCall && !I->isDebugInstr() &&
                I->getOpcode() != TargetOpcode::REG_SEQUENCE &&
                I->readsVirtualRegister(Src))
              AcrossCall = true;
          }
          if (SawCall)
            for (const MachineInstr &Other : MRI.use_nodbg_instructions(Src))
              if (Other.getParent() != Def->getParent() &&
                  Other.getOpcode() != TargetOpcode::REG_SEQUENCE)
                AcrossCall = true;
          if (!AcrossCall)
            continue;
          Register Fresh = MRI.createVirtualRegister(MRI.getRegClass(Src));
          MachineInstr *Copy = MF.CloneMachineInstr(Def);
          Copy->getOperand(0).setReg(Fresh);
          Copy->getOperand(0).setIsDead(false);
          Copy->setDebugLoc(MI.getDebugLoc());
          MBB.insert(MI.getIterator(), Copy);
          Use.setReg(Fresh);
          Use.setIsKill(false);
          MRI.clearKillFlags(Src);
          Cloned.emplace_back(Src, Fresh);
          Changed = true;
        }
      }
    }
    // i64 is split before selection on PPE42, so DAG pre-indexing cannot form
    // VDR updates. Once the scalar halves have been paired, fold a shared
    // address increment into the existing memory instruction instead. Do not
    // move the memory access, or extend the lifetime of the original pointer:
    // a two-address update would otherwise need a compensating copy.
    for (MachineBasicBlock &MBB : MF) {
      for (auto I = MBB.begin(); I != MBB.end();) {
        MachineInstr &Mem = *I++;
        bool IsLoad = Mem.getOpcode() == PPC::LVD;
        if ((!IsLoad && Mem.getOpcode() != PPC::STVD) ||
            Mem.getNumOperands() != 3 || !Mem.getOperand(1).isImm() ||
            !Mem.getOperand(2).isReg() || Mem.getOperand(2).getSubReg() ||
            Mem.hasOrderedMemoryRef() ||
            Mem.getFlag(MachineInstr::FrameSetup) ||
            Mem.getFlag(MachineInstr::FrameDestroy))
          continue;
        Register MemBase = Mem.getOperand(2).getReg();
        if (!MemBase.isVirtual())
          continue;
        int64_t Offset = Mem.getOperand(1).getImm();
        MachineInstr *Add = nullptr;
        if (!Offset) {
          // LVD/STVD 0, (base + displacement).
          Add = MRI.getVRegDef(MemBase);
        } else {
          // LVD/STVD displacement, base; next = base + displacement.
          for (MachineInstr &Use : MRI.use_nodbg_instructions(MemBase))
            if (Use.getOpcode() == PPC::ADDI &&
                Use.getOperand(2).isImm() &&
                Use.getOperand(2).getImm() == Offset) {
              Add = &Use;
              break;
            }
        }
        if (!Add || Add->getParent() != &MBB ||
            Add->getOpcode() != PPC::ADDI || Add->getNumOperands() != 3 ||
            !Add->getOperand(0).isReg() ||
            Add->getOperand(0).getSubReg() ||
            !Add->getOperand(1).isReg() || Add->getOperand(1).getSubReg() ||
            !Add->getOperand(2).isImm() ||
            Add->getFlag(MachineInstr::FrameSetup) ||
            Add->getFlag(MachineInstr::FrameDestroy))
          continue;
        Register Address = Add->getOperand(0).getReg();
        Register Base = Add->getOperand(1).getReg();
        int64_t Increment = Add->getOperand(2).getImm();
        if (!Address.isVirtual() || !Base.isVirtual() || Address == Base ||
            !MRI.hasOneDef(Address) || !isInt<16>(Increment) || !Increment ||
            (Offset ? (Offset != Increment || MemBase != Base)
                    : MemBase != Address))
          continue;
        // The old pointer must die here. Debug uses do not require a copy.
        if (llvm::any_of(MRI.use_nodbg_instructions(Base),
                         [&](MachineInstr &Use) {
                           return &Use != Add && &Use != &Mem;
                         }))
          continue;
        // Moving the address definition to Mem must not move it past a use.
        // Also reject a store of the address itself: that would be a cycle.
        bool BeforeMem = true, Safe = true;
        for (MachineInstr &MI : MBB) {
          if (&MI == &Mem) {
            BeforeMem = false;
            if (!IsLoad && MI.getOperand(0).getReg() == Address)
              Safe = false;
            continue;
          }
          if (BeforeMem && !MI.isDebugInstr() && !MI.isPHI() &&
              MI.readsVirtualRegister(Address)) {
            Safe = false;
            break;
          }
        }
        if (!Safe ||
            llvm::none_of(MRI.use_nodbg_instructions(Address),
                          [&](MachineInstr &Use) { return &Use != &Mem; }) ||
            !MRI.constrainRegClass(Address, &PPC::GPRC_NOR0RegClass) ||
            !MRI.constrainRegClass(Base, &PPC::GPRC_NOR0RegClass))
          continue;

        MachineInstrBuilder Update =
            BuildMI(MBB, Mem, Mem.getDebugLoc(),
                    TII.get(IsLoad ? PPC::LVDU : PPC::STVDU));
        if (IsLoad)
          Update.addReg(Mem.getOperand(0).getReg(),
                        RegState::Define | RegState::EarlyClobber);
        Update.addReg(Address, RegState::Define);
        if (!IsLoad)
          Update.add(Mem.getOperand(0));
        Update.addImm(Increment).addReg(Base).cloneMemRefs(Mem);
        Update.setMIFlags(Mem.getFlags());
        MRI.clearKillFlags(Base);
        MRI.clearKillFlags(Address);
        // Debug references between the old ADDI and Mem no longer have a
        // value at that point. Preserve debug uses after the new definition.
        for (MachineInstr &MI : MBB) {
          if (&MI == &Mem)
            break;
          if (MI.isDebugValue())
            for (MachineOperand &MO : MI.operands())
              if (MO.isReg() && MO.getReg() == Address)
                MO.setReg(0);
        }
        if (I != MBB.end() && &*I == Add)
          ++I;
        Add->eraseFromParent();
        Mem.eraseFromParent();
        Changed = true;
      }
    }
    return Changed;
  }
};
} // namespace

INITIALIZE_PASS(PPCPPE42StorePairs, DEBUG_TYPE,
                "PPE42 virtual doubleword load and store pairs", false, false)

char PPCPPE42StorePairs::ID = 0;
FunctionPass *llvm::createPPCPPE42StorePairsPass() {
  return new PPCPPE42StorePairs();
}
