#!/usr/bin/env bash
# Install the backslashxx KernelSU fork (the only fork supporting 32-bit ARM).
#
# setup.sh ends its checkout with `git checkout "$1" || echo ...`, so an invalid
# ref does not fail -- it silently leaves the tree on the default branch. The
# ref is therefore validated before setup.sh runs and the checkout is verified
# afterwards.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must point at the kernel source tree}

KSU_REPO="https://github.com/backslashxx/KernelSU"
KSU_SETUP_REF="master"
KSU_DEFAULT_REF="master"
KSU_DISPLAY_NAME="backslashxx KernelSU"

ksu_install() {
	local requested_ref=${1-}
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

	local setup_url="https://raw.githubusercontent.com/backslashxx/KernelSU/${KSU_SETUP_REF}/kernel/setup.sh"
	info "running ${setup_url}"
	(
		cd "$KERNEL_DIR"
		fetch_stdout "$setup_url" | bash -s "$ref"
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
	export_env UPLOADNAME "-backslashxx_${version_label}"

	summary "| KernelSU | \`${KSU_DISPLAY_NAME}\` @ \`${version_label}\` |"
	endgroup
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	ksu_install "${KSU_REF:-}"
fi
