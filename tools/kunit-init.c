/* The /init of tools/kunit.sh's initramfs: load the modules listed in /modules in order,
 * print each KUnit suite's results from debugfs, power off. Static, so the initramfs
 * needs nothing else. Lines for kunit.sh start with "kunit-init: ". */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/syscall.h>
#include <unistd.h>

static void print_file(const char *path)
{
	char buf[4096];
	ssize_t n;
	int fd = open(path, O_RDONLY);

	if (fd < 0) {
		printf("kunit-init: error: open %s: %s\n", path, strerror(errno));
		return;
	}
	while ((n = read(fd, buf, sizeof(buf))) > 0)
		fwrite(buf, 1, n, stdout);
	close(fd);
}

int main(void)
{
	char line[512], path[512];
	struct dirent *e;
	FILE *list;
	DIR *dir;
	int fd;

	/* The initramfs has no /dev/console, so the kernel gave us no stdout. */
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
	fd = open("/dev/console", O_RDWR);
	if (fd >= 0) {
		dup2(fd, 0);
		dup2(fd, 1);
		dup2(fd, 2);
	}
	setvbuf(stdout, NULL, _IOLBF, 0);
	if (mount("debugfs", "/debugfs", "debugfs", 0, NULL))
		printf("kunit-init: error: mount debugfs: %s\n", strerror(errno));

	/* KUnit runs a module's suites while loading it (CONFIG_KUNIT_AUTORUN_ENABLED). */
	list = fopen("/modules", "r");
	if (!list)
		printf("kunit-init: error: open /modules: %s\n", strerror(errno));
	while (list && fgets(line, sizeof(line), list)) {
		line[strcspn(line, "\n")] = 0;
		fd = open(line, O_RDONLY);
		if (fd < 0 || syscall(SYS_finit_module, fd, "", 0))
			printf("kunit-init: error: load %s: %s\n", line, strerror(errno));
		else
			printf("kunit-init: loaded %s\n", line);
		if (fd >= 0)
			close(fd);
	}

	dir = opendir("/debugfs/kunit");
	if (!dir)
		printf("kunit-init: error: open /debugfs/kunit: %s\n", strerror(errno));
	while (dir && (e = readdir(dir))) {
		if (e->d_name[0] == '.')
			continue;
		printf("kunit-init: suite %s\n", e->d_name);
		snprintf(path, sizeof(path), "/debugfs/kunit/%s/results", e->d_name);
		print_file(path);
	}
	printf("kunit-init: done\n");
	sync();
	reboot(RB_POWER_OFF);
	return 1;
}
