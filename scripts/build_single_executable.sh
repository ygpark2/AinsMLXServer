#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <binary_path> <metallib_path> <assets_payload_path> <output_path>" >&2
  exit 1
fi

BIN_PATH="$1"
METALLIB_PATH="$2"
ASSETS_PAYLOAD_PATH="$3"
OUT_PATH="$4"
BIN_NAME="$(basename "$BIN_PATH")"

if [[ ! -f "$BIN_PATH" ]]; then
  echo "error: binary not found: $BIN_PATH" >&2
  exit 1
fi

if [[ ! -f "$METALLIB_PATH" ]]; then
  echo "error: metallib not found: $METALLIB_PATH" >&2
  exit 1
fi

if [[ ! -f "$ASSETS_PAYLOAD_PATH" ]]; then
  echo "error: assets payload not found: $ASSETS_PAYLOAD_PATH" >&2
  exit 1
fi

BIN_B64="$(mktemp)"
LIB_B64="$(mktemp)"
ASSETS_B64="$(mktemp)"
trap 'rm -f "$BIN_B64" "$LIB_B64" "$ASSETS_B64"' EXIT

base64 < "$BIN_PATH" > "$BIN_B64"
base64 < "$METALLIB_PATH" > "$LIB_B64"
base64 < "$ASSETS_PAYLOAD_PATH" > "$ASSETS_B64"

cat > "$OUT_PATH" <<SCRIPT_HEADER
#!/usr/bin/env bash
set -euo pipefail

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ainsmlx-single.XXXXXX")"
BIN_NAME="${BIN_NAME}"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

decode_base64() {
  local in_file="$1"
  local out_file="$2"
  if base64 --decode < "$in_file" > "$out_file" 2>/dev/null; then
    return 0
  fi
  base64 -D -i "$in_file" -o "$out_file"
}

cat > "$TMP_DIR/payload.bin.b64" <<'__AINS_BIN_B64__'
SCRIPT_HEADER

cat "$BIN_B64" >> "$OUT_PATH"

cat >> "$OUT_PATH" <<'SCRIPT_MID'
__AINS_BIN_B64__

cat > "$TMP_DIR/payload.metallib.b64" <<'__AINS_LIB_B64__'
SCRIPT_MID

cat "$LIB_B64" >> "$OUT_PATH"

cat >> "$OUT_PATH" <<'SCRIPT_FOOTER'
__AINS_LIB_B64__

cat > "$TMP_DIR/payload.assets.b64" <<'__AINS_ASSETS_B64__'
SCRIPT_FOOTER

cat "$ASSETS_B64" >> "$OUT_PATH"

cat >> "$OUT_PATH" <<'SCRIPT_TRAILER'
__AINS_ASSETS_B64__

decode_base64 "$TMP_DIR/payload.bin.b64" "$TMP_DIR/$BIN_NAME"
decode_base64 "$TMP_DIR/payload.metallib.b64" "$TMP_DIR/mlx.metallib"
mkdir -p "$TMP_DIR/Resources"
decode_base64 "$TMP_DIR/payload.assets.b64" "$TMP_DIR/Resources/embedded_assets_payload.zlib"
chmod +x "$TMP_DIR/$BIN_NAME"

"$TMP_DIR/$BIN_NAME" "$@"
SCRIPT_TRAILER

chmod +x "$OUT_PATH"
echo "✅ Created single executable: $OUT_PATH"
