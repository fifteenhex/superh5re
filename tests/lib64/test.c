/*
 * Exercise the Linux arch/sh/lib64 string routines (memcpy, memset, strlen,
 * strcpy) for every length and alignment and compare against byte loops.
 * Output goes to the SCIF transmit register; ends with "DONE".
 */
typedef unsigned long size_t;
typedef unsigned char u8;
void *memcpy(void *, const void *, size_t);
void *memset(void *, int, size_t);
size_t strlen(const char *);
char *strcpy(char *, const char *);

#define SCIF_TDR (*(volatile u8 *)0x0a03000c)
static void putc(char c) { SCIF_TDR = c; }
void puts(const char *s) { while (*s) putc(*s++); }
void puthex(unsigned long v)
{
	const char *d = "0123456789abcdef";
	int i;
	for (i = 28; i >= 0; i -= 4)
		putc(d[(v >> i) & 15]);
}

static u8 src[1024], dst[1024], ref[1024];
int failures;
void cstring_tests(void);
void cstring_tests2(void);
void strcpy_case_tests(void);

static void fail(const char *what, int len, int sa, int da, int at)
{
	if (failures++ < 20) {
		puts(what); puts(" len="); puthex(len); puts(" sa="); puthex(sa);
		puts(" da="); puthex(da); puts(" byte="); puthex(at);
		puts(" got="); puthex(dst[at]); puts(" want="); puthex(ref[at]);
		puts("\n");
	}
}

static void init(void)
{
	int i;
	for (i = 0; i < 1024; i++) {
		src[i] = 0x40 + (i & 0x3f);
		dst[i] = ref[i] = 0xaa;
	}
}

static int check(const char *what, int len, int sa, int da)
{
	int i, bad = 0;
	for (i = 0; i < 1024; i++)
		if (dst[i] != ref[i]) {
			if (!bad)
				fail(what, len, sa, da, i);
			bad++;
		}
	return bad;
}

int main(void)
{
	int len, sa, da, i;

	puts("lib64 string tests\n");
	for (len = 0; len <= 600; len += (len < 100 ? 1 : 7))
		for (sa = 0; sa < 8; sa++)
			for (da = 0; da < 40; da += (da < 8 ? 1 : 3)) {
				init();
				for (i = 0; i < len; i++)
					ref[32 + da + i] = src[32 + sa + i];
				memcpy(dst + 32 + da, src + 32 + sa, len);
				check("memcpy", len, sa, da);
			}
	puts("memcpy done, failures="); puthex(failures); puts("\n");

	for (len = 0; len <= 600; len += (len < 100 ? 1 : 7))
		for (da = 0; da < 40; da += (da < 8 ? 1 : 3)) {
			init();
			for (i = 0; i < len; i++)
				ref[32 + da + i] = 0x5c;
			memset(dst + 32 + da, 0x5c, len);
			check("memset", len, 0, da);
		}
	puts("memset done, failures="); puthex(failures); puts("\n");

	for (len = 0; len <= 100; len++)
		for (sa = 0; sa < 8; sa++) {
			init();
			src[32 + sa + len] = 0;
			if (strlen((char *)src + 32 + sa) != (size_t)len) {
				failures++;
				puts("strlen len="); puthex(len); puts(" sa="); puthex(sa);
				puts(" got="); puthex(strlen((char *)src + 32 + sa)); puts("\n");
			}
			for (da = 0; da < 8; da++) {
				init();
				src[32 + sa + len] = 0;
				for (i = 0; i <= len; i++)
					ref[32 + da + i] = src[32 + sa + i];
				strcpy((char *)dst + 32 + da, (char *)src + 32 + sa);
				check("strcpy", len, sa, da);
			}
		}
	cstring_tests();
	cstring_tests2();
	strcpy_case_tests();
	puts("all done, failures="); puthex(failures); puts("\nDONE\n");
	return 0;
}
