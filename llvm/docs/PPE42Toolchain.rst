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

SBE Forge's ``scripts/dev.sh`` is the common entry point for local builds and
LLVM CI. It supports native and container execution, phase selection, candidate
source directories and output-directory overrides. ``all`` prepares/builds the
compiler, runs the compiler and package regressions, creates an archive, then
runs firmware validation. ``test`` reruns validation against an existing build.

The shared LLVM modules own the implementation:

* ``utils/ppe42/toolchain-environment.sh`` owns host dependencies, Python and
  TensorFlow setup. The TensorFlow version is defined once there.
* ``utils/ppe42/build-toolchain.sh`` owns model pins/checksums, CMake settings,
  build/package tool lists, the PPE42 runtime, staging and archiving.
* ``utils/ppe42/toolchain-tests.sh`` owns compiler test selections, core fixtures,
  packaged LLDB/linking checks and host-architecture validation.

The full local path and CI invoke those same checks. No compiler test lists or
core fixtures are duplicated in the workflow. CI owns runner selection,
checkouts, cache restore/save, artifact upload, attestation and tagged release
publication. Apart from the minimal container bootstrap needed before checkout,
its build-job shell steps call ``dev.sh --native --phase ...``. Linux x86 also
runs ``dev.sh --container --phase check`` against the packaged candidate.

Container caching
-----------------

The development image has separate layers for system dependencies, TensorFlow
and model preparation. Only the stable environment module is copied before
installing TensorFlow; compiler/model scripts are copied afterward. A compiler
script edit or model-extraction failure therefore does not invalidate the
TensorFlow layer. Model extraction ignores release archive owner IDs, allowing
rootless containers to use the same image build. Preparation validates and
reuses the pinned TensorFlow wheel without running pip when it is already
installed. Container compiler-cache data persists in the selected build tree.

Linux staging bundles the transitive non-glibc libraries required by the tools,
including LLDB's libxml2 dependency. Tools and bundled libraries use relative
runtime search paths. The Fedora container smoke check tests the resulting
Ubuntu package in the development image.

Phase and path controls
-----------------------

``dev.sh --help`` lists the supported phases, including dependency/model setup,
configuration/build, runtime generation, staging/checking, compiler and package
regressions, firmware validation and archiving. Host checks and ccache reporting
also have phases so workflow ordering can surround the existing cache actions.
``build-toolchain.sh --help`` exposes the LLVM backend phases directly.

``SBE_LLVM_SOURCE_DIR`` selects the candidate LLVM checkout; CI does not replace
it with the SBE Forge submodule. ``SBE_LLVM_BUILD_DIR``,
``SBE_LLVM_INSTALL_DIR`` and ``SBE_LLVM_DEPS_DIR`` select the build tree,
staging directory and dependency cache. Existing ``BUILD_DIR`` and
``PACKAGE_DIR`` CI cache paths remain supported. Additional CMake arguments
can follow ``configure`` or ``all`` in the backend, or ``--`` in ``dev.sh``.
Native builds require Python 3.11 and the supported host dependencies; the
default container supplies them.

The register-allocation model remains disabled. Activate the embedded inliner
with ``-mllvm -enable-ml-inliner=release``.
