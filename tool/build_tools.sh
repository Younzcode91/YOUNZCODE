#!/usr/bin/env bash
# Precompiles the repo's CLI tools with `dart compile exe` into build/tools/,
# so invocations skip the ~5-7s of pub build hooks + JIT compile that plain
# `dart run` pays every time. Run once after changing a tool or its deps:
#
#   bash tool/build_tools.sh
#
# Consumers (tests, scripts) prefer the compiled binary when it exists and
# fall back to `dart run` otherwise, so builds are optional.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR="build/tools"
mkdir -p "$OUT_DIR"

built=0
skipped=0
for src in tool/*.dart; do
  name="$(basename "$src" .dart)"
  bin="$OUT_DIR/$name"
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) bin="$bin.exe" ;;
  esac
  if [ -f "$bin" ] && [ "$bin" -nt "$src" ]; then
    skipped=$((skipped + 1))
    continue
  fi
  echo "Building $name..."
  dart compile exe "$src" -o "$bin" >/dev/null
  built=$((built + 1))
done

echo "Tools ready in $OUT_DIR: $built rebuilt, $skipped up to date."
