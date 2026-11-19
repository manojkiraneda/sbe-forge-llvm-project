"""Relocation checks, including a native Mach-O integration test on macOS."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import package_darwin as packaging


class DependencyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / "lib").mkdir()
        self.library = self.root / "lib/libdep.dylib"
        self.library.touch()
        self.loader = self.root / "lib/libloader.dylib"
        self.executable = self.root / "bin/tool"
        self.executable.parent.mkdir()

    def test_loader_and_executable_relative_paths(self):
        for name in ("@loader_path/libdep.dylib",
                     "@executable_path/../lib/libdep.dylib"):
            self.assertEqual(packaging.resolve_dependency(
                name, self.loader, self.executable, []), self.library)

    def test_rpath_resolution_and_missing_dependency(self):
        self.assertEqual(packaging.resolve_dependency(
            "@rpath/libdep.dylib", self.loader, self.executable,
            [self.root / "absent", self.root / "lib"]), self.library)
        with self.assertRaisesRegex(RuntimeError, "Cannot resolve"):
            packaging.resolve_dependency("@rpath/missing.dylib", self.loader,
                                         self.executable, [self.root / "lib"])

    def test_system_shared_cache_needs_no_file(self):
        self.assertEqual(packaging.resolve_dependency(
            "/usr/lib/libSystem.B.dylib", self.loader, self.executable, []),
            Path("/usr/lib/libSystem.B.dylib"))

    def test_runpath_parsing_preserves_spaces(self):
        commands = ("Load command 2\n          cmd LC_RPATH\n"
                    "      cmdsize 48\n         path @loader_path/../some libs (offset 12)\n")
        with patch.object(packaging, "output", return_value=commands):
            self.assertEqual(packaging.rpaths(self.loader),
                             ["@loader_path/../some libs"])


@unittest.skipUnless(sys.platform == "darwin", "requires macOS Mach-O tools")
class NativeRelocationTests(unittest.TestCase):
    def test_recursive_dependencies_survive_moving_package(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            build = root / "build"
            package = root / "package"
            external = root / "external libs"
            for directory in (build / "bin", build / "lib", package / "bin", external):
                directory.mkdir(parents=True)
            edit = external / "libedit.0.dylib"
            library = build / "lib/liblldb.21.dylib"
            (root / "edit.c").write_text("int edit_value(void) { return 42; }\n")
            (root / "lldb.c").write_text(
                "int edit_value(void); int wrapped(void) { return edit_value(); }\n")
            (root / "main.c").write_text(
                '#include <stdio.h>\nint wrapped(void);\n'
                'int main(void) { printf("%d\\n", wrapped()); return 0; }\n')

            def clang(*args):
                subprocess.run(["xcrun", "clang", "-Wl,-headerpad_max_install_names",
                                *map(str, args)], check=True)

            clang("-dynamiclib", root / "edit.c", "-install_name", edit, "-o", edit)
            clang("-dynamiclib", root / "lldb.c", edit, "-install_name",
                  "@rpath/" + library.name, "-o", library)
            (build / "lib/liblldb.dylib").symlink_to(library.name)
            for name in ("clang", "lldb"):
                executable = build / "bin" / name
                clang(root / "main.c", library, "-Wl,-rpath," + str(build / "lib"),
                      "-o", executable)
                shutil.copy2(executable, package / "bin" / name)

            packaging.package_toolchain(build, package)
            # Local development stages into the same directory repeatedly.
            packaging.package_toolchain(build, package)
            # Neither the original LLVM build nor the external library install
            # can satisfy a load after relocation.
            build.rename(root / "hidden-build")
            external.rename(root / "hidden-external")
            relocated = root / "relocated package"
            package.rename(relocated)
            for name in ("clang", "lldb"):
                self.assertEqual(subprocess.check_output(
                    [str(relocated / "bin" / name)], text=True), "42\n")
            self.assertTrue((relocated / "lib/libedit.0.dylib").is_file())
            self.assertTrue((relocated / "lib/liblldb.dylib").is_file())


if __name__ == "__main__":
    unittest.main()
