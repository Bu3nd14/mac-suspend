#!/bin/bash
# Test suite for coffee / chamomile / coffee-tick.
#
# Nothing here touches the real system: `pmset`, `launchctl`, `sudo` and `install`
# are replaced by fakes on PATH, and the LaunchDaemons directory is redirected with
# LAUNCHD_DIR. The scripts are copied into a temporary root so $ROOT points there.
#
# Usage: tests/run.sh [-v]
# Exit: 0 all passed, 1 failures.

set -uo pipefail
VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
ko()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
check() {  # check "description" expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else ko "$1" "expected [$2] got [$3]"; fi
}

# ---------------------------------------------------------------- fixtures
setup() {
  ROOT="$TMP/root"; BIN="$TMP/fakebin"; ST="$TMP/state"; LD="$TMP/ld"
  rm -rf "$ROOT" "$BIN" "$ST" "$LD"
  mkdir -p "$ROOT" "$BIN" "$ST" "$LD" "$ROOT/logs"
  cp -R "$SRC/bin" "$ROOT/bin"
  cp -R "$SRC/daemon" "$ROOT/daemon"
  rm -f "$ST"/*

  cat > "$BIN/sudo" <<'EOS'
#!/bin/bash
exec "$@"
EOS

  cat > "$BIN/install" <<'EOS'
#!/bin/bash
# ignore -m/-o/-g and copy source → dest
src="${@: -2:1}"; dst="${@: -1}"
cp "$src" "$dst"
EOS

  cat > "$BIN/launchctl" <<'EOS'
#!/bin/bash
ST="$FAKE_STATE"
case "$1" in
  print)     [ -f "$ST/job" ] && echo "ok" || exit 113 ;;
  bootstrap) touch "$ST/job" ;;
  bootout)   rm -f "$ST/job" ;;
esac
exit 0
EOS

  cat > "$BIN/pmset" <<'EOS'
#!/bin/bash
ST="$FAKE_STATE"; echo "$*" >> "$ST/calls"
LIE="${FAKE_LIE:-0}"
case "$1" in
  -g)
    if [ "$2" = sched ]; then
      echo "Scheduled power events:"
      echo " [0]  wake at 10/30/2026 07:00:00 by 'com.apple.alarm.user-invisible-com.apple.acmd.alarm'"
      if [ -f "$ST/repeat" ]; then printf 'Repeating power events:\n'; cat "$ST/repeat"; else echo; fi
    elif [ "$2" = batt ]; then
      echo "Now drawing from '${FAKE_POWER:-AC Power}'"
      printf " -InternalBattery-0 (id=1)\t${FAKE_CHARGE:-80}%%; AC attached; not charging present: true\n"
    else
      [ "$(cat "$ST/ds" 2>/dev/null)" = 1 ] && printf 'System-wide power settings:\n SleepDisabled\t\t1\n' || printf 'System-wide power settings:\n'
    fi ;;
  -a)
    [ "$LIE" = 1 ] && exit 0
    [ "$2" = disablesleep ] && echo "$3" > "$ST/ds" ;;
  repeat)
    [ "$LIE" = 1 ] && exit 0
    if [ "$2" = cancel ]; then rm -f "$ST/repeat"; else echo "  wake at 6:30AM every day" > "$ST/repeat"; fi ;;
  sleepnow) : ;;
esac
exit 0
EOS

  cat > "$BIN/date" <<'EOS'
#!/bin/bash
[ -n "${FAKE_HHMM:-}" ] || exec /bin/date "$@"
case "$*" in
  *"%Y-%m-%dT%H:%M:%S%z"*) echo "2026-10-30T${FAKE_HHMM}:00+0100" ;;
  *"+%H"*)                  echo "${FAKE_HHMM%%:*}" ;;
  *"+%M"*)                  echo "${FAKE_HHMM##*:}" ;;
  *"%Y-%m-%d"*)             echo "2026-10-30" ;;
  *)                        exec /bin/date "$@" ;;
esac
EOS

  chmod +x "$BIN"/*
  export PATH="$BIN:$PATH" LAUNCHD_DIR="$LD" FAKE_STATE="$ST" PMSET_BIN="$BIN/pmset"
  unset FAKE_LIE FAKE_HHMM FAKE_POWER FAKE_CHARGE
  COFFEE="$ROOT/bin/coffee"; CHAMOMILE="$ROOT/bin/chamomile"; TICK="$ROOT/daemon/coffee-tick"
}

# ---------------------------------------------------------------- coffee
echo "coffee"
setup
out="$("$COFFEE" 2>&1)"; rc=$?
check "happy path exit 0"        0 "$rc"
check "disablesleep set to 1"    1 "$(cat "$ST/ds")"
check "wake armed (repeat)"      yes "$([ -f "$ST/repeat" ] && echo yes || echo no)"
check "job installed"            yes "$([ -f "$LD/com.roberto.coffee.tick.plist" ] && echo yes || echo no)"
check "job loaded"               yes "$([ -f "$ST/job" ] && echo yes || echo no)"
check "plist rendered (no @ROOT@)" 0 "$(grep -c '@ROOT@' "$LD/com.roberto.coffee.tick.plist" 2>/dev/null)"
check "plist points at fake root" yes "$(grep -q "$ROOT/daemon/coffee-tick" "$LD/com.roberto.coffee.tick.plist" && echo yes || echo no)"
[ "$VERBOSE" = 1 ] && printf '       output: %s\n' "$out"

out="$("$COFFEE" 2>&1)"; rc=$?
check "idempotent re-run exit 0" 0 "$rc"

# the bug that broke the first real run: $HOME changes under sudo
setup
out="$(HOME=/var/root "$COFFEE" 2>&1)"; rc=$?
check "works with HOME=/var/root" 0 "$rc"
[ "$rc" -ne 0 ] && [ "$VERBOSE" = 1 ] && printf '       output: %s\n' "$out"

# pmset that lies: exits 0 and changes nothing
setup
out="$(FAKE_LIE=1 "$COFFEE" 2>&1)"; rc=$?
check "lying pmset is detected"  1 "$rc"

# foreign repeating events must not be clobbered
setup
echo "  shutdown at 9:00PM every day" > "$ST/repeat"
echo 0 > "$ST/ds"
out="$("$COFFEE" 2>&1)"; rc=$?
check "foreign repeats refused"  1 "$rc"
check "  …nothing written"       0 "$(cat "$ST/ds")"
check "  …foreign event kept"    yes "$(grep -q shutdown "$ST/repeat" && echo yes || echo no)"

setup
out="$("$COFFEE" --bogus 2>&1)"; rc=$?
check "unknown argument exit 2"  2 "$rc"

# ---------------------------------------------------------------- chamomile
echo "chamomile"
setup
"$COFFEE" >/dev/null 2>&1
out="$("$CHAMOMILE" 2>&1)"; rc=$?
check "happy path exit 0"        0 "$rc"
check "disablesleep back to 0"   0 "$(cat "$ST/ds")"
check "repeat cancelled"         no "$([ -f "$ST/repeat" ] && echo yes || echo no)"
check "job unloaded"             no "$([ -f "$ST/job" ] && echo yes || echo no)"
check "job plist removed"        no "$([ -f "$LD/com.roberto.coffee.tick.plist" ] && echo yes || echo no)"

out="$("$CHAMOMILE" 2>&1)"; rc=$?
check "idempotent on clean state" 0 "$rc"

# escape hatch: foreign repeats must not stop disablesleep 0
setup
"$COFFEE" >/dev/null 2>&1
echo "  shutdown at 9:00PM every day" > "$ST/repeat"
echo 1 > "$ST/ds"
out="$("$CHAMOMILE" 2>&1)"; rc=$?
check "foreign repeats → exit 1"  1 "$rc"
check "  …but sleep restored"     0 "$(cat "$ST/ds")"
check "  …foreign event kept"     yes "$(grep -q shutdown "$ST/repeat" && echo yes || echo no)"

out="$("$CHAMOMILE" --force 2>&1)"; rc=$?
check "--force cancels them"      0 "$rc"
check "  …nothing left"           no "$([ -f "$ST/repeat" ] && echo yes || echo no)"

setup
out="$("$CHAMOMILE" --bogus 2>&1)"; rc=$?
check "unknown argument exit 2"   2 "$rc"

# ---------------------------------------------------------------- tick windows
echo "coffee-tick"
setup
echo 1 > "$ST/ds"
FAKE_HHMM=23:30 "$TICK"; calls="$(cat "$ST/calls" 2>/dev/null)"
check "23:30 releases sleep"      yes "$(printf '%s' "$calls" | grep -q 'disablesleep 0' && echo yes || echo no)"
check "23:30 calls sleepnow"      yes "$(printf '%s' "$calls" | grep -q 'sleepnow' && echo yes || echo no)"
check "23:30 logged source"       yes "$(grep -q 'source=AC Power charge=80%' "$ROOT/logs/tick.log" && echo yes || echo no)"

setup
echo 0 > "$ST/ds"
FAKE_HHMM=06:30 "$TICK"; calls="$(cat "$ST/calls" 2>/dev/null)"
check "06:30 restores disablesleep" yes "$(printf '%s' "$calls" | grep -q 'disablesleep 1' && echo yes || echo no)"
check "06:30 does not sleep"        no "$(printf '%s' "$calls" | grep -q 'sleepnow' && echo yes || echo no)"

for t in 12:01 23:20 22:00 03:00; do
  setup
  echo 1 > "$ST/ds"
  FAKE_HHMM="$t" "$TICK"; calls="$(cat "$ST/calls" 2>/dev/null)"
  check "outside window $t does nothing" no "$(printf '%s' "$calls" | grep -q 'disablesleep\|sleepnow' && echo yes || echo no)"
done

setup
echo 0 > "$ST/ds"
FAKE_HHMM=12:00 "$TICK"; calls="$(cat "$ST/calls" 2>/dev/null)"
check "12:00 is inside the window (boundary)" yes "$(printf '%s' "$calls" | grep -q 'disablesleep 1' && echo yes || echo no)"

setup
echo 1 > "$ST/ds"
FAKE_HHMM=23:30 FAKE_POWER="Battery Power" FAKE_CHARGE=24 "$TICK"
check "battery <30% warns"        yes "$(grep -q 'WARN batteria al 24%' "$ROOT/logs/tick.log" && echo yes || echo no)"

setup
echo 0 > "$ST/ds"
FAKE_HHMM=06:30 FAKE_POWER="Battery Power" FAKE_CHARGE=67 "$TICK"
check "morning on battery warns"  yes "$(grep -q 'WARN sveglia a batteria' "$ROOT/logs/tick.log" && echo yes || echo no)"

# ---------------------------------------------------------------- summary
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
