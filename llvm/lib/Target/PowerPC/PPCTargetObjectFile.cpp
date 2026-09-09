//===-- PPCTargetObjectFile.cpp - PPC Object Info -------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "PPCTargetObjectFile.h"
#include "MCTargetDesc/PPCMCAsmInfo.h"
#include "llvm/BinaryFormat/ELF.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/MC/MCContext.h"
#include "llvm/MC/MCExpr.h"
#include "llvm/MC/MCSectionELF.h"

using namespace llvm;

void
PPC64LinuxTargetObjectFile::
Initialize(MCContext &Ctx, const TargetMachine &TM) {
  TargetLoweringObjectFileELF::Initialize(Ctx, TM);
  SmallDataSection = Ctx.getELFSection(
      ".sdata", ELF::SHT_PROGBITS, ELF::SHF_WRITE | ELF::SHF_ALLOC);
  SmallBSSSection = Ctx.getELFSection(
      ".sbss", ELF::SHT_NOBITS, ELF::SHF_WRITE | ELF::SHF_ALLOC);
  SmallData2Section =
      Ctx.getELFSection(".sdata2", ELF::SHT_PROGBITS, ELF::SHF_ALLOC);
}

bool PPC64LinuxTargetObjectFile::isGlobalInSmallSection(
    const GlobalValue *GV, const TargetMachine &TM) const {
  const auto *GVar = dyn_cast<GlobalVariable>(GV);
  if (!TM.getTargetTriple().isPPC32() || !GVar)
    return false;
  if (GVar->hasSection())
    return GVar->getSection() == ".sdata" || GVar->getSection() == ".sbss" ||
           GVar->getSection() == ".sdata2" || GVar->getSection() == ".sbss2";
  if (GVar->isDeclaration() || GVar->hasCommonLinkage() ||
      !GVar->getValueType()->isSized())
    return false;
  uint64_t Size = GVar->getDataLayout().getTypeAllocSize(GVar->getValueType());
  return Size > 0 && Size <= SSThreshold;
}

bool PPC64LinuxTargetObjectFile::isGlobalInReadOnlySmallSection(
    const GlobalValue *GV, const TargetMachine &TM) const {
  const auto *GVar = dyn_cast<GlobalVariable>(GV);
  if (!GVar || !isGlobalInSmallSection(GV, TM))
    return false;
  return GVar->hasSection() ? GVar->getSection() == ".sdata2" ||
                                  GVar->getSection() == ".sbss2"
                            : GVar->isConstant();
}

MCSection *PPC64LinuxTargetObjectFile::SelectSectionForGlobal(
    const GlobalObject *GO, SectionKind Kind, const TargetMachine &TM) const {
  const auto *GVar = dyn_cast<GlobalVariable>(GO);
  if (GVar && isGlobalInSmallSection(GVar, TM)) {
    if (isGlobalInReadOnlySmallSection(GVar, TM))
      return SmallData2Section;
    bool EmitUniquedSection = TM.getDataSections();
    if (Kind.isBSS()) {
      if (EmitUniquedSection)
        return getContext().getELFSection(
            (Twine(".sbss.") + GO->getName()).str(), ELF::SHT_NOBITS,
            ELF::SHF_WRITE | ELF::SHF_ALLOC);
      return SmallBSSSection;
    }
    if (Kind.isData()) {
      if (EmitUniquedSection)
        return getContext().getELFSection(
            (Twine(".sdata.") + GO->getName()).str(), ELF::SHT_PROGBITS,
            ELF::SHF_WRITE | ELF::SHF_ALLOC);
      return SmallDataSection;
    }
  }

  // Here override ReadOnlySection to DataRelROSection for PPC64 SVR4 ABI
  // when we have a constant that contains global relocations.  This is
  // necessary because of this ABI's handling of pointers to functions in
  // a shared library.  The address of a function is actually the address
  // of a function descriptor, which resides in the .opd section.  Generated
  // code uses the descriptor directly rather than going via the GOT as some
  // other ABIs do, which means that initialized function pointers must
  // reference the descriptor.  The linker must convert copy relocs of
  // pointers to functions in shared libraries into dynamic relocations,
  // because of an ordering problem with initialization of copy relocs and
  // PLT entries.  The dynamic relocation will be initialized by the dynamic
  // linker, so we must use DataRelROSection instead of ReadOnlySection.
  // For more information, see the description of ELIMINATE_COPY_RELOCS in
  // GNU ld.
  if (Kind.isReadOnly()) {
    const auto *GVar = dyn_cast<GlobalVariable>(GO);

    if (GVar && GVar->isConstant() &&
        GVar->getInitializer()->needsDynamicRelocation())
      Kind = SectionKind::getReadOnlyWithRel();
  }

  return TargetLoweringObjectFileELF::SelectSectionForGlobal(GO, Kind, TM);
}

void PPC64LinuxTargetObjectFile::getModuleMetadata(Module &M) {
  TargetLoweringObjectFileELF::getModuleMetadata(M);
  SmallVector<Module::ModuleFlagEntry, 8> ModuleFlags;
  M.getModuleFlagsMetadata(ModuleFlags);
  for (const auto &MFE : ModuleFlags) {
    if (MFE.Key->getString() == "SmallDataLimit") {
      SSThreshold = mdconst::extract<ConstantInt>(MFE.Val)->getZExtValue();
      break;
    }
  }
}

const MCExpr *PPC64LinuxTargetObjectFile::
getDebugThreadLocalSymbol(const MCSymbol *Sym) const {
  const MCExpr *Expr =
      MCSymbolRefExpr::create(Sym, PPC::S_DTPREL, getContext());
  return MCBinaryExpr::createAdd(Expr,
                                 MCConstantExpr::create(0x8000, getContext()),
                                 getContext());
}
