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
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/InitializePasses.h"
#include "llvm/Pass.h"
#include "llvm/Support/MathExtras.h"

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
    // PPC32 byval copies have word-aligned outgoing storage even when the
    // source type only requires byte/halfword alignment. Align local sources
    // as well, without changing the type layout or the call's ABI attributes.
    for (Instruction &I : instructions(F)) {
      auto *CB = dyn_cast<CallBase>(&I);
      if (!CB)
        continue;
      for (unsigned A = 0; A != CB->arg_size(); ++A) {
        Type *ByValTy = CB->getParamByValType(A);
        if (!ByValTy || !ByValTy->isSized())
          continue;
        TypeSize CopySize = DL.getTypeAllocSize(ByValTy);
        if (CopySize.isScalable() || CopySize.getFixedValue() < 4)
          continue;
        int64_t Offset = 0;
        auto *AI = dyn_cast<AllocaInst>(
            GetPointerBaseWithConstantOffset(CB->getArgOperand(A), Offset, DL));
        if (!AI || !AI->isStaticAlloca() || AI->isUsedWithInAlloca() ||
            AI->isSwiftError() ||
            AI->getAddressSpace() != DL.getAllocaAddrSpace() || Offset < 0 ||
            !isAligned(Align(4), Offset) || AI->getAlign() >= Align(4))
          continue;
        auto *ST = dyn_cast<StructType>(AI->getAllocatedType());
        auto *Count = dyn_cast<ConstantInt>(AI->getArraySize());
        if (!ST || !ST->isSized() || !Count || !Count->isOne())
          continue;
        TypeSize Size = DL.getTypeAllocSize(ST);
        if (Size.isScalable() || uint64_t(Offset) > Size.getFixedValue() ||
            CopySize.getFixedValue() > Size.getFixedValue() - uint64_t(Offset))
          continue;
        Alignments[AI] = Align(4);
      }
    }
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
          AI->isSwiftError() ||
          AI->getAddressSpace() != DL.getAllocaAddrSpace())
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
    bool Changed = !Alignments.empty();
    SmallVector<MemSetInst *, 8> ZeroFills;
    for (Instruction &I : instructions(F))
      if (auto *MS = dyn_cast<MemSetInst>(&I))
        ZeroFills.push_back(MS);
    for (MemSetInst *MS : ZeroFills) {
      auto *ByteValue = dyn_cast<ConstantInt>(MS->getValue());
      auto *Length = dyn_cast<ConstantInt>(MS->getLength());
      if (MS->isVolatile() || !ByteValue || !ByteValue->isZero() || !Length ||
          Length->getValue().ugt(16) || Length->getValue().ult(4))
        continue;
      uint64_t Bytes = Length->getZExtValue();
      int64_t Offset = 0;
      auto *AI = dyn_cast<AllocaInst>(
          GetPointerBaseWithConstantOffset(MS->getDest(), Offset, DL));
      if (!AI || !AI->isStaticAlloca() || AI->isUsedWithInAlloca() ||
          AI->isSwiftError() ||
          AI->getAddressSpace() != DL.getAllocaAddrSpace() || Offset < 0 ||
          AI->getAlign() < Align(4) || !AI->getAllocatedType()->isSized())
        continue;
      auto *Count = dyn_cast<ConstantInt>(AI->getArraySize());
      TypeSize Size = DL.getTypeAllocSize(AI->getAllocatedType());
      if (!Count || !Count->isOne() || Size.isScalable() ||
          uint64_t(Offset) > Size.getFixedValue() ||
          Bytes > Size.getFixedValue() - uint64_t(Offset))
        continue;
      // An odd interior offset hides the word alignment of later bytes from
      // generic memset expansion. Peel only within this small local object;
      // never overstore padding outside the requested range.
      Align StartAlign = std::max(commonAlignment(AI->getAlign(), Offset),
                                  MS->getDestAlign().valueOrOne());
      if (StartAlign >= Align(4))
        continue;
      SmallVector<unsigned, 16> Widths;
      for (unsigned Written = 0; Written < Bytes;) {
        unsigned Width = 4;
        while (Width > Bytes - Written ||
               commonAlignment(AI->getAlign(), uint64_t(Offset) + Written) < Align(Width))
          Width /= 2;
        Widths.push_back(Width);
        Written += Width;
      }
      if (Widths.size() >= divideCeil(Bytes, StartAlign.value()))
        continue;
      IRBuilder<> B(MS);
      unsigned Written = 0;
      for (unsigned Width : Widths) {
        Type *Ty = B.getIntNTy(Width * 8);
        Value *Ptr =
            B.CreateConstGEP1_32(B.getInt8Ty(), MS->getDest(), Written);
        B.CreateAlignedStore(ConstantInt::get(Ty, 0), Ptr, Align(Width));
        Written += Width;
      }
      MS->eraseFromParent();
      Changed = true;
    }
    // SelectionDAG's pointer-alignment inference propagates the stronger frame
    // alignment to loads/stores before legalization. External and genuinely
    // unaligned packed accesses keep their original alignment and lowering.
    return Changed;
  }

  void getAnalysisUsage(AnalysisUsage &AU) const override {
    AU.setPreservesCFG();
  }
};
} // namespace

char PPCPPE42StackAlign::ID = 0;
INITIALIZE_PASS(PPCPPE42StackAlign, "ppc-ppe42-stack-align",
                "PPE42 local packed object alignment", false, false)

FunctionPass *llvm::createPPCPPE42StackAlignPass(PPCTargetMachine &TM) {
  return new PPCPPE42StackAlign(TM);
}
