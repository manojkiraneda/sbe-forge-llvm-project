# PPE42 PIBMEM crash dumps in LLDB

The PPE42 toolchain includes a host LLDB and `share/ppe42/ppe42_core.py`. The
converter wraps a raw PIBMEM image and a text register snapshot in a 32-bit,
big-endian PowerPC ELF core. LLDB reads that core alongside the **unstripped**
firmware ELF, which supplies code, symbols, and `.debug_frame` unwind data.

Capture PIBMEM as raw bytes in ascending address order, and save the Simics
`sregs-poz` or `pregs-poz` output to a text file. The parser accepts the
pipe-delimited register table as well as `name=0x...` lines. It needs at least
`r1` and `iar`; include the other available GPRs, `lr`, `cr`, `ctr`, `xer`, and
`msr` for useful debugging. Supply the address of the **first captured byte**
as `--base`:

```sh
python3 share/ppe42/ppe42_core.py \
  --pibmem sppe_pibmem.bin --base 0xfff80000 \
  --registers sppe_registers.txt --output sppe.core
bin/lldb /path/to/odyssey_sppe.out -c sppe.core
(lldb) register read pc r1 lr
(lldb) bt
```

For a dump taken after the exception handler has reached `pk_halt`, `iar`
points at the halt instruction. Use `--pc-source srr0` to inspect the faulting
instruction. The live `r1` and `lr` may then belong to the handler, so use
`--set r1=...` and `--set lr=...` if the original values were saved separately.
An accurate backtrace requires the original stack bytes and registers. The
converter does not invent frames missing from a partial PIBMEM capture.

The core uses the Linux PPC32 `NT_PRSTATUS` GPR order. LLDB maps the saved
`iar`/`srr0` to `pc` and uses PPE42's existing PowerPC DWARF unwind data.
Registers absent from the reduced PPE42 register file are zero-filled in the
conventional 32-register PPC core format.
