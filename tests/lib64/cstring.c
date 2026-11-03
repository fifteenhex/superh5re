/*
 * gcc-generated string code (copies of lib/string.c functions) run on the
 * emulator and checked against simple byte loops.  Exercises the compiler's
 * SHmedia code generation rather than the hand-written lib64 routines.
 */
typedef unsigned long size_t;
typedef unsigned char u8;
void puts(const char *);
void puthex(unsigned long);
extern int failures;

char *k_strchr(const char *s, int c)
{
	for (; *s != (char)c; ++s)
		if (*s == '\0')
			return (char *)0;
	return (char *)s;
}

size_t k_strlen(const char *s)
{
	const char *sc;
	for (sc = s; *sc != '\0'; ++sc)
		;
	return sc - s;
}

size_t k_strlcpy(char *dest, const char *src, size_t size)
{
	size_t ret = k_strlen(src);
	if (size) {
		size_t len = (ret >= size) ? size - 1 : ret;
		int i;
		for (i = 0; i < (int)len; i++)
			dest[i] = src[i];
		dest[len] = '\0';
	}
	return ret;
}

int k_strcmp(const char *cs, const char *ct)
{
	unsigned char c1, c2;
	while (1) {
		c1 = *cs++;
		c2 = *ct++;
		if (c1 != c2)
			return c1 < c2 ? -1 : 1;
		if (!c1)
			break;
	}
	return 0;
}

int k_strncmp(const char *cs, const char *ct, size_t count)
{
	unsigned char c1, c2;
	while (count) {
		c1 = *cs++;
		c2 = *ct++;
		if (c1 != c2)
			return c1 < c2 ? -1 : 1;
		if (!c1)
			break;
		count--;
	}
	return 0;
}

int k_memcmp(const void *cs, const void *ct, size_t count)
{
	const unsigned char *su1, *su2;
	int res = 0;
	for (su1 = cs, su2 = ct; 0 < count; ++su1, ++su2, count--)
		if ((res = *su1 - *su2) != 0)
			break;
	return res;
}

static char buf[128], out[128];

void cstring_tests(void)
{
	int i, a;
	const char *words[] = { "console=ttySC0", "kernel.panic", "a.b", ".x", "nodot", "" };

	for (a = 0; a < 8; a++) {
		for (i = 0; i < 100; i++)
			buf[a + i] = 'a' + (i % 26);
		buf[a + 100] = 0;
		if (k_strlen(buf + a) != 100) {
			failures++; puts("strlen a="); puthex(a); puts(" got="); puthex(k_strlen(buf + a)); puts("\n");
		}
		buf[a + 37] = '.';
		if (k_strchr(buf + a, '.') != buf + a + 37) {
			failures++; puts("strchr a="); puthex(a); puts(" got="); puthex((unsigned long)k_strchr(buf + a, '.')); puts(" want="); puthex((unsigned long)(buf + a + 37)); puts("\n");
		}
		if (k_strchr(buf + a, '!') != 0) {
			failures++; puts("strchr-miss a="); puthex(a); puts("\n");
		}
		if (k_strchr(buf + a, 0) != buf + a + 100) {
			failures++; puts("strchr-nul a="); puthex(a); puts("\n");
		}
		for (i = 0; i < (int)(sizeof(words) / sizeof(words[0])); i++) {
			const char *w = words[i];
			char *dot = k_strchr(w, '.');
			unsigned long nl = dot ? (unsigned long)(dot - w + 1) : 0;
			k_strlcpy(out, w, sizeof(out));
			if (k_strcmp(out, w) != 0 || k_strncmp(out, w, 5) != 0 || k_memcmp(out, w, k_strlen(w)) != 0) {
				failures++; puts("strlcpy/cmp word="); puthex(i); puts("\n");
			}
			if (i == 1 && nl != 7) { failures++; puts("dot pos kernel.panic got="); puthex(nl); puts("\n"); }
			if (i == 2 && nl != 2) { failures++; puts("dot pos a.b got="); puthex(nl); puts("\n"); }
			if (i == 3 && nl != 1) { failures++; puts("dot pos .x got="); puthex(nl); puts("\n"); }
			if (i == 4 && nl != 0) { failures++; puts("dot pos nodot got="); puthex(nl); puts("\n"); }
			if (nl) {
				k_strlcpy(out, w, nl);
				if (k_strlen(out) != nl - 1) { failures++; puts("strlcpy trunc word="); puthex(i); puts(" len="); puthex(k_strlen(out)); puts("\n"); }
			}
		}
	}
	puts("cstring done, failures="); puthex(failures); puts("\n");
}

/* lib/string.c generic forms actually used by the kernel on sh64 */
char *k_strcpy(char *dest, const char *src)
{
	char *tmp = dest;
	while ((*dest++ = *src++) != '\0')
		/* nothing */;
	return tmp;
}

size_t k_strnlen(const char *s, size_t count)
{
	const char *sc;
	for (sc = s; count-- && *sc != '\0'; ++sc)
		/* nothing */;
	return sc - s;
}

void *memcpy(void *, const void *, size_t);
size_t strlen(const char *);
size_t k_strlcpy_real(char *dest, const char *src, size_t size)
{
	size_t ret = strlen(src);
	if (size) {
		size_t len = (ret >= size) ? size - 1 : ret;
		memcpy(dest, src, len);
		dest[len] = '\0';
	}
	return ret;
}

void cstring_tests2(void)
{
	static char sbuf[600], dbuf[600];
	int len, a, i;

	for (len = 0; len < 200; len++)
		for (a = 0; a < 8; a++) {
			for (i = 0; i < len; i++)
				sbuf[a + i] = 'A' + (i % 26);
			sbuf[a + len] = 0;
			for (i = 0; i < 600; i++)
				dbuf[i] = 0x55;
			k_strcpy(dbuf + ((a * 3) & 7), sbuf + a);
			if (k_strnlen(dbuf + ((a * 3) & 7), 600) != (size_t)len || k_strcmp(dbuf + ((a * 3) & 7), sbuf + a)) {
				failures++; puts("strcpy len="); puthex(len); puts(" a="); puthex(a); puts(" got len="); puthex(k_strnlen(dbuf + ((a * 3) & 7), 600)); puts("\n");
			}
			k_strlcpy_real(dbuf, sbuf + a, 600);
			if (k_strcmp(dbuf, sbuf + a)) {
				failures++; puts("strlcpy_real len="); puthex(len); puts(" a="); puthex(a); puts("\n");
			}
		}
	puts("cstring2 done, failures="); puthex(failures); puts("\n");
}

char *strcpy(char *, const char *);
void strcpy_case_tests(void)
{
	static char s[128] __attribute__((aligned(32)));
	static char d[128] __attribute__((aligned(32)));
	const char *strs[] = { "console=ttySC0_abcdefghijklmnopqrstuvwxyz", "console=ttySC0", "console=ttySC0,38400", "console=ttySC0_loglevel=8_abcdefghijklmnopqrstuvwxyz", "a=b", "0123456789abcdef", "0123456789abcde", "0123456789abcdefg" };
	int i, sa, da, j, bad = 0;

	for (i = 0; i < (int)(sizeof(strs) / sizeof(strs[0])); i++)
		for (sa = 0; sa < 8; sa++)
			for (da = 0; da < 32; da += 8) {
				int n = k_strlen(strs[i]);
				for (j = 0; j < 128; j++) { s[j] = 'S'; d[j] = 'D'; }
				for (j = 0; j <= n; j++) s[sa + j] = strs[i][j];
				strcpy(d + da, s + sa);
				for (j = 0; j < 128; j++) {
					char want = (j >= da && j <= da + n) ? strs[i][j - da] : 'D';
					if (d[j] != want) {
						if (bad++ < 12) {
							puts("strcpy-case str="); puthex(i); puts(" sa="); puthex(sa); puts(" da="); puthex(da);
							puts(" byte="); puthex(j); puts(" got="); puthex((u8)d[j]); puts(" want="); puthex((u8)want); puts("\n");
						}
						failures++;
						break;
					}
				}
			}
	puts("strcpy-case done, failures="); puthex(failures); puts("\n");
}
