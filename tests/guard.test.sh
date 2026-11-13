#!/usr/bin/env bash
# Teardown and deadline tests for scripts/omarchy-dock-guard.
#
# The guard exists because Quickshell's Process destructor SIGKILLs only the
# tracked PID (the timeout monitor) when the plugin unloads. These tests run
# the same bash -> exec timeout -> guard -> command shape the QML uses, then
# kill the tracked timeout and verify that descendants -- including ones that
# ignore TERM -- are removed by the guard's KILL escalation.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
guard="$root/scripts/omarchy-dock-guard"
work="$(mktemp -d)"
export WORK="$work"
pids=()

cleanup() {
  local pid
  for pid in "${pids[@]:-}"; do
    [[ -n "$pid" ]] && kill -KILL "$pid" 2>/dev/null || true
  done
  rm -rf "$work"
}
trap cleanup EXIT

fail() {
  echo "guard test failed: $*" >&2
  exit 1
}

# Mirror the QML boundedCommand shape exactly.
bounded() {
  local seconds="$1"
  shift
  bash -c 'exec "$@"' bash timeout -k 5 "$seconds" "$guard" 2 "$@"
}

wait_for_file() {
  local i
  for ((i = 0; i < 600; i++)); do
    [[ -s "$1" ]] && return 0
    sleep 0.01
  done
  return 1
}

wait_for_death() {
  local i
  for ((i = 0; i < 600; i++)); do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.01
  done
  return 1
}

echo "== nested deadlines stay inside the guarded process group"
bad="$(grep -rn 'timeout -k' "$root/scripts/omarchy-dock-icon" "$root/DockPanelBase.qml" \
  "$root/IconPickerPanel.qml" "$root/BoundedTextField.qml" 2>/dev/null | grep -v -- '--foreground' || true)"
[[ -z "$bad" ]] || {
  printf '%s\n' "$bad" >&2
  fail "nested timeout without --foreground can escape the guard"
}

echo "== every tracked Process uses the deadline wrapper"
# Literal argv arrays bypass boundedCommand and therefore have no timeout or
# guard. Dynamic commands are assigned through boundedCommand; the paste
# command in BoundedTextField already embeds timeout + guard explicitly.
bad="$(grep -rnE '^[[:space:]]*command:[[:space:]]*\[' "$root"/*.qml 2>/dev/null || true)"
[[ -z "$bad" ]] || {
  printf '%s\n' "$bad" >&2
  fail "Process command literal bypasses the deadline wrapper"
}
bad="$(grep -rn '\.command = ' "$root"/*.qml 2>/dev/null | grep -v 'boundedCommand' || true)"
[[ -z "$bad" ]] || {
  printf '%s\n' "$bad" >&2
  fail "Process command assignment bypasses the deadline wrapper"
}

echo "== normal completion preserves stdout and exit status"
set +e
output="$(bounded 10 bash -c 'printf "guard-ok\n"; exit 7')"
status=$?
set -e
[[ "$status" -eq 7 ]] || fail "exit status $status, expected 7"
[[ "$output" == "guard-ok" ]] || fail "stdout was '$output'"

echo "== plugin teardown cleans up TERM-ignoring descendants"
bounded 60 bash -c '
  trap "" TERM
  echo $$ > "$WORK/victim.pid"
  bash -c '\''trap "" TERM; echo $$ > "$WORK/grandchild.pid"; exec sleep 300'\'' &
  wait
' &
tracked=$!
pids+=("$tracked")
wait_for_file "$work/victim.pid" || fail "victim did not start"
wait_for_file "$work/grandchild.pid" || fail "grandchild did not start"
victim="$(cat "$work/victim.pid")"
grandchild="$(cat "$work/grandchild.pid")"
pids+=("$victim" "$grandchild")

kill -0 "$victim" 2>/dev/null || fail "victim not running before teardown"
kill -0 "$grandchild" 2>/dev/null || fail "grandchild not running before teardown"
kill -KILL "$tracked" 2>/dev/null || true
wait "$tracked" 2>/dev/null || true

# The guard's TERM trap fires first; these processes ignore TERM, so they must
# survive briefly and then be removed by the detached KILL escalation.
sleep 0.2
wait_for_death "$victim" || fail "victim survived plugin teardown"
wait_for_death "$grandchild" || fail "grandchild survived plugin teardown"

echo "== deadline expiry still returns 124 and removes TERM-ignoring work"
set +e
bounded 1 bash -c 'trap "" TERM; echo $$ > "$WORK/deadline.pid"; exec sleep 300'
status=$?
set -e
[[ "$status" -eq 124 ]] || fail "deadline status $status, expected 124"
wait_for_file "$work/deadline.pid" || fail "deadline child never started"
deadline_pid="$(cat "$work/deadline.pid")"
pids+=("$deadline_pid")
wait_for_death "$deadline_pid" || fail "deadline child survived"

echo "== nested --foreground timeout stays in the guarded group"
bounded 60 bash -c '
  timeout --foreground -k 1 60 bash -c '\''trap "" TERM; echo $$ > "$WORK/nested.pid"; exec sleep 300'\'' &
  wait
' &
tracked=$!
pids+=("$tracked")
wait_for_file "$work/nested.pid" || fail "nested timeout child did not start"
nested_pid="$(cat "$work/nested.pid")"
pids+=("$nested_pid")
kill -KILL "$tracked" 2>/dev/null || true
wait "$tracked" 2>/dev/null || true
wait_for_death "$nested_pid" || fail "nested timeout child escaped teardown"

if command -v setsid >/dev/null 2>&1; then
  echo "== direct invocation does not signal the caller's process group"
  safety="$(
    setsid bash -c '
      sleep 300 & sibling=$!
      bash "$1" 1 sleep 300 & guard_pid=$!
      kill -TERM "$guard_pid" 2>/dev/null || true
      wait "$guard_pid" 2>/dev/null || true
      if kill -0 "$sibling" 2>/dev/null; then
        echo SAFETY_OK
      else
        echo SAFETY_FAIL
      fi
      kill -KILL "$sibling" 2>/dev/null || true
    ' bash "$guard"
  )"
  [[ "$safety" == "SAFETY_OK" ]] || fail "guard signaled a foreign process group"
fi

echo "guard tests passed"
