#!/usr/bin/env python3
"""checklog.py VIVADO_LOG... - the synthesis messages that have cost silicon.

build.tcl promotes two of them to errors while synthesising; this reads a
finished log (vc.py returns it as vivado.log) and reports all three, with
the lines that matter and nothing else:

  Synth 8-11241  undeclared symbol, assumed a one-bit wire   (rtl/sh5_core.sv, 2026-11-05)
  Synth 8-3848   a net in one of our modules has no driver    (register file, 2026-11-07)
  Synth 8-4767   an array kept in registers because it is written from
                 several ports in one process, or the write is "invalid"
                 (the same register file; Verilator ran it correctly)

Exit status 1 if anything was found. The IP cores (MIG, PCIe) produce the
first two benignly and are skipped: only paths under rtl/, fpga/ and
fpgaslop/rtl/, and modules named after those files, count.
"""
import re, sys, os

OURS = re.compile(r"(^|/)(rtl|fpga|fpgaslop/rtl)/[^/]*\.sv")
IP_MODULE = re.compile(r"^(sh5_pcie_|sh5_ddr3|mig_7series|axi_pcie|xpm_)")

def scan(path):
    with open(path, errors="replace") as f:
        lines = f.read().split("\n")
    bad = []
    for i, line in enumerate(lines):
        if "Synth 8-11241" in line and OURS.search(line):
            bad.append(line.strip())
        m = re.search(r"Synth 8-3848\] Net (\S+) in module/entity (\S+) does not have driver", line)
        if m and (m.group(2).startswith("sh5_") or m.group(2) in ("memarb", "mem_cdc", "req_to_axi4", "axi4_to_req")
                  or m.group(2).startswith("slop_")) and not IP_MODULE.match(m.group(2)):
            bad.append(line.strip())
        if "Synth 8-4767" in line and OURS.search(line):
            reasons = [r.strip() for r in lines[i + 1:i + 7] if r.strip().startswith(("1:", "2:", "3:", "4:", "5:"))]
            hard = [r for r in reasons if "multiple writes" in r or "Invalid write" in r or "No valid clock" in r]
            if hard:
                bad.append(line.strip() + "\n    " + "\n    ".join(hard))
    return bad

def main(argv):
    if len(argv) < 2:
        print(__doc__); return 2
    total = 0
    for path in argv[1:]:
        bad = scan(path)
        for b in bad:
            print(b)
        total += len(bad)
        print(f"checklog: {path}: {len(bad)} finding(s)")
    return 1 if total else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv))
