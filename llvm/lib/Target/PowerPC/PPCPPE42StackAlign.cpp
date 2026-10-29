//===-- PPCPPE42StackAlign.cpp - Align local packed objects for PPE42 -------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "PPC.h"
#include "PPCSubtarget.h"
#include "PPCTargetMachine.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/InitializePasses.h"
#include "llvm/Pass.h"

using namespace llvm;

namespace {
class PPCPPE42StackAlign : public FunctionPass {
  PPCTargetMachine &TM;

public:
  static char ID;
  explicit PPCPPE42StackAlign(PPCTargetMachine &TM) : FunctionPass(ID), TM(TM) {
    initializePPCPPE42StackAlignPass(*PassRegistry::getPassRegistry());
  }

  bool runOnFunction(Function &F) override {
    if (skipFunction(F) || !F.hasOptSize() ||
        !TM.getSubtargetImpl(F)->isPPE42())
      return false;
    const DataLayout &DL = F.getDataLayout();
    DenseMap<AllocaInst *, Align> Alignments;
    // A packed type specifies field offsets, not a requirement that its local
    // stack allocation have byte alignment. On strict-alignment PPE42, a word
    // load from such an object otherwise becomes four byte loads and shifts.
    // Only pay for extra alignment when a naturally placed scalar access can
    // use it. Halfword/word alignment adds at most 1/3 bytes of stack padding,
    // and remains below the ABI stack alignment (no stack realignment).
    for (Instruction &I : instructions(F)) {
      Value *Ptr;
      Type *Ty;
      Align OldAlign;
      if (auto *L = dyn_cast<LoadInst>(&I)) {
        if (!L->isSimple())
          continue;
        Ptr = L->getPointerOperand();
        Ty = L->getType();
        OldAlign = L->getAlign();
      } else if (auto *S = dyn_cast<StoreInst>(&I)) {
        if (!S->isSimple())
          continue;
        Ptr = S->getPointerOperand();
        Ty = S->getValueOperand()->getType();
        OldAlign = S->getAlign();
      } else
        continue;
      if (!Ty->isIntegerTy(16) && !Ty->isIntegerTy(32))
        continue;
      Align Required(Ty->getIntegerBitWidth() / 8);
      if (OldAlign >= Required)
        continue;
      int64_t Offset = 0;
      auto *AI = dyn_cast<AllocaInst>(
          GetPointerBaseWithConstantOffset(Ptr, Offset, DL));
      if (!AI || !AI->isStaticAlloca() || AI->isUsedWithInAlloca() ||
          AI->isSwiftError() || AI->getAddressSpace() != DL.getAllocaAddrSpace())
        continue;
      auto *ST = dyn_cast<StructType>(AI->getAllocatedType());
      auto *Count = dyn_cast<ConstantInt>(AI->getArraySize());
      if (!ST || !ST->isPacked() || !ST->isSized() || !Count ||
          !Count->isOne() || Offset < 0 || !isAligned(Required, Offset))
        continue;
      TypeSize Size = DL.getTypeAllocSize(ST);
      if (Size.isScalable() ||
          uint64_t(Offset) + Required.value() > Size.getFixedValue() ||
          AI->getAlign() >= Required)
        continue;
      auto [It, Inserted] = Alignments.try_emplace(AI, Required);
      if (!Inserted)
        It->second = std::max(It->second, Required);
    }
    for (auto [AI, Alignment] : Alignments)
      AI->setAlignment(Alignment);
    // SelectionDAG's pointer-alignment inference propagates the stronger frame
    // alignment to loads/stores before legalization. External and genuinely
    // unaligned packed accesses keep their original alignment and lowering.
    return !Alignments.empty();
  }

  void getAnalysisUsage(AnalysisUsage &AU) const override { AU.setPreservesCFG(); }
};
} // namespace

char PPCPPE42StackAlign::ID = 0;
INITIALIZE_PASS(PPCPPE42StackAlign, "ppc-ppe42-stack-align",
                "PPE42 local packed object alignment", false, false)

FunctionPass *llvm::createPPCPPE42StackAlignPass(PPCTargetMachine &TM) {
  return new PPCPPE42StackAlign(TM);
}
