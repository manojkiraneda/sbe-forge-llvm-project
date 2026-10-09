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

  explicit PPCPPE42WideCompare(PPCTargetMachine &TM) : FunctionPass(ID), TM(TM) {
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
        Value *High = Builder.CreateTrunc(
            Builder.CreateLShr(Wide, 32), Builder.getInt32Ty());
        bool IsZero = Pred == ICmpInst::ICMP_ULT || Pred == ICmpInst::ICMP_ULE;
        Value *NewCmp = IsZero ? Builder.CreateICmpEQ(High, Builder.getInt32(0))
                               : Builder.CreateICmpNE(High, Builder.getInt32(0));
        Cmp->replaceAllUsesWith(NewCmp);
        Cmp->eraseFromParent();
        Changed = true;
      }
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
