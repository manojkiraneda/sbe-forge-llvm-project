# PPE42 size-aware inlining decision

This document describes the inlining rule introduced in [PR #47](https://github.com/manojkiraneda/sbe-forge-llvm-project/pull/47) and extended to ordinary repeated helpers. It applies to PPE42 code compiled for size. Its immediate motivation was `ppe42_app_ctx_set`: inlining its hardware-register sequence at many call sites duplicated instructions that could be shared in one function.

## Where the decision runs

The ordinary LLVM inliner asks `getInlineCost` whether to inline each direct call. PR #47 adds `TargetTransformInfo::preferCallForCodeSize(Call, Callee)`. Its default implementation returns `false`, so other targets retain their existing decisions. PowerPC implements the hook in `PPCTTIImpl`. When it returns `true`, `getInlineCost` returns `InlineCost::getNever("shared call is smaller on this target")` before the ordinary cost calculation. Explicit user inlining decisions are handled earlier in `getInlineCost`.

This is a **Boolean size heuristic**, not a byte-accurate cost formula. A `false` result means the ordinary inliner continues; it does not require inlining.

## Decision rule

The PowerPC hook keeps a call only when **all** of these conditions hold:

| Condition | Reason |
| --- | --- |
| Target subtarget is PPE42 and the caller has `optsize` | Limit the rule to PPE42 size builds (`-Os`/`-Oz` when they set this attribute). |
| The call directly names a defined, `dso_local` callee | Keep the analysis within a known, non-preemptible function. This includes externally visible firmware helpers. |
| The callee has at most three arguments and is not the caller | Limit argument setup costs and avoid blocking recursive-call handling. |
| The caller contains another direct, non-intrinsic function call | The caller is already non-leaf, so retaining this helper call is less likely to add a new link-register save. |
| The same caller contains at least four direct call sites to this callee | Amortize one shared helper body across repeated uses. |
| The callee contains at least four side-effecting inline-assembly **call sites** with nonempty assembly strings, or its body meets the repeated-work threshold below | Keep sizable shared work, including ordinary C helpers. |

For an ordinary helper, let `N` be the number of calls in the caller and `B` the number of non-PHI, non-debug, non-lifetime IR instructions in the helper. The hook requires `B >= 5` and `(N - 1) * B > 4 * N + 2`. This approximates the duplicated body against calls and a shared return. The implementation counts inline-assembly IR calls, not parsed machine instructions. One assembly string may emit more than one instruction. These thresholds are fixed heuristics; the hook does not inspect final register allocation, exact call-frame cost, branch distance, or machine instruction count.

For example, the resulting `ppe42_app_ctx_set` body in QME has six hardware or bit-manipulation instructions plus `blr`. A call site uses `bl` instead of copying the body, though surrounding register and stack code can change. Keeping the helper may therefore save bytes across repeated calls, but the exact saving depends on subsequent optimization and linking.

## Scope and trade-offs

- The rule is evaluated per caller and callee. Four calls spread across four different callers do not satisfy the repeated-call condition.
- A leaf caller, a helper used fewer than four times by that caller, or a helper below both body thresholds goes through the ordinary inliner.
- Normal optimization priorities remain in effect outside size builds. Retaining the helper adds a call and return at each site, so it may cost cycles.
- The rule makes no whole-program size guarantee. Other inlining decisions, code layout, and link-time padding can offset its savings. It should be treated as a targeted correction to a known size blind spot, not a general estimate of compiled bytes.

## Evidence and validation

`llvm/test/Transforms/Inline/PowerPC/ppe42-size-shared-asm.ll` checks repeated assembly and ordinary helpers at `-Os`, inlining at `-O2`, and cases below the threshold. The PPE42 toolchain workflow runs this test remotely. No local compilation was performed for this work.

In the QME samples examined on October 7, 2026, `pm/artifacts/qme.dis` contains one out-of-line `ppe42_app_ctx_set` body and 56 calls to it. The matching Downloads `qme (1).dis` contains no such calls. The artifacts disassembly has 14 fewer instructions overall, but both corresponding `qme.bin` files are 77,968 bytes. These samples demonstrate that the decision changed code generation; they do not isolate PR #47's byte contribution from other build differences.

## Code locations

- `llvm/lib/Target/PowerPC/PPCTargetTransformInfo.cpp`: PPE42 decision rule.
- `llvm/lib/Analysis/InlineCost.cpp`: inliner use of the target hook.
- `llvm/include/llvm/Analysis/TargetTransformInfo.h`: public hook contract.
- `llvm/test/Transforms/Inline/PowerPC/ppe42-size-shared-asm.ll`: behavior checks.
