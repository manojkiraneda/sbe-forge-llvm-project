PPE42 Linux host toolchains
==========================

The ``PPE42 toolchain`` GitHub Actions workflow builds native Linux toolchains
for two host architectures:

* x86-64, on ``ubuntu-24.04`` runners, packaged as
  ``sbe-ppe42-toolchain-linux-x86_64.tar.zst``.
* AArch64, on ``ubuntu-24.04-arm`` runners, packaged as
  ``sbe-ppe42-toolchain-linux-aarch64.tar.zst``.

The host architecture is the machine running Clang and LLDB. Both packages
target PPE42 and include the same compiler tools, PPE42 runtime library, LLDB
core converter, and embedded MLGO inliner model. Each archive contains the
``ppe42-toolchain`` directory and a manifest recording its Linux host
architecture, LLVM revision, and model version. Each archive has a separate
``.tar.zst.sha256`` checksum file.

Both builds run the compiler regression tests, MLGO smoke test, LLDB core
tests, and SBE Forge firmware integration on native hardware. The workflow
also checks the ELF architecture of the packaged executables. On a
``ppe42-toolchain-v*`` tag, one publishing job waits for both host builds to
pass before uploading their archives and checksums to the same release.

Build caches
------------

Compiler objects and CMake/Ninja build trees use separate cache namespaces
for each host. The existing x86-64 keys are preserved:

* ``ppe42-ccache-Linux-<revision>``
* ``ppe42-mlgo-build-v1-Linux-<revision>``

AArch64 uses distinct keys and restore prefixes:

* ``ppe42-aarch64-ccache-Linux-<revision>``
* ``ppe42-aarch64-mlgo-build-v1-Linux-<revision>``

The first AArch64 build populates its caches. Later builds can restore an
earlier revision from the same architecture. GitHub's branch cache access
rules still apply. Cache restoration never falls back to the other host's
namespace. Each build resets ccache statistics before compilation and prints
its hits and misses afterward, including when compilation fails.
