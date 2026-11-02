# Bare-metal tests

Small SHmedia programs linked at 0xc0000000 (the Cayman kernel address; the
emulator loads them at physical 0x80000000 and starts with the MMU off). Each
test ends in `trapa r63`, which with RESVEC = 0 lands at address 0 as a panic.
Run under QEMU with the register dump enabled and read the state printed at
the trap:

```
qemu-system-sh5 -M cayman -kernel add64.elf -nographic -d cpu,exec,nochain,int -D out.log
```

| Test | Checks |
|---|---|
| `add64.S` | 64-bit `add` versus `add.l`/`addz.l`, `mshflo.l`/`mshfhi.l` folding |
