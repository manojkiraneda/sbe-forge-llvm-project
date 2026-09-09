// RUN: %clang -### -S --target=powerpc-unknown-elf -G0 %s 2>&1 | FileCheck %s --check-prefix=ZERO
// RUN: %clang -### -S --target=powerpc-unknown-elf -G8 %s 2>&1 | FileCheck %s --check-prefix=EIGHT
// ZERO: "-msmall-data-limit" "0"
// EIGHT: "-msmall-data-limit" "8"
