#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(dirname "$SCRIPT_DIR")"
GCC_DIR="$WORKSPACE/kernel_workspace/gcc-32"

real_gcc="$GCC_DIR/bin/arm-linux-androideabi-gcc"

# 如果默认路径不存在，搜索实际解压位置
if [ ! -x "$real_gcc" ]; then
    real_gcc="$(find "$GCC_DIR" -type f \
        -name arm-linux-androideabi-gcc -perm -u+x \
        -print -quit 2>/dev/null)"
fi

if [ -z "$real_gcc" ] || [ ! -x "$real_gcc" ]; then
    echo "[ERROR] GCC 4.9 compiler not found!"
    echo "[DEBUG] GCC directory:"
    find "$GCC_DIR" -maxdepth 4 -type f -name '*gcc*' 2>/dev/null | head -50
    exit 127
fi

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
