#!/usr/bin/env bash
# Repack the original boot.img with the freshly built kernel.
#
# The gtelwifiue boot image is a Samsung/Qualcomm layout:
#   header + zImage + ramdisk + appended QCDT dt image + SEANDROIDENFORCE
# Generic repackers (magiskboot/AnyKernel3) drop the QCDT and the footer, which
# leaves the bootloader without a device tree and makes the kernel fail
# silently. This script replaces only the kernel and copies everything else
# verbatim.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
ARCH=${ARCH:-arm}
BOOT_OUT="${KERNEL_DIR}/out/arch/${ARCH}/boot"
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# u32_le FILE OFFSET -- read a little-endian uint32.
u32_le() {
	od -An -tu4 -j"$2" -N4 "$1" | tr -d '[:space:]'
}

# le32_to_file VALUE FILE OFFSET -- write VALUE as a little-endian uint32.
le32_to_file() {
	local n=$1 out=$2 off=$3
	printf '%b' "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' \
		$((n & 0xff)) $(((n >> 8) & 0xff)) $(((n >> 16) & 0xff)) $(((n >> 24) & 0xff)))" \
		| dd of="$out" bs=1 seek="$off" conv=notrunc 2>/dev/null
}

# Replace the kernel inside the original image, preserving the header,
# ramdisk, appended QCDT and trailing SEANDROIDENFORCE footer.
samsung_dt_repack() {
	local src=$1 dst=$2 new_kernel=$3
	local page_size=$4 kernel_size=$5 ramdisk_size=$6 second_size=$7 dt_size=$8

	local kernel_pad ramdisk_pad second_pad dt_off file_size footer_size
	kernel_pad=$(( (kernel_size + page_size - 1) / page_size * page_size ))
	ramdisk_pad=$(( (ramdisk_size + page_size - 1) / page_size * page_size ))
	second_pad=$(( (second_size + page_size - 1) / page_size * page_size ))
	dt_off=$(( page_size + kernel_pad + ramdisk_pad + second_pad ))
	file_size=$(wc -c < "$src")
	footer_size=$(( file_size - dt_off - dt_size ))

	local new_size new_pad new_dt_off
	new_size=$(wc -c < "$new_kernel")
	new_pad=$(( (new_size + page_size - 1) / page_size * page_size ))
	new_dt_off=$(( page_size + new_pad + ramdisk_pad + second_pad ))

	head -c "$page_size" "$src" > "$dst"
	le32_to_file "$new_size" "$dst" 8

	cat "$new_kernel" >> "$dst"
	if [ "$new_pad" -gt "$new_size" ]; then
		head -c $((new_pad - new_size)) /dev/zero >> "$dst"
	fi

	# Original ramdisk (page padded) plus the (normally empty) second stage.
	# dd is used instead of tail|head: pipefail turns head's early exit into a
	# SIGPIPE (141) that would abort the whole repack.
	local ram_off=$((page_size + kernel_pad))
	dd if="$src" bs="$page_size" skip=$((ram_off / page_size)) \
		count=$(((ramdisk_pad + second_pad) / page_size)) >> "$dst" 2>/dev/null

	# Appended Qualcomm DT image and the trailing footer.
	local dt_pages=$((dt_size / page_size))
	local dt_rem=$((dt_size % page_size))
	if [ "$dt_pages" -gt 0 ]; then
		dd if="$src" bs="$page_size" skip=$((dt_off / page_size)) \
			count="$dt_pages" >> "$dst" 2>/dev/null
	fi
	if [ $((dt_rem + footer_size)) -gt 0 ]; then
		dd if="$src" bs=1 skip=$((dt_off + dt_pages * page_size)) \
			count=$((dt_rem + footer_size)) >> "$dst" 2>/dev/null
	fi

	local got_magic got_ksize
	got_magic=$(head -c 8 "$dst")
	got_ksize=$(u32_le "$dst" 8)
	[ "$got_magic" = "ANDROID!" ] && [ "$got_ksize" -eq "$new_size" ] \
		|| die "boot image repack produced an invalid header"
	[ "$(u32_le "$dst" 40)" -eq "$dt_size" ] \
		|| die "boot image repack lost dt_size"
	[ "$(dd if="$dst" bs=1 skip="$new_dt_off" count=4 2>/dev/null)" = "QCDT" ] \
		|| die "boot image repack lost the QCDT device tree"

	ok "boot.img built with appended QCDT ($(du -h "$dst" | cut -f1))"
}

make_boot_image() {
	is_true "${BUILD_BOOT_IMG:-false}" || return 0
	group "Repacking boot image"

	local src src_img
	src=${SOURCE_BOOT_IMAGE:?SOURCE_BOOT_IMAGE required}
	src_img="${WORKSPACE}/boot-source.img"
	case "$src" in
		*://*) fetch "$src" "$src_img" ;;
		/*)    cp "$src" "$src_img" ;;
		*)     [ -f "${REPO_ROOT}/${src}" ] || die "SOURCE_BOOT_IMAGE not found: ${src}"
		       cp "${REPO_ROOT}/${src}" "$src_img" ;;
	esac

	local magic kernel_size ramdisk_size second_size page_size dt_size
	magic=$(head -c 8 "$src_img")
	[ "$magic" = "ANDROID!" ] || die "SOURCE_BOOT_IMAGE is not an Android boot image"
	kernel_size=$(u32_le "$src_img" 8)
	ramdisk_size=$(u32_le "$src_img" 16)
	second_size=$(u32_le "$src_img" 24)
	page_size=$(u32_le "$src_img" 36)
	dt_size=$(u32_le "$src_img" 40)
	[ "$page_size" -gt 0 ] || die "invalid page size in SOURCE_BOOT_IMAGE"

	local kernel_pad ramdisk_pad second_pad dt_off dt_magic
	kernel_pad=$(( (kernel_size + page_size - 1) / page_size * page_size ))
	ramdisk_pad=$(( (ramdisk_size + page_size - 1) / page_size * page_size ))
	second_pad=$(( (second_size + page_size - 1) / page_size * page_size ))
	dt_off=$(( page_size + kernel_pad + ramdisk_pad + second_pad ))
	dt_magic=$(dd if="$src_img" bs=1 skip="$dt_off" count=4 2>/dev/null)

	if [ "$second_size" -ne 0 ] || [ "$dt_size" -le "$page_size" ] ||
	   [ "$dt_magic" != "QCDT" ] ||
	   [ $((dt_off + dt_size)) -gt "$(wc -c < "$src_img")" ]; then
		die "SOURCE_BOOT_IMAGE does not have the expected appended QCDT layout.
       This repository only repacks the gtelwifiue boot image; point
       SOURCE_BOOT_IMAGE at boot/boot.img from the matching ROM."
	fi

	info "source boot image has an appended QCDT dt image (${dt_size} bytes)"
	samsung_dt_repack "$src_img" "${WORKSPACE}/boot.img" \
		"${BOOT_OUT}/${KERNEL_IMAGE_NAME}" \
		"$page_size" "$kernel_size" "$ramdisk_size" "$second_size" "$dt_size"

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
	for f in "${BOOT_OUT}/${KERNEL_IMAGE_NAME}" "${WORKSPACE}/boot.img"; do
		[ -f "$f" ] && summary "| \`$(basename "$f")\` | $(du -h "$f" | cut -f1) |"
	done
	summary ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	case "${1:-all}" in
		bootimg) make_boot_image ;;
		all)     make_boot_image; write_summary ;;
		*) die "unknown package step '$1'" ;;
	esac
fi
