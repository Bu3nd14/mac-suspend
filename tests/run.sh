#!/bin/bash
# Test suite for coffee / chamomile / coffee-tick.
#
# Nothing here touches the real system: `pmset`, `launchctl`, `sudo`, `install` and
# `date` are replaced by fakes on PATH, the LaunchDaemons directory is redirected with
# LAUNCHD_DIR and the tick's pmset with PMSET_BIN. Scripts are copied into a temporary
# root so $ROOT points there.
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
  mkdir -p "$ROOT" "$BIN" "$ST" "$LD" "$ROOT/logs" "$ROOT/state"
  cp -R "$SRC/bin" "$ROOT/bin"
  cp -R "$SRC/daemon" "$ROOT/daemon"

  cat > "$BIN/sudo" <<'EOS'
#!/bin/bash
exec "$@"
EOS

  cat > "$BIN/install" <<'EOS'
#!/bin/bash
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
    if [ "$2" = cancel ]; then
      rm -f "$ST/repeat"
    else
      # repeat wake MTWRFSU HH:MM:SS  → record the 24h time, like pmset does
      echo "  wake at ${4%:*}" > "$ST/repeat"
    fi ;;
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
  PLIST="$LD/com.roberto.coffee.tick.plist"
}

plist_int() { /usr/libexec/PlistBuddy -c "Print :StartCalendarInterval:$1:$2" "$PLIST" 2>/dev/null; }
calls() { cat "$ST/calls" 2>/dev/null; }

# ---------------------------------------------------------------- coffee (defaults)
echo "coffee (defaults)"
setup
out="$("$COFFEE" 2>&1)"; rc=$?
check "happy path exit 0"            0 "$rc"
check "disablesleep set to 1"        1 "$(cat "$ST/ds")"
check "wake armed"                   yes "$([ -f "$ST/repeat" ] && echo yes || echo no)"
check "job installed"                yes "$([ -f "$PLIST" ] && echo yes || echo no)"
check "job loaded"                   yes "$([ -f "$ST/job" ] && echo yes || echo no)"
check "rendered plist is valid"      yes "$(/usr/bin/plutil -lint "$PLIST" >/dev/null 2>&1 && echo yes || echo no)"
check "no @ROOT@ left"               0 "$(grep -c '@ROOT@' "$PLIST" 2>/dev/null)"
check "no time placeholder left"     0 "$(grep -cE '@(SH|SM|WH|WM|BH|BM|SLEEP|WAKE)@' "$PLIST" 2>/dev/null)"
check "plist points at fake root"    yes "$(grep -q "$ROOT/daemon/coffee-tick" "$PLIST" && echo yes || echo no)"
check "sleep interval 23:30"         "23 30" "$(plist_int 0 Hour) $(plist_int 0 Minute)"
check "wake interval 06:30"          "6 30"  "$(plist_int 1 Hour) $(plist_int 1 Minute)"
check "backup interval 06:45"        "6 45"  "$(plist_int 2 Hour) $(plist_int 2 Minute)"
check "config written"               yes "$([ -f "$ROOT/state/config" ] && echo yes || echo no)"
[ "$VERBOSE" = 1 ] && printf '       output: %s\n' "$out"

"$COFFEE" >/dev/null 2>&1
check "idempotent re-run exit 0"     0 "$?"

setup
HOME=/var/root "$COFFEE" >/dev/null 2>&1
check "works with HOME=/var/root"    0 "$?"

setup
FAKE_LIE=1 "$COFFEE" >/dev/null 2>&1
check "lying pmset is detected"      1 "$?"

setup
echo "  shutdown at 9:00PM every day" > "$ST/repeat"
echo 0 > "$ST/ds"
"$COFFEE" >/dev/null 2>&1
check "foreign repeats refused"      1 "$?"
check "  …nothing written"           0 "$(cat "$ST/ds")"
check "  …foreign event kept"        yes "$(grep -q shutdown "$ST/repeat" && echo yes || echo no)"

# ---------------------------------------------------------------- coffee (custom times)
echo "coffee (custom times)"
setup
out="$("$COFFEE" --sleep 22:15 --wake 07:05 2>&1)"; rc=$?
check "custom times exit 0"          0 "$rc"
check "sleep interval 22:15"         "22 15" "$(plist_int 0 Hour) $(plist_int 0 Minute)"
check "wake interval 07:05"          "7 5"   "$(plist_int 1 Hour) $(plist_int 1 Minute)"
check "backup interval 07:20"        "7 20"  "$(plist_int 2 Hour) $(plist_int 2 Minute)"
check "wake passed to pmset"         yes "$(calls | grep -q 'repeat wake MTWRFSU 07:05:00' && echo yes || echo no)"
check "times passed to the tick"     yes "$(grep -q '<string>22:15</string>' "$PLIST" && grep -q '<string>07:05</string>' "$PLIST" && echo yes || echo no)"
check "config holds the times"       "SLEEP=22:15" "$(sed -n 1p "$ROOT/state/config")"

# a bare re-run keeps the configured times instead of resetting to defaults
rm -f "$ST/calls"
"$COFFEE" >/dev/null 2>&1
check "bare re-run keeps 07:05"      yes "$(calls | grep -q '07:05:00' && echo yes || echo no)"

# changing the times must not be mistaken for a foreign event
out="$("$COFFEE" --sleep 21:00 --wake 06:00 2>&1)"; rc=$?
check "times can be changed"         0 "$rc"
check "  …new wake in the plist"     "6 0" "$(plist_int 1 Hour) $(plist_int 1 Minute)"

# midnight crossing for the backup interval
setup
"$COFFEE" --sleep 12:00 --wake 23:55 >/dev/null 2>&1
check "backup wraps midnight"        "0 10" "$(plist_int 2 Hour) $(plist_int 2 Minute)"

# validation
for bad in "--sleep 24:00 --wake 06:30" "--sleep 7:5 --wake 06:30" \
           "--sleep 10:00 --wake 10:00" "--sleep 10:00 --wake 10:30" \
           "--sleep 23:30 --wake 00:20" "--sleep"; do
  setup
  # shellcheck disable=SC2086
  "$COFFEE" $bad >/dev/null 2>&1
  check "rejects [$bad]" 2 "$?"
done

setup
"$COFFEE" --sleep 22:00 --wake 06:00 --bogus >/dev/null 2>&1
check "unknown argument exit 2"      2 "$?"

# ---------------------------------------------------------------- chamomile
echo "chamomile"
setup
"$COFFEE" >/dev/null 2>&1
out="$("$CHAMOMILE" 2>&1)"; rc=$?
check "happy path exit 0"            0 "$rc"
check "disablesleep back to 0"       0 "$(cat "$ST/ds")"
check "repeat cancelled"             no "$([ -f "$ST/repeat" ] && echo yes || echo no)"
check "job unloaded"                 no "$([ -f "$ST/job" ] && echo yes || echo no)"
check "job plist removed"            no "$([ -f "$PLIST" ] && echo yes || echo no)"
check "config removed"               no "$([ -f "$ROOT/state/config" ] && echo yes || echo no)"

"$CHAMOMILE" >/dev/null 2>&1
check "idempotent on clean state"    0 "$?"

# configured wake is recognised as ours, not as a foreign event
setup
"$COFFEE" --sleep 22:00 --wake 06:15 >/dev/null 2>&1
"$CHAMOMILE" >/dev/null 2>&1
check "custom wake cancelled (not foreign)" 0 "$?"

setup
"$COFFEE" >/dev/null 2>&1
echo "  shutdown at 9:00PM every day" > "$ST/repeat"
echo 1 > "$ST/ds"
"$CHAMOMILE" >/dev/null 2>&1
check "foreign repeats → exit 1"     1 "$?"
check "  …but sleep restored"        0 "$(cat "$ST/ds")"
check "  …foreign event kept"        yes "$(grep -q shutdown "$ST/repeat" && echo yes || echo no)"

"$CHAMOMILE" --force >/dev/null 2>&1
check "--force cancels them"         0 "$?"
check "  …nothing left"              no "$([ -f "$ST/repeat" ] && echo yes || echo no)"

setup
"$CHAMOMILE" --bogus >/dev/null 2>&1
check "unknown argument exit 2"      2 "$?"

# ---------------------------------------------------------------- tick windows
echo "coffee-tick"
setup
echo 1 > "$ST/ds"
FAKE_HHMM=23:30 "$TICK" 23:30 06:30
check "23:30 releases sleep"         yes "$(calls | grep -q 'disablesleep 0' && echo yes || echo no)"
check "23:30 calls sleepnow"         yes "$(calls | grep -q 'sleepnow' && echo yes || echo no)"
check "log records the times"        yes "$(grep -q 'sleep=23:30 wake=06:30' "$ROOT/logs/tick.log" && echo yes || echo no)"
check "log records the source"       yes "$(grep -q 'source=AC Power charge=80%' "$ROOT/logs/tick.log" && echo yes || echo no)"

setup
echo 0 > "$ST/ds"
FAKE_HHMM=06:30 "$TICK" 23:30 06:30
check "06:30 restores disablesleep"  yes "$(calls | grep -q 'disablesleep 1' && echo yes || echo no)"
check "06:30 does not sleep"         no  "$(calls | grep -q 'sleepnow' && echo yes || echo no)"

# windows follow the configured times, not the defaults
setup
echo 1 > "$ST/ds"
FAKE_HHMM=22:15 "$TICK" 22:15 07:05
check "22:15 sleeps (custom)"        yes "$(calls | grep -q 'sleepnow' && echo yes || echo no)"

setup
echo 0 > "$ST/ds"
FAKE_HHMM=07:05 "$TICK" 22:15 07:05
check "07:05 restores (custom)"      yes "$(calls | grep -q 'disablesleep 1' && echo yes || echo no)"

setup
echo 1 > "$ST/ds"
FAKE_HHMM=23:30 "$TICK" 22:15 07:05
check "23:30 outside custom window"  no "$(calls | grep -q 'disablesleep\|sleepnow' && echo yes || echo no)"

# circum-midnight window
setup
echo 1 > "$ST/ds"
FAKE_HHMM=00:05 "$TICK" 23:58 08:00
check "window wraps midnight"        yes "$(calls | grep -q 'sleepnow' && echo yes || echo no)"

setup
echo 0 > "$ST/ds"
FAKE_HHMM=00:30 "$TICK" 10:00 23:30
check "wake window wraps midnight"   yes "$(calls | grep -q 'disablesleep 1' && echo yes || echo no)"

setup
echo 0 > "$ST/ds"
FAKE_HHMM=02:00 "$TICK" 10:00 23:30
check "02:00 outside wrapped wake window" no "$(calls | grep -q 'disablesleep' && echo yes || echo no)"

for t in 12:01 23:20 22:00 03:00; do
  setup
  echo 1 > "$ST/ds"
  FAKE_HHMM="$t" "$TICK" 23:30 06:30
  check "outside window $t does nothing" no "$(calls | grep -q 'disablesleep\|sleepnow' && echo yes || echo no)"
done

setup
echo 0 > "$ST/ds"
FAKE_HHMM=12:00 "$TICK" 23:30 06:30
check "12:00 outside wake window now" no "$(calls | grep -q 'disablesleep' && echo yes || echo no)"

setup
echo 0 > "$ST/ds"
FAKE_HHMM=08:00 "$TICK" 23:30 06:30
check "08:00 inside wake window (+120m)" yes "$(calls | grep -q 'disablesleep 1' && echo yes || echo no)"

setup
echo 1 > "$ST/ds"
FAKE_HHMM=23:30 FAKE_POWER="Battery Power" FAKE_CHARGE=24 "$TICK" 23:30 06:30
check "battery <30% warns"           yes "$(grep -q 'WARN batteria al 24%' "$ROOT/logs/tick.log" && echo yes || echo no)"

setup
echo 0 > "$ST/ds"
FAKE_HHMM=06:30 FAKE_POWER="Battery Power" FAKE_CHARGE=67 "$TICK" 23:30 06:30
check "morning on battery warns"     yes "$(grep -q 'WARN sveglia a batteria' "$ROOT/logs/tick.log" && echo yes || echo no)"

# ---------------------------------------------------------------- summary
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
