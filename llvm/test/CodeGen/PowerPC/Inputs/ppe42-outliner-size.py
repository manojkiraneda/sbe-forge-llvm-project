"""Check total executable bytes, including every generated outlined helper."""

import struct
import sys


def text_size(path):
    with open(path, "rb") as source:
        data = source.read()
    assert data[:6] == b"\x7fELF\x01\x02", "expected ELF32 big endian"
    section_offset = struct.unpack_from(">I", data, 32)[0]
    entry_size, count = struct.unpack_from(">HH", data, 46)
    total = 0
    for index in range(count):
        section = section_offset + index * entry_size
        flags = struct.unpack_from(">I", data, section + 8)[0]
        if flags & 4:  # SHF_EXECINSTR
            total += struct.unpack_from(">I", data, section + 20)[0]
    return total


before, after = map(text_size, sys.argv[1:])
assert after < before, f"outlining grew executable code: {before} -> {after}"
print(f"Executable bytes: {before} -> {after} (saved {before - after})")
