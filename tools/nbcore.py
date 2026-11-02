#!/usr/bin/env python3
"""Read a NetBSD/sh5 ELF32 core dump captured over the console.

usage: nbcore.py FILE [ADDR [LEN]]
FILE is either a core file or a console transcript holding
"CORE-BEGIN ... CORE-END" blocks of gzip data as hex records separated by '!'
(as produced by  gzip -c core | hexdump -v -e '32/1 "%02x" "!"').
Prints the process info and registers; with ADDR dumps LEN (default 256)
bytes of memory from the core at that virtual address.
"""
import sys, struct, gzip, re

def load(path):
    data = open(path, 'rb').read()
    if data[:4] == b'\x7fELF':
        return [data]
    cores = []
    for m in re.finditer(rb'CORE-BEGIN (/\S+)\r?\n(.*?)CORE-END', data, re.S):
        body = m.group(2).split(b'\n', 1)[1] if b'\n' in m.group(2) else b''
        toks = [t.strip() for t in body.replace(b'\r', b'').replace(b'\n', b'').split(b'!')]
        hexdata = b''.join(t for t in toks if t and re.fullmatch(rb'[0-9a-f]+', t))
        try:
            cores.append(gzip.decompress(bytes.fromhex(hexdata.decode())))
            print('== %s' % m.group(1).decode())
        except Exception as e:
            print('%s: cannot decode: %s' % (m.group(1).decode(), e))
    return cores

def parse(core):
    (ident, e_type, e_machine, e_version, e_entry, e_phoff, e_shoff, e_flags,
     e_ehsize, e_phentsize, e_phnum) = struct.unpack('<16sHHIIIIIHHH', core[:40])
    segs, notes = [], []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_flags, p_align = \
            struct.unpack('<IIIIIIII', core[off:off + 32])
        if p_type == 1:
            segs.append((p_vaddr, p_memsz, p_offset, p_filesz, p_flags))
        elif p_type == 4:
            pos, end = p_offset, p_offset + p_filesz
            while pos + 12 <= end:
                namesz, descsz, ntype = struct.unpack('<III', core[pos:pos + 12])
                name = core[pos + 12:pos + 12 + namesz].rstrip(b'\0').decode()
                dpos = pos + 12 + (namesz + 3) // 4 * 4
                notes.append((name, ntype, core[dpos:dpos + descsz]))
                pos = dpos + (descsz + 3) // 4 * 4
    return segs, notes

def show(core, addr=None, length=256):
    segs, notes = parse(core)
    for name, ntype, desc in notes:
        if name == 'NetBSD-CORE' and ntype == 1:
            # netbsd_elfcore_procinfo: version, size, signo, sigcode, 4x4 sig
            # words, pid, ppid, pgrp, sid, 6 ids, nlwps, name[32]
            signo, code = struct.unpack('<ii', desc[8:16])
            pid, ppid = struct.unpack('<ii', desc[80:88])
            pname = desc[124:156].split(b'\0')[0].decode()
            print('process %s: signal %d (code %d) pid %d ppid %d' %
                  (pname, signo, code, pid, ppid))
        elif name.startswith('NetBSD-CORE@') and ntype == 33:
            regs = struct.unpack('<%dq' % (len(desc) // 8), desc)
            print('lwp %s: pc=0x%x usr=0x%x' % (name[12:], regs[0], regs[1]))
            for i in range(0, 63, 4):
                print('  ' + ' '.join('r%-2d=%016x' % (i + j, regs[2 + i + j] & (2**64-1))
                                      for j in range(4) if i + j < 63))
            print('  ' + ' '.join('tr%d=%016x' % (j, regs[65 + j] & (2**64-1)) for j in range(8)))
    print('segments:')
    for va, memsz, off, filesz, flags in segs:
        print('  va 0x%08x size 0x%x file 0x%x flags %d' % (va, memsz, filesz, flags))
    if addr is not None:
        for va, memsz, off, filesz, flags in segs:
            if va <= addr < va + filesz:
                o = off + (addr - va)
                chunk = core[o:o + length]
                for i in range(0, len(chunk), 16):
                    b = chunk[i:i + 16]
                    print('%08x  %s  %s' % (addr + i, b.hex(' '),
                          ''.join(chr(c) if 32 <= c < 127 else '.' for c in b)))
                break
        else:
            print('address 0x%x not in core' % addr)

if __name__ == '__main__':
    cores = load(sys.argv[1])
    addr = int(sys.argv[2], 0) if len(sys.argv) > 2 else None
    length = int(sys.argv[3], 0) if len(sys.argv) > 3 else 256
    for c in cores:
        show(c, addr, length)
