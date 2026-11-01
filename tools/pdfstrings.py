import re, sys, zlib
data = open(sys.argv[1], 'rb').read()
n = int(sys.argv[2]) if len(sys.argv) > 2 else 3
out = []
for m in re.finditer(rb'stream\r?\n(.*?)\r?\nendstream', data, re.S):
    s = m.group(1)
    try:
        s = zlib.decompress(s)
    except Exception:
        continue
    # text operands: (...) Tj and [..] TJ
    txt = b''.join(re.findall(rb'\((.*?)(?<!\\)\)', s))
    if txt:
        out.append(txt)
    if len(out) >= n:
        break
for t in out:
    print(t.decode('latin1')[:1500])
    print('----')
