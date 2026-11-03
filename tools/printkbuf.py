#!/usr/bin/env python3
"""Decode a Linux 5.x printk ring buffer dumped with the QEMU monitor.

usage: printkbuf.py TRANSCRIPT
TRANSCRIPT holds the output of  xp /<N>xb <phys addr of __log_buf>
(as produced by qrun.py 'mon:xp /16384xb 0x807e6fc0').  Records are
struct printk_log: u64 ts_nsec, u16 len, u16 text_len, u16 dict_len,
u8 facility, u8 flags, text, dict, padded to 8 bytes (little endian).
"""
import sys, re, struct

def main(path):
    data = open(path, 'rb').read().decode('latin1')
    data = data.replace('\r', '')
    if '[monitor] xp' in data:
        data = data.split('[monitor] xp', 1)[1]
    buf = bytearray()
    for line in data.split('\n'):
        m = re.match(r'\s*[0-9a-fx]+:((?:\s+0x[0-9a-f]{2})+)\s*$', line)
        if m:
            buf += bytes(int(b, 16) for b in m.group(1).split())
    pos = 0
    while pos + 16 <= len(buf):
        ts, ln, tl, dl, fac, flags = struct.unpack_from('<QHHHBB', buf, pos)
        if ln == 0 or ln < 16 or pos + ln > len(buf):
            break
        text = buf[pos + 16:pos + 16 + tl].decode('latin1')
        print('[%5d.%06d] %s' % (ts // 10**9, (ts % 10**9) // 1000, text))
        pos += ln

if __name__ == '__main__':
    main(sys.argv[1])
