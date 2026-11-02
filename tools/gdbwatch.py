#!/usr/bin/env python3 -u
"""Set QEMU gdbstub write watchpoints and log every hit.

usage: gdbwatch.py HOST:PORT ADDR[,LEN] [ADDR[,LEN]...]
Connects to a running qemu-system-sh5 started with -gdb tcp::PORT, inserts
write watchpoints, continues, and on each hit prints the registers (gdb
numbering: r0-r63, pc, sr, ... as the target's gdbstub defines them) and the
16 bytes at the watched address, then continues.  Ends when QEMU goes away.
"""
import sys, socket, re

def rsp_send(s, payload):
    s.sendall(b'$' + payload + b'#%02x' % (sum(payload) & 0xff))

def rsp_recv(s):
    data = b''
    while True:
        c = s.recv(1)
        if not c:
            raise EOFError
        if c == b'+' or c == b'-':
            continue
        if c == b'$':
            break
    while True:
        c = s.recv(1)
        if not c:
            raise EOFError
        if c == b'#':
            s.recv(2)
            s.sendall(b'+')
            return data
        data += c

def cmd(s, payload):
    rsp_send(s, payload)
    return rsp_recv(s)

def main(argv):
    host, port = argv[1].split(':')
    s = socket.create_connection((host, int(port)))
    cmd(s, b'QStartNoAckMode')
    cmd(s, b'?')
    watches = []
    for a in argv[2:]:
        addr, _, ln = a.partition(',')
        addr = int(addr, 0); ln = int(ln or '4', 0)
        print('watch 0x%x,%d: %s' % (addr, ln, cmd(s, b'Z2,%x,%x' % (addr, ln)).decode()))
        watches.append((addr, ln))
    rsp_send(s, b'c')
    n = 0
    while True:
        try:
            r = rsp_recv(s)
        except EOFError:
            print('connection closed after %d hits' % n)
            return
        n += 1
        m = re.search(rb'watch:([0-9a-f]+)', r)
        waddr = int(m.group(1), 16) if m else None
        regs = cmd(s, b'g')
        vals = [int.from_bytes(bytes.fromhex(regs[i:i + 16].decode()), 'little')
                for i in range(0, len(regs) - 15, 16)]
        print('--- hit %d: %s' % (n, r.decode()[:60]))
        if len(vals) >= 74:
            print('    pc=%x sr=%x ' % (vals[72], vals[73]) +
                  ' '.join('tr%d=%x' % (i, vals[64 + i]) for i in range(8)))
        print('    ' + ' '.join('r%d=%x' % (i, vals[i]) for i in range(0, 32)))
        for addr, ln in watches:
            mem = cmd(s, b'm%x,10' % addr)
            print('    mem[0x%x] = %s' % (addr, mem.decode()))
        rsp_send(s, b'c')

if __name__ == '__main__':
    main(sys.argv)
