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

    def run_function(self, command, variables='', expected=0):
        result = subprocess.run(['bash', '-c', 'source "$1"; ' + self.variables + variables + command,
                                 'test', str(DRIVER)], env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

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

    def linux_package_fixture(self):
        system = self.root / 'system libraries'
        system.mkdir()
        (self.package / 'lib').mkdir()
        (self.package / 'bin').mkdir()
        (self.build / 'lib').mkdir()
        (self.build / 'bin').mkdir()
        for tool in ('clang', 'ld.lld', 'lldb', 'llvm-ar', 'llvm-objcopy',
                     'llvm-objdump', 'llvm-nm', 'llvm-strip'):
            (self.package / 'bin' / tool).write_text('fixture')
            (self.build / 'bin' / tool).write_text('fixture')
        (self.build / 'lib/liblldb.so').write_text('lldb')
        (system / 'libxml2.so.2.9.14').write_text('xml fixture')
        (system / 'libxml2.so.2').symlink_to('libxml2.so.2.9.14')
        (system / 'libicudata.so.74').write_text('transitive ICU fixture')
        (system / 'libc.so.6').write_text('host glibc')
        listing = self.root / 'ldd.txt'
        listing.write_text(''.join(
            f'\t{name} => {system / name} (0x00000001)\n'
            for name in ('libxml2.so.2', 'libicudata.so.74', 'libc.so.6')) +
            '\t/lib64/ld-linux-x86-64.so.2 (0x00000002)\n')
        self.env['DEPENDENCY_LIST'] = str(listing)
        self.stub('ldd', "import os, pathlib; print(pathlib.Path(os.environ['DEPENDENCY_LIST']).read_text())\n")
        self.stub('patchelf', "import os, sys, json\nwith open(os.environ['RECORD'], 'a') as f: f.write(json.dumps(sys.argv[1:]) + '\\n')\n")
        self.stub('strip', '')
        return listing

    def test_linux_bundles_xml_and_transitive_dependencies_without_glibc(self):
        self.linux_package_fixture()
        self.run_function('bundle_linux_dependencies')
        xml = self.package / 'lib/libxml2.so.2'
        self.assertEqual(xml.read_text(), 'xml fixture')
        self.assertFalse(xml.is_symlink())
        self.assertEqual((self.package / 'lib/libicudata.so.74').read_text(), 'transitive ICU fixture')
        self.assertFalse((self.package / 'lib/libc.so.6').exists())
        self.assertFalse((self.package / 'lib/ld-linux-x86-64.so.2').exists())
        commands = self.commands()
        self.assertIn(['--set-rpath', '$ORIGIN/../lib', str(self.package / 'bin/lldb')], commands)
        self.assertTrue(any(args[:2] == ['--set-rpath', '$ORIGIN'] and str(xml) in args[2:]
                            for args in commands))

    def test_linux_rejects_unresolved_dependencies(self):
        listing = self.linux_package_fixture()
        listing.write_text('libxml2.so.2 => not found\n')
        result = self.run_function('bundle_linux_dependencies', expected=1)
        self.assertIn('unresolved shared-library dependencies', result.stderr)

    def test_linux_rejects_failed_dependency_inspection(self):
        self.linux_package_fixture()
        self.stub('ldd', 'raise SystemExit(1)\n')
        result = self.run_function('bundle_linux_dependencies', expected=1)
        self.assertIn('Unable to inspect', result.stderr)

    def test_model_extraction_ignores_release_archive_owner_ids(self):
        import io
        import tarfile
        real_tar = shutil.which('tar')
        self.assertIsNotNone(real_tar)
        files = {'model/saved_model.pb': b'model fixture',
                 'model/variables/variables.data-00000-of-00001': b'weights fixture'}
        with tarfile.open(self.root / 'inliner.tar.gz', 'w:gz') as archive:
            for name, data in files.items():
                member = tarfile.TarInfo(name)
                member.uid, member.gid = 796054, 89939
                member.size = len(data)
                member.mode = 0o644
                archive.addfile(member, io.BytesIO(data))
        self.env['REAL_TAR'] = real_tar
        self.stub('tar', "import json, os, subprocess, sys\n"
                  "with open(os.environ['RECORD'], 'a') as f: f.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                  "raise SystemExit(subprocess.call([os.environ['REAL_TAR'], *sys.argv[1:]]))\n")
        self.run_function('extract_inliner_model')
        self.assertIn('--no-same-owner', self.commands()[0])
        for name, data in files.items():
            with self.subTest(name=name):
                target = self.root / name
                self.assertEqual(target.read_bytes(), data)
                self.assertEqual(target.stat().st_uid, os.geteuid())
                self.assertEqual(target.stat().st_gid, self.root.stat().st_gid)

    def tensorflow_fixture(self, installed):
        self.env['VIRTUAL_ENV'] = '/fixture/venv'
        self.env['CI'] = 'true'
        self.env['MOCK_TF_INSTALLED'] = '1' if installed else '0'
        self.stub('python', "import json, os, sys\n"
                  "with open(os.environ['RECORD'], 'a') as f: f.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                  "if any('importlib.metadata' in arg for arg in sys.argv):\n"
                  "    raise SystemExit(0 if os.environ['MOCK_TF_INSTALLED'] == '1' else 1)\n")

    def test_cached_tensorflow_does_not_run_pip(self):
        self.tensorflow_fixture(installed=True)
        self.run_function('prepare_tensorflow')
        self.assertFalse(any(args[:2] == ['-m', 'pip'] for args in self.commands()))
        self.assertIn(['-'], self.commands(), 'AOT import/runtime validation must still run')

    def test_missing_tensorflow_installs_pinned_wheel(self):
        self.tensorflow_fixture(installed=False)
        self.run_function('prepare_tensorflow')
        pip = [args for args in self.commands() if args[:2] == ['-m', 'pip']]
        self.assertEqual(len(pip), 1)
        self.assertIn('tensorflow==2.15.1', pip[0])
        self.assertIn('--only-binary=:all:', pip[0])
        self.assertIn('--disable-pip-version-check', pip[0])

    def test_prepare_checks_tensorflow_before_model(self):
        result = self.run_function("prepare_tensorflow() { echo tensorflow; }; "
                                   "prepare_model() { echo model; }; prepare")
        self.assertEqual(result.stdout.splitlines(), ['tensorflow', 'model'])

    def pipeline_overrides(self, failed_configure=False):
        names = ('verify_host', 'prepare', 'test_unit', 'cache_start', 'cache_report',
                 'build_deps', 'build', 'runtime', 'test_compiler', 'stage', 'check',
                 'test_package', 'archive')
        code = ''.join(f'{name}() {{ echo {name}; }}; ' for name in names)
        code += 'configure() { printf "configure:%s\\n" "$*"; '
        code += 'return 19; ' if failed_configure else ''
        return code + '}; '

    def test_full_build_runs_compiler_and_package_regressions_before_archive(self):
        self.env['SBE_LLVM_DEPS_DIR'] = str(self.root)
        result = self.run_function(self.pipeline_overrides() + 'main all -DTEST=ON')
        self.assertEqual(result.stdout.splitlines(), [
            'verify_host', 'prepare', 'test_unit', 'cache_start', 'configure:-DTEST=ON', 'build_deps',
            'build', 'runtime', 'test_compiler', 'stage', 'check', 'test_package',
            'archive', 'cache_report'])

    def test_failed_configure_preserves_failure_and_reports_cache(self):
        self.env['SBE_LLVM_DEPS_DIR'] = str(self.root)
        result = self.run_function(self.pipeline_overrides(failed_configure=True) + 'main all', expected=19)
        self.assertEqual(result.stdout.splitlines(), [
            'verify_host', 'prepare', 'test_unit', 'cache_start', 'configure:', 'cache_report'])

    def test_unknown_phase_fails(self):
        result = subprocess.run(['bash', str(DRIVER), 'invalid'], env=dict(self.env,
                                SBE_LLVM_DEPS_DIR=str(self.root)), capture_output=True)
        self.assertEqual(result.returncode, 2)


if __name__ == '__main__':
    unittest.main()
