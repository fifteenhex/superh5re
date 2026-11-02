#!/usr/bin/env python3
"""Drive qemu-system-sh5 over its stdio console with expect/send steps.

usage: qrun.py [--qemu PATH] [--kernel FILE] [--timeout S] [--qemu-args 'ARGS']
               [--log FILE] step...
steps: expect:TEXT   wait for TEXT on the console
       send:TEXT     type TEXT (\\r and \\n escapes allowed)
       sleep:N       keep reading for N seconds
The transcript is printed at the end (and written to --log, default qrun.out).
"""
import sys, os, subprocess, select, time

def main(argv):
    qemu = os.environ.get('QEMU', 'qemu-system-sh5')
    kernel = 'netbsd'
    timeout = 120.0
    extra = []
    logname = 'qrun.out'
    args = argv[1:]
    while args and args[0].startswith('--'):
        a = args.pop(0)
        if a == '--qemu':
            qemu = args.pop(0)
        elif a == '--kernel':
            kernel = args.pop(0)
        elif a == '--timeout':
            timeout = float(args.pop(0))
        elif a == '--qemu-args':
            extra = args.pop(0).split()
        elif a == '--log':
            logname = args.pop(0)
        else:
            sys.exit('unknown option ' + a)
    cmd = [qemu, '-M', 'cayman', '-kernel', kernel, '-nographic'] + extra
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, bufsize=0)
    log = open(logname, 'wb')
    buf = b''
    start = time.time()

    def readsome(t):
        nonlocal buf
        r, _, _ = select.select([p.stdout], [], [], t)
        if r:
            d = os.read(p.stdout.fileno(), 65536)
            if d:
                buf += d
                log.write(d)
                log.flush()
            return bool(d)
        return False

    def expect(text, t):
        nonlocal buf
        end = time.time() + t
        while time.time() < end:
            i = buf.find(text.encode())
            if i >= 0:
                buf = buf[i + len(text):]
                return True
            readsome(min(0.5, max(0.0, end - time.time())))
        return False

    ok = True
    for step in args:
        kind, _, val = step.partition(':')
        val = val.replace('\\r', '\r').replace('\\n', '\n')
        if kind == 'expect':
            if not expect(val, timeout - (time.time() - start)):
                print('TIMEOUT waiting for %r' % val)
                ok = False
                break
        elif kind == 'send':
            for ch in val.encode():
                p.stdin.write(bytes([ch]))
                p.stdin.flush()
                time.sleep(0.05)
        elif kind == 'sleep':
            end = time.time() + float(val)
            while time.time() < end:
                readsome(0.2)
    readsome(1.0)
    p.kill()
    p.wait()
    log.close()
    sys.stdout.write(open(logname, 'rb').read().decode('latin1'))
    return 0 if ok else 1

if __name__ == '__main__':
    sys.exit(main(sys.argv))
