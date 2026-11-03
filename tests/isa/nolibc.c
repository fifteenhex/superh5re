/* MODE=nolibc: Linux user space program (works as /init). */
#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include "harness.h"

int isa_main(const char *const *only);

void isa_puts(const char *s)
{
	write(1, s, strlen(s));
}

void isa_exit(int failures)
{
	isa_puts("isa: DONE\n");
	if (getpid() == 1) {
		/* we are init; exiting would panic the kernel */
		for (;;)
			sleep(60);
	}
	exit(failures ? 1 : 0);
}

int main(int argc, char **argv)
{
	int i, n = 0;
	static const char *only[16];

	for (i = 1; i < argc && n < 15; i++) {
		if (!strcmp(argv[i], "-v"))
			isa_verbose = 1;
		else
			only[n++] = argv[i];
	}
	only[n] = 0;
	return isa_main(n ? only : 0);
}
