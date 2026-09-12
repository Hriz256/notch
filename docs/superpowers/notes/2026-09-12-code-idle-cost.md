# Idle-cost audit — Coding Agent

Date: 2026-09-12
Commit measured: `f6566cf` (`feature/coding-agent`, all review fixes applied)
Machine: Apple M5 Pro, macOS 26.5.2 (Darwin 25.5.0)
Build: Debug, `build/Build/Products/Debug/Notch.app`

## Verdict

CPU at idle is effectively zero. **Memory is the number to watch**: the phys_footprint
sits between 46 MB and 93 MB with a 131–172 MB peak, and every bit of the variance is the
7-day transcript scan behind the sparkline. That is over the 40 MB the Island Core audit
held itself to, and it is the one thing in this feature worth a follow-up.

| Measure | Target (spec §8) | Measured (Code only) | Result |
| ------- | ---------------- | -------------------- | ------ |
| CPU, three `ps` samples 10 s apart | ≤ 0.2 % | 0.0 %, 0.0 %, 0.0 % | pass |
| CPU time accumulated over 120 s | ≤ 0.2 % | 0.18 s / 120 s = **0.15 %** | pass |
| Threads alive, all blocked | no timer / repeating animation | 3 threads, 8 762 of 13 143 samples in `mach_msg2_trap`, the rest in `__workq_kernreturn` | pass |
| `phys_footprint` | ≤ 40 MB | **93 MB** (peak 131 MB) | **fail** |

## A note on measuring this feature from a coding-agent session

The first run was nonsense — 16.4 %, 9.5 %, 10.2 % CPU and 197 MB RSS — because the agent
session *taking the measurement* was firing hooks into the app the whole time:

```
10:34:53 [app.notch:code.viewmodel] showing creating for claude
10:34:53 [app.notch:code.viewmodel] showing thinking for claude
…  ~40 stage changes in 60 s, plus one `alerting completed for claude`
```

That is the feature working, not the feature idling. The real measurement was taken with
all three agents switched off in `UserDefaults` before launch, so the incoming hook events
are dropped at `CodeAgentViewModel.handle` and the island genuinely has no session:

```bash
pkill -x Notch
for a in claude codex cursor; do defaults write app.notch.Notch code.$a.enabled -bool false; done
defaults write app.notch.Notch feature.music.enabled -bool false   # isolate Code from Music
open build/Build/Products/Debug/Notch.app
```

Both keys were restored afterwards. No agent config file was touched: disabling an agent
through `defaults` (rather than through the menu) does not run the uninstaller, so
`~/.claude/settings.json`, `~/.codex/config.toml` and `~/.cursor/hooks.json` were left
exactly as they were.

Music had to go too. With Music on and Spotify playing, the same process measured 0.98 %
CPU and carried two `caulk.messenger` CoreAudio threads — that is the Music card's cost,
not Code's.

## Commands and results

### 1. Three measurements, 10 s apart (after 60 s idle)

```bash
NP=$(pgrep -x Notch); sleep 60
for i in 1 2 3; do ps -o %cpu,rss,time,etime -p $NP; sleep 10; done
```

```
=== sample 1  10:42:05 ===
 %CPU    RSS      TIME ELAPSED
  0.0 180832   0:00.87   01:11
=== sample 2  10:42:15 ===
  0.0 180816   0:00.87   01:21
=== sample 3  10:42:25 ===
  0.0 180800   0:00.88   01:31
```

Ten milliseconds of CPU across 20 s. (RSS ~180 MB is not the footprint — it counts the
shared read-only dyld cache pages every app maps; see the `vmmap` split below.)

### 2. CPU-time delta over 120 s

`ps %cpu` is a lifetime average, so the decisive figure is the growth of accumulated CPU
time over a fixed window.

```bash
t0=$(ps -o time= -p $NP); sleep 120; t1=$(ps -o time= -p $NP)
# Notch 0:00.88 -> 0:01.06 over 120s
```

0.18 s / 120 s = 0.15 %. No usage poll fell inside that window (the idle cadence is 900 s),
so this is the floor: run-loop wake-ups, nothing of ours.

### 3. Threads — nothing is ticking

```bash
sample $(pgrep -x Notch) 5
```

```
4381 Thread_1519651   DispatchQueue_1: com.apple.main-thread  (serial)
4381 Thread_1519672: com.apple.NSEventThread
4381 Thread_1561358                                    # idle libdispatch worker

Sort by top of stack, same collapsed (when >= 5):
        mach_msg2_trap  (in libsystem_kernel.dylib)        8762
        __workq_kernreturn  (in libsystem_kernel.dylib)    4381
```

Three threads, every sample blocked. No 1 Hz clock (`visiblePanels == 0`, so
`startTicking()` was never called), no `TimelineView`, no animation. The third thread is
the parked `app.notch.code.process` queue worker.

### 4. Memory

```bash
footprint -p $NP; vmmap --summary $NP
```

```
phys_footprint:      93 MB
phys_footprint_peak: 131 MB

Physical footprint:            93.5M
ReadOnly portion of Libraries: Total=1.8G resident=746.1M(42%)
Writable regions:              Total=387.9M written=109.5M(28%) resident=109.6M(28%)

MALLOC_LARGE (empty)   41.7M   26.0M resident
MALLOC_SMALL           69.1M   40.0M resident
MALLOC_SMALL (empty)   50.9M   39.4M resident
```

65 MB of that is malloc'd and *already freed* (`(empty)` zones) — the allocator has not
returned the pages to the OS. It is the sparkline scan's parse buffers and its decoded
cache, and the 46 MB seen in an earlier run of the same build is the same figure sampled
after a scan that had less to re-read.

Why it is that big, on this machine:

```bash
find ~/.claude/projects -name '*.jsonl' | wc -l                 # 1520 transcripts
find ~/.claude/projects -name '*.jsonl' -mtime -8 | wc -l       #  634 inside the window
find ~/.claude/projects -name '*.jsonl' -mtime -8 -exec du -ch {} + | tail -1   # 1.6G
du -sh ~/.claude/projects                                        # 4.1G
ls -lh ~/Library/Application\ Support/Notch/claude-usage-cache.json  # 9.1M
```

634 transcripts and 1.6 GB fall inside the 8-day cutoff. The mtime filter and the on-disk
cache keep the *reads* down to the handful of files that changed, but the cache itself is
9.1 MB of JSON that is decoded into `[String: CachedFile]` on the first scan and held for
the life of the process, and every scan rebuilds the `fresh` dictionary alongside it.

## What runs at idle

| Thing | Cadence when idle | Cost |
| ----- | ----------------- | ---- |
| `UsageRefreshCoordinator` poll, per provider | one `ScheduledToken` every 900 s | one HTTPS request (Claude, Cursor) or one `codex app-server` exchange (~0.9 s, measured); nothing between fires |
| Reset-boundary refresh | one-shot per window per agent | one extra fetch just after a window rolls |
| Wake observer | `NSWorkspace.didWakeNotification` | passive |
| `ClaudeSparkline` scan | after each *successful* Claude fetch, and on a finished session (throttled to 60 s) | the memory high-water mark above; runs on a detached utility task, cancellable, and skips the cache write when nothing changed |
| `EventReceiver` | `DistributedNotificationCenter` observer | passive; a dropped event for a disabled agent costs one dictionary lookup |
| `SessionTracker` | no sessions → no timers | zero |
| Elapsed clock | `visiblePanels == 0` → not scheduled | zero |
| `Caffeinator` | off (no active session) | zero |
| `ScrollSwipeMonitor` / `HoverMonitor` | per event | scroll no longer allocates a `Task` per event (this branch); hover still does — unchanged, and it is the next place to look if the pointer ever shows up in a profile |

Between polls, the Code feature schedules nothing, holds nothing open, and draws nothing.

## Follow-ups this measurement suggests

1. **The sparkline cache is the footprint.** 9.1 MB of JSON decoded and held resident, plus
   a second copy built on every scan. Worth either capping the cache to the files inside
   the window before decoding, streaming it, or dropping the in-memory copy between scans
   and re-reading it — the scan runs at most once a minute, so a re-read is affordable.
2. **`malloc` keeps the freed pages.** 65 MB sits in `(empty)` zones after the scan. A
   `malloc_zone_pressure_relief` after a scan, or moving the scan into a short-lived
   subprocess, would hand them back.
3. Neither is a regression from this branch — both are inherent to the 7-day scan as
   designed — so both were left alone here.
