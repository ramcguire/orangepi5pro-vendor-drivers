# orangepi5pro-vendor-drivers

Armbian's "current" kernel (6.18) for the **Orange Pi 5 Pro** (RK3588S), with Rockchip's vendor drivers:

- **MPP** (`/dev/mpp_service`): both RKVDEC2 decoder and RKVENC2 encoder cores;
- **multi-RGA** (`/dev/rga`): both RGA3 cores and RGA2;
- **RKNPU 0.9.8** (`/dev/rknpu`): all three NPU cores, for Rockchip's `librknnrt`.

It's an Armbian [`userpatches/`](userpatches/) directory: patches, device tree, one extension, one build config.

It also has a fix for Armbian's U-Boot on this board, which leaves the PCIe slot powered and its link up when Linux starts: the YT6801 Ethernet then fails on about half of the boots. See [U-Boot](#u-boot).

## Use

**Packages.** Each [release](../../releases) has the `linux-image`, `linux-dtb` and `linux-headers` packages. On an Armbian `current` install for the Orange Pi 5 Pro:

```sh
sha256sum --check --ignore-missing SHA256SUMS
apt install ./linux-image-*.deb ./linux-dtb-*.deb ./linux-headers-*.deb
apt-mark hold linux-image-current-rockchip64 linux-dtb-current-rockchip64 linux-headers-current-rockchip64
reboot
```

The packages carry the names of Armbian's kernel, so hold them, or Armbian's repository replaces them.

**U-Boot.** Each release also has `linux-u-boot-orangepi5pro-current`, Armbian's U-Boot with the fix. It doesn't depend on the kernel. Installing the package doesn't change what boots: write it to the card or eMMC Armbian boots from, after saving that boot area:

```sh
apt install ./linux-u-boot-orangepi5pro-current_*.deb
apt-mark hold linux-u-boot-orangepi5pro-current
dev=/dev/$(lsblk -ndo pkname "$(findmnt -no SOURCE /)")
dd if="$dev" of=/root/bootarea.img bs=512 count=32768
. /usr/lib/u-boot/platform_install.sh && write_uboot_platform "$DIR" "$dev"
reboot
```

To undo it, write the saved one back with `dd if=/root/bootarea.img of="$dev" bs=32k skip=1 seek=1 count=511 conv=notrunc`. For U-Boot in SPI flash, use `armbian-install` instead.

**Userspace.** For the codecs and RGA, use FFmpeg built with rkmpp and librga. NPU clients need `/dev/rknpu`, `/dev/dma_heap` and `librknnrt` 2.3.2; 2.3.0 times out every job on this driver.

**Build with Armbian.** Copy `userpatches/` (or a release's `opi5-userpatches-*.tar.gz`) into [armbian/build](https://github.com/armbian/build) at the tag `build.sh` pins, then run `./compile.sh opi5 kernel` (and `./compile.sh opi5 uboot`). To add the drivers to another build, copy `kernel/archive/rockchip64-6.18/` and `extensions/opi5.sh` and set `ENABLE_EXTENSIONS=opi5`.

**Build here.** With Docker and [mise](https://mise.jdx.dev), on any OS, `mise run build` runs `build.sh` in Armbian's builder image. The packages and logs go to `out/`, and caches go to the `opi5-armbian` volume. Arguments after `--` go to `compile.sh`. The other tasks (`mise tasks`):

- `modules`: only the three drivers, their KUnit tests and the DTB, into `out/drivers/`. Uses the config of the package in `out/` if there is one, so they load on that kernel.
- `check`: applies every patch with Armbian's patcher, failing on any that doesn't apply or of ours that needs fuzz, then compiles the drivers (`tools/patch.sh`).
- `kunit`: boots the built package in QEMU and runs every KUnit suite in it (`tools/kunit.sh`).
- `bump-report`: a report on the last `check`, for bumps (below).
- `tests`: the abuse tests (Hardening), as static arm64 binaries.
- `queue-import`, `queue-export`, `shell`: edit the patches as git commits (`tools/queue.sh`). Rewrite them in `mise run shell`, then export.
- `lint`, `renovate-check`, `clean`.

**CI.** `check.yml` runs `check` on every push and every third day, which also keeps the caches from expiring. It skips Armbian's patching while the patches and Armbian are unchanged. Commits follow [Conventional Commits](https://www.conventionalcommits.org): hk checks them locally, and `pr-title.yml` checks pull request titles, as pull requests are squash-merged. On `main`, `release.yml` releases when `userpatches/`, `build.sh` or the builder image changed: `build.yml` builds and runs `kunit`, then tags `v<kernel>-<n>` and publishes the release, with notes from the commits (`cliff.toml`). A tag pushed by hand releases too.

**Bumps** follow Armbian's tags. Renovate moves the Armbian tag, the 6.18.y kernel tag and the builder image together in one pull request on Tuesdays, and we don't patch ahead of Armbian. Everything else (Actions, tools) comes grouped in one pull request, which doesn't release. On those pull requests, `check.yml` adds `tools/bump-report.sh`'s report:
- Armbian patches that failed;
- Armbian patches that overlap ours;
- new NPU source commits, to mark applied or not applicable;
- config drift. Explain it, then `mise run bump-report -- --update`.

## Patches

The thousands digit is the purpose.

| Patch | What it does |
| --- | --- |
| **1xxx: MPP/RGA import** | New files only, from Rockchip's `kernel` `develop-6.1` at `b4ef083dc0c3` |
| `1010` | `rk-mpp.h`, the vendor request ABI |
| `1020` | The MPP service (`rk_vcodec`), runtime PM instead of the PMU idle hint |
| `1030` | RKVDEC2: both cores and their CCU; devfreq compiled out |
| `1040` | RKVENC2: both cores; OPP, IPA and devfreq compiled out |
| `1050` | Multi-RGA (`rga3`) |
| **2xxx: 6.18 under Armbian** | |
| `2010` | RGA: drops an unexported page-walk fallback, fixes the IOMMU fault handler and DMA segment size |
| `2020` | The Kconfig/Makefile hooks, the only lines in files mainline or Armbian own |
| **3xxx: fixes from the board** | |
| `3010` | RKVDEC2 CCU timeout at 4K: 106.7 → 120 ms |
| **4xxx: hardening (ours)** | Hardening below |
| `4010` | MPP: bound user requests |
| `4020` | RGA: own requests and buffers |
| **5xxx: NPU** (`rknpu.ko`) | |
| `5010` | [w568w/rknpu-module](https://github.com/w568w/rknpu-module) at `a8792fe6b633`, unchanged |
| `5020` | [mack42/OrangePi5Pro](https://github.com/mack42/OrangePi5Pro)'s mainline port at `6798f7e8af4e`: memory ioctls, devfreq, multi-core, `/dev/rknpu` |
| `5030` | Power off once the IOMMU has actually suspended; the NPU was never clock-gated |
| `5040` | Free a client's imported buffers when it closes |
| `5050` | NPU: harden user input (ours) |
| **6xxx: KUnit tests (ours)** | Modules only. Loading one runs it and taints the kernel |
| `6010` | `mpp_kunit`: the ABI (1010), command filter, request bounds (4010), CCU timeout (3010). With `CONFIG_KUNIT`, the functions under test are exported in `EXPORTED_FOR_KUNIT_TESTING` |
| `6020` | `rga_kunit`: the request filter, one base address per buffer (2010). `rga3.ko` won't load without RGA cores, so the checks are header inlines the test includes |

**Device tree.** `dt/rk3588s-orangepi-5-pro.dts` is Armbian's file plus two `#include`s, and `check` fails if it drifts from Armbian's.
- `-mpp.dtsi`: the codec and RGA3 cores, their CCUs and IOMMUs. It points `&rga` at the vendor RGA2 driver and disables the V4L2 decoders. Keep the node order: the RGA3 scheduler bits follow probe order.
- `-npu.dtsi`: mack42's vendor NPU node in place of mainline's rocket nodes, with one IOMMU domain for all three cores.

**Kernel config.** `extensions/opi5.sh` builds the drivers and tests as modules. It turns off the V4L2 decoder and rocket (they bind the same hardware), and turns on the lockup and hung-task detectors, warn-only. The build fails if an option is missing from the final `.config`.

## U-Boot

Armbian's U-Boot 2025.10 for this board turns on `CONFIG_PCI_INIT_R`, so it trains the PCIe link to the YT6801 and probes it on every boot. Its PCIe driver then leaves the link up, PERST# released and the slot powered for Linux. On about half of the boots, the YT6801 then doesn't train under Linux and Ethernet is missing. Switching the slot off before Linux fixes it; holding it in reset alone doesn't. The patches, in `userpatches/u-boot/v2025.10/board_orangepi5pro/`:

| Patch | What it does |
| --- | --- |
| `0010` | `pcie_dw_rockchip`: a remove hook, run just before the OS (`DM_FLAG_OS_PREPARE`), that asserts PERST#, stops the link and switches the slot supply off. For upstream U-Boot |
| `0020` | The board's U-Boot DT: `vcc3v3_phy1` is no longer `regulator-always-on` or `regulator-boot-on`, which kept it on. The PCIe driver switches it on itself, and Linux's DT is unchanged |

With them, Ethernet came up on 14 of 14 boots, against 15 of 32 without. Armbian applies them only while its `BOOTPATCHDIR` for the board is `v2025.10`: `check` fails if a bump moves it, and the build fails if they weren't applied (`extensions/opi5.sh`).

## Hardening

`4010`, `4020` and `5050` are ours, written from reading the vendor code. The devices are root-only on the host, but containers that use them get them, and without these patches a buggy or compromised process there could corrupt kernel memory. They passed the abuse tests (`tests/`, each file's header says how to run it) and every bench stage. If other userspace hits a check, the kernel log names it.

- **`4010`, MPP:** bounds checks done in `int` (a 2 GB offset passed), unchecked register-table and RCB indices, rkvenc2 array overruns, any fd accepted as a session.
- **`4020`, RGA:** physical addresses mapped as given, a kernel pointer taken from userspace, and global request ids and buffer handles: one client could cancel or free another's.
- **`5050`, NPU:** userspace addresses used as kernel pointers, unchecked task indices. Buffers are now the caller's own and reference-counted.

**Not fixed:**
- Userspace programs the codec registers, so a client can make the hardware DMA anywhere in the shared IOMMU domain. This is a hardware design limit.
- An async NPU job's buffers can be unmapped if its client exits mid-job. librknnrt 2.3.2 only submits blocking jobs.

## Known limits

- Fixed-clock codecs: the decoder runs at 786/594 MHz.
- No 10-bit hardware encode. HDR goes to 8-bit through RGA, still tagged BT.2020/PQ.
- RGA2 is untested: no workload has reached it.
- Keep suspend off: an earlier build hung on resume.
- An NPU client that keeps timing out can freeze the board (librknnrt 2.3.0). Use 2.3.2.

## License

GPL-2.0, as Armbian ([LICENSE](LICENSE)). The kernel files keep their own SPDX headers: MPP and the device tree `(GPL-2.0+ OR MIT)`, `rk-mpp.h` with the Linux-syscall-note, RGA and RKNPU `GPL-2.0`, the NPU dtsi `GPL-2.0-only`.
