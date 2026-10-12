//===-- RegisterInfoPOSIX_ppc32.h ------------------------------*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLDB_SOURCE_PLUGINS_PROCESS_UTILITY_REGISTERINFOPOSIX_PPC32_H
#define LLDB_SOURCE_PLUGINS_PROCESS_UTILITY_REGISTERINFOPOSIX_PPC32_H

#include "RegisterInfoInterface.h"

#include <vector>

/// The 32-bit Linux PowerPC NT_PRSTATUS GPR layout.  PPE42 core files use
/// this layout even though the hardware implements only a subset of GPRs.
class RegisterInfoPOSIX_ppc32 : public lldb_private::RegisterInfoInterface {
public:
  explicit RegisterInfoPOSIX_ppc32(const lldb_private::ArchSpec &target_arch);

  size_t GetGPRSize() const override;
  const lldb_private::RegisterInfo *GetRegisterInfo() const override;
  uint32_t GetRegisterCount() const override;

private:
  std::vector<lldb_private::RegisterInfo> m_register_info;
};

#endif
