#!/usr/bin/env bash
# Package build output: AnyKernel3 flashable zip and, optionally, a boot image.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
ARCH=${ARCH:-arm64}
BOOT_OUT="${KERNEL_DIR}/out/arch/${ARCH}/boot"
AK3="${WORKSPACE}/AnyKernel3"

make_anykernel3() {
	group "Building AnyKernel3 package"
	rm -rf "$AK3"

	if is_true "${USE_CUSTOM_ANYKERNEL3:-false}"; then
		local src=${CUSTOM_ANYKERNEL3_SOURCE:?CUSTOM_ANYKERNEL3_SOURCE required}
		case "$src" in
			*.tar.gz | *.tgz)
				fetch "$src" "${WORKSPACE}/ak3.tar.gz"
				extract_archive "${WORKSPACE}/ak3.tar.gz" "$AK3" ;;
			*.zip)
				fetch "$src" "${WORKSPACE}/ak3.zip"
				extract_archive "${WORKSPACE}/ak3.zip" "$AK3" ;;
			*git*)
				retry 3 git clone -q --depth=1 ${CUSTOM_ANYKERNEL3_BRANCH:+-b "$CUSTOM_ANYKERNEL3_BRANCH"} \
					"$src" "$AK3" || die "failed to clone ${src}" ;;
			*)
				fetch "$src" "${WORKSPACE}/ak3.zip"
				extract_archive "${WORKSPACE}/ak3.zip" "$AK3" ;;
		esac
	else
		retry 3 git clone -q --depth=1 https://github.com/osm0sis/AnyKernel3 "$AK3" \
			|| die "failed to clone AnyKernel3"
		# Device checks are meaningless here: we do not know the target's
		# ro.product.device, and the zip is flashed deliberately by its builder.
		sed -i 's/do.devicecheck=1/do.devicecheck=0/g' "${AK3}/anykernel.sh"
		sed -i 's!BLOCK=/dev/block/platform/omap/omap_hsmmc.0/by-name/boot;!BLOCK=auto;!g' "${AK3}/anykernel.sh"
		sed -i 's/IS_SLOT_DEVICE=0;/is_slot_device=auto;/g' "${AK3}/anykernel.sh"
	fi

	cp "${BOOT_OUT}/${KERNEL_IMAGE_NAME}" "${AK3}/" \
		|| die "kernel image missing at ${BOOT_OUT}/${KERNEL_IMAGE_NAME}"
	if is_true "${CHECK_DTBO_IS_OK:-false}"; then
		cp "${BOOT_OUT}/dtbo.img" "${AK3}/"
	fi
	rm -rf "${AK3}/.git" "${AK3}/.github" "${AK3}/README.md"

	ok "AnyKernel3 package assembled"
	endgroup
}

make_boot_image() {
	is_true "${BUILD_BOOT_IMG:-false}" || return 0
	group "Repacking boot image"

	local tools="${WORKSPACE}/tools"
	[ -x "${tools}/unpack_bootimg.py" ] || [ -f "${tools}/unpack_bootimg.py" ] \
		|| die "mkbootimg tools not found at ${tools}"

	# A local path is resolved against the current directory first (the
	# workflow runs from the repository root, where boot/boot.img lives) and
	# then against GITHUB_WORKSPACE. Anything else is downloaded.
	local src=${SOURCE_BOOT_IMAGE:?SOURCE_BOOT_IMAGE required}
	local staged="${WORKSPACE}/boot-source.img"
	case "$src" in
		http://* | https://*)
			fetch "$src" "$staged" ;;
		*)
			if [ -f "$src" ]; then
				info "using local source boot image: ${src}"
				cp "$src" "$staged"
			elif [ -n "${GITHUB_WORKSPACE:-}" ] && [ -f "${GITHUB_WORKSPACE}/${src}" ]; then
				info "using local source boot image: ${GITHUB_WORKSPACE}/${src}"
				cp "${GITHUB_WORKSPACE}/${src}" "$staged"
			else
				die "SOURCE_BOOT_IMAGE '${src}' is neither a URL nor an existing file"
			fi
			;;
	esac

	# mkbootimg produces an unsigned image. Keep the original AVB footer out
	# of the way but tell the user why verified boot will reject it.
	if tail -c 64 "$staged" | grep -q 'AVBf'; then
		warn "source boot.img is AVB-signed; the repacked boot.img is unsigned (unlocked bootloader required)"
	fi

	# unpack_bootimg writes its output into ./out; remove stale files from a
	# previous local run so no old dtb/ramdisk can sneak into the repack.
	rm -rf "${WORKSPACE}/out"

	cd "$WORKSPACE"
	local fmt
	fmt=$(python3 "${tools}/unpack_bootimg.py" --boot_img boot-source.img --format mkbootimg) \
		|| die "failed to read the source boot image"
	info "source boot image args: ${fmt}"

	python3 "${tools}/unpack_bootimg.py" --boot_img boot-source.img >/dev/null \
		|| die "failed to unpack the source boot image"

	# boot header v2 can carry a dtb in its own section. If the new kernel
	# image also has one appended (Image.gz-dtb), the repacked boot image will
	# contain both. That is normally harmless because the appended dtb follows
	# the gzip stream, but call it out when boot debugging is needed.
	if [ -f "${WORKSPACE}/out/dtb" ] && [ "${KERNEL_IMAGE_NAME%-dtb}" != "$KERNEL_IMAGE_NAME" ]; then
		warn "source boot.img has a separate dtb section and ${KERNEL_IMAGE_NAME} embeds one too; both will be present"
	fi

	cp "${BOOT_OUT}/${KERNEL_IMAGE_NAME}" "${WORKSPACE}/out/kernel" \
		|| die "could not stage the new kernel into the unpacked ramdisk"

	# --format mkbootimg prints a shell-quoted argument list. Expanding it
	# unquoted breaks values that contain spaces (the cmdline usually does),
	# and eval would execute whatever a hostile boot image put in cmdline.
	# Split it with shlex instead and pass the words through an array.
	local -a fmt_args
	mapfile -d '' -t fmt_args < <(
		python3 -c 'import shlex, sys; sys.stdout.write("\0".join(shlex.split(sys.argv[1])) + "\0")' "$fmt"
	)
	[ "${#fmt_args[@]}" -gt 0 ] || die "could not parse the source boot image arguments"

	python3 "${tools}/mkbootimg.py" "${fmt_args[@]}" -o boot.img \
		|| die "mkbootimg failed"
	[ -s "${WORKSPACE}/boot.img" ] || die "boot.img was not produced"

	ok "boot.img built ($(du -h "${WORKSPACE}/boot.img" | cut -f1))"
	export_env MAKE_BOOT_IMAGE_IS_OK true
	endgroup
}

write_summary() {
	summary ""
	summary "### Build artifacts"
	summary ""
	summary "| Artifact | Size |"
	summary "| --- | --- |"
	local f
	for f in "${BOOT_OUT}/${KERNEL_IMAGE_NAME}" "${BOOT_OUT}/dtbo.img" "${WORKSPACE}/boot.img"; do
		[ -f "$f" ] && summary "| \`$(basename "$f")\` | $(du -h "$f" | cut -f1) |"
	done
	[ -d "$AK3" ] && summary "| \`AnyKernel3\` (flashable zip) | $(du -sh "$AK3" | cut -f1) |"
	summary ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	case "${1:-all}" in
		anykernel3) make_anykernel3 ;;
		bootimg)    make_boot_image ;;
		all)        make_anykernel3; make_boot_image; write_summary ;;
		*) die "unknown package step '$1'" ;;
	esac
fi
