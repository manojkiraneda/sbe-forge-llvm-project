# Odyssey SPPE size investigation

This change addresses three confirmed backend gaps found in an Odyssey image
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
