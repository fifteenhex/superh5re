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
- `getline_renames.patch`: rename `getline` in ctags, gencat, pax, ftp,
  unifdef, inetd and lpr, which clashes with glibc.

Apply with `patch -p1` in the directory containing `usr/src`.

The gcc install step needs `tools/lib/gcc-lib/sh5le--netbsd/3.3.3` to exist.
Resulting cross compiler: `sh5le--netbsd-gcc` (gcc 3.3.3, binutils 2.15).

## Kernel

- `CAYMAN_QEMU`: the CAYMAN configuration plus `MEMORY_DISK_HOOKS`,
  `MEMORY_DISK_IS_ROOT`, `MEMORY_DISK_ROOT_SIZE=24576` and `pseudo-device md`.
  Copy to `sys/arch/evbsh5/conf/`.
- `CAYMAN64_QEMU`: the same with `SH5_ABI=64`, `EXEC_ELF64` and
  `COMPAT_NETBSD32`, so the 32-bit userland runs on the 64-bit kernel.
- `sys_arch_sh5.patch`:
  - `in_cksum.S`: fix the pseudo-header checksum overflow (see
    `../docs/cayman-platform.md`).
  - `param.h`: 512-byte mbufs for LP64; with 256 bytes
    `sizeof(struct _m_ext) > MHLEN` and the 64-bit kernel panics at boot.
  - `vmparam.h`: keep 32-bit processes below 2 GB on the 64-bit kernel.
    Effective addresses are sign-extended from bit 31, so a 32-bit stack at
    0xbffff000 appears to the kernel as 0xffffffffbffff000, outside the
    process map, and execve of init fails with EFAULT.
  - `trap.c`: sign-extend `pcb_onfault` when resuming after a copyin/copyout
    fault; the zero-extended address is outside the 32-bit effective address
    space and the CPU raises IADDERR in kernel mode.

```
sh build.sh -m evbsh5 -U -u -N 1 -V MKMAN=no -O obj -T tools -j8 kernel=CAYMAN_QEMU
sh build.sh -m evbsh5 -U -u -N 1 -V MKMAN=no -O obj -T tools -j8 kernel=CAYMAN64_QEMU
```

## Root image and boot

```
sh mkroot.sh base.tgz etc.tgz tools root.img
cp obj/sys/arch/evbsh5/compile/CAYMAN_QEMU/netbsd netbsd-qemu
python3 mdsetimage.py netbsd-qemu root.img
qemu-system-sh5 -M cayman -kernel netbsd-qemu -nographic
```

The root image (32 MB) holds `/rescue`, the `etc` set, the statically linked
programs the rc scripts and a console login need, device nodes from
`MAKEDEV -s`, and an `rc.conf` with `rc_configured=YES`, hostname `cayman`,
`sm0` at 10.0.2.15 and default route 10.0.2.2 (QEMU user networking).
The kernel boots multi-user to a getty on the console; log in as `root`
without a password.

Status:

- CAYMAN_QEMU (32-bit): multi-user, login, network (ping to the gateway).
- CAYMAN64_QEMU (64-bit): multi-user and login. `ifconfig` and `route` fail
  with "Invalid argument" / "Device not configured": the 32-bit network
  tools do not work through COMPAT_NETBSD32 in NetBSD 3.1.
- Open: some processes die with SIGBUS/SIGSEGV during rc (two `sh` and
  `tset` on 32-bit, `grep` and `csh` on 64-bit); one 32-bit boot in four hung
  in `/etc/rc` with a process looping on `wait4` returning ECHILD.
