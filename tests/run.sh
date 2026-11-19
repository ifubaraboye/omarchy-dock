#!/usr/bin/env bash
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node --test tests/*.test.js
# The submenu state machine is held to 100% line/branch/function coverage:
# its hover discipline broke twice behind untested QML signal handlers, so
# the logic lives in DockSubmenu.js and anything less than full coverage of
# it fails the suite.
node --test --experimental-test-coverage --test-coverage-lines=100 --test-coverage-branches=100 --test-coverage-functions=100 tests/DockSubmenu.test.js
bash tests/helper.test.sh
bash tests/guard.test.sh
bash tests/qml-structure.test.sh
