#!/usr/bin/env python3
"""Embed a filesystem image into a NetBSD kernel's md_root_image array.
usage: mdsetimage.py kernel image   (modifies kernel in place; ELF32 or ELF64 LE)"""
import struct, sys
kern, img = sys.argv[1], sys.argv[2]
data = bytearray(open(kern, 'rb').read()); image = open(img, 'rb').read()
cls = data[4]
if cls == 1:
    (e_shoff,) = struct.unpack_from('<I', data, 0x20); e_shentsize, e_shnum = struct.unpack_from('<HH', data, 0x2e)
    (e_phoff,) = struct.unpack_from('<I', data, 0x1c); e_phentsize, e_phnum = struct.unpack_from('<HH', data, 0x2a)
    def shdr(i):
        o = e_shoff + i * e_shentsize; name, typ, flags, addr, off, size, link, info, align, entsize = struct.unpack_from('<IIIIIIIIII', data, o)
        return typ, addr, off, size, link, entsize
    def phdr(i):
        o = e_phoff + i * e_phentsize; typ, off, vaddr, paddr, filesz, memsz, flags, align = struct.unpack_from('<IIIIIIII', data, o)
        return typ, off, vaddr, filesz, memsz
    symfmt = '<IIIBBH'; symsize = 16
else:
    (e_shoff,) = struct.unpack_from('<Q', data, 0x28); e_shentsize, e_shnum = struct.unpack_from('<HH', data, 0x3a)
    (e_phoff,) = struct.unpack_from('<Q', data, 0x20); e_phentsize, e_phnum = struct.unpack_from('<HH', data, 0x36)
    def shdr(i):
        o = e_shoff + i * e_shentsize; name, typ, flags, addr, off, size, link, info, align, entsize = struct.unpack_from('<IIQQQQIIQQ', data, o)
        return typ, addr, off, size, link, entsize
    def phdr(i):
        o = e_phoff + i * e_phentsize; typ, flags, off, vaddr, paddr, filesz, memsz, align = struct.unpack_from('<IIQQQQQQ', data, o)
        return typ, off, vaddr, filesz, memsz
    symfmt = '<IBBHQQ'; symsize = 24
syms = {}
for i in range(e_shnum):
    typ, addr, off, size, link, entsize = shdr(i)
    if typ != 2: continue
    stypc, saddr, soff, ssize, slink, sent = shdr(link)
    for j in range(size // symsize):
        f = struct.unpack_from(symfmt, data, off + j * symsize)
        if cls == 1: st_name, st_value, st_size = f[0], f[1], f[2]
        else: st_name, st_value, st_size = f[0], f[4], f[5]
        end = data.index(b'\0', soff + st_name); nm = data[soff + st_name:end].decode()
        if nm in ('md_root_image', 'md_root_size'): syms[nm] = (st_value, st_size)
def vaddr_to_off(v):
    for i in range(e_phnum):
        typ, off, vaddr, filesz, memsz = phdr(i)
        if typ == 1 and vaddr <= v < vaddr + filesz: return off + (v - vaddr)
    raise SystemExit('address 0x%x not in a loaded segment' % v)
ia, isz = syms['md_root_image']; sa, ssz = syms['md_root_size']
if len(image) > isz: raise SystemExit('image %d bytes > md_root_image %d bytes' % (len(image), isz))
io = vaddr_to_off(ia); data[io:io + len(image)] = image
struct.pack_into('<I', data, vaddr_to_off(sa), len(image))
open(kern, 'wb').write(data)
print('embedded %d bytes at 0x%x (array %d bytes)' % (len(image), ia, isz))
