#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
EXPORT_DIR="${EXPORT_DIR:-$ROOT_DIR/tmp/wechat_favorites_export}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/tmp/wechat_favorites_build}"
PENDING_BATCH_DIR="${PENDING_BATCH_DIR:-$EXPORT_DIR/pending_batches}"
TARGET="${TARGET:-100}"
CAPTURE_MODE="${CAPTURE_MODE:-fast}"
IMPORT_MODE="${IMPORT_MODE:-fast}"
RESOLVE_INFLIGHT="${RESOLVE_INFLIGHT:-}"
LOCK_DIR="$EXPORT_DIR/.sync.lock"

mkdir -p "$EXPORT_DIR" "$BUILD_DIR" "$ROOT_DIR/tmp/swift-module-cache"
cd "$ROOT_DIR"

export SWIFT_MODULE_CACHE_PATH="$ROOT_DIR/tmp/swift-module-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/tmp/swift-module-cache"
export SDKROOT="${SDKROOT_OVERRIDE:-$(/usr/bin/xcrun --sdk macosx --show-sdk-path)}"

release_lock() {
  rm -f "$LOCK_DIR/pid"
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" >"$LOCK_DIR/pid"
    trap release_lock EXIT INT TERM
    return 0
  fi

  local owner=""
  [[ -f "$LOCK_DIR/pid" ]] && owner="$(<"$LOCK_DIR/pid")"
  if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then
    echo "Another sync is already running (pid=$owner)." >&2
    exit 1
  fi

  rm -f "$LOCK_DIR/pid"
  rmdir "$LOCK_DIR" 2>/dev/null || {
    echo "Cannot clear stale sync lock: $LOCK_DIR" >&2
    exit 1
  }
  mkdir "$LOCK_DIR"
  printf '%s\n' "$$" >"$LOCK_DIR/pid"
  trap release_lock EXIT INT TERM
}

compile_if_needed() {
  local source="$1"
  local output="$2"
  if [[ ! -x "$output" || "$source" -nt "$output" ]]; then
    swiftc "$source" -O -o "$output"
  fi
}

mode_flag() {
  case "$1" in
    turbo) printf '%s' "--turbo" ;;
    fast) printf '%s' "--fast" ;;
    safe|"") printf '%s' "" ;;
    *)
      echo "Unsupported mode: $1" >&2
      exit 2
      ;;
  esac
}

refresh() {
  python3 scripts/wechat_favorites_progress.py --dir "$EXPORT_DIR" --target "$TARGET" refresh
}

make_batches() {
  local pending="$EXPORT_DIR/pending_links.txt"
  mkdir -p "$PENDING_BATCH_DIR"
  find "$PENDING_BATCH_DIR" -maxdepth 1 -type f -name 'batch_*.txt' -delete
  python3 - "$pending" "$PENDING_BATCH_DIR" <<'PY'
from pathlib import Path
import sys

pending = Path(sys.argv[1])
batches = Path(sys.argv[2])
links = [line.strip() for line in pending.read_text(encoding="utf-8").splitlines() if line.strip()]
for index in range(0, len(links), 10):
    batch_number = index // 10 + 1
    path = batches / f"batch_{batch_number:03d}.txt"
    chunk = links[index:index + 10]
    path.write_text("\n".join(chunk) + "\n", encoding="utf-8")
PY
}

batch_count() {
  find "$PENDING_BATCH_DIR" -maxdepth 1 -name 'batch_*.txt' | wc -l | tr -d ' '
}

run_capture() {
  compile_if_needed scripts/wechat_favorites_capture.swift "$BUILD_DIR/wechat_favorites_capture"
  local flag
  flag="$(mode_flag "$CAPTURE_MODE")"
  local args=(--dir "$EXPORT_DIR" --target "$TARGET")
  [[ -n "$flag" ]] && args+=("$flag")
  "$BUILD_DIR/wechat_favorites_capture" "${args[@]}"
  refresh
}

run_import() {
  compile_if_needed scripts/ima_import_batches.swift "$BUILD_DIR/ima_import_batches"
  refresh >/dev/null
  if [[ -f "$EXPORT_DIR/import_inflight.json" ]]; then
    local recovery_args=(--dir "$EXPORT_DIR" --recover-only)
    if [[ -n "$RESOLVE_INFLIGHT" ]]; then
      recovery_args+=(--resolve-inflight "$RESOLVE_INFLIGHT")
    fi
    "$BUILD_DIR/ima_import_batches" "${recovery_args[@]}"
    refresh >/dev/null
  fi
  make_batches
  local count
  count="$(batch_count)"
  if [[ "$count" == "0" ]]; then
    echo "No pending links to import."
    return 0
  fi
  local flag
  flag="$(mode_flag "$IMPORT_MODE")"
  local args=(--dir "$EXPORT_DIR" --batch-dir "$PENDING_BATCH_DIR" --from 1 --to "$count")
  [[ -n "$flag" ]] && args+=("$flag")
  if [[ -n "$RESOLVE_INFLIGHT" ]]; then
    args+=(--resolve-inflight "$RESOLVE_INFLIGHT")
  fi
  "$BUILD_DIR/ima_import_batches" "${args[@]}"
  refresh
}

case "${1:-all}" in
  compile)
    compile_if_needed scripts/wechat_favorites_capture.swift "$BUILD_DIR/wechat_favorites_capture"
    compile_if_needed scripts/ima_import_batches.swift "$BUILD_DIR/ima_import_batches"
    ;;
  capture)
    acquire_lock
    run_capture
    ;;
  import)
    acquire_lock
    run_import
    ;;
  refresh)
    refresh
    ;;
  all)
    acquire_lock
    run_capture
    run_import
    ;;
  *)
    cat <<EOF
Usage:
  $0 compile
  $0 capture
  $0 import
  $0 refresh
  $0 all

Environment:
  TARGET=100
  CAPTURE_MODE=safe|fast|turbo
  IMPORT_MODE=safe|fast|turbo
  RESOLVE_INFLIGHT=submitted|retry
  EXPORT_DIR=$EXPORT_DIR
EOF
    exit 2
    ;;
esac
