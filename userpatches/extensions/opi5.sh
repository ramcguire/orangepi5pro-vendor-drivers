# shellcheck shell=bash
# Armbian sources this file; opts_* and kernel_work_dir are its own.
# shellcheck disable=SC2034,SC2154
#
# Kconfig for the zz-opi5-* patches. Their symbols lack useful defaults, so all are set
# here, and the build fails if one isn't in the final .config (an unmet dependency drops
# it silently).

declare -g -a OPI5_KERNEL_CONFIG=(
	# MPP (1020-1040): rk_vcodec.ko.
	ROCKCHIP_MPP_SERVICE=m
	ROCKCHIP_MPP_PROC_FS=y
	ROCKCHIP_MPP_RKVDEC2=y
	ROCKCHIP_MPP_RKVENC2=y

	# Multi-RGA (1050): rga3.ko. FFmpeg's scale_rkrga needs ASYNC.
	ROCKCHIP_MULTI_RGA=m
	ROCKCHIP_RGA_ASYNC=y
	ROCKCHIP_RGA_DEBUG_FS=y
	ROCKCHIP_RGA_PROC_FS=n
	ROCKCHIP_RGA_GENPOOL=n

	# MPP alone owns the decoders (the device tree also disables vdec0/vdec1).
	VIDEO_ROCKCHIP_VDEC=n

	# Lockup detection, warn-only (Armbian's config has it off).
	SOFTLOCKUP_DETECTOR=y
	BOOTPARAM_SOFTLOCKUP_PANIC=n
	# The buddy detector, as there's no ARM64_PSEUDO_NMI.
	HARDLOCKUP_DETECTOR=y
	HARDLOCKUP_DETECTOR_BUDDY=y
	BOOTPARAM_HARDLOCKUP_PANIC=n
	DETECT_HUNG_TASK=y
	DEFAULT_HUNG_TASK_TIMEOUT=120
	BOOTPARAM_HUNG_TASK_PANIC=n

	# NPU (5010-5050): rknpu.ko. Rocket binds the same hardware; librknnrt needs /dev/rknpu.
	ROCKCHIP_RKNPU=m
	DRM_ACCEL_ROCKET=n

	# KUnit tests (6010, 6020): mpp_kunit.ko and rga_kunit.ko, run in QEMU by
	# tools/kunit.sh. Only loading one runs it (and taints the kernel).
	ROCKCHIP_MPP_KUNIT_TEST=m
	ROCKCHIP_RGA_KUNIT_TEST=m
)

# Each option leaves Armbian's other opts_* arrays first, so ours win.
function custom_kernel_config__opi5() {
	declare option symbol value array item
	for option in "${OPI5_KERNEL_CONFIG[@]}"; do
		symbol="${option%%=*}" value="${option#*=}"
		for array in opts_y opts_m opts_n; do
			declare -n _opi5_ref="${array}"
			declare -a _opi5_keep=()
			for item in "${_opi5_ref[@]}"; do
				[[ "${item}" == "${symbol}" ]] || _opi5_keep+=("${item}")
			done
			_opi5_ref=("${_opi5_keep[@]}")
			unset -n _opi5_ref
		done
		unset "opts_val[${symbol}]"
		case "${value}" in
			y) opts_y+=("${symbol}") ;;
			m) opts_m+=("${symbol}") ;;
			n) opts_n+=("${symbol}") ;;
			*) opts_val["${symbol}"]="${value}" ;;
		esac
	done
}

# Every option must have survived olddefconfig.
function pre_package_kernel_image__opi5_check_config() {
	declare config="${kernel_work_dir}/.config" option symbol value
	declare -a missing=()
	[[ -f "${config}" ]] || exit_with_error "opi5: no ${config} to check"
	for option in "${OPI5_KERNEL_CONFIG[@]}"; do
		symbol="CONFIG_${option%%=*}" value="${option#*=}"
		if [[ "${value}" == n ]]; then
			grep -q "^${symbol}=" "${config}" && missing+=("${option}")
		else
			grep -qx "${symbol}=${value}" "${config}" || missing+=("${option}")
		fi
	done
	if [[ ${#missing[@]} -gt 0 ]]; then
		exit_with_error "opi5: kernel options not in the final .config (unmet dependency?)" "${missing[*]}"
	fi
	display_alert "opi5" "all ${#OPI5_KERNEL_CONFIG[@]} kernel options in the final .config" "info"
}
