#!/usr/bin/env bash
# Prepare the defconfig and compile the kernel.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
ARCH=${ARCH:-arm64}
OUT="${KERNEL_DIR}/out"

DEFCONFIG_PATH="${KERNEL_DIR}/arch/${ARCH}/configs/${KERNEL_CONFIG}"

# ------------------------------------------------------------- defconfig ---

prepare_defconfig() {
	group "Preparing defconfig"
	[ -f "$DEFCONFIG_PATH" ] \
		|| die "defconfig not found: arch/${ARCH}/configs/${KERNEL_CONFIG}
       Available: $(ls "${KERNEL_DIR}/arch/${ARCH}/configs/" | head -20 | tr '\n' ' ')"

	cp "$DEFCONFIG_PATH" "${WORKSPACE}/defconfig.orig"

	if [ "${KSU_VARIANT:-none}" != "none" ]; then
		# backslashxx on 32-bit ARM uses syscall-table tampering; no kprobes and
		# no source-level hooks are needed.
		kconf_enable "$DEFCONFIG_PATH" CONFIG_KSU
		kconf_enable "$DEFCONFIG_PATH" CONFIG_KSU_TAMPER_SYSCALL_TABLE
	fi

	if is_true "${DISABLE_LTO:-false}"; then
		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_LTO=n CONFIG_LTO_CLANG=n CONFIG_LTO_CLANG_FULL=n \
			CONFIG_LTO_CLANG_THIN=n CONFIG_THINLTO=n CONFIG_LTO_NONE=y
	fi

	is_true "${DISABLE_CC_WERROR:-false}" && kconf_disable "$DEFCONFIG_PATH" CONFIG_CC_WERROR

	# Free-form extras: one CONFIG_x=y per line, or space separated.
	if [ -n "${EXTRA_DEFCONFIG:-}" ]; then
		local kv
		# shellcheck disable=SC2086
		for kv in $(printf '%s' "$EXTRA_DEFCONFIG" | tr '\n' ' '); do
			[ -n "$kv" ] || continue
			case "$kv" in
				*=*) kconf_set "$DEFCONFIG_PATH" "${kv%%=*}" "${kv#*=}" ;;
				*)   warn "ignoring malformed EXTRA_DEFCONFIG entry '${kv}' (want CONFIG_X=y)" ;;
			esac
		done
	fi

	# The ROM's prebuilt vendor modules were built against exactly this kernel
	# version. A git suffix (-g<sha>) or -dirty changes uname -r and breaks their
	# vermagic, so keep the version stable unless KERNEL_NAME overrides it below.
	kconf_disable "$DEFCONFIG_PATH" CONFIG_LOCALVERSION_AUTO

	# A stable LOCALVERSION keeps artifact names predictable. Without this the
	# tree appends "-dirty" as soon as any patch above touches a tracked file.
	if [ -n "${KERNEL_NAME:-}" ]; then
		kconf_set "$DEFCONFIG_PATH" CONFIG_LOCALVERSION "\"-${KERNEL_NAME}\""
		if [ -f "${KERNEL_DIR}/scripts/setlocalversion" ]; then
			sed -i 's/-dirty//g' "${KERNEL_DIR}/scripts/setlocalversion"
		fi
	fi

	info "defconfig changes:"
	diff -u "${WORKSPACE}/defconfig.orig" "$DEFCONFIG_PATH" | sed -n '4,$p' | sed 's/^/    /' || true
	endgroup
}

# ----------------------------------------------------------------- build ---

make_args() {
	printf '%s' "O=out ARCH=${ARCH}"
	[ -n "${CUSTOM_CMDS:-}" ] && printf ' %s' "$CUSTOM_CMDS"
	[ -n "${EXTRA_CMDS:-}"  ] && printf ' %s' "$EXTRA_CMDS"
	[ -n "${GCC_64:-}"      ] && printf ' %s' "$GCC_64"
	[ -n "${GCC_32:-}"      ] && printf ' %s' "$GCC_32"
	if is_true "${USE_LLVM:-false}"; then
		printf ' LLVM=1 LLVM_IAS=1'
		[ -n "${GCC_64:-}" ] || printf ' CROSS_COMPILE=aarch64-linux-gnu-'
	fi
}

build_kernel() {
	group "Building kernel"
	if [ -n "${CLANG_PATH:-}" ]; then
		export PATH="${CLANG_PATH}:${PATH}"
	fi
	export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-Github-Action}
	export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-kernelsu-action}

	# DISABLE_LTO is this action's boolean configuration switch, but several
	# Android kernel trees use the same Make variable for compiler flags (for
	# example, "-fno-lto").  Leaving our value in the environment makes a
	# non-LTO build invoke `clang ... false ...`, treating "false" as an input
	# file.  prepare_defconfig() has already consumed the action setting, so let
	# Kbuild own the name from this point on.
	unset DISABLE_LTO

	# Custom manager signature, when the user builds their own manager APK.
	if [ -n "${KSU_EXPECTED_SIZE:-}" ] && [ -n "${KSU_EXPECTED_HASH:-}" ]; then
		export KSU_EXPECTED_SIZE KSU_EXPECTED_HASH
		info "using custom manager signature (size=${KSU_EXPECTED_SIZE})"
	fi

	# AOSP's Android arm toolchain (arm-linux-androideabi-*) defaults to
	# Android mode: -fpic, -mbionic and possibly Thumb, which produces an
	# unbootable kernel. AndroidKernel.mk probes for -mno-android and passes it
	# when supported; force ARM mode for the same reason. arm-eabi toolchains
	# do not accept -mno-android and default to ARM already.
	if ! is_true "${USE_LLVM:-false}" && [ "${ARCH}" = "arm" ]; then
		local kcflags="-marm"
		if [ -n "${CROSS_COMPILE:-}" ] &&
		   printf 'int main(void) { return 0; }\n' | "${CROSS_COMPILE}gcc" -E -mno-android - >/dev/null 2>&1; then
			kcflags="-mno-android -marm"
		fi
		# KernelSU compiles ksu.o with -std=gnu11. Old ARM headers use
		# "extern inline", which C99/C11 turn into a global definition and
		# collide with arch/arm/kernel's return_address. GNU89 inline
		# semantics match the rest of the kernel.
		if [ "${KSU_VARIANT:-none}" != "none" ]; then
			kcflags="${kcflags} -fgnu89-inline"
		fi
		export KCFLAGS="$kcflags"
		info "using KCFLAGS='${KCFLAGS}'"
	fi

	# toolchain.sh exports CC when a GCC toolchain (rather than clang) is used.
	local cc="${CC:-clang}" args
	args=$(make_args)

	cd "$KERNEL_DIR"
	info "make ${args} ${KERNEL_CONFIG}"
	# shellcheck disable=SC2086
	make -j"$(nproc --all)" CC="$cc" $args "${KERNEL_CONFIG}" \
		|| die "defconfig generation failed"

	# Kconfig silently drops symbols whose dependencies are unmet. A kernel that
	# claims to include KernelSU but does not is the worst failure mode, so fail
	# here instead of after a long build.
	if [ "${KSU_VARIANT:-none}" != "none" ]; then
		grep -q '^CONFIG_KSU=y' "${OUT}/.config" \
			|| die "CONFIG_KSU was dropped by Kconfig (unmet dependency, e.g. SELinux), refusing to build without KernelSU."
	fi

	info "make ${args}"
	# shellcheck disable=SC2086
	make -j"$(nproc --all)" CC="$cc" $args \
		|| die "kernel build failed"

	endgroup
}

# --------------------------------------------------------------- verify ---

check_output() {
	group "Checking build output"
	local boot="${OUT}/arch/${ARCH}/boot"
	local image="${boot}/${KERNEL_IMAGE_NAME}"

	[ -f "$image" ] || die "expected kernel image not found: ${image}
       Built files: $(ls "$boot" 2>/dev/null | tr '\n' ' ')
       Check that KERNEL_IMAGE_NAME matches what your kernel produces."

	ok "kernel image: ${KERNEL_IMAGE_NAME} ($(du -h "$image" | cut -f1))"
	export_env CHECK_FILE_IS_OK true

	# Record the version string the kernel actually reports.
	if [ -f "${OUT}/include/generated/utsrelease.h" ]; then
		local rel
		rel=$(sed -nE 's/.*UTS_RELEASE[[:space:]]+"([^"]+)".*/\1/p' "${OUT}/include/generated/utsrelease.h")
		export_env KERNEL_RELEASE "$rel"
		ok "kernel release: ${rel}"
		summary "| Kernel release | \`${rel}\` |"
	fi
	endgroup
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	case "${1:-all}" in
		defconfig) prepare_defconfig ;;
		compile)   build_kernel ;;
		check)     check_output ;;
		all)       prepare_defconfig; build_kernel; check_output ;;
		*) die "unknown build step '$1'" ;;
	esac
fi
