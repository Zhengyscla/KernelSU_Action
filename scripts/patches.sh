#!/usr/bin/env bash
# Kernel source patch: path_umount() backport for kernels older than 5.9.
#
# KernelSU unmounts its own overlays before handing control to an app that is
# checking for root. path_umount() landed upstream in Linux 5.9, so 3.10 trees
# need it backported or module unmounting silently no-ops.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must point at the kernel source tree}

# The body below is upstream's, unchanged. It is inserted immediately before
# the comment that introduces the umount syscall, which puts it after
# do_umount() -- its only forward dependency.
path_umount_apply() {
	local ns="${KERNEL_DIR}/fs/namespace.c"
	group "Backporting path_umount()"

	local kver
	kver=$(kernel_version "$KERNEL_DIR") || die "cannot read kernel version"

	if ver_ge "$kver" "5.9"; then
		info "kernel ${kver} already provides path_umount() upstream; nothing to do"
		endgroup; return 0
	fi
	[ -f "$ns" ] || die "fs/namespace.c not found"

	if grep -q '^int path_umount\|^static int path_umount' "$ns"; then
		info "path_umount() is already present in fs/namespace.c; nothing to do"
		endgroup; return 0
	fi

	local anchor='Now umount can handle mount points as well as block devices'
	grep -q "$anchor" "$ns" \
		|| die "could not find the insertion point in fs/namespace.c; patch this kernel manually"

	local snippet
	snippet=$(mktemp)
	# 'can_umount' is a separate helper upstream; guard it in case a partial
	# backport already added it.
	if ! grep -q 'static int can_umount' "$ns"; then
		cat >>"$snippet" <<'EOF'
static int can_umount(const struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);

	if (flags & ~(MNT_FORCE | MNT_DETACH | MNT_EXPIRE | UMOUNT_NOFOLLOW))
		return -EINVAL;
	if (!may_mount())
		return -EPERM;
	if (path->dentry != path->mnt->mnt_root)
		return -EINVAL;
	if (!check_mnt(mnt))
		return -EINVAL;
#ifdef MNT_LOCKED
	if (mnt->mnt.mnt_flags & MNT_LOCKED) /* Check optimistically */
		return -EINVAL;
#endif
	if (flags & MNT_FORCE && !capable(CAP_SYS_ADMIN))
		return -EPERM;
	return 0;
}

EOF
	fi
	cat >>"$snippet" <<'EOF'
int path_umount(struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);
	int ret;

	ret = can_umount(path, flags);
	if (!ret)
		ret = do_umount(mnt, flags);

	/* we mustn't call path_put() as that would clear mnt_expiry_mark */
	dput(path->dentry);
	mntput_no_expire(mnt);
	return ret;
}

EOF

	# Insert before the line *above* the anchor comment body, i.e. at the '/*'
	# that opens it.
	local lineno start
	lineno=$(grep -n "$anchor" "$ns" | head -n1 | cut -d: -f1)
	start=$lineno
	while [ "$start" -gt 1 ] && ! sed -n "${start}p" "$ns" | grep -q '/\*'; do
		start=$((start - 1))
	done

	local tmp
	tmp=$(mktemp)
	head -n "$((start - 1))" "$ns" >"$tmp"
	cat "$snippet" >>"$tmp"
	tail -n "+${start}" "$ns" >>"$tmp"
	mv "$tmp" "$ns"
	rm -f "$snippet"

	grep -q '^int path_umount' "$ns" || die "path_umount() insertion failed"
	ok "path_umount() backported into fs/namespace.c (kernel ${kver})"
	summary "| path_umount | backported (kernel ${kver}) |"
	endgroup
}

# ------------------------------------------- SukiSU-Nova arm32 compat ---
# builtin-new's arm32 paths were written against newer headers/compilers and
# need two source fixes to build with GCC 4.9 on 3.10:
#
#  * `__attribute__((used, noinline))`: 3.10's compiler-gcc.h defines
#    `noinline` as `__attribute__((noinline))`, so nesting it inside another
#    attribute list is a syntax error. Move it to a following attribute.
#  * `DEFINE_RWLOCK()`: 3.10 expands it to a compound-literal cast
#    `(rwlock_t) {...}`, which GCC 4.9 rejects as a non-constant initializer
#    under the -std=gnu11 the tree uses for ksu.o. This kernel has lock
#    debugging off, so the plain initializer is equivalent.
sukisu_nova_compat() {
	local ksu="${KERNEL_DIR}/KernelSU/kernel"
	local avc="${ksu}/downstream/slow_avc_audit_defs.h"
	local dm="${ksu}/extension/dynamic_manager.c"

	group "Applying SukiSU-Nova arm32/GCC 4.9 fixes"
	[ -f "$avc" ] || die "missing ${avc#"${KERNEL_DIR}/"}"
	[ -f "$dm" ] || die "missing ${dm#"${KERNEL_DIR}/"}"

	sed -i \
		-e 's/__attribute__((used, noinline))/__attribute__((used)) noinline/' \
		-e 's/__attribute__((naked, used, noinline))/__attribute__((naked, used)) noinline/' \
		"$avc"
	sed -i 's|^static DEFINE_RWLOCK(dynamic_manager_lock);|static rwlock_t dynamic_manager_lock = { .raw_lock = __ARCH_RW_LOCK_UNLOCKED, RW_DEP_MAP_INIT(dynamic_manager_lock) };|' "$dm"

	# These replacements are what make the build possible; a silent miss would
	# only surface as a confusing compile error much later.
	if grep -q '__attribute__((used, noinline))\|__attribute__((naked, used, noinline))' "$avc"; then
		die "noinline attribute fix did not apply to slow_avc_audit_defs.h"
	fi
	if grep -q '^static DEFINE_RWLOCK(dynamic_manager_lock);' "$dm"; then
		die "DEFINE_RWLOCK fix did not apply to dynamic_manager.c"
	fi

	ok "patched arm32 trampoline attributes and dynamic_manager rwlock"
	summary "| SukiSU-Nova compat | noinline attributes + rwlock initializer |"
	endgroup
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	case "${1:-all}" in
		path_umount) path_umount_apply ;;
		nova-compat) sukisu_nova_compat ;;
		all)
			if [ "${KSU_VARIANT:-none}" = "sukisu-nova" ]; then
				sukisu_nova_compat
			fi
			# path_umount is only needed when KernelSU is built in.
			if [ "${KSU_VARIANT:-none}" != "none" ] &&
			   is_true "${ENABLE_PATH_UMOUNT:-false}"; then
				path_umount_apply
			fi
			;;
		*) die "unknown patch step '$1'" ;;
	esac
fi
