//===-- RegisterInfoPOSIX_ppc32.cpp ---------------------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "RegisterInfoPOSIX_ppc32.h"
#include "RegisterContextFreeBSD_powerpc.h"

#include <cstdlib>
#include <cstring>

using namespace lldb_private;

RegisterInfoPOSIX_ppc32::RegisterInfoPOSIX_ppc32(const ArchSpec &target_arch)
    : RegisterInfoInterface(target_arch) {
  RegisterContextFreeBSD_powerpc32 generic(target_arch);
  const RegisterInfo *info = generic.GetRegisterInfo();
  m_register_info.assign(info, info + generic.GetRegisterCount());

  // Linux pt_regs uses r0-r31, nip, msr, orig_r3, ctr, link, xer, ccr,
  // followed by mq, trap, dar, dsisr, and result.  The FreeBSD PPC32 layout
  // has the same GPR names but puts its special registers in another order.
  // Its DWARF numbers also differ from Linux PowerPC.  Assign every differing
  // number here so an inherited FPSCR/VMX alias cannot mask LR or CTR during
  // unwinding.  GPRs and FPRs already use Linux numbers 0-63.
  auto set_dwarf_number = [](RegisterInfo &reg, uint32_t number) {
    reg.kinds[lldb::eRegisterKindEHFrame] = number;
    reg.kinds[lldb::eRegisterKindDWARF] = number;
  };
  for (RegisterInfo &reg : m_register_info) {
    if (std::strcmp(reg.name, "pc") == 0) {
      reg.byte_offset = 32 * 4;
      set_dwarf_number(reg, 118);
    } else if (std::strcmp(reg.name, "ctr") == 0) {
      reg.byte_offset = 35 * 4;
      set_dwarf_number(reg, 66);
    } else if (std::strcmp(reg.name, "lr") == 0) {
      reg.byte_offset = 36 * 4;
      set_dwarf_number(reg, 65);
    } else if (std::strcmp(reg.name, "xer") == 0) {
      reg.byte_offset = 37 * 4;
      set_dwarf_number(reg, 76);
    } else if (std::strcmp(reg.name, "cr") == 0) {
      reg.byte_offset = 38 * 4;
    } else if (std::strcmp(reg.name, "fpscr") == 0) {
      set_dwarf_number(reg, 122);
    } else if (std::strcmp(reg.name, "vscr") == 0) {
      set_dwarf_number(reg, 110);
    } else if (std::strcmp(reg.name, "vrsave") == 0) {
      set_dwarf_number(reg, 117);
    } else if (reg.name[0] == 'v' && reg.name[1] >= '0' &&
               reg.name[1] <= '9') {
      // VMX v0-v31 use DWARF numbers 77-108 on Linux PowerPC.
      set_dwarf_number(reg, 77 + std::strtoul(reg.name + 1, nullptr, 10));
    }
  }
}

size_t RegisterInfoPOSIX_ppc32::GetGPRSize() const { return 44 * 4; }

const RegisterInfo *RegisterInfoPOSIX_ppc32::GetRegisterInfo() const {
  return m_register_info.data();
}

uint32_t RegisterInfoPOSIX_ppc32::GetRegisterCount() const {
  return static_cast<uint32_t>(m_register_info.size());
}
