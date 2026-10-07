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
    bool Changed = false;
    for (MachineBasicBlock &MBB : MF) {
      for (auto I = MBB.begin(); I != MBB.end();) {
        MachineInstr &HiStore = *I++;
        if (HiStore.getOpcode() != PPC::STW ||
            HiStore.getNumOperands() != 3 || !HiStore.hasOneMemOperand() ||
            !HiStore.getOperand(0).isReg() ||
            !HiStore.getOperand(1).isImm() ||
            !HiStore.getOperand(2).isReg())
          continue;

        auto Next = I;
        while (Next != MBB.end() && Next->isDebugInstr())
          ++Next;
        if (Next == MBB.end())
          continue;
        MachineInstr &LoStore = *Next;
        if (LoStore.getOpcode() != PPC::STW ||
            LoStore.getNumOperands() != 3 || !LoStore.hasOneMemOperand() ||
            !LoStore.getOperand(0).isReg() ||
            !LoStore.getOperand(1).isImm() ||
            !LoStore.getOperand(2).isReg())
          continue;

        Register Hi = HiStore.getOperand(0).getReg();
        Register Lo = LoStore.getOperand(0).getReg();
        int64_t Offset = HiStore.getOperand(1).getImm();
        Register Base = HiStore.getOperand(2).getReg();
        if (!Hi.isVirtual() || !Lo.isVirtual() || Hi == Lo ||
            !MRI.hasOneNonDBGUse(Hi) || !MRI.hasOneNonDBGUse(Lo) ||
            !isInt<16>(Offset) || !isInt<16>(Offset + 4) ||
            LoStore.getOperand(1).getImm() != Offset + 4 ||
            Base != LoStore.getOperand(2).getReg())
          continue;

        MachineMemOperand *HiMem = *HiStore.memoperands_begin();
        MachineMemOperand *LoMem = *LoStore.memoperands_begin();
        if (!HiMem->isStore() || !LoMem->isStore() ||
            HiMem->isVolatile() || LoMem->isVolatile() ||
            HiMem->isAtomic() || LoMem->isAtomic() ||
            HiMem->getAlign() < Align(8) || LoMem->getAlign() < Align(4))
          continue;

        // A REG_SEQUENCE gives the allocator a chance to place both source
        // words in one VDR tuple. Restrict this to their final uses: otherwise
        // the extra copies could outweigh the saved store instruction.
        Register Pair = MRI.createVirtualRegister(&PPC::VDRCRegClass);
        BuildMI(MBB, HiStore, HiStore.getDebugLoc(),
                TII.get(TargetOpcode::REG_SEQUENCE), Pair)
            .addReg(Hi)
            .addImm(PPC::sub_gpr_hi)
            .addReg(Lo)
            .addImm(PPC::sub_gpr_lo);
        BuildMI(MBB, HiStore, HiStore.getDebugLoc(), TII.get(PPC::STVD))
            .addReg(Pair, RegState::Kill)
            .addImm(Offset)
            .addReg(Base, LoStore.getOperand(2).isKill() ? RegState::Kill : 0)
            .addMemOperand(HiMem)
            .addMemOperand(LoMem);
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
