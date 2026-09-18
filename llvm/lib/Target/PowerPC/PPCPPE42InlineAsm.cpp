//===-- PPCPPE42InlineAsm.cpp - PPE42 asm register pairs
//--------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// PPE42 keeps i64 illegal in SelectionDAG. Inline asm lowering therefore
// represents an i64 "r" operand with two independent i32 virtual registers.
// Before register allocation, combine these into a VDR tuple so that both
// halves are consecutive and participate in interference and clobber checks.
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
#include "llvm/IR/InlineAsm.h"

using namespace llvm;

#define DEBUG_TYPE "ppc-ppe42-inline-asm"

namespace {
class PPCPPE42InlineAsm : public MachineFunctionPass {
public:
  static char ID;
  PPCPPE42InlineAsm() : MachineFunctionPass(ID) {}

  StringRef getPassName() const override {
    return "PPE42 inline assembly register pairs";
  }

  bool runOnMachineFunction(MachineFunction &MF) override;
};
} // namespace

bool PPCPPE42InlineAsm::runOnMachineFunction(MachineFunction &MF) {
  const auto &ST = MF.getSubtarget<PPCSubtarget>();
  if (!ST.isPPE42())
    return false;

  MachineRegisterInfo &MRI = MF.getRegInfo();
  const auto &TII = *ST.getInstrInfo();
  const auto &TRI = *ST.getRegisterInfo();
  bool Changed = false;

  for (MachineBasicBlock &MBB : MF) {
    for (MachineInstr &MI : make_early_inc_range(MBB)) {
      if (!MI.isInlineAsm())
        continue;

      // Record operand groups first: matching constraints refer to group
      // numbers, not machine operand indices. Explicit physical registers and
      // clobbers must retain their original meaning.
      SmallVector<unsigned> Groups;
      SmallVector<bool> Pair;
      unsigned End = InlineAsm::MIOp_FirstOperand;
      while (End < MI.getNumOperands() && MI.getOperand(End).isImm()) {
        InlineAsm::Flag F(MI.getOperand(End).getImm());
        unsigned RC, Matched;
        bool IsPair = F.getNumOperandRegisters() == 2 &&
                      (F.isRegUseKind() || F.isRegDefKind() ||
                       F.isRegDefEarlyClobberKind());
        if (IsPair) {
          if (F.isUseOperandTiedToDef(Matched))
            IsPair = Pair[Matched];
          else
            IsPair = F.hasRegClassConstraint(RC) && RC == PPC::GPRCRegClassID;
          for (unsigned J = 1; IsPair && J <= 2; ++J)
            IsPair = MI.getOperand(End + J).isReg() &&
                     MI.getOperand(End + J).getReg().isVirtual();
        }
        Groups.push_back(End);
        Pair.push_back(IsPair);
        End += 1 + F.getNumOperandRegisters();
      }
      if (!is_contained(Pair, true))
        continue;

      auto NewMI = BuildMI(MBB, MI, MI.getDebugLoc(), TII.get(MI.getOpcode()));
      NewMI->setFlags(MI.getFlags());
      NewMI.cloneMemRefs(MI);
      for (unsigned I = 0; I < InlineAsm::MIOp_FirstOperand; ++I)
        NewMI.add(MI.getOperand(I));

      SmallVector<unsigned> NewGroups;
      struct Output {
        Register Word;
        Register Tuple;
        unsigned SubReg;
      };
      SmallVector<Output> Outputs;
      for (unsigned G = 0; G < Groups.size(); ++G) {
        unsigned I = Groups[G];
        InlineAsm::Flag F(MI.getOperand(I).getImm());
        unsigned NumRegs = F.getNumOperandRegisters();
        NewGroups.push_back(NewMI->getNumOperands());
        unsigned Matched;
        bool Tied = F.isUseOperandTiedToDef(Matched);
        if (!Pair[G]) {
          for (unsigned J = 0; J <= NumRegs; ++J)
            NewMI.add(MI.getOperand(I + J));
        } else {
          Register Tuple = MRI.createVirtualRegister(&PPC::VDRCRegClass);
          InlineAsm::Flag NewF(F.getKind(), 1);
          NewF.setRegMayBeFolded(F.getRegMayBeFolded());
          if (Tied)
            NewF.setMatchingOp(Matched);
          else
            NewF.setRegClass(PPC::VDRCRegClassID);
          NewMI.addImm(NewF);

          // The generic asm lowering orders the words according to endianness.
          unsigned First =
              ST.isLittleEndian() ? PPC::sub_gpr_lo : PPC::sub_gpr_hi;
          unsigned Second =
              ST.isLittleEndian() ? PPC::sub_gpr_hi : PPC::sub_gpr_lo;
          if (F.isRegUseKind()) {
            BuildMI(MBB, *NewMI, MI.getDebugLoc(),
                    TII.get(TargetOpcode::REG_SEQUENCE), Tuple)
                .add(MI.getOperand(I + 1))
                .addImm(First)
                .add(MI.getOperand(I + 2))
                .addImm(Second);
            NewMI.addReg(Tuple);
          } else {
            unsigned Flags = RegState::Define;
            if (F.isRegDefEarlyClobberKind())
              Flags |= RegState::EarlyClobber;
            NewMI.addReg(Tuple, Flags);
            Outputs.push_back({MI.getOperand(I + 1).getReg(), Tuple, First});
            Outputs.push_back({MI.getOperand(I + 2).getReg(), Tuple, Second});
          }
          NumRegs = 1;
        }
        if (Tied)
          for (unsigned J = 0; J < NumRegs; ++J)
            NewMI->tieOperands(NewGroups[Matched] + 1 + J,
                               NewGroups[G] + 1 + J);
      }
      // Preserve implicit operands and metadata after the operand groups.
      for (unsigned I = End; I < MI.getNumOperands(); ++I)
        NewMI.add(MI.getOperand(I));

      // Replace uses directly, including PHIs on asm-goto successors. Inserting
      // extraction copies after INLINEASM_BR would put them after a terminator.
      for (const Output &O : Outputs)
        for (MachineOperand &Use :
             make_early_inc_range(MRI.use_operands(O.Word))) {
          Use.substVirtReg(O.Tuple, O.SubReg, TRI);
          if (!Use.isDebug())
            Use.setIsKill(false);
        }

      MI.eraseFromParent();
      Changed = true;
    }
  }
  return Changed;
}

INITIALIZE_PASS(PPCPPE42InlineAsm, DEBUG_TYPE,
                "PPE42 inline assembly register pairs", false, false)

char PPCPPE42InlineAsm::ID = 0;
FunctionPass *llvm::createPPCPPE42InlineAsmPass() {
  return new PPCPPE42InlineAsm();
}
