# Odyssey SPPE size investigation

This change addresses several confirmed backend gaps found in an Odyssey image
comparison. It also records a negative inlining experiment so that a smaller
wrapper is not mistaken for a smaller program. No firmware names or addresses
are encoded in the optimization rules.

## Cached SDA stores

The eight-byte-aligned error-code global is commonly addressed in two ways:

```
r31 = LA r13, @global@sda21
... calls and control flow ...
STW r4, 4(r31)
STW r3, @global@sda21(r13)
```

The value is already in a physical VDR pair. The existing late peephole can
fold this to `STVD d3,@global@sda21(r13)` when the address materialization is
within eight instructions in the same block. The missed case is a cached
address retained in a saved register across calls or blocks, not absence of
all symbolic-store support.

The new fallback proves all reaching definitions of the cached address:

* Only R13-rooted SDA21 global relocations are considered.
* Exact relocation equality is required, including the symbol and addend.
* Full-register copies and nonrecording OR copies can be followed.
* A call may be crossed only while the cached register survives its regmask.
  R13 remains the ABI-reserved SDA base; explicit definitions still reject.
* All predecessor paths must agree. Cycles with unchanged values can close,
  but a matching address definition must be reached somewhere. Conflicting
  loop or diamond definitions reject the fold.
* Limit the search to 64 distinct queries and 1,024 ordinary instructions.
  Failure to prove an address simply preserves the two stores.
* Retain the existing physical-pair, alignment, ordering, volatile/atomic and
  intervening-clobber checks. No scratch register or new allocation is needed.

The image scan found 1,532 syntactically matching stores already using r3:r4,
which represents a gross 6,128-byte instruction budget. This is not a measured
whole-image reduction: individual sites must pass the complete proof and
memory checks, and final layout may change.

## Repeated scalar values in an existing physical pair

An isolated pair of stores of one scalar does not normally justify creating a
VDR: one extra copy plus one STVD costs as much as two STWs. The pre-allocation
pass already amortizes that copy over contiguous runs of multiple pairs.

There is a separate, copy-free missed case after allocation:

```
LI r4, 0
LI r5, 0
STW r4, 220(r1)
STW r4, 216(r1)
```

The supplied `poz_putRingUtils` disassembly contains this case at 0xfff904b0.
The stores can use `STVD d4,216(r1)` because r4:r5 already hold equal values.
The original late matcher only recognized stores explicitly using different
registers for the two words, so it missed this available physical pair.

For equal-source stores, try the existing VDR containing that source in either
half. Prove that the other half equals it using at most 32 ordinary instructions
in the same block. Follow full-register COPY/nonrecording OR copies and compare
32-bit LI/LIS constants. Unknown definitions, undef copies, calls, inline
assembly and control-flow boundaries reject the proof. Register aliases are
checked through the target register information. All existing address and
memory-safety checks still apply, including effective stack alignment when
scalar frame MMOs retain align 4. Recompute the block's dead/kill flags when
the fold extends a neighbour's use; the local proof needs no new live-ins.

Each accepted pair saves exactly one instruction (four bytes), with no extra
copies, materializers, scratch registers or allocation changes. This does not
make all 332 global repeated-value candidates profitable: if no provably equal
neighbour already exists, leave those stores unchanged. No additional
whole-image saving is claimed before testing the rebuilt firmware.

## Larger shared comparison ranges

`initRuntimeConfigEnableBits` reuses immediate comparisons in groups of five,
six and ten branch users. Its CFG also exceeds the original 64-block search
bound. Those cases were outside the original CR-spill pass's four-user limit.

Keep the same transformation and safety requirements, but permit up to sixteen
users and a 256-block predecessor search. Comparisons still need one virtual
GPR input, integer LT/GT/EQ-derived predicates, and actual CR0 interference.
Loads are not replayed, SO tests are excluded, and the source's kill flags are
cleared when its live range is extended. The bounds remain finite and no
register-allocation policy is changed.

A controlled MIR experiment used the matching local firmware frontend output,
the original limits versus the new limits, and the existing older allocator.
It measured 1,368 -> 1,236 bytes (132 saved), with MFCR count 6 -> 0. The
experiment processes compares in order, including newly inserted compares in
subsequent interference checks. These are reproduction measurements, not
execution of the newly compiled C++ pass or whole-firmware savings.

## CCS inlining: preserve the current decision

The small GCC wrapper and large LLVM wrapper alone suggested retaining the
CCS helpers out of line. Testing the matching LLVM translation unit disproved
that proposed fix. Using its saved frontend IR and the existing compiler:

| Policy | All emitted text | Caller-reachable text after section GC |
| --- | ---: | ---: |
| Existing inline decision | 30,140 | 14,664 |
| Retain vector helper | 30,260 | 14,768 |
| Retain port helper | 30,200 | 14,716 |
| Retain both | 30,252 | 14,760 |

The section-GC experiment is a relocatable link rooted at
`execute_concurrent_ccs`; external relocations remain unresolved. It measures
only this object's reachable code, not an executable firmware image.

Forcing sharing saves wrapper bytes but adds larger retained helpers. The
helper is a static template instantiated independently in different translation
units, so similarly named helpers elsewhere in the final disassembly cannot
be counted as one already-shared body. No inlining-policy change is included.
The store and CR fixes reduce actual instruction overhead without imposing
this measured 52-104-byte reachable-code regression.

## Validation

### Follow-up after the first firmware rebuild

The first PR63 image shrank by 4,312 bytes, but 511 of 640 remaining
syntactic SDA store candidates reloaded their address from a stack slot.
The late address proof deliberately cannot treat arbitrary stack memory as
an immutable pointer. Normalize the SSA address before it can spill instead:

* Follow up to eight full-register COPY/constant-ADDI definitions to an
  R13-rooted LA with an exact SDA21 global relocation.
* Fold the displacement into the global addend, checking signed overflow,
  signed displacement range and declared object bounds.
  Rewrite LWZ/STW/LVD/STVD addresses directly; the access and its MMOs stay
  at the same program point, including ordered accesses.
* Reject the invariant if any instruction explicitly changes R13. Calls
  preserve the reserved base by ABI, but explicit call definitions also reject.
* Remove only unused pure address chains, and invalidate their debug uses.
  Address uses that escape to other instructions remain intact.
* Recognize normalized global/global+4 operands in both pre-RA load pairing
  and late physical load/store pairing. Alignment and volatile/atomic guards
  still control whether accesses can be widened.

A controlled reproduction of the matching PHY function normalized 148 memory
operands and removed its otherwise-spilled SDA pointer. Using the same older
allocator, text went from 12,280 to 11,752 bytes after normalization, then to
11,248 with 125 physical store folds and one load fold: 1,032 bytes saved.
The older allocator emits different absolute code sizes from the installed
firmware compiler; this comparison isolates the transformation, not final
image size. The experiment models the new rewrite on saved MIR, not execution
of newly compiled C++. To capture SDA lowering with stop-before, the saved
frontend declaration was assigned its existing SBSS section explicitly: the
shortened pipeline otherwise omits AsmPrinter's module-metadata initialization.

Three smaller follow-ups address the other observed patterns without changing
the inliner or general select cost policy:

* Fold a strict conditional-OR diamond after allocation: hoist its common
  base copy, invert the CR branch, and remove the copy block/unconditional
  jump. Require single-entry copy/update arms, exact source/destination
  agreement, no extra instructions, and no EH/address-taken arms. Update CFG
  edges and liveness. This saves one branch in each accepted diamond; it is
  not a claim that all materialized booleans are removable.
* Fold an adjacent in-place ADDI and LVD/STVD into an update-form operation,
  including pairs formed late with two MMOs. Reject ordered accesses, frame
  operations, R0/R1/R13 updates, mismatched offsets and value/base overlap.
  Do not introduce a compensating copy or scratch register.
* Reuse a repeated scalar tuple across short gaps in struct zeroing, without
  moving the stores past other memory accesses. Keep the range within one
  block, stop at calls/terminators/asm/clobbers, and require three pairs when
  gaps are used so two setup instructions can be amortized. Existing contiguous
  two-pair cases retain their original eligibility.
* Handle a single zero pair in a canonical counted self-loop when the body is
  only the pointer PHI, an early increment, the two stores and loop branches.
  Initialize a dedicated zero tuple in the unique preheader and replace the
  increment/stores with STVDU, removing the loop-carried pointer copy during
  allocation. Reject nonzero inputs, extra accesses, calls and other uses of
  the old pointer. This is a bounded code-shape rule, not general loop unrolling.
  A controlled old-allocator fixture shrank from 44 to 40 bytes even before
  dropping its now-unused original zero materializer. Count setup bytes when
  assessing this optimization; the smaller loop body alone overstates savings.

New MIR tests cover these rewrites and negative cases, with verified complete
object emission in CI. Local compatibility runs checked inputs and constructed
expected outputs. The older llc lacks SDA21 parsing and has obsolete LVDU/
STVDU memory flags, so temporary compatibility outputs use LO spelling and
omit update MMOs only for that older verifier; repository tests retain the
actual SDA21 operands and all MMOs. No local LLVM build or download was used.

CI runs positive/negative cached-address MIR cases and complete object emission,
plus comparison tests with ten users, an eighty-block range, and a seventeen-
user negative bound. Existing SO, physical-input and noninterference cases
remain in the suite.

Equal-value store tests cover positive constant/copy cases, reversed stores,
either source half, dead-neighbour liveness, stack MMOs and SDA addressing.
Negative cases cover unequal/unknown values, alias clobbers, undef copies,
call/search boundaries, nonconsecutive addresses, volatile/atomic stores and
insufficient alignment. The existing local llc verifies their input forms and
emits manually constructed expected outputs; it cannot execute the new C++
equality proof. The added CI test exercises that implementation.

The existing older local llc lacks the SDA21 MIR flag; the cached-address test
inputs and manually constructed expected outputs were verified and emitted
with its equivalent LO operand spelling for compatibility. This validates
fixture structure and machine instructions, not execution of the new address
proof. CI must build and exercise the actual new implementation. LLVM was not
built locally and no toolchain was downloaded.
