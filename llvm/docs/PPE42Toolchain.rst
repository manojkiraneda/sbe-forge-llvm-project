PPE42 host toolchains
====================

The ``PPE42 toolchain`` GitHub Actions workflow builds native toolchains
for three hosts:

* x86-64, on ``ubuntu-24.04`` runners, packaged as
  ``sbe-ppe42-toolchain-linux-x86_64.tar.zst``.
* Linux ARM64, built in a ``fedora:45`` container on native
  ``ubuntu-24.04-arm`` runners, packaged as
  ``sbe-ppe42-toolchain-linux-aarch64.tar.zst``.
* macOS on Apple Silicon, on ``macos-latest`` runners, packaged as
  ``sbe-ppe42-toolchain-darwin-arm64.tar.zst``.

The host architecture is the machine running Clang and LLDB. All packages
target PPE42 and include the same compiler tools, PPE42 runtime library, LLDB
core converter, and embedded MLGO inliner model. Each archive contains the
``ppe42-toolchain`` directory and a manifest recording its host operating
system and architecture, LLVM revision, and model version. Each archive has
a separate ``.tar.zst.sha256`` checksum file.

Clang routes bare-metal PowerPC ELF links directly to ``ld.lld``, rather than
using a host GCC driver. The existing ELF unwind-table default is preserved.
CI checks both linker discovery and a freestanding PowerPC ELF link using
the packaged compiler on every host.

All builds run the compiler regression tests, MLGO smoke test, LLDB core
tests, and SBE Forge firmware integration on native hardware. The workflow
also checks the ELF or Mach-O architecture of the packaged executables. On a
``ppe42-toolchain-v*`` tag, one publishing job waits for all host builds to
pass before uploading their archives and checksums to the same release.

Firmware integration checks out ``main`` from ``manojkiraneda/sbe-forge``
and runs its firmware tests against the packaged compiler.

The macOS package bundles non-system dynamic libraries, including any Homebrew
dependencies. Their install names are rewritten to paths relative to the
packaged executables and libraries. The binaries receive ad-hoc code signatures
after stripping and relocation; these are not Developer ID signatures or Apple
notarization. System libraries and frameworks remain provided by macOS. A native
integration test checks that a package still runs after moving it away from
the original build and dependency directories.

The ARM64 builds enable ``LLVM_TF_AOT_SCALAR_RUNTIME`` for the
TensorFlow 2.15 runtime. Its convolution packers require four-column Eigen
kernels, while the bundled ARM NEON specialization selects eight. The option
uses Eigen's scalar implementation only for the host runtime object library.
The embedded model remains enabled and compiled for the native host, and LLVM
and PPE42 code generation retain their normal optimization settings. CI builds
the runtime and generated model before starting the full compiler build.

Build caches
------------

Compiler objects and CMake/Ninja build trees use separate cache namespaces
for each host. The existing x86-64 keys are preserved:

* ``ppe42-ccache-Linux-<revision>``
* ``ppe42-mlgo-build-v1-Linux-<revision>``

Apple Silicon uses distinct keys and restore prefixes:

* ``ppe42-darwin-arm64-ccache-macOS-<revision>``
* ``ppe42-darwin-arm64-mlgo-build-v1-macOS-<revision>``

Linux ARM64 has its own keys and restore prefixes:

* ``ppe42-fedora45-linux-aarch64-ccache-Linux-<revision>``
* ``ppe42-fedora45-linux-aarch64-mlgo-build-v1-Linux-<revision>``

The Linux ARM64 package uses Fedora 45's compiler, libraries, and glibc ABI.
Python 3.11 and MLGO's build dependencies run in a virtual environment in
the container. The Fedora cache namespace cannot restore Ubuntu build outputs.

The first build for a new host populates its caches. Later builds can restore an
earlier revision from the same architecture. GitHub's branch cache access
rules still apply. Cache restoration never falls back to the other host's
namespace. Each build resets ccache statistics before compilation and prints
its hits and misses afterward, including when compilation fails.
The workflow explicitly sets ``CCACHE_DIR`` to ``~/.cache/ccache`` on all
hosts, so the macOS cache is saved from the directory ccache actually uses.

Shared local and release builds
-------------------------------

``utils/ppe42/build-toolchain.sh`` owns the MLGO dependency versions, model
checksum, CMake configuration, explicit tool targets, runtime library and
release packaging. Release CI calls its phases around the existing build caches
and regression checks. SBE Forge delegates to the same script through its pinned
LLVM submodule.

Install Python 3.11 and run ``build-toolchain.sh deps`` to install host build
and integration dependencies. Then run ``build-toolchain.sh`` to prepare the
TensorFlow AOT compiler and inliner model, build and stage the toolchain, verify
MLGO compilation and create a compressed release archive. Native local builds
use a private Python environment; CI uses its provisioned Python 3.11.

``SBE_LLVM_BUILD_DIR``, ``SBE_LLVM_INSTALL_DIR`` and ``SBE_LLVM_DEPS_DIR``
select the build tree, staging directory and dependency cache. Existing CI
``BUILD_DIR`` and ``PACKAGE_DIR`` values remain supported. Run ``--help`` for
individual phases. Additional CMake arguments can follow ``configure`` or
``all``. The register-allocation model remains disabled; the embedded inliner
is activated with ``-mllvm -enable-ml-inliner=release``.

Development entry-point coverage
--------------------------------

Toolchain CI checks out a pinned SBE Forge revision and invokes its
``scripts/dev.sh --native --phase ...`` entry point for dependency preparation,
configuration, compilation, runtime generation, staging, checking and packaging.
The job selects its own LLVM checkout with ``SBE_LLVM_SOURCE_DIR``; the SBE Forge
submodule is not initialized or substituted for the candidate being tested.
Existing ``BUILD_DIR`` and ``PACKAGE_DIR`` cache locations remain unchanged.

Firmware integration also goes through ``dev.sh --native --phase firmware``.
On Linux x86, CI additionally runs ``dev.sh --container --phase check`` against
the staged candidate. This exercises the actual Docker image build and container
launcher without compiling LLVM a second time. Command-routing tests run on
all three host architectures. The LLVM build driver remains the owner of model
versions and compiler configuration; both native and container entry points
use it.
