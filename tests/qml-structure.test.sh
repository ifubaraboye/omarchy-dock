#!/usr/bin/env bash
# Structural QML checks that the toolchain does not reliably fail on:
# duplicate property, signal, or id declarations inside one file. A duplicate
# `property` declaration once shipped silently and broke submenu behavior at
# runtime while qmllint reported nothing the CI grep looked for; this check
# fails the suite instead.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail=0

# Structural QML checks the QML toolchain does not reliably fail on:
# duplicate root-level property, signal, or id declarations inside one file.
# A duplicate `property` declaration once shipped silently and broke submenu
# behavior at runtime while qmllint reported nothing the CI grep looked for.
#
# Root-level only (exactly two leading spaces): QML scopes properties per
# object, so the same name in different delegates or inline components is
# legal — those sit at deeper indentation and are skipped on purpose. Root
# members share one scope, so a duplicate there is always a real error.
check_dupes() {
  local label="$1" pattern="$2" extract="$3" file="$4" found
  # grep exits 1 on no matches, which set -e + pipefail would treat as fatal;
  # an empty result is the expected case for most files.
  found=$({ grep -E "$pattern" "$file" || true; } | sed -E "$extract" | sort | uniq -d)
  if [[ -n "$found" ]]; then
    echo "duplicate $label in $file: $(echo "$found" | tr '\n' ' ')" >&2
    fail=1
  fi
}

for file in *.qml; do
  [[ -e "$file" ]] || continue
  # property <name> — plain, readonly, and required, root members only
  check_dupes "property declarations" \
    '^  ((readonly|required)[[:space:]]+)?property[[:space:]]+[A-Za-z0-9_.<>]+[[:space:]]+[A-Za-z0-9_]+.*$' \
    's/^.*property[[:space:]]+[A-Za-z0-9_.<>]+[[:space:]]+([A-Za-z0-9_]+).*$/\1/' \
    "$file"
  check_dupes "signal declarations" \
    '^  signal[[:space:]]+[A-Za-z0-9_]+.*$' \
    's/^  signal[[:space:]]+([A-Za-z0-9_]+).*$/\1/' \
    "$file"
  check_dupes "ids" \
    '^  id:[[:space:]]*[A-Za-z0-9_]+[[:space:]]*$' \
    's/^  id:[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*$/\1/' \
    "$file"
done

# Belt and braces: qmllint flags some duplicates natively. Best-effort —
# skip silently when the binary is absent (it is not on PATH by default).
qmllint_bin="/usr/lib/qt6/bin/qmllint"
if [[ -x "$qmllint_bin" ]]; then
  lint_out=$("$qmllint_bin" *.qml 2>&1 || true)
  if grep -qiE "duplicate" <<<"$lint_out"; then
    grep -iE "duplicate" <<<"$lint_out" >&2
    fail=1
  fi
fi

if (( fail )); then
  echo "qml structure tests FAILED" >&2
  exit 1
fi

echo "qml structure tests passed"
