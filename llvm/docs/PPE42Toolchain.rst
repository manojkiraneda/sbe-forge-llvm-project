PPE42 host toolchains
====================

The ``PPE42 toolchain`` GitHub Actions workflow builds native toolchains
for two hosts:

* x86-64, on ``ubuntu-24.04`` runners, packaged as
  ``sbe-ppe42-toolchain-linux-x86_64.tar.zst``.
* macOS on Apple Silicon, on ``macos-latest`` runners, packaged as
  ``sbe-ppe42-toolchain-darwin-arm64.tar.zst``.

The host architecture is the machine running Clang and LLDB. Both packages
target PPE42 and include the same compiler tools, PPE42 runtime library, LLDB
core converter, and embedded MLGO inliner model. Each archive contains the
``ppe42-toolchain`` directory and a manifest recording its host operating
system and architecture, LLVM revision, and model version. Each archive has
a separate ``.tar.zst.sha256`` checksum file.

Both builds run the compiler regression tests, MLGO smoke test, LLDB core
tests, and SBE Forge firmware integration on native hardware. The workflow
also checks the ELF or Mach-O architecture of the packaged executables. On a
``ppe42-toolchain-v*`` tag, one publishing job waits for both host builds to
pass before uploading their archives and checksums to the same release.

The macOS package bundles non-system dynamic libraries, including any Homebrew
dependencies. Their install names are rewritten to paths relative to the
packaged executables and libraries. The binaries receive ad-hoc code signatures
after stripping and relocation; these are not Developer ID signatures or Apple
notarization. System libraries and frameworks remain provided by macOS. A native
integration test checks that a package still runs after moving it away from
the original build and dependency directories.

Build caches
------------

Compiler objects and CMake/Ninja build trees use separate cache namespaces
for each host. The existing x86-64 keys are preserved:

* ``ppe42-ccache-Linux-<revision>``
* ``ppe42-mlgo-build-v1-Linux-<revision>``

Apple Silicon uses distinct keys and restore prefixes:

* ``ppe42-darwin-arm64-ccache-macOS-<revision>``
* ``ppe42-darwin-arm64-mlgo-build-v1-macOS-<revision>``

The first macOS build populates its caches. Later builds can restore an
earlier revision from the same architecture. GitHub's branch cache access
rules still apply. Cache restoration never falls back to the other host's
namespace. Each build resets ccache statistics before compilation and prints
its hits and misses afterward, including when compilation fails.
The workflow explicitly sets ``CCACHE_DIR`` to ``~/.cache/ccache`` on both
hosts, so the macOS cache is saved from the directory ccache actually uses.
