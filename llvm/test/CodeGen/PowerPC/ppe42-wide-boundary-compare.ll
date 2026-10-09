; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -O=2 < %s | FileCheck %s

; A 64-bit ReturnCode returned in two GPRs has its status in the high word.
; Comparing the whole value with 2^32 (or 2^32-1) only needs that word.
; The second check in a repeated-call function previously materialized a
; Boolean from both words, including a compare against -1 and cntlzw.

@current = external global i64, align 8

declare i64 @get()
declare void @sink()

define void @two_calls() #0 {
; CHECK-LABEL: two_calls:
; CHECK-NOT: cntlzw
; CHECK-NOT: cmplw {{[0-9]+}}, {{[0-9]+}}
; CHECK: bl sink
  %first = call i64 @get()
  store i64 %first, ptr @current, align 8
  %first.failed = icmp uge i64 %first, 4294967296
  br i1 %first.failed, label %done, label %second.call

second.call:
  %second = call i64 @get()
  store i64 %second, ptr @current, align 8
  %second.failed = icmp ugt i64 %second, 4294967295
  br i1 %second.failed, label %sink, label %done

sink:
  call void @sink()
  br label %done

done:
  ret void
}

attributes #0 = { optsize "target-cpu"="ppe42" }
