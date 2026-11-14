#!/usr/bin/env bash
# Resolve the build configuration, validate it, and export it to later steps.
#
# Resolution order (last wins):
#   1. built-in defaults below
#   2. the config file named by CONFIG_ENV (default: config.env)
#   3. workflow_dispatch inputs, passed in as IN_<KEY> environment variables
#
# The old workflow parsed config.env with
#     grep -w "$KEY" config.env | head -n1 | cut -d= -f2
# which truncates any value containing '=', matches commented-out lines, and
# matches a key that merely appears as a substring of a comment. That is why
# EXTRA_CMDS had to use a ':' separator. Both forms are still accepted here,
# but parsing is now anchored and comment-aware, so '=' in values is fine.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONFIG_FILE=${CONFIG_ENV:-config.env}

# --------------------------------------------------------------- defaults ---

declare -A DEFAULTS=(
	[KERNEL_SOURCE]=""
	[KERNEL_SOURCE_BRANCH]=""
	[KERNEL_CONFIG]=""
	[KERNEL_IMAGE_NAME]="zImage"
	[ARCH]="arm"
	[KERNEL_NAME]=""
	[ADD_LOCALVERSION_TO_FILENAME]="false"
	[EXTRA_CMDS]=""
	[CUSTOM_CMDS]=""

	# Toolchain (GCC 4.9 arm32; toolchain.sh supplies the AOSP defaults)
	[USE_LLVM]="false"
	[ENABLE_GCC_ARM32]="false"
	[USE_CUSTOM_GCC_32]="false"
	[CUSTOM_GCC_32_SOURCE]=""
	[CUSTOM_GCC_32_BRANCH]=""
	[CUSTOM_GCC_32_BIN]="arm-linux-androideabi-"

	# KernelSU
	[KSU_VARIANT]="none"
	[KSU_REF]=""
	[KSU_EXPECTED_SIZE]=""
	[KSU_EXPECTED_HASH]=""

	# Patches
	[ENABLE_PATH_UMOUNT]="false"

	# Kconfig tweaks
	[DISABLE_LTO]="false"
	[DISABLE_CC_WERROR]="false"
	[EXTRA_DEFCONFIG]=""

	# Packaging
	[BUILD_BOOT_IMG]="false"
	[SOURCE_BOOT_IMAGE]=""
)

# Legacy spellings that must keep working for existing config.env files.
declare -A ALIASES=(
	[DISABLE-LTO]="DISABLE_LTO"
	[KERNELSU_TAG]="KSU_REF"
)

# ----------------------------------------------------------------- parsing ---

# cfg_read FILE KEY -- first non-comment "KEY=value" or "KEY:value" line.
cfg_read() {
	local file=$1 key=$2
	[ -f "$file" ] || return 0
	sed -nE "s/\r$//; s/^[[:space:]]*${key}[[:space:]]*[=:][[:space:]]*(.*)$/\1/p" "$file" \
		| head -n1 \
		| sed -E 's/[[:space:]]+$//'
}

resolve() {
	local key val
	for key in "${!DEFAULTS[@]}"; do
		val=${DEFAULTS[$key]}

		local from_file
		from_file=$(cfg_read "$CONFIG_FILE" "$key")
		[ -n "$from_file" ] && val=$from_file

		# Workflow inputs win over the file, but only when actually provided.
		#
		# The sentinel "config" means "leave the config file's value alone".
		# The dispatch form needs it because a GitHub input always has a concrete
		# value; a disabled-by-default boolean would otherwise silently override
		# a feature the profile enabled.
		local in_var="IN_${key}"
		local in_val=${!in_var:-}
		if [ -n "$in_val" ] && [ "$in_val" != "config" ]; then
			val=$in_val
		fi

		CFG[$key]=$val
	done

	# Fold legacy spellings in only where the modern key is not already set.
	local legacy modern
	for legacy in "${!ALIASES[@]}"; do
		modern=${ALIASES[$legacy]}
		local lv
		lv=$(cfg_read "$CONFIG_FILE" "$legacy")
		[ -n "$lv" ] || continue
		local mv in_var="IN_${modern}"
		mv=$(cfg_read "$CONFIG_FILE" "$modern")
		if [ -z "$mv" ] && [ -z "${!in_var:-}" ]; then
			CFG[$modern]=$lv
			debug "legacy key ${legacy} -> ${modern}=${lv}"
		fi
	done
}

# -------------------------------------------------------------- validation ---

validate() {
	local errors=0
	_err() { warn "config: $*"; errors=$((errors + 1)); }

	[ -n "${CFG[KERNEL_SOURCE]}" ]        || _err "KERNEL_SOURCE is required"
	[ -n "${CFG[KERNEL_SOURCE_BRANCH]}" ] || _err "KERNEL_SOURCE_BRANCH is required"
	[ -n "${CFG[KERNEL_CONFIG]}" ]        || _err "KERNEL_CONFIG is required"
	[ -n "${CFG[KERNEL_IMAGE_NAME]}" ]    || _err "KERNEL_IMAGE_NAME is required"

	case "${CFG[ARCH]}" in
		arm64 | arm | x86_64 | riscv) ;;
		*) _err "ARCH must be one of arm64/arm/x86_64/riscv (got '${CFG[ARCH]}')" ;;
	esac

	case "${CFG[KSU_VARIANT]}" in
		none | backslashxx) ;;
		*) _err "unknown KSU_VARIANT '${CFG[KSU_VARIANT]}' (supported: none, backslashxx)" ;;
	esac

	if is_true "${CFG[BUILD_BOOT_IMG]}" && [ -z "${CFG[SOURCE_BOOT_IMAGE]}" ]; then
		_err "BUILD_BOOT_IMG=true requires SOURCE_BOOT_IMAGE"
	fi

	[ "$errors" -eq 0 ] || die "${errors} configuration error(s); fix ${CONFIG_FILE} or the workflow inputs"
}

# ------------------------------------------------------------------- main ---

declare -A CFG
resolve
validate

# Derive the device label from the defconfig name, as before.
DEVICE=$(printf '%s' "${CFG[KERNEL_CONFIG]}" | sed 's!.*/!!; s/_defconfig$//; s/_user$//; s/-perf$//')
[ -n "${CFG[KERNEL_NAME]}" ] && DEVICE=${CFG[KERNEL_NAME]}
CFG[DEVICE]=$DEVICE

summary "### Build configuration"
summary ""
summary "| Item | Value |"
summary "| --- | --- |"

group "Resolved configuration"
for key in $(printf '%s\n' "${!CFG[@]}" | sort); do
	printf '  %-32s = %s\n' "$key" "${CFG[$key]}"
	export_env "$key" "${CFG[$key]}"
done
endgroup

export_env BUILD_TIME "$(TZ=${BUILD_TZ:-Asia/Shanghai} date '+%Y%m%d%H%M')"

ok "configuration resolved (device: ${DEVICE})"
