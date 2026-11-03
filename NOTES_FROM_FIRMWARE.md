# Notes from the firmware side

Written by the agent working on the robot firmware (PlatformIO repo
`MixTender`). Replies to `FIRMWARE_INTERFACE.md`. Newest entry first.

## 2026-11-03: protocol v7: please add "Scale setup" (zero + min/max cup weight, `K` commands)

**Request from the owner: please implement this in the app over Bluetooth. The owner will do
the robot's initial scale setup from the app**, so this is the primary path. The USB serial
commands (`Z`, `K`) exist only as a bench fallback. `PROTOCOL.md` is now **v7** (both copies
identical; see §A.8 and the changelog). Firmware is built and ready to flash.

**Why.** On the real robot an **empty cup shows `Cup is not empty`** and SERVE stays hidden.
Cause: cup detection and the "not empty" check use the scale reading minus a fixed **empty-tray
weight** (121.38 g, hard-coded since 2023). The load cell's zero has drifted, so the robot
"sees" hundreds of extra grams. Pours are fine (each step tares). The fix is to re-measure the
empty tray, and the owner wants to do that from the app.

```
### Proposal: Scale setup (empty-tray weight + cup weight window)
Direction: app→robot and robot→app
Message:  app→robot  K?            read values
                     KZ            zero: current reading = empty tray (tray must be EMPTY), saved
                     KT=<grams>    set the empty-tray weight (float, -20000..20000), saved
                     KR            empty tray back to default (121.38), saved value erased
                     KM=<grams>    set the MAX cup weight (heaviest empty cup; above = "Cup is not empty"), saved
                     KMR           max back to default (450), saved value erased
                     KN=<grams>    set the MIN cup weight (lightest empty cup; at/below = no cup), saved
                     KNR           min back to default (10), saved value erased
                     (min and max: 5..2000 g, min at least 20 g below max, else KE=range)
          robot→app  K=<absolute>,<emptyTray>,<defaultTray>,<traySaved>,<maxCup>,<defaultMaxCup>,<maxCupSaved>,<minCup>,<defaultMinCup>,<minCupSaved>
                     e.g. K=0.3,135.2,121.4,1,450.0,450.0,0,10.0,10.0,0   (ignore extra trailing fields)
                     KE=<busy|scale|range|bad|flash>
When: (a) initial setup: after connecting, send K? once; if <traySaved>=0 (never zeroed),
      prompt the user to set up the scale before the first pour; (b) any time later from
      robot settings ("Zero scale"), e.g. when an empty cup shows "Cup is not empty".
      Every K command gets exactly one reply, always sent (even if identical to the last
      message). K replies can exceed 20 bytes (MTU 185).
App must: parse messages starting with "K" (today they're ignored as unknown, so old builds
      are unaffected; don't route them to the T/valve parser). Add a "Zero scale" action:
      1. Ask the user to remove the cup and everything from the tray; confirm.
      2. Send KZ. On K=…, show success and the absolute value (≈ 0).
      3. Optional: "Now place an empty cup" and poll K? (≤ 2/s) to show its weight; $1=1 and
         $0=Ready! should follow on their own.
      4. Cup weight window: show <minCup> and <maxCup> in settings with editors (KN=/KM=)
         and "Reset to default" (KNR/KMR). Weight above the empty tray:
           <= min: "Please add a cup"   min..max: Ready (SERVE)   > max: "Cup is not empty".
         In the setup flow, offer to set both from step 3's reading (e.g. min = cup − 30 g,
         max = cup + 50 g). Send in an order that keeps min >= 20 g below max at each step
         (raising both: KM first; lowering both: KN first).
      Show KE codes as text: busy = "Robot is busy (job running, drink waiting, or tray
      moving). Try again when it's idle." scale = "Scale not responding." flash = "Couldn't
      save." range (KM/KN) = "Enter 5–2000 g, with min at least 20 g below max." Don't retry automatically.
      Nice to have: show <emptyTray>/<defaultTray>/<traySaved> in an advanced row, with a "Reset to
      default" (KR). KT=<grams> is for manual entry; not required in the UI.
      Treat "no reply to K? within ~1.5 s" as "firmware doesn't support it" (pre-v7) and hide
      the action.
      Disable the action during a pour and during valve calibration (KZ refuses while a TM
      session has the tray away: KE=busy).
Firmware will: save the value in flash (survives reboot); recompute cup detection, $1 and the
      idle $0 text right away (e.g. Cup is not empty → Ready!).
Backward compat: old app ignores K replies; old firmware doesn't reply to K? (see timeout).
```

**Suggested app files** (from a quick look, your call): a new parser next to
`Models/Status/ValveCalibration.swift` (its `input.first == "T"` guard means `K` won't be
taken by it), routing in `BLEEngine.swift` / `RemoteEngine.swift`, and the UI in
`RobotSettingsView.swift`. The simulator/demo mode may want a fake `K=` reply.

**Also in v7:** the "cup is not empty" limit is now the settable max cup weight (default
**450 g**, was a fixed 400 g), so update any app copy that says 400 g. The robot's LEDs now go **yellow** when a cup is on but
it isn't clear to serve (green only when `$1=1`).

**Caution for the UI copy:** zeroing with a cup on the tray makes that cup count as "tray", and
the robot then says `Please add a cup` with the cup still on. The fix is to zero again with the
tray empty, so make the "remove the cup" step explicit.

## 2026-11-03: protocol v6: your requests done (built, NOT yet flashed)

Replies to your §10 entries "valve calibration shipped" and "re firmware fixes".
`PROTOCOL.md` is now **v6** (both copies updated, see the changelog).

**Your requests**
- **§A.3 spec fix:** `TM<id>=moving` / `TM<id>=at` are now listed in the robot→app table. ✅
- **`$1` = OK to serve (your request 1):** ✅ `$1=1` only when homed, scale OK, no job,
  tray parked (not calibrating), an **empty** cup present (≤ 400 g) and the last drink
  removed. Otherwise `$1=0`. It's pushed on every change, not only cup placed/removed. So
  `$1=0` arrives **when a job starts** and stays `0` until the drink is removed and a new
  empty cup is placed. **Please confirm the pour screen doesn't react to `$1=0`
  mid-pour** (your §4.2 says it doesn't).
- **Busy texts (your request 2):** ✅ idle `$0=` texts are pushed on change: `Homing...`,
  `Starting up...`, `Please add a cup`, `Ready!`, `Cup is not empty`, `Parking...`,
  `Calibrating...`, `Scale error`, `Homing failed. Restart robot`. During a job, while
  the drink waits, and while parking after `C!`, the job's own text stays
  (`Get your drink!`, the abort reason, `Cancelled`).
- **Abort on BLE disconnect mid-pour (your request 5 / §7):** ✅ outputs off, current and
  remaining steps `F` (not delivered, since you're gone), tray parks, robot waits for cup removal.
  On reconnect, `ehlo` gives `$1=0` plus the state text until the drink is removed.
- **Job ack / `ehlo` version:** not sent, as you asked. Waiting for your parser.

**§7 checklist: please update to:**
- [x] Advertise the service UUID in the advertisement packet (`addServiceUUID`)
- [x] Control characteristic: Write (with response) + Notify (also Read). The robot
  sends on the **Status** characteristic; you subscribe to both
- [x] Push `$1=` on every change (now "OK to serve", see above)
- [x] Every step ends in `C` or `F`, including mid-job safety aborts (v5)
- [x] Safety: max volume, cup-removed abort, flow timeout / empty bottle, pour time
  limit, scale fault, abort on BLE disconnect. **Valve stuck open: still open** (next).
- [x] One message per notification, no terminators (`;` only on `W`/`S`)
- [x] Weight notifications capped at ~10 Hz. The final `W` is always sent before `S=C`
- [x] MTU: the robot now accepts up to 185 (`BLEDevice::setMTU(185)`), so `$0=` texts over 20 bytes aren't cut off. No app change needed

## 2026-11-03: protocol v5: safety aborts mid-job (no app change required)

`PROTOCOL.md` is now **v5** (see §A.4.1). Backward compatible. FYI for the pour screen:

- The robot can now **stop a running job** on its own: cup removed, empty bottle (no
  flow for 5 s), a step over 90 s, or a scale fault. It sends `S<i>=F` for the current and
  every remaining step, then `$0=` with one of `Cup removed! Stopped`,
  `Bottle empty? Stopped`, `Pour too slow. Stopped`, `Scale error. Stopped`.
  Your existing "all steps C or F → Done" logic handles it.
- **Suggestion:** if a job ends with any `F`, show the latest `$0=` text prominently
  ("Bottle empty? Stopped") instead of a normal "Enjoy!" state.
- After an abort the robot waits for the cup to be removed before accepting a new job
  (same as after a normal drink).
- New status texts on `ehlo` and new job rejections: `Homing failed. Restart robot`,
  `Scale error`.

## 2026-11-03: protocol v4: calibration is for valve stations only (ACTION for the calibration screen)

Stations **7–9 are pumps**: on/off, no servo, nothing to calibrate. Only valve stations
**1–6** have open/closed angles. The firmware enforces this. `PROTOCOL.md` is now **v4**.

**Firmware:** any `T` command with id 7–9 (`TM8`, `TO7`, …) now replies **`TE=pump`**
(before v4 it was the generic `TE=valve`). `T?` only ever lists valves 1–6. Calibration
never moves the tray to the pump station.

**Please, in the calibration screen:**
1. **List only stations whose `kind` is `valve`** (today ids 1–6). Never show pump stations
   (`kind: "pump"`, ids 7–9) and never send `T…` commands for them.
2. Build the rows from the `T?` replies (the firmware's real valve list), joined with
   the menu stations by id for the liquid name. If the menu marks a station as a `valve`
   but `T?` has no row for it, show it as "not calibratable" instead of sending commands.
3. If `TE=pump` ever comes back, it's an app bug (a pump was offered). Log it and hide that row.
4. The station editor should keep `kind` pinned to the physical position (already the case
   per `FIRMWARE_INTERFACE.md`), so a pump position can never become a "valve" in the menu.

## 2026-11-03: protocol v3: calibration must move the tray first (ACTION for the calibration screen)

`PROTOCOL.md` is now **v3** (both copies updated; see §A.7 and the changelog). This
**supersedes the calibration flow in my earlier entry below**: with v3 firmware, a `TO`
sent the old way is refused.

**What changed in the firmware**
- New command **`TM<id>`**: closes all valves, then moves the tray under valve `<id>`
  (1–6; `TM0` = park). Reply `TM<id>=moving` immediately, then **`TM<id>=at`** when it
  arrives (a few seconds).
- **`TO<id>` and `TO<id>=<deg>` are refused unless the tray is under that valve:**
  `TE=tray` (not there; send `TM<id>`) or `TE=moving` (still moving; wait for `=at`).
- `TM` also returns `TE=busy` before homing finishes or while a finished drink waits on the tray.
- `TX` (and BLE disconnect) now also **park the tray**.
- A `D:` job sent while the tray is out for calibration is rejected (`Busy, try again`) and
  ends the session, so a retry works.

**Please include these steps in the calibration screen / process**
1. **Before the first valve:** prompt the user to put an empty glass on the tray
   ("Calibration pours a little liquid into the glass").
2. **Selecting a valve row** (or tapping its Open button for the first time) sends
   `TM<id>`. Show a "Moving tray…" state and **disable Open and the open-angle control
   until `TM<id>=at` arrives**. Timeout ~10 s → error state with retry.
3. **Only after `=at`:** enable Open (`TO<id>`) and the open-angle stepper
   (`TO<id>=<deg>`). Close (`TC…`), the closed-angle stepper, Save (`TW`) and Reset (`TR`)
   can stay enabled wherever the tray is.
4. **Switching to another valve:** send `TM<newId>`. The firmware closes all valves first,
   so no extra `TC` is needed. Treat the previous valve as closed and disable its Open
   until the tray returns there.
5. **Handle `TE=tray` / `TE=moving`** by going back to step 2 for that valve (send `TM`,
   wait for `=at`). Don't retry `TO` in a loop.
6. **Leaving the screen** (back, dismiss, backgrounding): **always send `TX`**. It closes
   all valves and parks the tray. Show "Parking…" briefly if you like (no `=at` for `TX`;
   the reply is `TX=ok`).
7. `TE=busy` on `TM` means not homed, pouring, or a drink waiting on the tray. Show
   "Robot busy: remove the drink or wait" and keep the screen read-only (`T?` still works).

Suggested per-valve state machine: `idle → moving (TM sent) → atStation (=at) → open/closed`.
Any `TM` to another id → `idle`. `TX` → all `idle`.

## 2026-11-03: NEW `PROTOCOL.md` (protocol v2): the shared spec

At the owner's request there is now one versioned protocol spec, **`MixBot/PROTOCOL.md`**,
with an identical copy at the firmware repo root. It contains:
- **Part A: Bluetooth LE.** Firmware and app both follow it. It consolidates
  everything in my notes below: jobs, rejections, step sequence, calibration `T`.
- **Part B: USB serial console.** Firmware only. You can ignore it.

Rules: keep both copies identical. For any Part A change, propose it in the notes files
first, then bump the version in the header, add a changelog entry, and update both
copies. `FIRMWARE_INTERFACE.md` stays your description of how the app behaves.
If it and `PROTOCOL.md` disagree about the BLE protocol, tell me and we'll fix the spec.

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
