#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <mlx_source_root> <output_metallib_path>" >&2
  exit 1
fi

MLX_SOURCE_ROOT="$1"
OUTPUT_PATH="$2"
METAL_TOOLCHAIN_ROOT="${METAL_TOOLCHAIN_ROOT:-/Users/ygpark2/Library/Developer/Toolchains/Metal.xctoolchain}"
if [[ ! -x "$METAL_TOOLCHAIN_ROOT/usr/bin/metal" && -x /private/tmp/metaltool/Metal.xctoolchain/usr/bin/metal ]]; then
  METAL_TOOLCHAIN_ROOT=/private/tmp/metaltool/Metal.xctoolchain
fi

METAL_BIN="$METAL_TOOLCHAIN_ROOT/usr/bin/metal"
METAL_FLAGS=(
  -x metal
  -Wall
  -Wextra
  -fno-fast-math
  -Wno-c++17-extensions
  -Wno-c++20-extensions
)

if [[ -n "${MACOSX_DEPLOYMENT_TARGET:-}" ]]; then
  METAL_FLAGS+=("-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}")
fi

if [[ ! -d "$MLX_SOURCE_ROOT" ]]; then
  echo "error: MLX source root not found: $MLX_SOURCE_ROOT" >&2
  exit 1
fi

tmpdir="$(mktemp -d /tmp/ainsmlx-metal.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT
module_cache_dir="$tmpdir/module-cache"
mkdir -p "$module_cache_dir"
METAL_FLAGS+=("-fmodules-cache-path=$module_cache_dir")

compile_root="$MLX_SOURCE_ROOT/mlx/mlx/backend/metal/kernels"
if [[ ! -d "$compile_root" ]]; then
  echo "error: MLX metal kernels not found: $compile_root" >&2
  exit 1
fi

metal_sources=()
while IFS= read -r src; do
  [[ -n "$src" ]] || continue
  metal_sources+=("$src")
done < <(find "$compile_root" -name '*.metal' | sort)

if [[ ${#metal_sources[@]} -eq 0 ]]; then
  echo "error: no Metal sources found under: $compile_root" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"

"$METAL_BIN" \
  "${METAL_FLAGS[@]}" \
  -I "$MLX_SOURCE_ROOT/mlx" \
  "${metal_sources[@]}" \
  -o "$OUTPUT_PATH"
