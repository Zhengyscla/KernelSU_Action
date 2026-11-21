#!/usr/bin/env bash
# Install the KernelSU fork selected by KSU_VARIANT.
#
# setup.sh ends its checkout with `git checkout "$1" || echo ...`, so an invalid
# ref does not fail -- it silently leaves the tree on the default branch. The
# ref is therefore validated before setup.sh runs and the checkout is verified
# afterwards.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must point at the kernel source tree}

# load_variant VARIANT -- fill the KSU_* globals for a supported fork.
#
# SukiSU-Nova's main/dev tree is 64-bit only: its hooks are compiled for
# ARM64/x86_64/RISCV and there is no CONFIG_ARM path at all. builtin-new is the
# armeabi-capable tree (Linux 3.0+, syscall-table hooking, GCC 4.9+); the older
# builtin tree uses a different hook path. Hence the arm32 default below.
load_variant() {
	case "$1" in
		backslashxx)
			KSU_REPO="https://github.com/backslashxx/KernelSU"
			KSU_SETUP_URL="https://raw.githubusercontent.com/backslashxx/KernelSU/master/kernel/setup.sh"
			KSU_DEFAULT_REF="master"
			KSU_DISPLAY_NAME="backslashxx KernelSU"
			KSU_UPLOAD_TAG="backslashxx"
			;;
		sukisu-nova)
			KSU_REPO="https://github.com/SukiSU-Nova/SukiSU-Nova"
			# main's setup.sh clones a third-party mirror; builtin-new's copy
			# clones the public GitHub repo. Always use the latter.
			KSU_SETUP_URL="https://raw.githubusercontent.com/SukiSU-Nova/SukiSU-Nova/builtin-new/kernel/setup.sh"
			KSU_DEFAULT_REF="builtin-new"
			KSU_DISPLAY_NAME="SukiSU-Nova"
			KSU_UPLOAD_TAG="sukisu-nova"
			;;
		*)
			die "unsupported KSU_VARIANT '$1' (supported: none, backslashxx, sukisu-nova)"
			;;
	esac
	export_env KSU_UPLOAD_TAG "$KSU_UPLOAD_TAG"
}

# verify_arm32_support DIR REF -- 32-bit ARM requires syscall-table hooking.
#
# This catches the most likely mistake with SukiSU-Nova: main/dev check out
# fine and only fail far later, with no obvious link to the ref. The Kconfig
# option we build with is the capability marker.
verify_arm32_support() {
	local dir=$1 ref=$2
	[ "${ARCH:-arm64}" = "arm" ] || return 0

	local kconfig="${dir}/kernel/Kconfig"
	[ -f "$kconfig" ] || die "KernelSU Kconfig not found at ${kconfig}"

	if ! grep -qE '^[[:space:]]*config KSU_TAMPER_SYSCALL_TABLE' "$kconfig"; then
		die "${KSU_DISPLAY_NAME} at '${ref}' has no KSU_TAMPER_SYSCALL_TABLE option.
       ARCH=arm needs syscall-table hooking; SukiSU-Nova's main/dev trees are
       64-bit only and the older builtin tree uses a different hook path.
       Use KSU_REF=builtin-new for arm32."
	fi
}

ksu_install() {
	local requested_ref=${1-}
	load_variant "${KSU_VARIANT:-backslashxx}"

	local ref=$requested_ref

	group "Installing ${KSU_DISPLAY_NAME}"
	info "repository: ${KSU_REPO}"

	if [ -z "$ref" ]; then
		ref=$KSU_DEFAULT_REF
		info "no KSU_REF pinned; using '${ref}' (set KSU_REF for reproducible builds)"
	fi

	info "validating ref '${ref}' exists in ${KSU_REPO}"
	ref_exists "$KSU_REPO" "$ref" \
		|| die "ref '${ref}' does not exist in ${KSU_REPO}.
       setup.sh would silently fall back to the default branch.
       Available branches: $(git ls-remote --heads "$KSU_REPO" 2>/dev/null | awk '{print $2}' | sed 's@refs/heads/@@' | grep -v dependabot | tr '\n' ' ')"
	ok "ref '${ref}' exists"

	info "running ${KSU_SETUP_URL}"
	(
		cd "$KERNEL_DIR"
		fetch_stdout "$KSU_SETUP_URL" | bash -s "$ref"
	) || die "${KSU_DISPLAY_NAME} setup.sh failed"

	# --- verify the installer actually did what it claims ------------------
	local ksu_dir="${KERNEL_DIR}/KernelSU"
	[ -d "$ksu_dir" ] || die "setup.sh finished but KernelSU/ is missing"

	local link="${KERNEL_DIR}/drivers/kernelsu"
	[ -e "$link" ] || die "drivers/kernelsu symlink was not created"

	# setup.sh only checks whether the word "kernelsu" already appears. Some
	# vendor trees carry an obsolete line guarded by CONFIG_WITH_KERNEL_SU, so
	# setup.sh reports success without adding the CONFIG_KSU rule and the final
	# link fails with every ksu_handle_* symbol undefined.
	local driver_makefile="${KERNEL_DIR}/drivers/Makefile"
	if ! grep -qE '^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' "$driver_makefile"; then
		if grep -qE '^[[:space:]]*obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' "$driver_makefile"; then
			sed -i -E 's@^[[:space:]]*obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$@obj-$(CONFIG_KSU) += kernelsu/@' "$driver_makefile"
			warn "normalized stale drivers/Makefile KernelSU guard to CONFIG_KSU"
		else
			printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >>"$driver_makefile"
			warn "added missing CONFIG_KSU rule to drivers/Makefile"
		fi
	fi

	grep -qE '^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' "$driver_makefile" \
		|| die "drivers/Makefile was not wired to CONFIG_KSU for kernelsu"
	grep -q 'drivers/kernelsu/Kconfig' "${KERNEL_DIR}/drivers/Kconfig" \
		|| die "drivers/Kconfig was not wired up for kernelsu"

	# Confirm the requested ref is actually checked out.
	local head_desc head_sha want
	head_sha=$(git -C "$ksu_dir" rev-parse --short HEAD)
	head_desc=$(git -C "$ksu_dir" describe --tags --always 2>/dev/null || echo "$head_sha")
	want=$(git -C "$ksu_dir" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null || true)
	if [ -n "$want" ] && [ "$want" != "$(git -C "$ksu_dir" rev-parse HEAD)" ]; then
		die "${KSU_DISPLAY_NAME} is checked out at ${head_desc}, not the requested ref '${ref}'"
	fi

	verify_arm32_support "$ksu_dir" "$ref"
	ok "${KSU_DISPLAY_NAME} installed at ${head_desc} (${head_sha})"

	# Publish facts later steps use.
	local count version_label
	count=$(git -C "$ksu_dir" rev-list --count HEAD 2>/dev/null || echo 0)
	if git -C "$ksu_dir" describe --exact-match --tags >/dev/null 2>&1; then
		version_label=$(git -C "$ksu_dir" describe --exact-match --tags)
	else
		version_label="${ref}-${head_sha}"
	fi

	export_env KSU_DIR "KernelSU"
	export_env KSU_NAME "$KSU_DISPLAY_NAME"
	export_env KSU_REF_RESOLVED "$ref"
	export_env KSU_VERSION_LABEL "$version_label"
	export_env KSU_COMMIT_COUNT "$count"
	export_env UPLOADNAME "-${KSU_UPLOAD_TAG}_${version_label}"

	summary "| KernelSU | \`${KSU_DISPLAY_NAME}\` @ \`${version_label}\` |"
	endgroup
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	ksu_install "${KSU_REF:-}"
fi
