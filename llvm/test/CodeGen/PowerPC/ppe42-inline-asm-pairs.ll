; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -verify-machineinstrs < %s | FileCheck %s
; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -O0 -verify-machineinstrs < %s -o /dev/null
; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -verify-machineinstrs -filetype=obj < %s -o /dev/null
; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -verify-machineinstrs -stop-after=ppc-ppe42-inline-asm < %s | FileCheck %s --check-prefix=MIR

; The argument is already in r5:r6. The tied early-clobber operand must be
; allocatable as d5, rather than requiring copies into a fixed d8.
define i32 @putscom_abs(i32 %address, i64 %data) {
; CHECK-LABEL: putscom_abs:
; CHECK-NOT: mr
; CHECK: stvd d5, 0(3)
; CHECK: mfmsr 3
; CHECK: rlwinm 3, 3, 12, 29, 31
; CHECK: blr
; MIR-LABEL: name: putscom_abs
; MIR: [[INPUT:%[0-9]+]]:vdrc = REG_SEQUENCE {{.*}}, %subreg.sub_gpr_hi, {{.*}}, %subreg.sub_gpr_lo
; MIR: INLINEASM &"stvd $0, 0($2)"{{.*}}regdef-ec:VDRC{{.*}}def early-clobber [[OUTPUT:%[0-9]+]], {{.*}}reguse tiedto:$0{{.*}}[[INPUT]](tied-def 3)
  %unused = call i64 asm sideeffect "stvd $0, 0($2)", "=&r,0,b,~{memory}"(i64 %data, i32 %address)
  %msr = call i32 asm sideeffect "mfmsr $0", "=r"()
  %shift = lshr i32 %msr, 20
  %rc = and i32 %shift, 7
  ret i32 %rc
}

; Two distinct 64-bit inputs must not both be assigned to the same fixed pair.
define void @two_inputs(i32 %address, i64 %a, i64 %b) {
; CHECK-LABEL: two_inputs:
; CHECK: stvd d5, 0(3)
; CHECK: stvd d7, 8(3)
; MIR-LABEL: name: two_inputs
; MIR: [[A:%[0-9]+]]:vdrc = REG_SEQUENCE
; MIR: [[B:%[0-9]+]]:vdrc = REG_SEQUENCE
; MIR: INLINEASM &"stvd $0, 0($2); stvd $1, 8($2)"{{.*}}reguse:VDRC{{.*}}[[A]], {{.*}}reguse:VDRC{{.*}}[[B]],
  call void asm sideeffect "stvd $0, 0($2); stvd $1, 8($2)", "r,r,b,~{memory}"(i64 %a, i64 %b, i32 %address)
  ret void
}

; Both output words must be extracted from the tuple in big-endian order.
define i64 @load(i32 %address) {
; CHECK-LABEL: load:
; CHECK: lvd d{{[0-9]+}}, 0(3)
; MIR-LABEL: name: load
; MIR: INLINEASM &"lvd $0, 0($1)"{{.*}}regdef:VDRC{{.*}}def [[LOAD:%[0-9]+]],
; MIR-DAG: COPY [[LOAD]].sub_gpr_hi
; MIR-DAG: COPY [[LOAD]].sub_gpr_lo
  %v = call i64 asm sideeffect "lvd $0, 0($1)", "=r,b"(i32 %address)
  ret i64 %v
}

; The early-clobber tuple must interfere with both input words and the address.
define i64 @early_clobber(i32 %address, i64 %input) {
; CHECK-LABEL: early_clobber:
; CHECK: lvd d{{[0-9]+}}, 0(3)
; CHECK: stvd d5, 8(3)
; MIR-LABEL: name: early_clobber
; MIR: [[ECIN:%[0-9]+]]:vdrc = REG_SEQUENCE
; MIR: INLINEASM &"lvd $0, 0($2); stvd $1, 8($2)"{{.*}}regdef-ec:VDRC{{.*}}def early-clobber {{%[0-9]+}}, {{.*}}reguse:VDRC{{.*}}[[ECIN]],
  %v = call i64 asm sideeffect "lvd $0, 0($2); stvd $1, 8($2)", "=&r,r,b,~{memory}"(i64 %input, i32 %address)
  ret i64 %v
}

; The L modifier must still name the second word after replacing two machine
; operands with one tuple. Assembling to an object also checks the syntax.
define i64 @word_modifier(i64 %input) {
; CHECK-LABEL: word_modifier:
; CHECK: #APP
; CHECK-NEXT: mr {{[0-9]+}}, {{[0-9]+}}
; CHECK-NEXT: mr {{[0-9]+}}, {{[0-9]+}}
; CHECK-NEXT: #NO_APP
  %v = call i64 asm "mr $0, $1; mr ${0:L}, ${1:L}", "=&r,r"(i64 %input)
  ret i64 %v
}

; Keep tuples live over a call, exercising callee-saved allocation and copies.
define i64 @across_call(i32 %address) {
; CHECK-LABEL: across_call:
; CHECK: lvd d{{[0-9]+}}, 0({{[0-9]+}})
; CHECK: bl callee
; CHECK: stvd d{{[0-9]+}}, 0({{[0-9]+}})
  %v = call i64 asm sideeffect "lvd $0, 0($1)", "=r,b"(i32 %address)
  call void @callee()
  call void asm sideeffect "stvd $0, 0($1)", "r,b,~{memory}"(i64 %v, i32 %address)
  ret i64 %v
}

; Reserve the second half of the incoming d5 explicitly. Allocation must move
; the pair, not just its first word, away from this clobber.
define void @clobber_low_word(i32 %address, i64 %input) {
; CHECK-LABEL: clobber_low_word:
; CHECK-NOT: stvd d5,
; CHECK-NOT: stvd d6,
; CHECK: stvd d{{[0-9]+}}, 0({{[0-9]+}})
  call void asm sideeffect "stvd $0, 0($1)", "r,b,~{r6},~{memory}"(i64 %input, i32 %address)
  ret void
}

; A live pointer in r4 must not be overwritten by the low half of a load into
; d3. The tuple model exposes that interference to the allocator.
define void @live_pointer(i32 %address, ptr %output) {
; CHECK-LABEL: live_pointer:
; CHECK: lvd d[[LIVEPAIR:[0-9]+]], 0(3)
; CHECK: stvd d[[LIVEPAIR]], 0(4)
  %v = call i64 asm sideeffect "lvd $0, 0($1)", "=r,b"(i32 %address)
  call void asm sideeffect "stvd $0, 0($1)", "r,b,~{memory}"(i64 %v, ptr %output)
  ret void
}

; Clobber every allocatable GPR while a loaded value remains live. The backend
; must spill and reload it correctly, including when allocated as a VDR tuple.
define i64 @spill_pair(i32 %address) {
; CHECK-LABEL: spill_pair:
; CHECK: lvd d{{[0-9]+}}, 0(3)
; CHECK: blr
  %v = call i64 asm sideeffect "lvd $0, 0($1)", "=r,b"(i32 %address)
  call void asm sideeffect "", "~{r0},~{r3},~{r4},~{r5},~{r6},~{r7},~{r8},~{r9},~{r10},~{r28},~{r29},~{r30},~{r31}"()
  call void asm sideeffect "stvd $0, 0($1)", "r,b,~{memory}"(i64 %v, i32 4096)
  ret i64 %v
}

; Outputs of asm goto must be usable on both successors without placing
; extraction instructions after INLINEASM_BR.
define i64 @branch_output(i32 %address) {
; MIR-LABEL: name: branch_output
; MIR: INLINEASM_BR {{.*}}regdef:VDRC
entry:
  %v = callbr i64 asm sideeffect "lvd $0, 0($1); b ${2:l}", "=r,b,!i"(i32 %address)
      to label %fallthrough [label %taken]
fallthrough:
  ret i64 %v
taken:
  %w = call i64 @llvm.callbr.landingpad.i64(i64 %v)
  ret i64 %w
}

declare i64 @llvm.callbr.landingpad.i64(i64)
declare void @callee()
