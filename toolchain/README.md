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
