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
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

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

# Some Samsung/Qualcomm boot images append a QCDT device-tree image after the
# ramdisk and store its size at offset 40 (where newer headers put
# header_version), followed by a SEANDROIDENFORCE footer. magiskboot and
# AnyKernel3 drop both when repacking, leaving the bootloader without a DTB;
# the kernel then fails silently. Repack the original image in place instead.
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

	if [ "$second_size" -eq 0 ] && [ "$dt_size" -gt "$page_size" ] &&
	   [ "$dt_magic" = "QCDT" ] &&
	   [ $((dt_off + dt_size)) -le "$(wc -c < "$src_img")" ]; then
		info "source boot image has an appended QCDT dt image (${dt_size} bytes)"
		samsung_dt_repack "$src_img" "${WORKSPACE}/boot.img" \
			"${BOOT_OUT}/${KERNEL_IMAGE_NAME}" \
			"$page_size" "$kernel_size" "$ramdisk_size" "$second_size" "$dt_size"
	else
		local tools="${WORKSPACE}/tools"
		[ -f "${tools}/unpack_bootimg.py" ] || die "mkbootimg tools not found at ${tools}"

		cd "$WORKSPACE"
		local fmt
		fmt=$(python3 "${tools}/unpack_bootimg.py" --boot_img boot-source.img --format mkbootimg) \
			|| die "failed to read the source boot image"
		info "source boot image args: ${fmt}"

		python3 "${tools}/unpack_bootimg.py" --boot_img boot-source.img >/dev/null \
			|| die "failed to unpack the source boot image"

		cp "${BOOT_OUT}/${KERNEL_IMAGE_NAME}" "${WORKSPACE}/out/kernel" \
			|| die "could not stage the new kernel into the unpacked ramdisk"

		# shellcheck disable=SC2086
		python3 "${tools}/mkbootimg.py" $fmt -o boot.img || die "mkbootimg failed"
		[ -s "${WORKSPACE}/boot.img" ] || die "boot.img was not produced"
		ok "boot.img built ($(du -h "${WORKSPACE}/boot.img" | cut -f1))"
	fi

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
