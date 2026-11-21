/* Bad requests the 5050 NPU hardening patch must refuse without touching memory.
 * Build with tests/Makefile, then run on the board as root: ./rknpu-abuse
 * Never run it against a driver without 5050: case 2 dereferences a wild pointer there. */
#include <errno.h>
#include <fcntl.h>
#include <linux/dma-heap.h>
#include <linux/ioctl.h>
#include <linux/types.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

struct mem_create { __u32 handle, flags; __u64 size, obj_addr, dma_addr, sram_size; __s32 domain; __u32 core_mask; };
struct mem_destroy { __u32 handle, reserved; __u64 obj_addr; };
struct mem_sync { __u32 flags, reserved; __u64 obj_addr, offset, size; };
struct subcore { __u32 task_start, task_number; };
struct submit {
	__u32 flags, timeout, task_start, task_number, task_counter; __s32 priority;
	__u64 task_obj_addr; __u32 domain, reserved; __u64 task_base_addr; __s64 elapsed;
	__u32 core_mask; __s32 fence_fd; struct subcore subcore_task[5];
};
#define MAGIC 'r'
#define SUBMIT _IOWR(MAGIC, 0x01, struct submit)
#define SUBMIT_SHORT _IOC(_IOC_READ | _IOC_WRITE, MAGIC, 0x01, 8)
#define CREATE _IOWR(MAGIC, 0x02, struct mem_create)
#define DESTROY _IOWR(MAGIC, 0x04, struct mem_destroy)
#define SYNC _IOWR(MAGIC, 0x05, struct mem_sync)
#define WILD 0xffff800012345678ULL

static int failures;

static void expect(const char *what, int ret, int want_errno)
{
	int got = ret < 0 ? errno : 0;
	int good = got == want_errno;

	printf("%s %s: %s (want %s)\n", good ? "PASS" : "FAIL", what,
	       got ? strerror(got) : "ok", want_errno ? strerror(want_errno) : "ok");
	failures += !good;
}

static __u64 import(int npu, int *buf_fd)
{
	struct dma_heap_allocation_data alloc = { .len = 4096, .fd_flags = O_RDWR | O_CLOEXEC };
	struct mem_create create = { 0 };
	int heap = open("/dev/dma_heap/system", O_RDWR);

	if (heap < 0 || ioctl(heap, DMA_HEAP_IOCTL_ALLOC, &alloc) < 0) {
		perror("dma_heap alloc");
		return 0;
	}
	close(heap);
	*buf_fd = alloc.fd;
	create.handle = alloc.fd;
	create.size = 4096;
	expect("import a 4 KiB dma-buf", ioctl(npu, CREATE, &create), 0);
	return create.obj_addr;
}

int main(void)
{
	int npu = open("/dev/rknpu", O_RDWR), other = open("/dev/rknpu", O_RDWR), buf_fd = -1;
	struct mem_create create = { .size = 1ULL << 40 };
	struct mem_sync sync = { .obj_addr = WILD };
	struct mem_destroy destroy = { .obj_addr = WILD };
	struct submit submit = { .task_obj_addr = WILD, .task_number = 1, .core_mask = 1,
				 .subcore_task = { { 0, 1 } } };
	__u64 obj;

	if (npu < 0 || other < 0) {
		perror("/dev/rknpu");
		return 2;
	}
	expect("1 MEM_CREATE without a dma-buf (1 TiB)", ioctl(npu, CREATE, &create), EOPNOTSUPP);
	expect("2 MEM_SYNC on a wild obj_addr", ioctl(npu, SYNC, &sync), EINVAL);
	expect("3 MEM_DESTROY on a wild obj_addr", ioctl(npu, DESTROY, &destroy), 0);
	expect("4 SUBMIT with a wild task_obj_addr", ioctl(npu, SUBMIT, &submit), EINVAL);
	expect("5 SUBMIT with a short size (zeroed: no task buffer)", ioctl(npu, SUBMIT_SHORT, &submit), EINVAL);

	obj = import(npu, &buf_fd);
	if (!obj)
		return 2;
	/* 4096 bytes hold 102 tasks of 40 bytes: indices 0..101. */
	submit.task_obj_addr = obj;
	submit.task_start = 0;
	submit.task_number = 103;
	submit.subcore_task[0] = (struct subcore){ 0, 103 };
	expect("6 SUBMIT, core 0 range past the task buffer", ioctl(npu, SUBMIT, &submit), EINVAL);
	submit.subcore_task[0] = (struct subcore){ 0xfffffff0u, 0x20 };
	expect("7 SUBMIT, start+number wrapping 32 bits", ioctl(npu, SUBMIT, &submit), EINVAL);
	submit.core_mask = 0x7;
	submit.subcore_task[2] = (struct subcore){ 0, 1 };
	submit.subcore_task[3] = (struct subcore){ 0, 1 };
	submit.subcore_task[4] = (struct subcore){ 101, 2 };
	expect("8 SUBMIT, 3 cores, core 2 range past the buffer", ioctl(npu, SUBMIT, &submit), EINVAL);
	submit.core_mask = 0;  /* auto: may pick any core, so all are checked */
	submit.subcore_task[0] = (struct subcore){ 0, 1 };
	submit.subcore_task[1] = (struct subcore){ 0, 1 };
	submit.subcore_task[2] = (struct subcore){ 500, 1 };
	expect("9 SUBMIT, auto mask, core 2 range past the buffer", ioctl(npu, SUBMIT, &submit), EINVAL);

	sync.obj_addr = obj;
	sync.flags = 1;
	expect("10 MEM_SYNC on our import", ioctl(npu, SYNC, &sync), 0);
	expect("11 MEM_SYNC on it from another client", ioctl(other, SYNC, &sync), EINVAL);
	destroy.obj_addr = obj;
	expect("12 MEM_DESTROY on it from another client (ignored)", ioctl(other, DESTROY, &destroy), 0);
	expect("13 MEM_SYNC on it still works", ioctl(npu, SYNC, &sync), 0);
	expect("14 MEM_DESTROY on our import", ioctl(npu, DESTROY, &destroy), 0);
	expect("15 MEM_SYNC after destroy (was a use-after-free)", ioctl(npu, SYNC, &sync), EINVAL);
	expect("16 MEM_DESTROY twice (was a double free)", ioctl(npu, DESTROY, &destroy), 0);

	import(npu, &buf_fd);  /* left for close to free */
	close(buf_fd);
	close(other);
	close(npu);
	printf("%d failures\n", failures);
	return failures != 0;
}
