#!/usr/bin/env bash
# Installs the repo's git hooks by pointing core.hooksPath at tool/hooks
# (the modern, shareable way to ship hooks — no copying into .git needed).
#
#   bash tool/install_git_hooks.sh
#
# The pre-push hook refuses to push a v* tag while any .github/workflows/*.yml
# fails to parse, so a broken workflow (which GitHub silently ignores) can
# never ship via a release tag. CI enforces the same check via
# workflow-lint.yml, so the hook is a fast local guard, not the only one.
set -euo pipefail
cd "$(dirname "$0")/.."

hooks_path="$(pwd)/tool/hooks"
git config core.hooksPath "$hooks_path"
echo "core.hooksPath -> $hooks_path"
echo "Hook pre-push aktif: blokir push tag v* jika workflow YAML rusak."

# Smoke test the hook logic against the current tree.
if ! dart run tool/check_workflows.dart >/dev/null; then
  echo "PERINGATAN: workflow saat ini tidak valid — push tag akan ditolak." >&2
  exit 1
fi
echo "Workflow saat ini valid."
