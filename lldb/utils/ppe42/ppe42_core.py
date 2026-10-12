#!/usr/bin/env python3
"""Convert a PPE42 PIBMEM image and register snapshot to a PPC32 ELF core.

The resulting core uses the Linux PPC32 NT_PRSTATUS layout understood by LLDB.
No Simics or target-side software is required after the files are captured.
"""

import argparse
import pathlib
import re
import struct


REGEX = re.compile(
    r"\b(r(?:[0-9]|[12][0-9]|3[01])|iar|pc|nip|srr0|srr1|msr|"
    r"lr|ctr|xer|cr)\b[^\w\n]{0,12}(0[xX][0-9a-fA-F]{1,16})",
    re.IGNORECASE,
)


def parse_registers(text):
    """Accept Simics tables, key/value lines, or Simics name/value lists."""
    registers = {}
    for name, value in REGEX.findall(text):
        name = name.lower()
        number = int(value, 16)
        if number > 0xFFFFFFFF:
            raise ValueError(f"{name} exceeds a 32-bit PPE42 register")
        registers[name] = number
    if "r1" not in registers:
        raise ValueError("register snapshot must include r1 (the stack pointer)")
    return registers


def make_note(name, kind, data):
    name = name.encode("ascii") + b"\0"
    return (struct.pack(">III", len(name), len(data), kind)
            + name.ljust((len(name) + 3) & ~3, b"\0")
            + data.ljust((len(data) + 3) & ~3, b"\0"))


def executable_entry(elf):
    header = elf.read_bytes()[:52]
    if (len(header) < 52 or header[:4] != b"\x7fELF" or
            header[4:7] != bytes([1, 2, 1]) or
            struct.unpack_from(">H", header, 18)[0] != 20):
        raise ValueError("executable must be a 32-bit big-endian PowerPC ELF")
    return struct.unpack_from(">I", header, 24)[0]


def make_core(memory, base, registers, pc_source="iar", entry=None):
    if not memory:
        raise ValueError("PIBMEM image is empty")
    if not 0 <= base <= 0xFFFFFFFF or base + len(memory) > 0x100000000:
        raise ValueError("PIBMEM image exceeds the 32-bit address space")
    if pc_source not in registers:
        raise ValueError(f"register snapshot must include {pc_source}")

    pc = registers[pc_source]
    # Linux/PPC32 elf_gregset_t: r0-r31, nip, msr, orig_r3, ctr, link,
    # xer, ccr, mq, trap, dar, dsisr, result.  Missing reduced-file GPRs
    # are represented by zero; the hardware has no values for them.
    values = [registers.get(f"r{i}", 0) for i in range(32)]
    values += [pc, registers.get("msr", 0), 0, registers.get("ctr", 0),
               registers.get("lr", 0), registers.get("xer", 0),
               registers.get("cr", 0), 0, 0, 0, 0, 0]

    # The 32-bit Linux elf_prstatus header is 72 bytes.  LLDB strips it
    # before handing the 44-word GPR block to its register context.
    prstatus = bytearray(72)
    struct.pack_into(">I", prstatus, 24, 1)  # pr_pid, for a visible thread
    prstatus += struct.pack(">44I", *values)
    note = make_note("CORE", 1, prstatus)  # NT_PRSTATUS
    if entry is not None:
        # AT_ENTRY is needed by LLDB's ELF core loader to set the executable's
        # section load addresses. Without it, `image lookup -a` can find a
        # symbol by file address while `bt` still shows only a raw PC.
        note += make_note("CORE", 6, struct.pack(">IIII", 9, entry, 0, 0))

    ehdr_size, phdr_size = 52, 32
    note_offset = ehdr_size + phdr_size * 2
    memory_offset = note_offset + len(note)
    ident = b"\x7fELF" + bytes([1, 2, 1, 3]) + bytes(8)
    header = struct.pack(">16sHHIIIIIHHHHHH", ident, 4, 20, 1, pc,
                         ehdr_size, 0, 0, ehdr_size, phdr_size, 2, 0, 0, 0)
    note_header = struct.pack(">IIIIIIII", 4, note_offset, 0, 0,
                              len(note), len(note), 0, 4)
    load_header = struct.pack(">IIIIIIII", 1, memory_offset, base, 0,
                              len(memory), len(memory), 7, 1)
    return header + note_header + load_header + note + memory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pibmem", type=pathlib.Path, required=True,
                        help="raw PIBMEM bytes in address order")
    parser.add_argument("--base", type=lambda x: int(x, 0), required=True,
                        help="address of the first PIBMEM byte (e.g. 0xfff80000)")
    parser.add_argument("--registers", type=pathlib.Path, required=True,
                        help="saved Simics register table or name/value list")
    parser.add_argument("--elf", type=pathlib.Path, required=True,
                        help="matching unstripped PPE42 firmware ELF")
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--pc-source", choices=("iar", "srr0"), default="iar",
                        help="use srr0 to show a fault before an exception handler")
    parser.add_argument("--set", dest="overrides", metavar="REG=VALUE",
                        action="append", default=[],
                        help="override a saved register, e.g. --set r1=0xfffea300")
    args = parser.parse_args()
    registers = parse_registers(args.registers.read_text())
    for item in args.overrides:
        name, separator, value = item.partition("=")
        name = name.lower()
        if not separator or not re.fullmatch(
                r"r(?:[0-9]|[12][0-9]|3[01])|iar|srr0|lr|ctr|cr|xer|msr",
                name):
            parser.error(f"invalid register override: {item}")
        number = int(value, 0)
        if not 0 <= number <= 0xFFFFFFFF:
            parser.error(f"register value is outside 32 bits: {item}")
        registers[name] = number
    memory = args.pibmem.read_bytes()
    args.output.write_bytes(make_core(memory, args.base, registers,
                                      args.pc_source, executable_entry(args.elf)))
    print(f"Created {args.output}; load with: lldb -c {args.output} <firmware.elf>")


if __name__ == "__main__":
    main()
