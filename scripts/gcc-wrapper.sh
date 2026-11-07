#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# WORKSPACE is exported by the workflow (points at <repo>/kernel_workspace).
WORKSPACE="${WORKSPACE:-$(dirname "$SCRIPT_DIR")/kernel_workspace}"
GCC_DIR="$WORKSPACE/gcc-32"

real_gcc=""

# toolchain.sh exports CROSS_COMPILE for ARCH=arm builds; prefer it so this
# wrapper does not depend on a fixed workspace layout.
if [ -n "${CROSS_COMPILE:-}" ] && [ -x "${CROSS_COMPILE}gcc" ]; then
    real_gcc="${CROSS_COMPILE}gcc"
fi

if [ -z "$real_gcc" ]; then
    real_gcc="$GCC_DIR/bin/arm-linux-androideabi-gcc"
fi

# 如果默认路径不存在，搜索实际解压位置（同时接受符号链接）
if [ ! -x "$real_gcc" ]; then
    real_gcc="$(find "$GCC_DIR" \( -type f -o -type l \) \
        -name arm-linux-androideabi-gcc \
        -print 2>/dev/null | sort -V | tail -n1)"
fi

if [ -z "$real_gcc" ] || [ ! -x "$real_gcc" ]; then
    echo "[ERROR] GCC compiler not found!"
    echo "[DEBUG] GCC directory:"
    find "$GCC_DIR" -maxdepth 4 -type f -name '*gcc*' 2>/dev/null | head -50
    exit 127
fi

chmod +x "$real_gcc" 2>/dev/null || true

echo "[INFO] Using GCC: $real_gcc" >&2

args=()
for arg in "$@"; do
    case "$arg" in
        -mtune=cortex-a57.cortex-a53)
            args+=("-mtune=cortex-a7")
            ;;
        -fisolate-erroneous-paths-dereference)
            ;;
        *)
            args+=("$arg")
            ;;
    esac
done

exec "$real_gcc" "${args[@]}"
