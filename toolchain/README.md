# sh64-linux cross toolchain (kernel only)

Sources: binutils 2.30 (last release with SH-5), gcc 6.5.0 (SH-5 deprecated
in 6, removed in 7). No libc; enough to build the Linux kernel.

## binutils

```
../binutils-2.30/configure --target=sh64-linux --prefix=$P --enable-obsolete \
    --disable-nls --disable-werror --disable-gdb --disable-sim
make MAKEINFO=true && make install MAKEINFO=true
```

## gcc

`contrib/download_prerequisites` fetches gmp/mpfr/mpc/isl into the tree.
With a 2025-era host gcc (C23 default) the in-tree gmp needs
`CC="gcc -std=gnu11 -Wno-implicit-function-declaration -Wno-implicit-int
-Wno-int-conversion -Wno-incompatible-pointer-types -Wno-return-mismatch"`.

```
../gcc-6.5.0/configure --target=sh64-linux --prefix=$P --enable-languages=c \
    --disable-shared --disable-threads --disable-libssp --disable-libgomp \
    --disable-libquadmath --disable-libatomic --disable-decimal-float \
    --disable-libmudflap --disable-libsanitizer --without-headers --with-newlib \
    --disable-nls --enable-obsolete --disable-multilib --with-gnu-as --with-gnu-ld \
    CFLAGS="-O2 -g0" CXXFLAGS="-O2 -g0 -fpermissive -Wno-error"
make MAKEINFO=true all-gcc && make MAKEINFO=true install-gcc
```

Apply `gcc-6.5-sh64-legitimate-constant.patch` first: in gcc 6.5
`sh_legitimate_constant_p` returns false for every SHmedia constant, so
`emit_move_insn` forces each constant into the pool, the pool address is again
a constant, and cc1 overflows its stack ("internal compiler error:
Segmentation fault") on functions as small as `int f(void){return 0;}`.

Install binutils and gcc into the same prefix, or symlink the binutils
programs into `$P/sh64-linux/bin/`: gcc looks for `as` and `ld` there and
falls back to the host's.

The kernel needs libgcc for the 64-bit shift helpers: after `install-gcc`
run `make all-target-libgcc install-target-libgcc` (works with
`--without-headers`).

## gcc 6.5 inline division bug (SHmedia)

The default division strategy for SHmedia expands `a / b` and `a % b`
inline (`divsi_inv_m1`, `_m2`, `_m3`, `_m1_3` in `gcc/config/sh/sh.md`).
Their scratch operands are plain `=r` clobbers, so the register allocator
may give a scratch the same register as an input that the split still
reads afterwards. In Linux 6.15 `lib/crypto/blake2s-selftest.c` the
sequence `l = (l + 37) % ++i` came out as `sub r0,r0,r0` (the constant 92
clobbered) and `shard r6,r6,r6` (the shift count clobbered), the remainder
was garbage and `blake2s_update` ran off the end of its buffer.

`gcc-6.5-sh64-divsi-inv-early-clobber.patch` makes the clobbers
`=&r`. It is untested: rebuilding gcc needs the gmp/mpfr/mpc sources
again. The kernel branch avoids the patterns with `-mdiv=call`
(`__sdivsi3`/`__udivsi3` from `arch/sh/lib64`). Any userland built with
this gcc needs the patch or `-mdiv=call`.

Related: labels defined in a SHmedia text section are marked ISA32 and
every reference to them (movi/shori, pt) gets bit 0 set. Data tables must
live in `.rodata`/`.data` (libgcc works around this with `datalabel`).
