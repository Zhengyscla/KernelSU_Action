#!/bin/bash
# Filter out flags unsupported by GCC 4.8
real_gcc="/home/runner/work/KernelSU_Action/KernelSU_Action/kernel_workspace/gcc-32/arm-linux-androideabi-4.8/bin/arm-linux-androideabi-gcc"

args=()
for arg in "$@"; do
  case "$arg" in
    -mtune=cortex-a57.cortex-a53)
      args+=("-mtune=cortex-a7")
      ;;
    -fisolate-erroneous-paths-dereference)
      # drop completely
      ;;
    *)
      args+=("$arg")
      ;;
  esac
done

exec "$real_gcc" "${args[@]}"
