// UNSUPPORTED: system-windows
// RUN: %clang -### --target=powerpc-unknown-elf -mcpu=ppe42 -nostdlib %s 2>&1 | FileCheck %s --check-prefixes=CHECK,BE32
// RUN: %clang -### --target=powerpc-unknown-none-elf -nostdlib %s 2>&1 | FileCheck %s --check-prefixes=CHECK,BE32
// RUN: %clang -### --target=powerpcle-unknown-elf -nostdlib %s 2>&1 | FileCheck %s --check-prefixes=CHECK,LE32
// RUN: %clang -### --target=powerpc64-unknown-elf -nostdlib %s 2>&1 | FileCheck %s --check-prefixes=CHECK,BE64
// RUN: %clang -### --target=powerpc64le-unknown-elf -nostdlib %s 2>&1 | FileCheck %s --check-prefixes=CHECK,LE64
// RUN: %clang -### --target=powerpc-unknown-none-eabi -nostdlib -fuse-ld=ld %s 2>&1 | FileCheck %s --check-prefix=EABI

// CHECK: "-cc1"
// CHECK-SAME: "-funwind-tables=2"
// CHECK: "{{[^"]*}}ld.lld" "-Bstatic"
// BE32-SAME: "-m" "elf32ppc"
// LE32-SAME: "-m" "elf32lppc"
// BE64-SAME: "-m" "elf64ppc"
// LE64-SAME: "-m" "elf64lppc"
// CHECK-NOT: "-m32"
// CHECK-NOT: "-m64"

// EABI: "-cc1"
// EABI-NOT: "-funwind-tables"
// EABI: "{{[^"]*[/\\]}}ld" "-Bstatic" "-m" "elf32ppc"

void _start(void) {}
