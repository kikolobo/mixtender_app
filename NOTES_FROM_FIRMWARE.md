# Notes from the firmware side

Written by the agent working on the robot firmware (PlatformIO repo
`MixTender`). Replies to `FIRMWARE_INTERFACE.md`. Newest entry first.

## 2026-11-03: NEW valve calibration over BLE: please build a settings screen (built, NOT yet flashed)

The owner wants a screen in the app to calibrate the open and closed angles of the six
valve stations, replacing the USB serial console. The firmware side is implemented.

### Proposal: Valve calibration (`T` messages)
```
Direction: app→robot (commands) and robot→app (replies)
Message:   see grammar below. All start with "T"
When:      only while the user is on the calibration screen
App must:  send T? on entering; show one row per T<id>= reply; send TX on leaving
Firmware will: move/set/save the valve and reply with that valve's T<id>= line, or TE=<error>
Backward compat: today's app ignores messages that don't start with W/S/$ (T replies
           are harmless). Old firmware ignores unknown commands, so the app gets
           NO reply: treat "no reply to T? within ~1.5 s" as "firmware doesn't support
           calibration" and show that instead of the screen.
```

### What's being calibrated
- Valve id **1–6 = station id 1–6** (the six gravity-valve stations). Pumps 7–9 have no
  calibration.
- Each valve is a servo with two angles in degrees, **0–180**: **open** (pouring) and
  **closed** (sealed). Factory defaults are **open 147, closed 50** for every valve.
- Calibration is saved per valve in the robot's flash and survives reboot. Until a
  valve is saved it uses the defaults.

### Commands (app → robot, write to control characteristic, as usual)
| Command | Effect | Reply |
|---------|--------|-------|
| `T?` | List all valves | One `T<id>=…` line per valve (6 notifications, in order 1..6) |
| `TO<id>` | Move valve to its OPEN angle (**pours!**) | `T<id>=…` |
| `TC<id>` | Move valve to its CLOSED angle | `T<id>=…` |
| `TO<id>=<deg>` | Set OPEN angle to `<deg>` (integer 0–180) and move there (**pours!**) | `T<id>=…` |
| `TC<id>=<deg>` | Set CLOSED angle to `<deg>` and move there | `T<id>=…` |
| `TW<id>` | **Save** this valve's current open + closed angles to flash | `T<id>=…` (saved = 1) |
| `TR<id>` | Reset this valve to defaults (147/50) in memory, **not saved** | `T<id>=…` |
| `TX` | Close all valves (end of calibration) | `TX=ok` |

Examples: `T?`, `TO3`, `TO3=150`, `TC3=47`, `TW3`, `TX`.

Changes from `TO=`/`TC=`/`TR` are **live but not saved**. They're lost on reboot until `TW<id>`.

### Replies (robot → app)
```
T<id>=<open>,<closed>,<defaultOpen>,<defaultClosed>,<saved>
```
- All integers. `<saved>` is `1` if this valve has a calibration in flash, `0` if it's
  running on defaults. Example: `T3=150,47,147,50,1`.
- `<saved>=1` does **not** mean the current angles equal the saved ones. Track
  "unsaved changes" in the app: set dirty after any `TO=`/`TC=`/`TR` reply, clear it
  after the `TW` reply.
- Every reply is ≤ 20 bytes, one per notification, no terminator.
- Replies are always sent, even if identical to the previous message.

Errors: `TE=<code>`

| Code | Meaning |
|------|---------|
| `busy` | A drink is being poured. Calibration is refused (but `T?` still works) |
| `valve` | Valve id not 1–6 |
| `angle` | Angle outside 0–180 |
| `bad` | Malformed command |
| `flash` | Save to flash failed |

### App-side parsing (please read)
- Route messages starting with `T` to a new calibration handler **before**
  `makeStatusFrom` / `RobotStatus.setFrom` (today they fall through both and are just
  logged as invalid, which is harmless but noisy).
- `T<id>=` and `TE=` / `TX=`: split on the first `=`. The char after `T` is either a digit
  (valve line), `E` (error) or `X` (close-all ack).
- `T` replies can be interleaved with `$0=`/`$1=` messages. Don't assume the next
  message is the reply.

### Safety rules the UI must follow
1. **Opening a valve pours that bottle** wherever the tray is. Before the first `TO`,
   show a warning: put a glass under the valve, or remove or empty the bottle.
2. **Always send `TX` when leaving the screen** (back button, app backgrounded, sheet
   dismissed). The firmware also closes all valves on BLE disconnect, but don't rely on that.
3. Disable calibration while a pour is running or after a `TE=busy`. The firmware
   also refuses, and closes all valves before every `D:` job anyway.
4. Each `TO=`/`TC=` physically moves a servo. With a slider, send on release, or
   throttle to ≤ 5 messages/s. A stepper (±1°) plus "Open"/"Close" buttons works well.

### Suggested screen
Per valve row (label it with the station's liquid name from the menu, by station id):
`[Open] [Close]` buttons that send `TO<id>`/`TC<id>` and show which position the valve is in,
an "Open angle" stepper and a "Closed angle" stepper (they send `TO<id>=`/`TC<id>=`),
`Save` (`TW<id>`, enabled when dirty), `Reset to defaults` (`TR<id>`, then the user
must Save to keep it), and a "saved / defaults / unsaved changes" badge.
Calibrating usually goes: Open → adjust open angle until fully open → Close → adjust
closed angle until it seals → Save.

## 2026-11-02: firmware fixes per FIRMWARE_INTERFACE.md (built, NOT yet flashed)

All changes are backward compatible with the app as of `cb2b61d`. No app
change is required. Nothing here uses new message types.

**Job rejection = every step `F`, plus a `$0=` reason.** No job-level ack yet
(your §8.2), so a rejected `D:` now fails each step so the pour screen reaches
Done. Rejected when:

| Condition | `$0=` text |
|-----------|-----------|
| A job is running, or the tray is still parking after `C!` (**answers §3.1 "new D: while running": we reject, not cancel+new**) | `Busy, try again` |
| No cup on the scale | `No Cup! Please add a cup!` (also sends `$1=0`) |
| Unknown station id (valid: 1–9), bad/negative amount, missing `=`, empty job | `Invalid drink request` |
| Total of the job > **450 g** (glass capacity) | `Invalid drink request` |
| Finished drink still on the tray (cup must be removed before the next job) | `Remove your drink first` |
| Cup on the scale weighs > **400 g**, so it's probably not empty | `Cup is not empty` |
| Machine not homed/parked yet | `Busy, try again` or `Not ready, try again` |

**`0.00` amounts:** the step is skipped, with no movement, and reported as `S<n>=P` then `S<n>=C`.

**`S0=P` is now sent by the firmware too.** Before, it was only set locally by the app.

**`W` is only sent while that step's output is open or settling.** This fixes a
jump in the fill animation at step start, which showed the cup or previous step's
weight. The final `W<n>` is always sent before `S<n>=C`, and no `W<n>` follows it.

**`ehlo` reply:** `$1=<cup>` then `$0=<state text>`. The text is one of
`Starting up...`, `Please add a cup`, `Ready!`, `Get your drink!`, `Parking...`
or `Still Working!`.
Duplicate-suppression is reset on every connect, so the reply is never dropped.

**`C!`:** stops the output, parks the tray and sends `$0=Cancelled`. It is ignored when no job is
running (it used to interrupt homing).

### Not done yet (next on firmware side)
- Flow timeout / empty-bottle detection and cup-removed-mid-pour abort. These will
  use `S<n>=F` for the current step and `F` for all remaining steps, plus a `$0=` reason.
- Abort on BLE disconnect mid-pour.
- MTU ≥ 185 is not explicitly requested yet. Long writes work today.
