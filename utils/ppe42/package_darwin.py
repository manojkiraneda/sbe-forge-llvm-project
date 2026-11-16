#!/usr/bin/env python3
"""Bundle Mach-O dependencies and sign a relocatable PPE42 host toolchain."""

import argparse
from pathlib import Path
import re
import shutil
import subprocess


def output(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True)


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def system_library(path):
    return str(path).startswith(("/usr/lib/", "/System/Library/"))


def dependencies(path):
    return [line.strip().split(" (compatibility version", 1)[0]
            for line in output("otool", "-L", path).splitlines()[1:]
            if line.strip()]


def rpaths(path):
    return re.findall(r"cmd LC_RPATH\n.*?\n\s*path (.*?) \(offset \d+\)",
                      output("otool", "-l", path))


def expand_path(name, loader, executable):
    return Path(name.replace("@loader_path", str(loader.parent))
                .replace("@executable_path", str(executable.parent)))


def resolve_dependency(name, loader, executable, search_paths):
    if name.startswith("@rpath/"):
        candidates = [expand_path(str(root), loader, executable) / name[7:]
                      for root in search_paths]
    else:
        candidates = [expand_path(name, loader, executable)]
    for candidate in candidates:
        # System dylibs can live only in the dyld shared cache.
        if system_library(candidate):
            return candidate
        if candidate.is_file():
            return candidate.resolve()
    raise RuntimeError(f"Cannot resolve {name} required by {loader}")


class Bundler:
    def __init__(self, build, package):
        self.build = build.resolve()
        self.package = package.resolve()
        self.libraries = self.package / "lib"
        self.libraries.mkdir(parents=True, exist_ok=True)
        self.sources = {}
        self.destinations = {}

    def bundle(self, source, destination, executable, inherited=()):
        source = source.resolve()
        if source in self.sources:
            return self.sources[source]
        previous = self.destinations.get(destination)
        if previous is not None and previous != source:
            raise RuntimeError(f"Conflicting libraries named {destination.name}: "
                               f"{previous} and {source}")
        self.sources[source] = destination
        self.destinations[destination] = source
        shutil.copy2(source, destination)
        destination.chmod(destination.stat().st_mode | 0o200)

        own_id = None
        if destination.suffix == ".dylib":
            ids = output("otool", "-D", source).splitlines()[1:]
            if ids:
                own_id = ids[0].strip()
            run("install_name_tool", "-id", "@rpath/" + destination.name,
                destination)

        paths = rpaths(source)
        # Expand loader-relative paths before passing them down the load chain.
        search = [expand_path(path, source, executable) for path in paths]
        search.extend(inherited)
        search.append(self.build / "lib")
        for name in dependencies(source):
            if name == own_id or system_library(name):
                continue
            dependency = resolve_dependency(name, source, executable, search)
            if system_library(dependency):
                replacement = str(dependency)
            else:
                target = self.bundle(dependency, self.libraries / dependency.name,
                                     executable, search)
                prefix = ("@executable_path/../lib/"
                          if destination.parent == self.package / "bin"
                          else "@loader_path/")
                replacement = prefix + target.name
            run("install_name_tool", "-change", name, replacement, destination)
        for path in paths:
            run("install_name_tool", "-delete_rpath", path, destination)
        return destination

    def finish(self):
        for destination in self.destinations:
            for name in dependencies(destination):
                if (not system_library(name)
                        and name != "@rpath/" + destination.name
                        and not name.startswith(
                            ("@executable_path/../lib/", "@loader_path/"))):
                    raise RuntimeError(f"Unrelocated dependency in {destination}: {name}")
            # Every Mach-O change invalidates the arm64 code signature. Strip
            # first and replace the signature only after all load commands change.
            run("strip", "-x", destination)
            run("codesign", "--force", "--sign", "-", destination)
            run("codesign", "--verify", destination)


def package_toolchain(build, package):
    bundler = Bundler(build, package)
    for destination in sorted((package / "bin").iterdir()):
        if destination.is_file() and not destination.is_symlink():
            source = build / "bin" / destination.name
            bundler.bundle(source, destination, source)
    source = (build / "lib/liblldb.dylib").resolve()
    executable = build / "bin/lldb"
    search = [expand_path(path, executable, executable)
              for path in rpaths(executable)]
    library = bundler.bundle(source, package / "lib" / source.name,
                             executable, search)
    alias = package / "lib/liblldb.dylib"
    if alias != library:
        alias.symlink_to(library.name)
    bundler.finish()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--package-dir", type=Path, required=True)
    args = parser.parse_args()
    package_toolchain(args.build_dir.resolve(), args.package_dir.resolve())


if __name__ == "__main__":
    main()
