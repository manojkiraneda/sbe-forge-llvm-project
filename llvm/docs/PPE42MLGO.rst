PPE42 MLGO inliner model
========================

The packaged PPE42 toolchain embeds Google's ``inlining-Oz-v1.1`` MLGO model
in ``clang``. The model is also included in
``share/mlgo/inliner-oz-v1.1`` so the package records the exact source model
used at build time. The model archive is fetched from the
`ml-compiler-opt release <https://github.com/google/ml-compiler-opt/releases/tag/inlining-Oz-v1.1>`_
and verified with SHA-256 before LLVM is configured. TensorFlow 2.15.1 is
needed only to compile the model into the toolchain; it is not required on
machines using the packaged compiler.

The model is not trained specifically for PPE42. It is opt-in so firmware
builds can compare it with LLVM's ordinary inliner using the same sources and
other compiler flags. For a size-optimized build, add::

  -Oz -mllvm -enable-ml-inliner=release

The corresponding baseline uses ``-Oz`` without the MLGO option. The model
affects inlining decisions only; the PPE42 instruction selection and linker
are unchanged. Compare final linked image sizes and inspect the resulting
disassembly before using the model for a release firmware build.

Only the size-oriented inliner model is embedded. No ML register allocation
model is selected by this toolchain build.
