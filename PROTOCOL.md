# MixTender Protocol

| | |
|---|---|
| **Protocol version** | **7** |
| **Date** | 2026-11-03 |
| **Firmware** | `kikolobo/MixTender`, branch `firmware-safety-and-calibration` |
| **App** | `kikolobo/mixtender_app` (MixBot) |

This file exists in **both** repos and the two copies must be identical:

- Firmware repo: `PROTOCOL.md` (repo root)
- App repo: `MixBot/PROTOCOL.md`

**Who cares about what**

| Part | Interface | Firmware | App |
|------|-----------|:--------:|:---:|
| [Part A](#part-a--bluetooth-le-protocol) | Bluetooth LE | ✅ | ✅ |
| [Part B](#part-b--usb-serial-console) | USB serial console | ✅ | — (firmware only) |

**Changing the protocol (Part A)**

1. Propose the change in the other side's notes file (app→firmware in `FIRMWARE_INTERFACE.md`,
   firmware→app in `NOTES_FROM_FIRMWARE.md`, both in the app repo).
2. Keep backward compatibility: add new prefixes/commands, don't change existing ones.
3. When it's implemented, **bump the version** in the header, add a [changelog](#changelog)
   entry, and update **both copies** of this file in the same sitting.

Part B (USB) can change freely with the firmware. Still bump the date and add a changelog line.

---

# Part A — Bluetooth LE protocol

The robot is the BLE **peripheral**, the app is the **central**. All messages are
UTF-8 text with **no terminator**. **One write or one notification = one message.**

## A.1 GATT layout

| Item | UUID | Properties |
|------|------|-----------|
| Service | `94635d24-cf8d-4ff8-9191-de713f39db89` | Advertised (the app scans for it) |
| Control characteristic | `4ac8a682-9736-4e5d-932b-e9b31405049c` | Read, Write, Notify. App writes commands here |
| Status characteristic | `6bcdd021-ffa5-4522-9454-a21d025d6562` | Read, Write, Notify. **Robot sends all messages here** |

Device name: `MixTender`. The app subscribes to every Notify characteristic and
treats them all the same, so it doesn't matter which one a message arrives on.

**Connection:** the app scans for the service, connects to the first robot found,
discovers everything, subscribes, then writes `ehlo`. On unexpected disconnect the app
rescans. The robot restarts advertising after a disconnect.

**Sizes:** the robot accepts an ATT MTU up to **185** (messages up to 182 bytes). iOS
negotiates it automatically on connect; the robot logs the result on USB serial
(`MTU negotiated: …`). `S`/`W`/`T` messages stay ≤ 20 bytes anyway; `$0=` texts and `K=`
replies can be longer. App writes can exceed 20 bytes (long writes also work).

**Rate:** weight updates (`W`) are capped at ~10 Hz per step (the final `W` of a step
is always sent). All messages are queued and sent in order, ≥ 5 ms apart, so bursts
(job rejection, aborts, `T?`) never block the robot.

## A.2 Commands: app → robot

| Command | Meaning |
|---------|---------|
| `ehlo` | Hello, sent after every connect. Robot replies `$1=<cup>` then `$0=<status>` |
| `D:<station>=<ml>,…` | Pour a drink ([A.4](#a4-dispense-job-d)) |
| `C!` | Cancel the running job ([A.5](#a5-cancel-c)) |
| `T…` | Valve calibration ([A.7](#a7-valve-calibration-t)) |
| `K…` | Scale setup: empty-tray weight (zero), min and max cup weight ([A.8](#a8-scale-setup-k)) (since v7) |

Unknown commands are logged on USB serial and ignored, with no reply.

## A.3 Messages: robot → app

The first character picks the parser.

| Message | Meaning |
|---------|---------|
| `$0=<text>` | Status text for the user (≤ ~40 chars). Value is shown verbatim |
| `$1=1` / `$1=0` | **OK to serve** / not (since v6; see below). Exactly these bytes (no `;`) |
| `S<step>=P;` | Step `<step>` started (Processing) |
| `S<step>=C;` | Step finished OK (Complete) |
| `S<step>=F;` | Step failed or was not executed (Failed) |
| `W<step>=<grams>;` | Weight poured so far **by this step** (float, e.g. `W0=37.240000;`) |
| `T<id>=…`, `TE=…`, `TX=ok` | Calibration replies ([A.7](#a7-valve-calibration-t)) |
| `TM<id>=moving` / `TM<id>=at` | Calibration tray move started / arrived under valve `<id>` ([A.7](#a7-valve-calibration-t)) |
| `K=…`, `KE=…` | Scale setup replies ([A.8](#a8-scale-setup-k)) (since v7) |

- `<step>` is the **0-based index in the `D:` job**, not the station id.
- `$` types other than `0` and `1` are **reserved**. Today's app clears its cup state
  on an unknown `$` type, so don't send new ones without an app change first.
- The trailing `;` on `S`/`W` is tolerated by the app. Never add one to `$` messages.

**Status texts the robot sends (`$0=`):** `Starting up...`, `Homing...`, `Please add a cup`,
`Ready!`, `Cup is not empty`, `Serving your drink!`, `Still Working!`, `Get your drink!`,
`Parking...`, `Calibrating...`, `Cancelled`, `Homing failed. Restart robot`, `Scale error`, the rejection reasons in
[A.4](#a4-dispense-job-d) and the abort reasons in [A.4.1](#a41-safety-aborts). The app should
display them, not interpret them.

**`$1` = OK to serve (since v6).** The app shows SERVE only while the last `$1` was `1`.
The robot sends `$1=1` only when **all** of these are true, and `$1=0` otherwise:
homed, scale answering, no job running, tray parked (not calibrating), an **empty cup**
present (cup detected, i.e. above the **min cup weight**, and ≤ the **max cup weight**, default 450 g (400 g before v7), both settable in [A.8](#a8-scale-setup-k), with 10 g hysteresis), and the previous drink removed.

`$1` is sent on every `ehlo` and **whenever that value changes** (e.g. `$1=0` when a job
starts, stays `0` while the finished drink waits, `1` again when an empty cup is placed).
A cup is detected when the scale reads more than the **min cup weight** (default 10 g) above the empty
tray and lost at ≤ min − 10 g (never below 3 g; with the default, lost at ≤ 3 g).
"Above the empty tray" uses the robot's stored empty-tray weight ([A.8](#a8-scale-setup-k)).
If that value is stale, an empty cup can read as `Cup is not empty` (or a cup isn't seen at all).

**Idle texts are pushed too.** Outside a job, the robot sends the matching `$0=` text
whenever it changes: `Homing...`, `Starting up...`, `Please add a cup`, `Ready!`,
`Cup is not empty`, `Parking...`, `Calibrating...`, `Scale error`,
`Homing failed. Restart robot`. During a job, while the finished drink waits, and
while parking after a cancel, the job's own texts stand (`Still Working!`,
`Get your drink!`, the abort reason, `Cancelled`).

## A.4 Dispense job `D:`

```
D:<stationId>=<ml>,<stationId>=<ml>,...
```

- Pairs are separated by `,`. No spaces, no trailing comma. The app formats amounts with 2 decimals.
- **Pair order = pour order = step index** (first pair is step 0).
- The robot stops on **weight in grams** and treats 1 ml as 1 g.

**Stations**

| Station id | Hardware | Physical position |
|-----------|----------|-------------------|
| 1–6 | Gravity valve 1–6 (servo) | Station 1–6 along the rail |
| 7–9 | Pump 1–3 | All at the pump station (rail station 7) |

**Validation.** The whole job is rejected if any of these fail:

- every station id is an integer 1–9
- every amount is a number ≥ 0
- there is at least one pair
- the total is ≤ **450 g** (glass capacity)

**Preconditions.** The job is rejected unless all of these hold:

| Condition | `$0=` reason if not met |
|-----------|------------------------|
| Homing succeeded | `Homing failed. Restart robot` |
| Scale is answering (a reading within the last 1 s) | `Scale error` |
| No job running, tray parked (also not homing, not parking after a cancel) | `Busy, try again` |
| Cup present (above the min cup weight) | `No Cup! Please add a cup!` (and `$1=0`) |
| Robot is Ready: the previous drink has been **removed** | `Remove your drink first` |
| Cup weighs ≤ the **max cup weight** (default **450 g**, settable, [A.8](#a8-scale-setup-k)), so it's probably empty | `Cup is not empty` |
| Job is valid (see above) | `Invalid drink request` |
| Dispatcher accepted the start | `Not ready, try again` |

**A rejected job sends `S<i>=F` for every step i, then the `$0=` reason.** There is no
job-level reject message yet, so this lets the app's pour screen finish.

**Accepted job: sequence per step**

```
S<n>=P            step starts (also for step 0)
W<n>=…            0..many weight updates, only while the valve/pump is open or settling
W<n>=<final>      last weight, always before the S
S<n>=C            or S<n>=F
```

- **Never a `W<n>` after `S<n>=C/F`.** (App builds before commit `061fdb6` reset a step's
  state on every `W`. The robot keeps this rule for compatibility.)
- A **0 ml** step does not move the tray: `S<n>=P` then `S<n>=C`, no `W`.
- A step whose pour device can't start: `S<n>=F`, and the job continues with the next step.
- After the last step: the tray parks and the robot sends `$0=Get your drink!`. It then
  waits for the cup to be removed before it accepts a new job.

Typical job:
```
App → D:3=75.00,9=225.00
Bot → S0=P;   $0=Still Working!   $0=Serving your drink!
Bot → W0=… … W0=74.9;   S0=C;
Bot → S1=P;   $0=Still Working!
Bot → W1=… … W1=224.6;  S1=C;
Bot → $0=Get your drink!
      (cup removed)  $0=Ready!
```

**Robot-side pour mechanics** (informative): move to station → wait 500 ms to settle →
tare (averages 10 readings, about 1 s, without blocking) → open the valve / start the pump →
close when the step weight reaches its target → wait 1 s for drips → 200 ms pause → next
step. All valves are closed before every job starts.

### A.4.1 Safety aborts

While a job runs, the robot stops the **whole job** if any of these happen:

| Trigger | `$0=` text |
|---------|-----------|
| Cup lifted: weight above the empty tray < 3 g for 300 ms (while moving, pouring, or between steps) | `Cup removed! Stopped` |
| No flow: the step's weight hasn't risen by 1 g in 5 s (empty bottle, blocked valve, dead pump) | `Bottle empty? Stopped` |
| One step has poured for more than 90 s | `Pour too slow. Stopped` |
| Scale stopped answering (no reading for 1 s while pouring, or a tare that doesn't finish in 3 s) | `Scale error. Stopped` |
| The app disconnected (since v6; the app can't resume a job) | `Disconnected. Stopped` (seen only if a client is still connected; normally none) |

On an abort the robot closes the output and sends **`S<i>=F` for the current step and every
remaining step**, so every step ends in `C` or `F`. Then it sends the `$0=` text and parks.
It then **waits for the cup to be removed** (like after a finished drink) before it accepts a
new job.

All messages are queued and sent in order, at least 5 ms apart, so a burst (rejections,
aborts, `T?`) never blocks the robot.

## A.5 Cancel `C!`

- If a job is running: close the valve / stop the pump, park the tray, send
  `$0=Cancelled`. Remaining steps get no further messages; the app closes its pour
  screen on its own.
- If no job is running: ignored, no reply.
- A `D:` sent while the tray is still parking after a cancel is rejected with `Busy, try again`.

## A.6 Disconnect

- If the app disconnects during **calibration**, the robot closes all valves and parks the
  tray if calibration moved it.
- A running **job is stopped** if the app disconnects (since v6): outputs off, tray parks,
  and the robot waits for the cup to be removed ([A.4.1](#a41-safety-aborts)). After
  reconnecting, `ehlo` reports the current state (`$1=0` until the drink is removed).

## A.7 Valve calibration `T`

Calibrates the open and closed servo angles of valve stations **1–6** only. Stations
**7–9 are pumps** (on/off, no angles): every `T` command with id 7–9 is refused with
`TE=pump`, and calibration never moves the tray to the pump station. A calibration UI
should list only stations of kind `valve`. Angles are degrees, **0–180**. Factory defaults: **open 147, closed 50**.
A calibration saved in flash survives reboot; until a valve is saved it uses the defaults.

**Opening a valve requires the tray under it** (since v3). Valve `<id>` sits at rail
station `<id>`. Move the tray there with `TM<id>` and wait for `TM<id>=at` before
`TO<id>`, so calibration pours into the cup and not onto the machine.

| Command | Effect | Reply |
|---------|--------|-------|
| `T?` | List all valves | `T1=…` … `T6=…`, 6 notifications in order |
| `TM<id>` | Close all valves, then move the tray under valve `<id>` (1–6). `TM0` = park | `TM<id>=moving` at once, then `TM<id>=at` on arrival |
| `TO<id>` | Move valve to its OPEN angle (**pours that bottle**). Tray must be under it | `T<id>=…` |
| `TC<id>` | Move valve to its CLOSED angle | `T<id>=…` |
| `TO<id>=<deg>` | Set OPEN angle (integer 0–180) and move there. Tray must be under it | `T<id>=…` |
| `TC<id>=<deg>` | Set CLOSED angle and move there | `T<id>=…` |
| `TW<id>` | Save this valve's open + closed angles to flash | `T<id>=…` |
| `TR<id>` | Reset to defaults in memory (not saved) and move | `T<id>=…` |
| `TX` | End calibration: close all valves, park the tray if `TM` moved it | `TX=ok` |

Reply line:
```
T<id>=<open>,<closed>,<defaultOpen>,<defaultClosed>,<saved>
e.g. T3=150,47,147,50,1
```
`<saved>` = 1 if this valve has a calibration in flash. It does **not** mean the current
angles equal the saved ones: changes are live but unsaved until `TW`.

Errors:

| Code | Meaning |
|------|---------|
| `busy` | A job is running (everything except `T?` is refused). For `TM` also: not homed yet, or a finished drink is waiting to be removed |
| `tray` | `TO` refused: the tray is not under that valve. Send `TM<id>` first |
| `moving` | `TO` refused: the tray is still moving. Wait for `TM<id>=at` |
| `pump` | Id 7–9: a pump station. Pumps are on/off and have no calibration |
| `valve` | Any other id out of range (1–6; 0–6 for `TM`) |
| `angle` | Angle outside 0–180 |
| `bad` | Malformed command |
| `flash` | Save failed |

Closing (`TC`), setting the closed angle, saving, reset and `T?` work wherever the tray is.

**Calibration session.** A `TM` (to 1–6) starts a session with the tray away from park.
While it is away, a `D:` job is rejected with `Busy, try again`. That rejection also ends the
session (closes valves and parks), so a retry a few seconds later works. `TX`, `TM0`, or a BLE
disconnect also end it.

Calibration replies are **always** sent, even if identical to the previous message.
Firmware without calibration (protocol v1) sends no reply: treat "no reply to `T?`
within ~1.5 s" as "not supported".

**Calibration flow for any UI:**
1. `TM<id>` → wait for `TM<id>=at` (a few seconds; show "moving").
2. `TO<id>` (and `TO<id>=<deg>` adjustments) → `TC<id>` (and `TC<id>=<deg>`) → `TW<id>` to save.
3. Next valve: `TM<next>` (closes all valves, moves).
4. Leaving the screen: **always `TX`** (closes valves, parks).

Safety rules: tell the user to put a glass on the tray before the first open. Disable
calibration during a pour. Throttle angle changes to ≤ 5/s. On `TE=tray` or `TE=moving`, send
`TM<id>` or wait for `=at`. Don't retry `TO` blindly.

The USB console ([B.3](#b3-valve-calibration)) edits the **same** stored calibration.

## A.8 Scale setup `K`

(Since v7.) Three saved settings: the **empty-tray weight** (zero) and the **cup weight
window** (min and max). All weights are "above the empty tray":

| Reading above the empty tray | Robot says | `$1` | LEDs |
|---|---|---|---|
| ≤ min cup weight | `Please add a cup` | 0 | blue |
| min … max | `Ready!` | 1 | green |
| > max cup weight | `Cup is not empty` | 0 | yellow |

**Empty-tray weight.** Cup detection, the "cup is not empty" check and the cup-removed abort all use
the **absolute weight**: the raw scale reading minus the **empty-tray weight**. Pours are not
affected (each step tares the scale first). The raw reading's zero drifts (load cell remounted,
tray changed, temperature), so the empty-tray weight must be re-measured now and then. Symptom
of a stale value: an empty cup shows `Cup is not empty`, or the robot says `Please add a cup`
with a cup on the tray.

Factory default: **121.38 g**. A value set with `KZ`/`KT` is saved in flash and survives reboot.

**Min cup weight.** The lightest *empty* cup the robot accepts: anything at or below it counts as
"no cup" (`Please add a cup`). Set it a bit below your lightest empty glass, so small objects or
a wet tray don't count as a cup. Factory default **10 g**. Once detected, the cup is "lost" only at
≤ min − 10 g (never below 3 g), so a cup near the limit doesn't flicker.

**Max cup weight.** The heaviest *empty* cup the robot accepts: a cup reading more than this above
the empty tray gets `Cup is not empty` (and `$1=0`, yellow LEDs). Set it a bit above your
heaviest empty glass. Factory default **450 g**.

Both: range **5–2000 g**, min must stay **at least 20 g below** max, saved in flash. The safety
checks that mean "tray is clear" don't use the min: cup lifted mid-job (< 3 g) and drink taken
after a job (< 2 g) stay as they are.

**The app is the primary way to set this** (initial setup and any re-zero later). The USB
console (`Z`, `K`) is a secondary, bench-only fallback for when no app is at hand.

**Initial setup.** `<traySaved>=0` in the `K=` reply means the robot has never been zeroed and is
running on the factory value, which is probably wrong for this robot. The app should then offer
the zero flow below (e.g. a "Set up scale" prompt) before the first pour.

| Command | Effect | Reply |
|---------|--------|-------|
| `K?` | Read the current values. Allowed any time | `K=…` |
| `KZ` | **Zero**: the current reading becomes the empty tray, saved. **The tray must be empty** (no cup) | `K=…` |
| `KT=<grams>` | Set the empty-tray weight to `<grams>` (float, −20000…20000), saved | `K=…` |
| `KR` | Empty tray back to the default; the saved value is erased | `K=…` |
| `KM=<grams>` | Set the max cup weight (float, 5–2000), saved | `K=…` |
| `KMR` | Max cup weight back to the default (450); the saved value is erased | `K=…` |
| `KN=<grams>` | Set the min cup weight (float, 5–2000), saved | `K=…` |
| `KNR` | Min cup weight back to the default (10); the saved value is erased | `K=…` |

Reply line (numbers with 1 decimal):
```
K=<absolute>,<emptyTray>,<defaultTray>,<traySaved>,<maxCup>,<defaultMaxCup>,<maxCupSaved>,<minCup>,<defaultMinCup>,<minCupSaved>
e.g. K=0.3,135.2,121.4,1,450.0,450.0,0,10.0,10.0,0
```
- `<absolute>`: what the robot reads above the empty tray **right now** (≈ 0 with an empty
  tray, ≈ the cup's weight with an empty cup). After `KZ` it's ≈ 0.
- `<emptyTray>`: the value in use. `<defaultTray>`: the factory value.
- `<traySaved>`: 1 if an empty-tray value is saved in flash.
- `<maxCup>`, `<defaultMaxCup>`, `<maxCupSaved>`: the same for the max cup weight.
- `<minCup>`, `<defaultMinCup>`, `<minCupSaved>`: the same for the min cup weight.
- Parsers should ignore extra trailing fields (room for future settings).

Errors (`KE=<code>`):

| Code | Meaning |
|------|---------|
| `busy` | A job is running, a finished drink is waiting, or the robot is parking/homing. `KZ` also: tray not parked, calibration (`TM`) session active, or a tare in progress |
| `scale` | `KZ`: the scale isn't answering |
| `range` | `KT` outside −20000…20000; `KM`/`KN` outside 5–2000 or min not ≥ 20 g below max (also `KMR`/`KNR` when the default would cross the other limit) |
| `bad` | Malformed command |
| `flash` | Save/erase failed |

Replies are **always** sent, even if identical to the previous message. Firmware older than v7
doesn't reply: treat "no reply to `K?` within ~1.5 s" as "not supported".

After a change, cup detection, `$1` and the idle `$0=` text update on their own within a moment
(e.g. `Cup is not empty` → `Ready!`, or `Ready!` → `Please add a cup` after `KZ`).

**Flow for any UI ("Zero scale"):**
1. Tell the user to **remove the cup** and anything else from the tray. Wait for confirmation.
2. Send `KZ` → expect `K=0.0,…` (absolute ≈ 0).
3. Optional check: ask the user to place an empty cup and poll `K?`. `<absolute>` should be the
   cup's weight (tens to a few hundred grams) and `$1=1` should follow.
4. Optional: offer to set the cup window from that reading, e.g. min = cup's weight − 30 g
   (`KN=`) and max = cup's weight + 50 g (`KM=`), or let the user type them. Send them in an
   order that keeps min ≥ 20 g below max at every step (raising both: `KM` first; lowering
   both: `KN` first), otherwise you get `KE=range`.

Old apps ignore `K` replies (unknown first character), so this is backward compatible.
Zeroing with a cup on the tray makes the cup count as "tray": the robot will then say
`Please add a cup` with that cup on. Re-zero with the tray empty to fix it.

The USB console ([B.2](#b2-commands)) edits the **same** stored values (`Z`, `K`, `M`); it's a fallback, not the main path.

---

# Part B — USB serial console

**Firmware only. The app never uses this.** It's for bench work and debugging over USB.

## B.1 Connection

- USB on the Feather ESP32 V2, **115200 baud**, 8N1.
- `pio device monitor` (from the firmware repo) or any serial terminal.
- **Single-character commands**, case-sensitive, executed immediately. No Enter needed.
- The firmware logs everything it does as `[Module][function] message` lines,
  including every BLE message received (`[BluetoothEngine] OnWrite > …`) and sent
  (`[BluetoothEngine] TXD: …`).
- `h` prints the command list.

## B.2 Commands

| Key | Action |
|-----|--------|
| `h` | Print help |
| `?` | Print the tray's current step position |
| `<` / `>` | Jog tray 20 steps left / right (no safety checks; don't use during a job) |
| `P` | Move tray to station 7 (pumps) |
| `B` | Start a built-in test job: valve 1, pumps 1–3, valve 2, 50 g each (only from Ready) |
| `C` | Cancel the running job (like BLE `C!`, but sends no `$0=Cancelled`) |
| `T` | Tare the scale (non-blocking, about 1 s; refused during a pour) |
| `H` | Re-run homing (e.g. after `HOMING FAILED`; refused during a pour) |
| `S` | Print the current (tared) weight |
| `A` | Print the absolute weight (above the empty tray), with the gross reading, empty-tray weight and the cup window (min–max) |
| `Z` | Zero: the current reading becomes the empty-tray weight, saved (same as BLE `KZ`; tray parked and **empty**) |
| `N` | Prompt for the min cup weight: grams + Enter to set and save (like `KN=`), `R` + Enter = default (like `KNR`), Enter alone = cancel |
| `M` | Prompt for the max empty-cup weight: grams + Enter to set and save (like `KM=`), `R` + Enter = default (like `KMR`), Enter alone = cancel |
| `K` | Prompt for the empty-tray weight: type grams and Enter to set and save (like `KT=`), `R` + Enter = default (like `KR`), Enter alone = cancel. Keys typed after `K` are not commands |
| `,` / `.` | Scale calibration factor −10 / +10, prints factor and reading (not saved) |
| `#` | Debug: run **pump 2** to 50 g in place, without moving the tray or checks |

## B.3 Valve calibration

Blocked while a job is running (prints `[Trim] Ignored: a drink is being poured.`).
Same safety as BLE: **opening needs the tray under the valve**.

| Key | Action |
|-----|--------|
| `G` then `0`–`6` | Close all valves and move the tray under valve 1–6 (`G0` = park). `G7`–`G9` refused (pumps) |
| `1`–`6` | Select valve 1–6 and move it OPEN (**pours**). Refused unless the tray is under it |
| `q` `w` `e` `r` `t` `y` | Select valve 1–6 and move it CLOSED |
| `+` / `-` | Move the selected valve's current position by ±1° (if it's open, the tray must be under it) |
| `@` | Reset the selected valve to defaults (147/50), not saved |
| `!` | Save the selected valve's open + closed angles to flash |
| `V` | List all valves |
| `X` | End calibration: close all valves, park the tray if `G` moved it |

Every change prints:
```
[Trim] Valve 1: open 149 (trim 2), closed 47 (trim -3) [saved] <- selected
```
Workflow: glass on the tray → `G1` → `1` → `+`/`-` until fully open → `q` → `+`/`-` until it
seals → `!` → `G2` … → `X` when done.

Storage: NVS namespace `valvetrim`, keys `v<index>o` / `v<index>c` (0-based index),
holding the **trim** (offset from the default angle), not the absolute angle.

Scale setup: NVS namespace `scale`, keys `empty` (empty-tray weight), `mincup` and `maxcup`
(cup window), floats in grams. Logged at boot as `[Scale] Empty tray weight: …` and
`[Scale] Cup window: …`.

---

# Changelog

## v7 — 2026-11-03
BLE (backward compatible; old apps ignore `K` replies):
- New `K` commands to read and set the **empty-tray weight** used by cup detection and the
  "cup is not empty" check ([A.8](#a8-scale-setup-k)): `K?`, `KZ` (zero), `KT=<g>`,
  `KR`, and to set the **cup weight window**: max `KM=<g>`/`KMR`, min `KN=<g>`/`KNR`. Replies
  `K=<absolute>,<emptyTray>,<defaultTray>,<traySaved>,<maxCup>,<defaultMaxCup>,<maxCupSaved>,<minCup>,<defaultMinCup>,<minCupSaved>`
  or `KE=<code>`. Saved in flash.
- The "cup is not empty" limit (max cup weight) defaults to **450 g** (was a fixed 400 g).
  Same texts and `$1` behavior.
- Cup detection uses the settable **min cup weight** (default 10 g, as before).

Firmware: the LEDs show **yellow** when a cup is on but the robot isn't clear to serve (cup not
empty, calibrating, parking), and green only when `$1=1`. No wire-format change.

USB:
- New `Z` (zero), `K` (type the empty-tray weight), `N` / `M` (type the min / max cup weight). `A` also prints the gross reading and the empty-tray weight.

## v6 — 2026-11-03
BLE (backward compatible; requested by the app side):
- §A.3 now lists the calibration tray replies `TM<id>=moving` / `TM<id>=at` (behavior unchanged since v3).
- `$1` now means **OK to serve**: `$1=0` also while a job runs, while the finished drink
  waits, for a cup over 400 g, while calibrating/parking/homing, and on homing/scale faults.
  It's pushed on every change.
- Idle `$0=` texts are pushed on change (new: `Homing...`, `Cup is not empty`, `Calibrating...`).
- A BLE disconnect during a job stops the job.
- `W` updates capped at ~10 Hz; the final `W` of a step is always sent before its `S`.

Firmware: the HX711 sample rate is measured at boot and logged (`[Dispenser] Scale rate: …`).
The robot now accepts an MTU up to 185 (`BLEDevice::setMTU`), so long `$0=` texts aren't cut
at 20 bytes. No wire-format change.

## v5 — 2026-11-03
BLE (backward compatible):
- Safety aborts during a job: cup removed, no flow (empty bottle), 90 s pour limit, scale
  fault. They fail the current and all remaining steps (`S<i>=F`), send a `$0=` reason, park,
  and wait for cup removal.
- New job preconditions: homing succeeded (`Homing failed. Restart robot`), scale answering
  (`Scale error`). `ehlo` reports these as the status text too.
- Outgoing messages are queued and paced (≥ 5 ms apart) instead of sent with delays.

Firmware internals: non-blocking tare, homing timeout (switch not found / 120 s), main-loop
watchdog (~5 s), LED refresh capped at 30 fps.

USB:
- `T` is non-blocking and refused during a pour. New `H` re-homes.

## v4 — 2026-11-03
- BLE: `T` commands with a pump station id (7–9) now reply `TE=pump` instead of `TE=valve`.
  Calibration is for valves 1–6 only (unchanged behavior, clearer error).
- USB: `G7`–`G9` print a "pumps can't be calibrated" message.

## v3 — 2026-11-03
BLE (backward compatible with v2 apps, except that `TO` now needs the tray under the valve):
- New `TM<id>`: close all valves and move the tray under valve `<id>` (`TM0` = park). Replies
  `TM<id>=moving`, then `TM<id>=at`.
- `TO<id>` / `TO<id>=<deg>` are refused with `TE=tray` / `TE=moving` unless the tray is
  under that valve.
- `TX` and BLE disconnect also park the tray. A `D:` during a session is rejected and ends it.

USB:
- New `G<0-6>` (move tray) and `X` (end calibration). Opening a valve needs the tray under it.

## v2 — 2026-11-03
BLE (backward compatible with v1 apps):
- Job validation (station 1–9, amount ≥ 0, total ≤ 450 g) and preconditions (busy, no cup,
  drink not removed, cup > 400 g). A rejected job sends `S<i>=F` for every step plus a `$0=` reason.
- 0 ml steps are skipped and reported `P` then `C`. A device that can't start fails its step.
- `S0=P` is now sent by the robot. `W` is only sent while pouring. No `W` after a step's final `S`.
- `ehlo` reply adds a `$0=` status text. Duplicate suppression resets on reconnect.
- `C!` is ignored when no job runs, and sends `$0=Cancelled` when it cancels one.
- New: valve calibration `T` commands. All valves close before each job and on disconnect.

USB:
- New keys `!`, `V`, `h`. Selecting a valve keeps its trim. Trims are saved in flash.
  Trim keys are blocked during a job.

## v1 — 2024-06 (baseline)
The original protocol: `ehlo`, `D:`, `C!`; `$0`, `$1`, `S…=P/C`, `W…`. No validation, no
calibration over BLE, trims not saved.
