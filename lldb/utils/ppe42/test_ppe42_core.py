"""Format checks for the PPE42 ELF core converter."""

import importlib.util
import pathlib
import struct
import unittest


SCRIPT = pathlib.Path(__file__).with_name("ppe42_core.py")
SPEC = importlib.util.spec_from_file_location("ppe42_core", SCRIPT)
core = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(core)


class PPE42CoreTest(unittest.TestCase):
    def test_simics_table_and_linux_register_layout(self):
        registers = core.parse_registers(
            "| iar | 0xFFF81234 | r1 | 0xFFFEA300 |\n"
            "| lr | 0xFFF81000 | ctr | 0x12345678 |\n"
            "| srr0 | 0xFFF80100 | cr | 0x20000000 |\n")
        image = core.make_core(b"\x12\x34\x56\x78", 0xFFF80000,
                               registers, "srr0")
        self.assertEqual(image[:4], b"\x7fELF")
        self.assertEqual(struct.unpack_from(">H", image, 16)[0], 4)
        self.assertEqual(struct.unpack_from(">I", image, 24)[0], 0xFFF80100)
        note_offset = struct.unpack_from(">I", image, 52 + 4)[0]
        desc_offset = note_offset + 12 + 8  # note header and padded CORE name
        self.assertEqual(struct.unpack_from(">I", image, desc_offset + 24)[0], 1)
        gpr = desc_offset + 72
        self.assertEqual(struct.unpack_from(">I", image, gpr + 4)[0],
                         0xFFFEA300)  # r1
        self.assertEqual(struct.unpack_from(">I", image, gpr + 32 * 4)[0],
                         0xFFF80100)  # nip / LLDB pc
        self.assertEqual(struct.unpack_from(">I", image, gpr + 35 * 4)[0],
                         0x12345678)  # ctr
        self.assertEqual(struct.unpack_from(">I", image, gpr + 36 * 4)[0],
                         0xFFF81000)  # lr
        load = 52 + 32
        memory_offset = struct.unpack_from(">I", image, load + 4)[0]
        self.assertEqual(image[memory_offset:], b"\x12\x34\x56\x78")

    def test_rejects_out_of_range_memory(self):
        with self.assertRaisesRegex(ValueError, "address space"):
            core.make_core(b"\0" * 16, 0xFFFFFFF8,
                           {"r1": 0x1000, "iar": 0x2000})


if __name__ == "__main__":
    unittest.main()
