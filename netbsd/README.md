# Building a NetBSD 3.1 kernel for the QEMU Cayman machine

Sources: NetBSD 3.1 `syssrc.tgz`, `gnusrc.tgz`, `src.tgz`, `sharesrc.tgz`
(source/sets) and the evbsh5 `base.tgz` (binary/sets).

## Cross tools on a modern Linux host

```
sh build.sh -m evbsh5 -U -N 1 -V MKMAN=no -O obj -T tools -j4 tools
```
with
```
HOST_CFLAGS="-O -fcommon -Wno-error -Wno-implicit-function-declaration -Wno-implicit-int -Wno-int-conversion -Wno-incompatible-pointer-types -Wno-return-mismatch -std=gnu89 -DARG_MAX=262144"
```
and the patches in `patches/`:

- `tools_gcc_Makefile.patch`: build only the C compiler.
- `usr.bin_ctags_getline.patch`, `usr.bin_gencat_gencat.c.patch`,
  `bin_pax_options.c.patch`: rename `getline`, which clashes with glibc.

The gcc install step needs `tools/lib/gcc-lib/sh5le--netbsd/3.3.3` to exist.
Resulting cross compiler: `sh5le--netbsd-gcc` (gcc 3.3.3, binutils 2.15).

## Kernel

- `CAYMAN_QEMU`: the CAYMAN configuration plus `MEMORY_DISK_HOOKS`,
  `MEMORY_DISK_IS_ROOT`, `MEMORY_DISK_ROOT_SIZE=24576` and `pseudo-device md`.
  Copy to `sys/arch/evbsh5/conf/`.
- `sys_arch_sh5_sh5_in_cksum.S.patch`: fix the pseudo-header checksum
  overflow (see `../docs/cayman-platform.md`).

```
sh build.sh -m evbsh5 -U -u -N 1 -V MKMAN=no -O obj -T tools -j8 kernel=CAYMAN_QEMU
```

## Root image and boot

```
sh mkroot.sh base.tgz tools root.img
cp obj/sys/arch/evbsh5/compile/CAYMAN_QEMU/netbsd netbsd-qemu
python3 mdsetimage.py netbsd-qemu root.img
qemu-system-sh5 -M cayman -kernel netbsd-qemu -nographic
```

The kernel comes up single-user; press return at the shell prompt. The
built-in `/etc/rc` is only used for multi-user boot.
