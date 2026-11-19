"""Exercise shared build commands without building LLVM or downloading dependencies."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

DRIVER = Path(__file__).with_name('build-toolchain.sh').resolve()


class SharedBuildTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='ppe42 build ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        RECORD=str(self.root / 'commands.jsonl'))
        self.build = self.root / 'build tree'
        self.build.mkdir()
        (self.build / 'CMakeCache.txt').write_text('LLDB_ENABLE_LIBEDIT:STRING=ON\n')
        self.package = self.root / 'local toolchain'
        self.package.mkdir()
        self.variables = f'BUILD_DIR={str(self.build)!r}; PACKAGE_DIR={str(self.package)!r}; DEPS_DIR={str(self.root)!r}; MLGO_MODEL_PATH={str(self.root / "model")!r}; RUNNER_OS=Linux; FEDORA=; SCALAR_RUNTIME=OFF; '
        self.stub('cmake', '''import json, os, sys
with open(os.environ['RECORD'], 'a') as f: f.write(json.dumps(sys.argv[1:]) + '\\n')
''')
        self.stub('python', "print('/fake tensorflow')\n")
        self.stub('saved_model_cli', '')

    def stub(self, name, body):
        import sys
        path = self.bin / name
        path.write_text('#!' + sys.executable + '\n' + body)
        path.chmod(0o755)

    def run_function(self, command, variables=''):
        return subprocess.run(['bash', '-c', 'source "$1"; ' + self.variables + variables + command,
                               'test', str(DRIVER)], env=self.env, check=True,
                              capture_output=True, text=True)

    def commands(self):
        return [json.loads(line) for line in Path(self.env['RECORD']).read_text().splitlines()]

    def test_configure_uses_embedded_inliner_and_preserves_spaces(self):
        self.run_function('configure -DCMAKE_VERBOSE_MAKEFILE=ON')
        args = self.commands()[0]
        for flag in ['-DLLVM_ENABLE_PROJECTS=clang;lld;lldb', '-DLLVM_RAEVICT_MODEL_PATH=none',
                     '-DTENSORFLOW_AOT_PATH=/fake tensorflow',
                     '-DLLVM_INLINER_MODEL_PATH=' + str(self.root / 'model'),
                     '-DCMAKE_INSTALL_PREFIX=' + str(self.package),
                     '-DLLVM_TF_AOT_SCALAR_RUNTIME=OFF', '-DCMAKE_VERBOSE_MAKEFILE=ON']:
            self.assertIn(flag, args)
        self.assertEqual(args[args.index('-B') + 1], str(self.build))

    def test_darwin_configuration(self):
        self.run_function('configure', 'RUNNER_OS=macOS; SCALAR_RUNTIME=ON; ')
        args = self.commands()[0]
        self.assertIn('-DLLVM_TF_AOT_SCALAR_RUNTIME=ON', args)
        self.assertIn('-DLLDB_BUILD_FRAMEWORK=OFF', args)
        self.assertIn('-DLLDB_USE_SYSTEM_DEBUGSERVER=ON', args)

    def test_fedora_cmake_compatibility(self):
        self.run_function('configure', 'FEDORA=1; SCALAR_RUNTIME=ON; ')
        self.assertIn('-DCMAKE_POLICY_VERSION_MINIMUM=3.5', self.commands()[0])

    def test_aot_dependency_order_and_explicit_tools(self):
        self.run_function('build_deps; build')
        deps, tools = self.commands()
        self.assertEqual(deps[-2:], ['tf_xla_runtime', 'lib/Analysis/InlinerSizeModel.o'])
        for tool in ('clang', 'lld', 'lldb', 'llvm-ar', 'llvm-strip', 'FileCheck'):
            self.assertIn(tool, tools)

    @unittest.skipUnless(shutil.which('zstd'), 'zstd is required for archive round trip')
    def test_archive_has_fixed_root_symlinks_and_checksum(self):
        # Run the actual Python archive writer, not the configure stub.
        (self.bin / 'python').unlink()
        import sys
        (self.bin / 'python').symlink_to(sys.executable)
        (self.package / 'clang').write_text('fixture')
        (self.package / 'clang++').symlink_to('clang')
        asset = self.root / 'release'
        self.run_function('archive', f'ASSET_NAME={str(asset)!r}; ')
        archive = asset.with_suffix('.tar.zst')
        self.assertEqual(archive.with_suffix('.zst.sha256').read_text(),
                         hashlib.sha256(archive.read_bytes()).hexdigest() + '  release.tar.zst\n')
        import io, tarfile
        data = subprocess.check_output(['zstd', '-dq', '-c', str(archive)])
        with tarfile.open(fileobj=io.BytesIO(data)) as tar:
            self.assertEqual(tar.getmember('ppe42-toolchain/clang++').linkname, 'clang')
            self.assertEqual(tar.extractfile('ppe42-toolchain/clang').read(), b'fixture')

    def test_unknown_phase_fails(self):
        result = subprocess.run(['bash', str(DRIVER), 'invalid'], env=dict(self.env,
                                SBE_LLVM_DEPS_DIR=str(self.root)), capture_output=True)
        self.assertEqual(result.returncode, 2)


if __name__ == '__main__':
    unittest.main()
