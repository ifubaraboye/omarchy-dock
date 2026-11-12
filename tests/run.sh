#!/usr/bin/env bash
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node --test tests/*.test.js
bash tests/helper.test.sh
bash tests/guard.test.sh
