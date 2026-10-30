# coffee / chamomile — scheduled suspend for macOS

Two commands for a headless Mac that must **stay awake during the day** and **sleep at
night**, waking up on its own at a fixed time.

```
coffee      → prevents sleep, and schedules: suspend 23:30 / resume 06:30
coffee --sleep 22:15 --wake 07:05        # the same, with different times
chamomile   → restores sleep and removes everything coffee set up
```

Built for a MacBook used with the **lid closed**, on power, reached over SSH
(here through a tunnel running inside a container in colima).

## Why `pmset repeat sleep` is not enough

Verified on macOS 26.7.1 (Apple Silicon), not taken on faith:

| test | result |
|---|---|
| `pmset -a disablesleep 1` + `pmset repeat sleep 23:30` | the machine **does not sleep** |
| `pmset -a disablesleep 1` + `pmset sleepnow` | `Unable to sleep system: error 0xe00002e2` (not permitted) |
| launchd `StartCalendarInterval` job while the Mac is asleep | **does not wake it**: the job runs at the next wake, late |
| `pmset repeat wake 06:30` | **wakes it** on time (RTC event) |

So `disablesleep` has to be cleared before sleeping, and the wake must be an RTC event.
The 23:30 sleep cannot be a `pmset` event at all: it is requested by a launchd job
(running as root, with no tty) via `disablesleep 0` followed by `sleepnow`.

## How it works

With the default times:

```
23:30  launchd  →  pmset -a disablesleep 0 ; pmset sleepnow     the machine sleeps
06:30  RTC      →  pmset repeat wake                            the machine wakes
06:30  launchd  →  pmset -a disablesleep 1                      it stays awake
06:45  launchd  →  pmset -a disablesleep 1                      second chance
```

The times are **parameters**, not constants: `coffee --sleep HH:MM --wake HH:MM`
renders them into the LaunchDaemon and into the `pmset` wake event, and passes them to
the tick as arguments. The guard windows are derived from them at every run:

| window | action |
|---|---|
| `[sleep−5m … sleep+15m]` | `disablesleep 0` + `sleepnow` |
| `[wake−5m … wake+120m]` | `disablesleep 1` |

Both windows handle the midnight wrap (`--sleep 23:58` gets `23:53 … 00:13`).
launchd re-runs missed jobs at the next wake, so without a window a tick missed at
23:30 could put the machine to sleep at noon the next day.

## Installation

No dependencies: bash and `pmset` only (both ship with macOS).

```bash
git clone <this-repo> ~/mac-suspend
cd ~/mac-suspend
./bin/coffee            # asks for your sudo password
```

`coffee` does, in order:

1. `pmset -a disablesleep 1` — the machine will not sleep (not even with the lid closed);
2. `pmset repeat wake MTWRFSU 06:30:00` — the actual wake-up;
3. installs the LaunchDaemon `com.roberto.coffee.tick` into `/Library/LaunchDaemons`
   (schedules live in the plist; absolute paths are rendered at install time);
4. **verifies the resulting state**, not `pmset`'s exit code — run as non-root, `pmset`
   prints "must be run as root" and still returns `0`.

If anything does not hold, it exits with an error instead of leaving half a state behind.

## Daily use

```bash
coffee                                 # arm everything (idempotent)
coffee --sleep 22:15 --wake 07:05      # change the times
chamomile                              # disarm everything and give sleep back (idempotent)
```

The times are remembered in `state/config`, so a bare `coffee` re-run keeps the last
ones instead of resetting them to the defaults. Validation:

- format `HH:MM`, `00:00`–`23:59`;
- `--sleep` and `--wake` must differ and be at least **60 minutes** apart
  (measured forward from the sleep time);
- changing the times is allowed while coffee is active: an existing repeating wake that
  matches either the new or the previous configuration is recognised as ours, anything
  else is still refused rather than overwritten.

Careful: `chamomile` sets `disablesleep 0`, so with the lid closed the machine goes to
sleep **immediately**. Run it locally, not over SSH.

## Verifying

```bash
# what is armed
launchctl print system/com.roberto.coffee.tick >/dev/null && echo "tick loaded"
pmset -g sched | sed -n '/Repeating/,$p'      # expect: wake at 6:30AM every day
pmset -g | grep SleepDisabled                  # 1 = keep awake

# what happened last night
grep -E "tick 23:30|tick 6:30|WARN" ~/mac-suspend/logs/tick.log
pmset -g log | awk '$4=="Sleep" || ($4=="Wake" && $5!="Requests")' | tail -6
```

The tick logs one line per run, including power source and charge:

```
2026-10-30T23:30:05+0100 tick 23:30 now=1410 disablesleep=1 source=Battery Power charge=68%
Sleeping now...
```

## Known issues (all observed in practice)

| symptom | cause | fix |
|---|---|---|
| at 23:30 it does not sleep; the log shows `Sleeping now...` but no `Sleep` in the system log | an **open SSH session**: `ttyskeepawake` plus the `ttyassertion` downgrade the sleep to *dark wake* | do not be connected at that time, or `sudo pmset -a ttyskeepawake 0` |
| it does not sleep and `pmset -g` says `sleep prevented by …` | an assertion (typically `coreaudiod`: video or music playing) | close the app; the tick records it in the log |
| it wakes into *DarkWake*, not FullWake | normal with the lid closed: CPU and network up, display off | that is what a headless machine needs; just check SSH answers |
| the night drains the battery | charger not connected: the log says `source=Battery Power` | plug it in; below 30% the tick writes a `WARN` |
| after a reboot it is unreachable | **FileVault**: the machine waits at the login screen until someone logs in | no software fix: know the risk |

## CI

`.github/workflows/tests.yml` runs the suite on every pull request and on every push to
`main`, on a `macos-latest` runner (macOS on purpose: `plutil` and BSD userland are in the
path, so a Linux runner would not exercise the same code).

## Layout

```
bin/coffee                                  the command
bin/chamomile                               the reverse command
daemon/coffee-tick                          run by launchd, with the time windows
daemon/com.roberto.coffee.tick.plist.in     LaunchDaemon template (@ROOT@ → real path)
logs/                                       tick log (git-ignored)
tests/                                      test suite with fakes (no sudo)
```

## Tests

```bash
./tests/run.sh        # 71 checks, no sudo, no changes to the real system
./tests/run.sh -v     # also prints the output of the failing commands
```

The suite copies `bin/` and `daemon/` into a temporary root, puts **fake** `pmset`,
`launchctl`, `sudo`, `install` and `date` on `PATH`, redirects the LaunchDaemons
directory with `LAUNCHD_DIR`, and the tick's `pmset` with `PMSET_BIN`. Nothing on the
host is read or modified.

What is covered:

- `coffee`: happy path, idempotency, plist rendering and its final paths, the
  `HOME=/var/root` case (what `sudo` actually gives you), a `pmset` that exits `0` while
  changing nothing, refusal to clobber foreign repeating events, usage errors,
  `--sleep/--wake` propagation into the plist and the `pmset` call, persistence of the
  times across a bare re-run, changing times while active, the backup interval crossing
  midnight, and six invalid time combinations.
- `chamomile`: happy path, idempotency on a clean state, foreign events left alone **but
  sleep still restored**, `--force`, usage errors.
- `coffee-tick`: the night branch, the morning branch, windows derived from custom times,
  windows crossing midnight (both directions), four times outside any window, and both
  battery warnings.

That suite found two real bugs while it was being written: a `pmset` that lies (non-root
`pmset` returns 0 and does nothing) and the `$HOME` change under `sudo`.

## Uninstall

```bash
chamomile                                   # disarm and give sleep back
sudo rm -rf ~/mac-suspend                   # if you no longer need it
```

Manual escape hatch, always available:

```bash
sudo pmset -a disablesleep 0
sudo pmset repeat cancel
sudo launchctl bootout system/com.roberto.coffee.tick
```

## Limitations

- The 60-minute minimum between `--sleep` and `--wake` is a sanity check, not a rule of
  the system: shorter cycles are refused on purpose.
- The label `com.roberto.coffee.tick` contains a user name: rename it if you mind.
- The resume is a single RTC `wake` event: it cannot power on a machine that is off.
- Tested on a single model (MacBook Air M5, macOS 26.7.1). The behaviour of
  `disablesleep` and of launchd jobs may change across macOS releases.
- Runtime messages printed by the scripts are in Italian; the code and this README are not.
