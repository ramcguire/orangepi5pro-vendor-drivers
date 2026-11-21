# Build the abuse tests as static arm64 binaries into $(OUT_DIR)/tests (default out/tests),
# to copy to the board and run there as root. Each file's header says what it needs.
#
#   make -C tests           # cross-compiles; `mise run tests` runs it in the builder image
#   make -C tests CC=gcc    # on the board

CC = aarch64-linux-gnu-gcc
CFLAGS = -O2 -Wall -Wextra -Werror
LDFLAGS = -static
OUT_DIR ?= $(abspath $(CURDIR)/../out)

out := $(OUT_DIR)/tests
bins := $(patsubst %.c,$(out)/%,$(wildcard *.c))

all: $(bins)

$(out)/%: %.c | $(out)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

$(out):
	mkdir -p $@

clean:
	rm -f $(bins)

.PHONY: all clean
