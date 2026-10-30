//===-- PPCPPE42CRSpill.cpp - Shorten PPE42 comparison live ranges ----------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "PPC.h"
#include "PPCInstrInfo.h"
#include "PPCSubtarget.h"
#include "MCTargetDesc/PPCPredicates.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/CodeGen/MachineFunctionPass.h"
#include "llvm/CodeGen/MachineRegisterInfo.h"

using namespace llvm;

namespace {
class PPCPPE42CRSpill : public MachineFunctionPass {
public:
  static char ID;
  PPCPPE42CRSpill() : MachineFunctionPass(ID) {}

  StringRef getPassName() const override {
    return "PPE42 cross-block immediate comparison live ranges";
  }

  bool runOnMachineFunction(MachineFunction &MF) override {
    const auto &ST = MF.getSubtarget<PPCSubtarget>();
    if (!ST.isPPE42() || !MF.getFunction().hasOptSize() ||
        !MF.getProperties().hasProperty(
            MachineFunctionProperties::Property::IsSSA))
      return false;
    auto &MRI = MF.getRegInfo();
    const auto &TRI = *ST.getRegisterInfo();
    SmallVector<MachineInstr *, 16> Compares;
    for (auto &MBB : MF)
      for (auto &MI : MBB)
        if ((MI.getOpcode() == PPC::CMPWI ||
             MI.getOpcode() == PPC::CMPLWI) &&
            MI.getNumOperands() == 3 && MI.getOperand(0).isReg() &&
            MI.getOperand(0).getReg().isVirtual() &&
            !MI.getOperand(0).getSubReg() && MI.getOperand(1).isReg() &&
            MI.getOperand(1).getReg().isVirtual() &&
            !MI.getOperand(1).getSubReg() && MI.getOperand(2).isImm())
          Compares.push_back(&MI);

    bool Changed = false;
    for (MachineInstr *Cmp : Compares) {
      Register CR = Cmp->getOperand(0).getReg();
      Register Input = Cmp->getOperand(1).getReg();
      if (!MRI.hasOneDef(CR) || !MRI.hasOneDef(Input))
        continue;
      // Generated configuration code can reuse one comparison in 5-10
      // conditional updates. Keep the analysis bounded without restricting
      // it to small branch diamonds.
      SmallVector<MachineInstr *, 16> Users;
      bool Safe = true;
      for (MachineInstr &Use : MRI.use_nodbg_instructions(CR)) {
        if (Use.getOpcode() != PPC::BCC ||
            Use.getOperand(1).getReg() != CR ||
            Use.getOperand(1).getSubReg() ||
            Use.getIterator() != Use.getParent()->getFirstTerminator()) {
          Safe = false;
          break;
        }
        // Integer LT/GT/EQ tests only. Repeating a compare also resamples
        // XER.SO, so it must not replace a use of the saved SO bit.
        unsigned Pred = Use.getOperand(0).getImm() & ~PPC::BR_HINT_MASK;
        if (Pred != (PPC::PRED_LT & ~PPC::BR_HINT_MASK) &&
            Pred != (PPC::PRED_GE & ~PPC::BR_HINT_MASK) &&
            Pred != (PPC::PRED_GT & ~PPC::BR_HINT_MASK) &&
            Pred != (PPC::PRED_LE & ~PPC::BR_HINT_MASK) &&
            Pred != (PPC::PRED_EQ & ~PPC::BR_HINT_MASK) &&
            Pred != (PPC::PRED_NE & ~PPC::BR_HINT_MASK)) {
          Safe = false;
          break;
        }
        Users.push_back(&Use);
        if (Users.size() > 16) {
          Safe = false;
          break;
        }
      }
      if (!Safe || Users.size() < 2)
        continue;

      for (MachineInstr *Use : Users) {
        if (Use->getParent() == Cmp->getParent())
          continue;
        // Only split when the saved field competes with another CR0 writer
        // on a path to this use. A comparison that can stay in CR0 without
        // interference should not be duplicated. Bound the CFG walk.
        SmallVector<MachineBasicBlock *, 16> Worklist{Use->getParent()};
        SmallPtrSet<MachineBasicBlock *, 32> Visited;
        bool Interference = false, TooLarge = false;
        while (!Worklist.empty()) {
          auto *BB = Worklist.pop_back_val();
          if (!Visited.insert(BB).second)
            continue;
          if (Visited.size() > 256) {
            TooLarge = true;
            break;
          }
          bool AfterDef = BB != Cmp->getParent();
          for (MachineInstr &MI : *BB) {
            if (&MI == Cmp) {
              AfterDef = true;
              continue;
            }
            if (&MI == Use)
              break;
            if (!AfterDef || MI.isDebugInstr())
              continue;
            if (MI.modifiesRegister(PPC::CR0, &TRI))
              Interference = true;
            if (!MI.isPHI() && !MI.isCopy())
              for (const MachineOperand &MO : MI.operands())
                if (MO.isReg() && MO.isDef() && !MO.isDead() &&
                    MO.getReg().isVirtual() &&
                    (PPC::CRRCRegClass.hasSubClassEq(
                         MRI.getRegClass(MO.getReg())) ||
                     PPC::CRBITRCRegClass.hasSubClassEq(
                         MRI.getRegClass(MO.getReg()))))
                  Interference = true;
          }
          if (BB != Cmp->getParent())
            Worklist.append(BB->pred_begin(), BB->pred_end());
        }
        if (!Interference || TooLarge)
          continue;

        // Keep exactly one GPR input, never replay a load or an instruction
        // with side effects. Even if that input spills, it has an ordinary
        // GPR spill/reload instead of MFCR/STW/LWZ/MTCR0 for a CR field. Do not
        // apply this to register-register compares, which retain two inputs.
        Register NewCR = MRI.createVirtualRegister(MRI.getRegClass(CR));
        MachineInstr *Copy = MF.CloneMachineInstr(Cmp);
        Copy->getOperand(0).setReg(NewCR);
        Copy->getOperand(0).setIsDead(false);
        Copy->getOperand(1).setIsKill(false);
        Copy->setDebugLoc(Use->getDebugLoc());
        Use->getParent()->insert(Use->getIterator(), Copy);
        Use->getOperand(1).setReg(NewCR);
        Use->getOperand(1).setIsKill(true);
        MRI.clearKillFlags(Input);
        MRI.clearKillFlags(CR);
        Changed = true;
      }
      if (MRI.use_nodbg_empty(CR)) {
        MRI.markUsesInDebugValueAsUndef(CR);
        Cmp->eraseFromParent();
      }
    }
    return Changed;
  }
};
} // namespace

char PPCPPE42CRSpill::ID = 0;
INITIALIZE_PASS(PPCPPE42CRSpill, "ppc-ppe42-cr-spill",
                "PPE42 cross-block immediate comparison live ranges", false,
                false)

FunctionPass *llvm::createPPCPPE42CRSpillPass() {
  return new PPCPPE42CRSpill();
}
