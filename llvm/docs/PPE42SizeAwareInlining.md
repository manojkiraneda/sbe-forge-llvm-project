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
| At least two eligible direct call sites share the callee | Amortize one out-of-line body. Sites in other size-optimized, non-leaf callers can contribute. |
| The helper meets either the existing four-call rule or the refined size threshold below | Keep sizable shared work while preserving the original QME decision. |

The original rule still applies when one caller contains at least four calls: four side-effecting inline-assembly call sites retain the helper, or its body meets `B >= 5` and `(N - 1) * B > 4 * N + 2`, where `N` is that caller's call count and `B` counts non-PHI, non-debug, non-lifetime IR instructions. This retains the previously established QME policy.

The additional rule uses `S`, the number of eligible calls across size-optimized non-leaf callers, and `D`, an estimate of machine instructions duplicated by inlining. It requires `S >= 2`, `D >= 6`, and `(S - 1) * D > 4 * S + 6`. The six-instruction margin allows for simplifications exposed by inlining. PHIs, allocas, returns, and ordinary nested calls do not contribute to `D`; their cost is not duplicated in the same way. Each 64-bit add, subtract, bitwise operation, or integer compare counts as two instructions; a 64-bit shift counts as three; and 64-bit multiply, divide, or remainder counts as four. Other instructions, including inline assembly, count as one. This is still an estimate: it does not inspect final register allocation, exact call-frame cost, branch distance, or machine instruction count.

A single-call helper is retained when a separate `noinline` or `optnone` use already keeps its out-of-line body alive and `D > 10`. A local helper with only one visible use remains eligible for inlining. Outlining such helpers based on their IR size alone increased Odyssey `.text` by 2,256 bytes: the newly emitted `mss::poll` bodies outweighed the savings at their call sites. The rule preserves the existing four-call QME decision.

For example, the resulting `ppe42_app_ctx_set` body in QME has six hardware or bit-manipulation instructions plus `blr`. A call site uses `bl` instead of copying the body, though surrounding register and stack code can change. Keeping the helper may therefore save bytes across repeated calls, but the exact saving depends on subsequent optimization and linking.

## Scope and trade-offs

- Calls in other size-optimized non-leaf callers can help meet the refined threshold. A leaf caller itself still goes through the ordinary inliner.
- A small one-use helper or a helper below the relevant body thresholds goes through the ordinary inliner. Two calls alone do not force outlining.
- Normal optimization priorities remain in effect outside size builds. Retaining the helper adds a call and return at each site, so it may cost cycles.
- The rule makes no whole-program size guarantee. Other inlining decisions, code layout, and link-time padding can offset its savings. It should be treated as a targeted correction to a known size blind spot, not a general estimate of compiled bytes.

## Evidence and validation

`llvm/test/Transforms/Inline/PowerPC/ppe42-size-shared-asm.ll` checks the original four-call behavior. `ppe42-size-shared-wide.ll` covers two calls, calls shared across callers, 64-bit costs, tiny helpers, and leaf callers. `ppe42-size-retained-helper.ll` covers a retained body and a local single-use helper that may inline. The PPE42 toolchain workflow runs these tests remotely. No local compilation was performed for this work.

In the QME samples examined on October 7, 2026, `pm/artifacts/qme.dis` contains one out-of-line `ppe42_app_ctx_set` body and 56 calls to it. The matching Downloads `qme (1).dis` contains no such calls. The artifacts disassembly has 14 fewer instructions overall, but both corresponding `qme.bin` files are 77,968 bytes. These samples demonstrate that the decision changed code generation; they do not isolate PR #47's byte contribution from other build differences.

## Code locations

- `llvm/lib/Target/PowerPC/PPCTargetTransformInfo.cpp`: PPE42 decision rule.
- `llvm/lib/Analysis/InlineCost.cpp`: inliner use of the target hook.
- `llvm/include/llvm/Analysis/TargetTransformInfo.h`: public hook contract.
- `llvm/test/Transforms/Inline/PowerPC/ppe42-size-shared-asm.ll`: behavior checks.
- `llvm/test/Transforms/Inline/PowerPC/ppe42-size-shared-wide.ll`: expanded cost-rule checks.
- `llvm/test/Transforms/Inline/PowerPC/ppe42-size-retained-helper.ll`: retained and single-use local helper checks.
