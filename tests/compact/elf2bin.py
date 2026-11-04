#!/usr/bin/env python3
"""elf2bin.py ELF BIN: raw image of the PT_LOAD segments of a little-endian
ELF32 file, from the lowest physical address, gaps zero-filled (objcopy of
the sh64 toolchain mishandles images above 0x80000000)."""
import struct, sys

data = open(sys.argv[1], 'rb').read()
phoff, = struct.unpack_from('<I', data, 28)
phentsize, phnum = struct.unpack_from('<HH', data, 42)
segs = []
for i in range(phnum):
    p = phoff + i * phentsize
    typ, off, vaddr, paddr, filesz, memsz = struct.unpack_from('<IIIIII', data, p)
    if typ == 1:
        segs.append((paddr, data[off:off + filesz] + b'\0' * (memsz - filesz)))
base = min(a for a, _ in segs)
end = max(a + len(d) for a, d in segs)
img = bytearray(end - base)
for a, d in segs:
    img[a - base:a - base + len(d)] = d
open(sys.argv[2], 'wb').write(img)
print('%s: %d bytes at 0x%08x' % (sys.argv[2], len(img), base))
