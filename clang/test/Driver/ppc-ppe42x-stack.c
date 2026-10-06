// RUN: %clang -target powerpc-unknown-elf -mcpu=ppe42 -mno-ppe42x-stack -### -c %s 2>&1 | FileCheck %s --check-prefix=DISABLE
// RUN: %clang -target powerpc-unknown-elf -mcpu=ppe42 -mno-ppe42x-stack -mppe42x-stack -### -c %s 2>&1 | FileCheck %s --check-prefix=ENABLE

// DISABLE: "-target-feature" "-ppe42x-stack"
// ENABLE: "-target-feature" "+ppe42x-stack"
