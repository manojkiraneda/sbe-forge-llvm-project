//===- PPCPPE42WideCompare.cpp - PPE42 high-word comparisons -------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "PPC.h"
#include "PPCSubtarget.h"
#include "PPCTargetMachine.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include "llvm/InitializePasses.h"
#include "llvm/Pass.h"

using namespace llvm;

namespace {

class PPCPPE42WideCompare : public FunctionPass {
  PPCTargetMachine &TM;

public:
  static char ID;

  explicit PPCPPE42WideCompare(PPCTargetMachine &TM)
      : FunctionPass(ID), TM(TM) {
    initializePPCPPE42WideComparePass(*PassRegistry::getPassRegistry());
  }

  bool runOnFunction(Function &F) override {
    if (!TM.getSubtargetImpl(F)->isPPE42())
      return false;

    bool Changed = false;
    for (BasicBlock &BB : F) {
      for (auto It = BB.begin(); It != BB.end();) {
        auto *Cmp = dyn_cast<ICmpInst>(&*It++);
        if (!Cmp)
          continue;

        Value *Wide = Cmp->getOperand(0);
        auto *Limit = dyn_cast<ConstantInt>(Cmp->getOperand(1));
        ICmpInst::Predicate Pred = Cmp->getPredicate();
        if (!Limit) {
          Limit = dyn_cast<ConstantInt>(Wide);
          Wide = Cmp->getOperand(1);
          Pred = Cmp->getSwappedPredicate();
        }
        if (!Limit || !Wide->getType()->isIntegerTy(64))
          continue;

        uint64_t Bound = Limit->getZExtValue();
        if ((Bound != (1ULL << 32) ||
             (Pred != ICmpInst::ICMP_ULT && Pred != ICmpInst::ICMP_UGE)) &&
            (Bound != 0xffffffffULL ||
             (Pred != ICmpInst::ICMP_ULE && Pred != ICmpInst::ICMP_UGT)))
          continue;

        IRBuilder<> Builder(Cmp);
        Value *High = Builder.CreateTrunc(Builder.CreateLShr(Wide, 32),
                                          Builder.getInt32Ty());
        bool IsZero = Pred == ICmpInst::ICMP_ULT || Pred == ICmpInst::ICMP_ULE;
        Value *NewCmp = IsZero
                            ? Builder.CreateICmpEQ(High, Builder.getInt32(0))
                            : Builder.CreateICmpNE(High, Builder.getInt32(0));
        Cmp->replaceAllUsesWith(NewCmp);
        Cmp->eraseFromParent();
        Changed = true;
      }
    }
    // Keep a branch-only wide relation as control flow instead of selecting
    // two Boolean words and keeping a high-word CR live over a low-word
    // comparison. Freeze each operand once: a split must not choose different
    // values for separate uses of an undef input.
    SmallVector<BranchInst *, 8> Branches;
    if (F.hasOptSize())
      for (BasicBlock &BB : F)
        if (auto *Br = dyn_cast<BranchInst>(BB.getTerminator()))
          if (Br->isConditional())
            Branches.push_back(Br);
    for (BranchInst *Br : Branches) {
      auto *Cmp = dyn_cast<ICmpInst>(Br->getCondition());
      if (!Cmp || !Cmp->hasOneUse() || !Cmp->isRelational() ||
          !Cmp->getOperand(0)->getType()->isIntegerTy(64) ||
          Br->getSuccessor(0) == Br->getSuccessor(1))
        continue;
      BasicBlock *Head = Br->getParent();
      BasicBlock *HighBB = BasicBlock::Create(F.getContext(), "wide.high", &F);
      BasicBlock *LowBB = BasicBlock::Create(F.getContext(), "wide.low", &F);
      IRBuilder<> B(Br);
      B.SetCurrentDebugLocation(Cmp->getDebugLoc());
      Value *L = B.CreateFreeze(Cmp->getOperand(0));
      Value *R = B.CreateFreeze(Cmp->getOperand(1));
      Value *LH = B.CreateTrunc(B.CreateLShr(L, 32), B.getInt32Ty());
      Value *RH = B.CreateTrunc(B.CreateLShr(R, 32), B.getInt32Ty());
      Value *LL = B.CreateTrunc(L, B.getInt32Ty());
      Value *RL = B.CreateTrunc(R, B.getInt32Ty());
      B.CreateCondBr(B.CreateICmpEQ(LH, RH), LowBB, HighBB);
      B.SetInsertPoint(HighBB);
      B.CreateCondBr(B.CreateICmp(Cmp->getPredicate(), LH, RH),
                     Br->getSuccessor(0), Br->getSuccessor(1));
      B.SetInsertPoint(LowBB);
      B.CreateCondBr(B.CreateICmp(Cmp->getUnsignedPredicate(), LL, RL),
                     Br->getSuccessor(0), Br->getSuccessor(1));
      for (BasicBlock *Succ : Br->successors())
        for (PHINode &Phi : Succ->phis()) {
          int Index = Phi.getBasicBlockIndex(Head);
          Value *V = Phi.getIncomingValue(Index);
          Phi.setIncomingBlock(Index, HighBB);
          Phi.addIncoming(V, LowBB);
        }
      Br->eraseFromParent();
      Cmp->eraseFromParent();
      Changed = true;
    }
    return Changed;
  }
};

} // end anonymous namespace

char PPCPPE42WideCompare::ID = 0;

INITIALIZE_PASS(PPCPPE42WideCompare, "ppc-ppe42-wide-compare",
                "PPE42 high-word boundary comparisons", false, false)

FunctionPass *llvm::createPPCPPE42WideComparePass(PPCTargetMachine &TM) {
  return new PPCPPE42WideCompare(TM);
}
