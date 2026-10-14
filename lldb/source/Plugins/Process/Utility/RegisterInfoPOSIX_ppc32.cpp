//===-- RegisterInfoPOSIX_ppc32.cpp ---------------------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "RegisterInfoPOSIX_ppc32.h"
#include "RegisterContextFreeBSD_powerpc.h"

#include <cstring>

using namespace lldb_private;

RegisterInfoPOSIX_ppc32::RegisterInfoPOSIX_ppc32(const ArchSpec &target_arch)
    : RegisterInfoInterface(target_arch) {
  RegisterContextFreeBSD_powerpc32 generic(target_arch);
  const RegisterInfo *info = generic.GetRegisterInfo();
  m_register_info.assign(info, info + generic.GetRegisterCount());

  // The FreeBSD register table numbers FPSCR as 65 and MSR as 66.  Linux
  // PowerPC CFI uses those numbers for LR and CTR, respectively.  Keep the
  // inherited register list, but remove these conflicting DWARF aliases.
  for (RegisterInfo &reg : m_register_info) {
    if (std::strcmp(reg.name, "fpscr") == 0 ||
        std::strcmp(reg.name, "msr") == 0) {
      reg.kinds[lldb::eRegisterKindEHFrame] = LLDB_INVALID_REGNUM;
      reg.kinds[lldb::eRegisterKindDWARF] = LLDB_INVALID_REGNUM;
    }
  }

  // Linux pt_regs uses r0-r31, nip, msr, orig_r3, ctr, link, xer, ccr,
  // followed by mq, trap, dar, dsisr, and result.  The FreeBSD PPC32 layout
  // has the same GPR names but puts its special registers in another order.
  for (RegisterInfo &reg : m_register_info) {
    if (std::strcmp(reg.name, "pc") == 0)
      reg.byte_offset = 32 * 4;
    else if (std::strcmp(reg.name, "ctr") == 0)
      reg.byte_offset = 35 * 4;
    else if (std::strcmp(reg.name, "lr") == 0) {
      reg.byte_offset = 36 * 4;
      // Linux/PPC32 (including PPE42) CFI uses DWARF register 65 for LR.
      // The FreeBSD table uses 108, which prevents unwinding past frame 0.
      reg.kinds[lldb::eRegisterKindEHFrame] = 65;
      reg.kinds[lldb::eRegisterKindDWARF] = 65;
    } else if (std::strcmp(reg.name, "xer") == 0)
      reg.byte_offset = 37 * 4;
    else if (std::strcmp(reg.name, "cr") == 0)
      reg.byte_offset = 38 * 4;
  }
}

size_t RegisterInfoPOSIX_ppc32::GetGPRSize() const { return 44 * 4; }

const RegisterInfo *RegisterInfoPOSIX_ppc32::GetRegisterInfo() const {
  return m_register_info.data();
}

uint32_t RegisterInfoPOSIX_ppc32::GetRegisterCount() const {
  return static_cast<uint32_t>(m_register_info.size());
}
