# MixTender Protocol

| | |
|---|---|
| **Protocol version** | **4** |
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

**Sizes:** robot messages are kept ≤ 20 bytes where possible (the default MTU).
`$0=` texts can be longer; iOS negotiates a larger MTU. App writes can exceed 20
bytes (long writes work).

**Rate:** the robot sends at most ~10–20 messages/s (weight updates follow the
scale's sample rate). Bursts (e.g. job rejection, `T?`) are spaced 5 ms apart.

## A.2 Commands: app → robot

| Command | Meaning |
|---------|---------|
| `ehlo` | Hello, sent after every connect. Robot replies `$1=<cup>` then `$0=<status>` |
| `D:<station>=<ml>,…` | Pour a drink ([A.4](#a4-dispense-job-d)) |
| `C!` | Cancel the running job ([A.5](#a5-cancel-c)) |
| `T…` | Valve calibration ([A.7](#a7-valve-calibration-t)) |

Unknown commands are logged on USB serial and ignored, with no reply.

## A.3 Messages: robot → app

The first character picks the parser.

| Message | Meaning |
|---------|---------|
| `$0=<text>` | Status text for the user (≤ ~40 chars). Value is shown verbatim |
| `$1=1` / `$1=0` | Cup present / absent. Exactly these bytes (no `;`) |
| `S<step>=P;` | Step `<step>` started (Processing) |
| `S<step>=C;` | Step finished OK (Complete) |
| `S<step>=F;` | Step failed or was not executed (Failed) |
| `W<step>=<grams>;` | Weight poured so far **by this step** (float, e.g. `W0=37.240000;`) |
| `T<id>=…`, `TE=…`, `TX=ok` | Calibration replies ([A.7](#a7-valve-calibration-t)) |

- `<step>` is the **0-based index in the `D:` job**, not the station id.
- `$` types other than `0` and `1` are **reserved**. Today's app clears its cup state
  on an unknown `$` type, so don't send new ones without an app change first.
- The trailing `;` on `S`/`W` is tolerated by the app. Never add one to `$` messages.

**Status texts the robot sends (`$0=`):** `Starting up...`, `Please add a cup`,
`Ready!`, `Serving your drink!`, `Still Working!`, `Get your drink!`, `Parking...`,
`Cancelled`, and the rejection reasons in [A.4](#a4-dispense-job-d). The app should
display them, not interpret them.

**Cup state:** `$1=` is sent on every `ehlo` and whenever the robot's cup state
changes. A cup is detected when the scale reads > 10 g above the empty tray and is
lost at ≤ 3 g.

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
| No job running, tray parked (also not homing, not parking after a cancel) | `Busy, try again` |
| Cup present | `No Cup! Please add a cup!` (and `$1=0`) |
| Robot is Ready: the previous drink has been **removed** | `Remove your drink first` |
| Cup weighs ≤ **400 g**, so it's probably empty | `Cup is not empty` |
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
tare → open the valve / start the pump → close when the step weight reaches its target →
wait 1 s for drips → 200 ms pause → next step. All valves are closed before every
job starts.

## A.5 Cancel `C!`

- If a job is running: close the valve / stop the pump, park the tray, send
  `$0=Cancelled`. Remaining steps get no further messages; the app closes its pour
  screen on its own.
- If no job is running: ignored, no reply.
- A `D:` sent while the tray is still parking after a cancel is rejected with `Busy, try again`.

## A.6 Disconnect

- If the app disconnects during **calibration**, the robot closes all valves and parks the
  tray if calibration moved it.
- A running **job continues** if the app disconnects. (Aborting a job on disconnect is planned.)

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
| `T` | Tare the scale |
| `S` | Print the current (tared) weight |
| `A` | Print the absolute weight (above the empty tray) |
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

---

# Changelog

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
