//===-- PPCPPE42StorePairs.cpp - Form PPE42 VDR stores before allocation --===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "PPC.h"
#include "PPCInstrInfo.h"
#include "PPCSubtarget.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/CodeGen/MachineFunctionPass.h"
#include "llvm/CodeGen/MachineInstrBuilder.h"
#include "llvm/CodeGen/MachineRegisterInfo.h"
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
    return "PPE42 virtual doubleword store pairs";
  }

  bool runOnMachineFunction(MachineFunction &MF) override {
    const auto &ST = MF.getSubtarget<PPCSubtarget>();
    if (!ST.isPPE42() || !MF.getFunction().hasOptSize())
      return false;

    MachineRegisterInfo &MRI = MF.getRegInfo();
    const auto &TII = *ST.getInstrInfo();
    const auto &TRI = *ST.getRegisterInfo();
    bool Changed = false;
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
        MachineInstr &LoStore = &HiStore == &FirstStore ? SecondStore
                                                      : FirstStore;
        Register Hi = HiStore.getOperand(0).getReg();
        Register Lo = LoStore.getOperand(0).getReg();
        int64_t Offset = HiStore.getOperand(1).getImm();
        const MachineOperand &Base = HiStore.getOperand(2);
        auto SameBaseOperands = [&](const MachineOperand &A,
                                    const MachineOperand &B) {
          return (A.isReg() && B.isReg() && A.getReg() == B.getReg()) ||
                 (A.isFI() && B.isFI() && A.getIndex() == B.getIndex());
        };
        if (!Hi.isVirtual() || !Lo.isVirtual() ||
            (Hi != Lo && (!MRI.hasOneNonDBGUse(Hi) ||
                          !MRI.hasOneNonDBGUse(Lo))) ||
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
        if (!HiMem->isStore() || !LoMem->isStore() ||
            HiMem->isVolatile() || LoMem->isVolatile() ||
            HiMem->isAtomic() || LoMem->isAtomic() ||
            HiMem->getAlign() < Align(8) || LoMem->getAlign() < Align(4))
          continue;

        if (Hi == Lo) {
          // A pair of stores of one value needs a copy into the other half
          // of a VDR.  That copy only pays for itself when the resulting VDR
          // can serve at least two pairs.  Keep the run contiguous so the
          // pair's live range stays short and no intervening definition or
          // memory operation can change what the stores observe.
          if (!Between.empty())
            continue;
          SmallVector<std::pair<MachineInstr *, MachineInstr *>, 4> Pairs;
          Pairs.emplace_back(&HiStore, &LoStore);
          auto After = std::next(Next);
          while (After != MBB.end()) {
            if (After->isDebugInstr()) {
              ++After;
              continue;
            }
            auto Other = std::next(After);
            while (Other != MBB.end() && Other->isDebugInstr())
              ++Other;
            if (Other == MBB.end() || After->getOpcode() != PPC::STW ||
                Other->getOpcode() != PPC::STW ||
                !After->hasOneMemOperand() || !Other->hasOneMemOperand() ||
                After->getNumOperands() != 3 || Other->getNumOperands() != 3 ||
                !After->getOperand(0).isReg() ||
                !Other->getOperand(0).isReg() ||
                !After->getOperand(1).isImm() ||
                !Other->getOperand(1).isImm() ||
                (!After->getOperand(2).isReg() &&
                 !After->getOperand(2).isFI()) ||
                (!Other->getOperand(2).isReg() &&
                 !Other->getOperand(2).isFI()))
              break;
            MachineInstr *High = &*After;
            MachineInstr *Low = &*Other;
            if (High->getOperand(1).getImm() > Low->getOperand(1).getImm())
              std::swap(High, Low);
            int64_t PairOffset = High->getOperand(1).getImm();
            MachineMemOperand *HighMem = *High->memoperands_begin();
            MachineMemOperand *LowMem = *Low->memoperands_begin();
            if (High->getOperand(0).getReg() != Hi ||
                Low->getOperand(0).getReg() != Hi ||
                !SameBaseOperands(High->getOperand(2),
                                  Low->getOperand(2)) ||
                !isInt<16>(PairOffset) || !isInt<16>(PairOffset + 4) ||
                Low->getOperand(1).getImm() != PairOffset + 4 ||
                !HighMem->isStore() || !LowMem->isStore() ||
                HighMem->isVolatile() || LowMem->isVolatile() ||
                HighMem->isAtomic() || LowMem->isAtomic() ||
                HighMem->getAlign() < Align(8) ||
                LowMem->getAlign() < Align(4))
              break;
            Pairs.emplace_back(High, Low);
            After = std::next(Other);
          }
          if (Pairs.size() < 2)
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
                .addReg(Pair, High == Pairs.back().first ? RegState::Kill : 0)
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
            BuildMI(MBB, FirstStore, FirstStore.getDebugLoc(), TII.get(PPC::STVD))
            .addReg(Pair, RegState::Kill)
            .addImm(Offset);
        if (Base.isFI())
          Store.addFrameIndex(Base.getIndex());
        else
          Store.addReg(Base.getReg(), SecondStore.getOperand(2).isKill()
                                          ? RegState::Kill
                                          : 0);
        Store.addMemOperand(HiMem).addMemOperand(LoMem);
        I = std::next(Next);
        HiStore.eraseFromParent();
        LoStore.eraseFromParent();
        Changed = true;
      }
    }
    return Changed;
  }
};
} // namespace

INITIALIZE_PASS(PPCPPE42StorePairs, DEBUG_TYPE,
                "PPE42 virtual doubleword store pairs", false, false)

char PPCPPE42StorePairs::ID = 0;
FunctionPass *llvm::createPPCPPE42StorePairsPass() {
  return new PPCPPE42StorePairs();
}
