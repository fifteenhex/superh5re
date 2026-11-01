import re, sys, zlib
data = open(sys.argv[1], 'rb').read()
pat = re.compile(sys.argv[2].encode(), re.I)
for m in re.finditer(rb'stream\r?\n(.*?)\r?\nendstream', data, re.S):
    try: s = zlib.decompress(m.group(1))
    except Exception: continue
    txt = b''.join(re.findall(rb'\((.*?)(?<!\\)\)', s))
    if pat.search(txt):
        print(txt.decode('latin1')[:3000]); print('----')
