/* Requests the 4020 RGA hardening patch must refuse. Starts no RGA job.
 * Build with tests/Makefile, then run on the board as root with CAP_SYS_RAWIO dropped:
 *   setpriv --bounding-set=-sys_rawio --inh-caps=-sys_rawio ./rga-abuse
 * Without 4020, cases 2-5 drop references other clients or jobs hold, and case 6 makes the
 * kernel use a made-up address as a struct dma_buf (an oops at best): run it only on 4020. */
#include <errno.h>
#include <fcntl.h>
#include <linux/dma-heap.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

struct memory_parm { uint32_t width, height, format, size; };
struct external_buffer {
	uint64_t memory;
	uint32_t type, handle;
	struct memory_parm memory_parm;
	uint8_t reserve[252];
};
struct buffer_pool { uint64_t buffers_ptr; uint32_t size; };
enum { DMA_BUFFER = 0, VIRTUAL_ADDRESS, PHYSICAL_ADDRESS, DMA_BUFFER_PTR };
#define MAGIC 'r'
#define IMPORT_BUFFER _IOWR(MAGIC, 0x3, struct buffer_pool)
#define RELEASE_BUFFER _IOW(MAGIC, 0x4, struct buffer_pool)
#define REQUEST_CREATE _IOR(MAGIC, 0x5, uint32_t)
#define REQUEST_CANCEL _IOWR(MAGIC, 0x8, uint32_t)

static int failures;

static void expect(const char *what, int ret, int want_ok)
{
	int good = want_ok ? ret >= 0 : ret < 0;

	printf("%s %s: %s (want %s)\n", good ? "PASS" : "FAIL", what,
	       ret < 0 ? strerror(errno) : "ok", want_ok ? "ok" : "an error");
	failures += !good;
}

static int buffer_op(int rga, unsigned long cmd, struct external_buffer *buffer)
{
	struct buffer_pool pool = { .buffers_ptr = (uintptr_t)buffer, .size = 1 };

	return ioctl(rga, cmd, &pool);
}

int main(void)
{
	int a = open("/dev/rga", O_RDWR), b = open("/dev/rga", O_RDWR);
	int heap = open("/dev/dma_heap/system", O_RDWR);
	struct dma_heap_allocation_data alloc = { .len = 640 * 480 * 4, .fd_flags = O_RDWR | O_CLOEXEC };
	struct external_buffer phys = { .memory = 0x10000000, .type = PHYSICAL_ADDRESS,
					.memory_parm = { .size = 4096 } };
	struct external_buffer in_a = { .type = DMA_BUFFER, .memory_parm = { .size = 640 * 480 * 4 } };
	struct external_buffer in_b;
	uint32_t id = 0, other;

	if (a < 0 || b < 0 || heap < 0 || ioctl(heap, DMA_HEAP_IOCTL_ALLOC, &alloc) < 0) {
		perror("setup");
		return 2;
	}
	in_a.memory = alloc.fd;
	in_b = in_a;

	expect("1 import a physical address without CAP_SYS_RAWIO", buffer_op(a, IMPORT_BUFFER, &phys), 0);

	expect("import a dma-buf in client A", buffer_op(a, IMPORT_BUFFER, &in_a), 1);
	expect("import the same dma-buf in client B", buffer_op(b, IMPORT_BUFFER, &in_b), 1);
	printf("     handles: A %u, B %u\n", in_a.handle, in_b.handle);
	expect("  ...as its own buffer (a separate handle)", in_a.handle != in_b.handle ? 0 : -1, 1);
	other = in_b.handle;
	in_b.handle = in_a.handle;
	expect("2 B releases A's handle", buffer_op(b, RELEASE_BUFFER, &in_b), 0);
	in_b.handle = other;
	expect("  A releases its handle", buffer_op(a, RELEASE_BUFFER, &in_a), 1);
	expect("3 A releases it again (dropped a job's reference)", buffer_op(a, RELEASE_BUFFER, &in_a), 0);
	expect("  B's handle survives A's release", buffer_op(b, RELEASE_BUFFER, &in_b), 1);

	expect("create a request in A", ioctl(a, REQUEST_CREATE, &id), 1);
	expect("4 B cancels A's request", ioctl(b, REQUEST_CANCEL, &id), 0);
	expect("  A cancels it", ioctl(a, REQUEST_CANCEL, &id), 1);
	expect("5 A cancels it again (a second put)", ioctl(a, REQUEST_CANCEL, &id), 0);

	/* A valid dma-buf first, so a kernel that imports buffer by buffer would take it
	 * before reaching the pointer. 4020 checks the whole pool first. */
	struct external_buffer pair[2] = {
		{ .memory = alloc.fd, .type = DMA_BUFFER, .memory_parm = { .size = 640 * 480 * 4 } },
		{ .memory = 0xffff000012345678ull, .type = DMA_BUFFER_PTR,
		  .memory_parm = { .size = 4096 } },
	};
	struct buffer_pool pool = { .buffers_ptr = (uintptr_t)pair, .size = 2 };
	int ret = ioctl(a, IMPORT_BUFFER, &pool), err = errno;

	expect("6 import a kernel pointer as a dma_buf", ret, 0);
	errno = err;
	expect("  ...refused with EINVAL", ret < 0 && err == EINVAL ? 0 : -1, 1);
	/* Had the pool's valid buffer been imported, this import would find it, and its
	 * handle would take two releases instead of one. */
	in_a.handle = 0;
	expect("  import the valid buffer alone", buffer_op(a, IMPORT_BUFFER, &in_a), 1);
	expect("  release it", buffer_op(a, RELEASE_BUFFER, &in_a), 1);
	expect("  the refused pool imported nothing (a second release fails)",
	       buffer_op(a, RELEASE_BUFFER, &in_a), 0);

	close(alloc.fd);
	close(heap);
	close(b);
	close(a);
	printf("%d failures\n", failures);
	return failures != 0;
}
