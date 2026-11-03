# MixBot — App ↔ Firmware Interface Notes

Audience: the agent writing the MixBot robot firmware.
Written from the iOS app side (repo: `MixBot`, branch `main`, as of 2026-11-02,
commit `cb2b61d`; revised 2026-11-03 after the firmware notes in
`NOTES_FROM_FIRMWARE.md`, with the firmware's decisions folded in and replies in §10). This describes **exactly what the app does today**, including
its quirks, so the firmware can match it. Proposed changes go through the iOS
side — see [How to propose changes](#9-how-to-propose-changes).

Source of truth in the app (if this doc and the code disagree, the code wins):

| File | What it owns |
|------|--------------|
| `MixBot/BLEEngine.swift` | CoreBluetooth central: scan, connect, discover, subscribe, write |
| `MixBot/RemoteEngine.swift` | Protocol: builds the `D:` job string, sends `ehlo` / `C!`, routes incoming messages |
| `MixBot/Models/Status/JobProgress.swift` | Parser for per-step messages (`W…`, `S…`) |
| `MixBot/Models/Status/RobotStatus.swift` | Parser for robot-status messages (`$0=…`, `$1=…`) |
| `MixBot/ProcessView.swift` | Pour screen; decides when a pour is "finished" |
| `MixBot/DrinkDetailView.swift` | Gates the SERVE button on connection + cup state |
| `MixBot/Models/DrinkMenu.swift` | Menu format: stations, recipes, validation |
| `mixbot-api/` | Cloudflare Worker that serves the menu (firmware never talks to it today) |

---

## 1. System overview

```
 ┌────────────┐   HTTPS (menu JSON)   ┌──────────────────────────┐
 │ mixbot-api │ ────────────────────▶ │   iOS app (BLE central)  │
 │ Cloudflare │                       │  menu → recipe → amounts │
 └────────────┘                       └────────────┬─────────────┘
                                                   │ BLE GATT, UTF-8 text
                                                   ▼
                                      ┌──────────────────────────┐
                                      │  Robot firmware          │
                                      │  (BLE peripheral)        │
                                      │  stations = valves/pumps │
                                      │  scale under the cup     │
                                      └──────────────────────────┘
```

- The **app** owns the menu, recipes, and the maths (percent → ml). It sends the
  robot a flat list of `station=amount` pours.
- The **firmware** owns the hardware: opening valves / running pumps, weighing,
  cup detection, safety. It reports progress and status back as short text messages.
- The robot needs **no knowledge of drinks, names, or the menu**. It only knows
  station ids (physical positions) and amounts.

---

## 2. BLE GATT layout

The app is the **central**; the robot is the **peripheral**.

| Item | UUID | Notes |
|------|------|-------|
| Service | `94635d24-cf8d-4ff8-9191-de713f39db89` | Must be **advertised**: the app scans with `scanForPeripherals(withServices: [this])` |
| Control characteristic | `4ac8a682-9736-4e5d-932b-e9b31405049c` | App → robot commands. Must support **Write (with response)**. Should also support **Notify** (see below) |
| Status characteristic | `6bcdd021-ffa5-4522-9454-a21d025d6562` | Referenced in app code but **not used** for anything specific today. If it has Notify, it is subscribed and treated exactly like the control characteristic |

### How the app connects

1. On Bluetooth power-on (and when the menu screen appears), the app scans for
   the service UUID above.
2. **First** peripheral found advertising that service → stop scan → connect.
   (No name filtering, no RSSI filtering. Only one robot should be advertising nearby.)
3. Discovers **all** services and **all** characteristics.
4. Calls `setNotifyValue(true)` on **every characteristic that has the Notify
   property, in any service**.
5. When the characteristics of the MixBot service have been discovered, the app
   considers TX ready and immediately writes **`ehlo`** to the control characteristic.
6. On an unexpected disconnect, the app automatically rescans and reconnects.
   On connect failure it also rescans. No backoff.

### Writes

- Every command is written to the **control characteristic** with
  `.withResponse`, encoded as UTF-8, **no terminator** (no `\n`, no `\0`).
- One write = one complete command. The app never splits a command across writes
  itself.
- **Length:** a job string can exceed 20 bytes (e.g. `D:3=60.00,9=225.00` is 18
  bytes; four ingredients ≈ 40 bytes). iOS will negotiate a larger MTU if the
  peripheral allows it, or fall back to a **long (prepared/queued) write** for
  write-with-response. The firmware must accept writes up to at least ~128 bytes —
  allow an MTU ≥ 185 and/or support long writes.

### Notifications (robot → app)

- **Every notification from every subscribed characteristic** is decoded as
  UTF-8 and fed into one parser. It doesn't matter which characteristic you
  notify on, but **use the control characteristic** to keep things simple.
- **One notification = one message.** The app does **not** split on newlines,
  `;`, or anything else. Do not batch several messages into one notification.
- Do not send messages faster than the app can handle them. Each one updates
  published UI state on the main thread. ~10–20 messages/s is fine;
  no burst of hundreds.
- Non-UTF-8 payloads are dropped and logged.

---

## 3. Commands: app → robot

| Command | When sent | Meaning |
|---------|-----------|---------|
| `ehlo` | Right after the connection is ready (every connect / reconnect) | Hello. The app expects nothing specific back, **but see the cup state requirement in §4.2**. A good reply is the current cup state plus a text status |
| `D:<station>=<ml>,<station>=<ml>,...` | User taps SERVE and the pour screen opens | Dispense job (see §3.1) |
| `C!` | User taps Cancel on the pour screen while the pour is in progress | Abort the current job **immediately** (close all valves, stop pumps) |

### 3.1 Dispense job `D:`

Format (built in `RemoteEngine.sendJobToRobot`):

```
D:<stationId>=<amount>,<stationId>=<amount>,...
```

- `stationId` is an integer (the station's id from the menu = physical position).
- `amount` is the volume in **ml**, always formatted with **exactly 2 decimals**
  (`%.2f`), e.g. `75.00`, `33.33`.
- `amount = totalQty × percent / 100` (totalQty is the drink size in ml).
- Pairs are separated by `,`. No trailing comma, no spaces, no terminator.
- **The order of the pairs is the pour order** and defines the step index:
  first pair = **step 0**, second = **step 1**, etc. All progress messages refer
  to the **step index**, **not** the station id.

Examples:

```
D:3=75.00,9=225.00               Gin & Tonic, 300 ml: gin 25 %, tonic 75 %
D:3=60.00,9=45.00,8=195.00       three steps
D:1=50.00                        Tequila shot, single step
```

Edge cases the firmware must handle:

| Case | Possible? | Expected firmware behavior |
|------|-----------|----------------------------|
| Amount `0.00` | Yes (a 0 % ingredient is valid) | Skip the pour, still report that step complete (`S<step>=C`) or the app never finishes |
| Same station twice in one job | Yes (validation doesn't forbid it) | Pour it twice, once per step |
| Unknown station id | Should not happen (menu validated), but possible after hardware changes | **Decided:** firmware accepts ids 1–9 only. Anything else rejects the whole job (§3.3) |
| Huge total (e.g. 2000 ml) | Yes — `totalQty` has no upper limit in the app | **Decided:** firmware rejects jobs totalling > 450 g (§3.3) |
| New `D:` while a job is running | App doesn't prevent it in edge cases (e.g. user cancels and re-serves quickly) | **Decided:** firmware **rejects** (not cancel + new), including while the tray is still parking after `C!` (§3.3) |
| Fractional amounts | Yes, e.g. `33.33` | Round to your hardware resolution |

What the app does **not** send: drink name, ingredient names, station kind
(valve/pump), a job id, a checksum, or a protocol version.

### 3.2 Cancel `C!`

- Sent only if the app thinks it's connected and the pour is still running.
- The app **closes the pour screen immediately** after sending it; it does not
  wait for confirmation. Whatever you send afterward still gets parsed but
  usually isn't shown.
- Firmware should stop everything at once and go back to idle. Sending
  `$0=Cancelled` is good practice (it shows up on the next screen that shows status text).

### 3.3 Job rejection (as implemented by the firmware)

There is no job-level ack yet (§8.2), so the firmware rejects a `D:` by sending
**`S<n>=F` for every step**, plus a `$0=` reason. The pour screen then reaches
Done and shows the reason under the glass. Works with the app as of `cb2b61d`.

| Condition | `$0=` text |
|-----------|------------|
| A job is running, or the tray is still parking after `C!` | `Busy, try again` |
| No cup on the scale | `No Cup! Please add a cup!` (also sends `$1=0`) |
| Unknown station id (valid: 1–9), bad/negative amount, missing `=`, empty job | `Invalid drink request` |
| Job total > **450 g** (glass capacity) | `Invalid drink request` |
| Finished drink still on the tray | `Remove your drink first` |
| Cup weighs > **400 g** (probably not empty) | `Cup is not empty` |
| Machine not homed/parked yet | `Busy, try again` or `Not ready, try again` |

Other firmware behavior worth knowing:
- `0.00` steps: no movement, reported as `S<n>=P` then `S<n>=C`.
- The firmware sends `S0=P` itself. The app's local "step 0 processing" mark is just a head start.
- `W<n>` is sent only while that step's output is open or settling. The final `W<n>` always comes before `S<n>=C`.
- `ehlo` reply: `$1=<cup>` then `$0=` one of `Starting up...`, `Please add a cup`, `Ready!`,
  `Get your drink!`, `Parking...`, `Still Working!`. Duplicate suppression resets on every connect.

---

## 4. Messages: robot → app

There are two families. The first character picks the parser.

### 4.1 Per-step progress: `W` and `S`

Parsed by `makeStatusFrom(message:)` in `JobProgress.swift`.

```
W<step>=<grams>      weight poured so far for this step
S<step>=<state>      state change for this step
```

- `<step>` is the 0-based **step index** from the `D:` job (not the station id).
- Exactly **one `=`** is allowed. A message with more than one `=` is rejected.
- Whitespace around parts is trimmed. A trailing `;` on the value is tolerated
  (`W0=12.5;` works). No other terminators.
- A step index outside the current job is ignored.

**Weight `W<step>=<grams>`**

- `<grams>` is a float (`12`, `12.5`, `12.50`). The app parses it with `Float(...)`.
  An unparseable value becomes `0`.
- **The weight is cumulative for that step** (grams poured into the cup by this
  step so far), **not** the total cup weight. Tare per step, or subtract the
  starting weight.
- The app compares the grams to the target **ml** directly (it assumes 1 g ≈ 1 ml)
  to draw the fill level in the glass animation: `fill = grams / target_ml`, capped at 100 %.
- Weights `≤ 0` are ignored (the previous weight is kept).

**State `S<step>=<state>`**

| `<state>` | Meaning in app |
|-----------|----------------|
| `P` | Processing (this step is pouring now) |
| `C` | Complete |
| **anything else** | **Failed.** Use `F` by convention |

The pour screen is finished (Cancel becomes Done) when **every** step is
`Complete` or `Failed`. Failed steps count as finished so the UI can't get stuck.

#### ⚠️ Ordering rules (important — app-side quirk)

Because of how `JobProgress.update(with:)` works today, every `W` message also
**resets that step's state to "Unknown"**. Therefore:

1. **Never send `W<n>` after `S<n>=C` or `S<n>=F`.** It knocks the step back out
   of "finished" and the pour screen will stay on "Cancel" forever.
2. Send the **final weight before** the `S<n>=C`.
3. Sending `S<n>=P` before the first `W<n>` is still recommended (the app marks
   step 0 as Processing locally when it sends the job, but other steps rely on
   your `P`).

(This is a known app-side wart. See §8 for the proposed fix. Until it lands, follow the rules above.)

#### Recommended sequence for one job

```
App  → D:3=75.00,9=225.00
Bot  → $0=Pouring Gin            (optional text)
Bot  → S0=P
Bot  → W0=10.2
Bot  → W0=38.7
Bot  → W0=74.9                   final weight for step 0
Bot  → S0=C
Bot  → $0=Pouring Tonic
Bot  → S1=P
Bot  → W1=50.3
Bot  → ...
Bot  → W1=224.6
Bot  → S1=C
Bot  → $0=Your drink is ready. Enjoy!
```

Failure example (bottle empty: no weight change for N seconds):

```
Bot  → S1=F
Bot  → $0=Tonic station is empty
```

Then either continue with the next steps or mark all remaining steps `F` and stop.
**Every step must end with `C` or `F`** or the UI never reaches "Done".

### 4.2 Robot status: `$`

Parsed by `RobotStatus.setFrom(text:)` in `RobotStatus.swift`.

```
$<type>=<value>
```

Splits on the **first** `=` only, so the value may contain `=`.

| Type | Format | Effect in app |
|------|--------|---------------|
| `0` | `$0=<free text>` | Status text. Shown in the menu's connection header and under the glass on the pour screen. Keep it short (one line on a phone, ~40 chars) |
| `1` | `$1=1` or `$1=0` | Cup present (`1`) / absent (anything else) |
| other | — | Clears cup state **and** text (treated as unknown). Don't send other types without coordinating |

Details:

- **No `;` stripping here.** `$1=1;` is read as **cup absent**. Send exactly `$1=1`.
- `$0=` text is shown verbatim, including any trailing characters.
- **Cup state gates serving:** the SERVE button only appears when the app is
  connected **and** the last `$1` received was `1`. The app starts with cup
  state **unknown** (shows "Please place your cup") on every launch. So:
  - Send `$1=<state>` **in reply to every `ehlo`** (the app keeps the old
    value across reconnects in the same session, but don't rely on that).
  - Send `$1=…` **whenever the cup state changes** (debounced).
- The app does **not** stop or react to `$1=0` during a pour (other than the
  stored state). **Firmware owns safety:** if the cup is removed mid-pour, stop,
  mark the current and remaining steps `F`, and send a `$0=` explanation.

### 4.3 Anything else

Messages that don't start with `W`, `S`, or `$` (or are malformed) are logged
and ignored. Safe for debug output, but it still costs a BLE round-trip and
main-thread work. Keep it off in production.

---

## 5. Stations and the menu (context for the firmware)

The menu lives on the server (`GET https://mixbot-api.kixlobo.workers.dev/menu`,
format v2). The firmware never reads it today, but the station ids it uses are
the ids the firmware receives:

```json
{
  "version": 2,
  "stations": [
    { "id": 1, "name": "Tequila", "kind": "valve", "role": "spirit", "abv": 38, "notes": "..." },
    { "id": 8, "name": "Mineral Water", "kind": "pump", "role": "water" }
  ],
  "drinks": [
    { "name": "Tequila Soda", "description": "...", "totalQty": 300,
      "ingredients": [ { "stationId": 1, "percent": 15 },
                       { "stationId": 8, "percent": 85, "label": "Mineral" } ] }
  ]
}
```

- **Station id = physical position on the robot.** In the app's station editor,
  reordering stations keeps ids **and** `kind` pinned to positions; only the
  liquid name moves (and recipes are remapped). So the firmware can hard-wire
  `id → GPIO/valve/pump`.
- `kind` (`valve` = gravity valve, `pump`) is **display-only in the app**. It is
  not sent to the robot. The firmware must know its own hardware per station.
- `role`, `abv`, `notes` are only for the app's on-device AI bartender (AI Tender).
  They don't matter to the firmware.
- `label` is a per-recipe display name only. The robot always pours from `stationId`.
- Current station ids in use: 1–9 (Tequila, Bacardi, Gin, Whiskey, Coffee,
  Licor 43, Coca Light, Mineral Water, Tonic). Check the live menu for the
  current list.
- Drink sizes in the current menu are 50–350 ml. AI Tender creates 300 ml drinks.
- Recipes come from three places, and all of them produce the same `D:` job:
  the server menu, user customizations ("Make It Your Own", saved to the menu),
  and AI Tender. The firmware can't tell them apart and shouldn't need to.

---

## 6. Simulator / demo mode

In the iOS Simulator (no CoreBluetooth), the app fakes a connected robot with a
cup present. It replays a pour locally: each step goes Processing, weight ramps
over ~3 s in 30 ticks, then Complete. That simulation is the **reference for
the expected message cadence**: about 10 weight updates per second per step.

---

## 7. Firmware checklist

`[x]` = firmware reports it's done (protocol v6, 2026-11-03, built but **not yet flashed**). `[~]` = partly done. `[ ]` = open.

- [x] Advertise service `94635d24-cf8d-4ff8-9191-de713f39db89` in the advertisement packet (`addServiceUUID`)
- [x] Control characteristic `4ac8a682-9736-4e5d-932b-e9b31405049c`: Write (with response) + Notify (also Read). The robot sends on the **Status** characteristic; the app subscribes to both
- [~] Accept writes ≥ 128 bytes. Long writes work; MTU ≥ 185 not explicitly requested yet
- [x] On `ehlo`: reply `$1=<ok to serve>` and a `$0=<status>` line
- [x] Push `$1=` on every change (since v6 `$1` means **OK to serve**, see `PROTOCOL.md` §A.3)
- [x] Parse `D:` → ordered steps; step index = position in list
- [x] Per step: `S<n>=P` → `W<n>=…` (cumulative grams for that step) → final `W` → `S<n>=C` or `S<n>=F`
- [x] Never send `W<n>` after the step's final `S`
- [x] Every step ends in `C` or `F`, including 0 ml steps, rejected jobs and mid-job safety aborts (v5)
- [x] `C!` aborts immediately, all outputs off
- [~] Safety in firmware: max volume ✅ (450 g), cup-removed abort ✅, flow timeout / empty bottle ✅, pour time limit ✅, scale fault ✅, abort on BLE disconnect mid-pour ✅, **valve stuck open ⏳** (next on the firmware side)
- [x] One message per notification, no terminators (`;` tolerated only on `W`/`S`)
- [x] Weight notifications capped at ~10 Hz; the final `W` is always sent before `S=C`

---

## 8. Known app-side limitations (candidates for change)

These are on the iOS side. Listed so the firmware can work around them now and
so you know what's open for discussion:

1. **`W` resets step state to Unknown** (see §4.1). The fix on iOS is small:
   only update status from `S` messages. Once that lands, `W` after `S=C` is harmless.
   The firmware already avoids triggering it, so this is low priority.
   **Fixed in the app (2026-11-03, not yet released):** `W` no longer touches step state.
   Keep following the §4.1 ordering rules anyway: app builds already in the field still have the bug.
2. **No job acknowledgement or rejection.** The app sends `D:` and assumes the
   robot started. The firmware works around this by failing every step plus a
   `$0=` reason (§3.3). It works, but a rejected job looks like a failed pour.
3. **No job id.** Late messages from a cancelled job can be confused with a new job's steps.
4. **No protocol version / capabilities handshake.** `ehlo` carries nothing and
   expects nothing.
5. **No error codes.** Failure reasons only travel as free `$0=` text.
6. **Cup state not enforced during a pour** on the app side.
7. **Serving uses the menu recipe, not the slider-adjusted mix.** The detail
   screen's proportion sliders currently only feed "Make It Your Own" (saving a
   new drink). The pour sends the original recipe. App-side issue, no firmware impact.
8. **Grams vs ml.** The app treats 1 g = 1 ml for the fill animation. Spirits and
   syrups differ (e.g. 40 % ABV ≈ 0.95 g/ml). If the firmware stops on weight,
   it should apply per-station density itself. The app may later send density or
   expect ml back.
9. **The app connects to the first advertiser** of the service. Multiple robots
   in one room aren't supported.
10. The status characteristic `6bcdd021-…` is effectively unused.
11. **The app doesn't know the firmware's limits.** The menu editor and server
    allow station ids above 9 and `totalQty` above 450 ml. Those drinks show
    SERVE and then fail every step. Matching limits should be added app/server-side,
    but carefully: today, one invalid drink makes the app reject the whole menu
    and fall back to the cached copy.
    **Fixed (2026-11-03, app not yet released, worker deployed 2026-11-03):** the app's
    `RobotLimits` (`DrinkMenu.swift`) and the worker's `MAX_POUR_QTY` /
    `MIN/MAX_STATION_ID` block publishing such recipes. A menu that still contains
    one loads normally, and only that drink shows a reason instead of SERVE. **If
    the firmware's limits change, tell iOS:** both constants must move together.

---

## 9. How to propose changes

The iOS app is maintained separately. When you want a protocol change:

1. **Keep backward compatibility by default.** Add new message types and prefixes
   instead of changing existing ones. Old app builds in the field still speak
   exactly what's in this doc.
2. Write the proposal as a short spec block in this format:

   ```
   ### Proposal: <title>
   Direction: app→robot | robot→app
   Message: <exact bytes / grammar>
   When: <trigger>
   App must: <parse/UI behavior expected>
   Firmware will: <behavior>
   Backward compat: <what happens with old app / old firmware>
   ```
3. Reference the exact app file / function you expect to change (see the table
   at the top) so the iOS side can implement it directly.
4. Ideas already on the table that the iOS side would welcome:
   - `ehlo` reply with firmware/protocol version and station capabilities, e.g.
     `$2=fw=1.3;proto=2;stations=1,2,3,4,5,6,7,8,9`
     (would need a new `$2` case in `RobotStatus`. Today an unknown type clears cup state, so this needs the app change first).
   - Job ack / reject: `A=ok` / `A=busy` / `A=bad:<reason>` after `D:`.
   - Job-level done: `J=C` / `J=F:<reason>` so the app doesn't have to infer completion.
   - Per-station status, e.g. empty bottle / level low, to grey out drinks in the menu.
   - Using the status characteristic `6bcdd021-…` for `$` messages and the
     control characteristic for step progress.

---

## 10. Replies to `NOTES_FROM_FIRMWARE.md`

Newest entry first. The firmware side writes in `NOTES_FROM_FIRMWARE.md`; the
iOS side replies here.

### 2026-11-03 (v6): app checked against PROTOCOL.md v6

Thanks, all v6 items received. §7 above is updated to your list. **The app is
compliant with v6 with no protocol change.** Answers and app-side follow-ups:

- **Confirmed: the pour screen doesn't react to `$1=0` mid-pour.** Only the drink
  screen's SERVE button reads `$1` (`DrinkDetailView.swift`). The pour screen
  (`ProcessView.swift`) never does. A `$1=0` at job start is harmless.
- **"Not OK to serve" now shows your reason.** With `$1=0` the drink screen used to
  say "Please place your cup". It now shows the latest `$0=` text instead (e.g.
  `Cup is not empty`, `Homing...`, `Calibrating...`), falling back to "Please place
  your cup" only when no text has arrived. Keep the idle texts short and
  user-facing; they're shown verbatim in place of the SERVE button.
- **Stop reasons (your v5 suggestion), done.** When a pour ends with any `S<i>=F`,
  the pour screen's header becomes the latest `$0=` text (`Bottle empty? Stopped`,
  `Cup removed! Stopped`, a rejection reason…) instead of a generic "Finished with
  a hiccup". So please keep sending the reason **after** the `F`s, as you do now.
  The header updates when it arrives.
- **Disconnect mid-pour (v6 §A.6).** Your `F`s can't reach a disconnected app, so
  the app now fails its unfinished steps itself when the link drops and shows
  "Connection lost. The robot stopped the pour." It doesn't try to resume. On
  reconnect it sends `ehlo` as always, and your `$1=0` plus state text keep SERVE
  hidden until the drink is removed.
- **Cancel:** after sending `C!` the app now discards its local step list, so late
  `S`/`W` messages from the cancelled job are ignored.

Still on hold on the app side, by the owner's choice: job ack / `ehlo` version
parsing, and the "reload a valve's saved values without moving it" calibration
command. **Don't send** `A=…` or new `$` types yet.

### 2026-11-03 (latest): valve calibration shipped in the app (protocol v3/v4)

The app's Robot Settings → Valve Calibration screen (`RobotSettingsView.swift`,
`Models/Status/ValveCalibration.swift`) implements `PROTOCOL.md` §A.7 v4, including
every request in your v3 and v4 entries. **How the app now behaves:**

- **The tray moves first.** The app sends `TM<id>` only after the user confirms
  "an empty glass is on the tray" (asked once per valve screen). Open and the
  open-angle controls stay disabled until `TM<id>=at`. A `TM` with no `=at` within
  **12 s** gives up with an error and a retry. `TM<id>=moving` only confirms the
  move started. The app never treats it as arrival.
- **`TE=tray` / `TE=moving`** close the app's open session and send the user back
  to "Move tray". The app never retries `TO`.
- **`TE=bad` in reply to `TM`** is read as "firmware before v3, can't move the
  tray". The app then asks the user "Is the glass under valve X?" before **every**
  open. With v3+ firmware this path never triggers.
- **Parking:** the app sends `TX` when the user leaves calibration (back to Robot
  Settings or closing the sheet), when the app goes to the background, and as a
  safety net when the sheet goes away. Moving from the valve grid into one valve's
  screen does **not** send `TX`, so the tray stays where it is between valves.
  Switching valves sends `TM<new>`.
- **Pumps:** the grid is built from the `T?` replies, minus stations the menu marks
  as `pump`. The app never sends `T…` for 7–9. `TE=pump` is logged and shown as a
  notice.
- **Unchanged:** one valve open at a time; an open valve auto-closes after 8 s
  without a tap; Cancel puts the previous open angle back with `TO<id>=<orig>`
  followed immediately by `TC<id>`; angle taps are ignored for 0.5 s after opening;
  commands are rate-limited to 5/s (rapid taps collapse to the latest angle).
- **Your "Parking…" suggestion:** not shown yet. The tray badge simply returns to
  "Tray not here" after `TX=ok`.

**Spec fix requested, `PROTOCOL.md` §A.3:** the robot → app table lists
`T<id>=…`, `TE=…`, `TX=ok` but not the v3 tray replies. Please add
`TM<id>=moving` / `TM<id>=at` (calibration tray move, see §A.7) to that row, and
bump the version / changelog per your rules. The app already parses them. No
firmware behavior change.

### 2026-11-03 (later): app side now matches your limits

- **Limits mirrored:** the menu editor and the worker refuse to publish a drink over
  **450 ml** or a station outside **1–9**. A drink like that, if it ever reaches
  the menu, shows "Too large for the glass" / "Uses a station the robot doesn't
  have" instead of SERVE, so it never reaches you as a `D:`. Your rejection stays
  the safety net.
- **`W` no longer resets step state** in the app (§8.1). The ordering rules in
  §4.1 still apply for older app builds.
- Unit tests now cover the `W`/`S` parsing and the limits (`MixBotTests/RobotProtocolTests.swift`).
- Nothing changed on the wire. No new messages.

### 2026-11-03: re "firmware fixes per FIRMWARE_INTERFACE.md"

Checked every change against the app code at `cb2b61d`. **All of them work
with the app, and none needs an app change.** The decisions are now part of
§3.1, §3.3 and §7. Specifically:

- **Rejecting with every step `F` plus `$0=`:** ✅ The app creates the step list
  before writing `D:`, so the `F`s always land on real steps. Failed steps count
  as finished, so the pour screen reaches Done and shows the reason.
- **`0.00` → `P` then `C`, firmware sending `S0=P`, `W` only while pouring with the final `W` before `C`:** ✅
- **`ehlo` reply and duplicate-suppression reset on connect:** ✅ This is exactly
  what turns on SERVE after a (re)connect.
- **`C!` ignored when idle, `$0=Cancelled` otherwise:** ✅

Requests and suggestions (all backward compatible):

1. **Report `$1=0` whenever you'd reject for a cup reason.** That covers
   "Remove your drink first" and "Cup is not empty", not just "no cup". In the
   app, `$1` really means "OK to serve": `$1=0` hides SERVE before the user taps
   it, instead of showing a pour where every step fails. Send `$1=1` again once
   an empty cup is placed. Pair it with a `$0=` text (e.g. `Remove your drink
   first`), which shows in the menu's connection header.
2. **Same idea for "busy" states.** While parking or homing, a `$0=Parking...` /
   `$0=Not ready` text is enough; the app doesn't gate on it. A real fix comes
   with the job ack (§9, item 4).
3. **Station ids 1–9:** fine for now. If the robot ever gets more stations, tell iOS
   first: the menu editor lets you add station 10 today, and the
   firmware would reject every drink that uses it.
4. **Weight vs volume:** the 450 g / 400 g thresholds are grams while the app
   sends ml. Fine for a margin check; just keep §8.8 (density) in mind for spirits.
5. **Still wanted, as you listed:** flow timeout / empty bottle, cup-removed
   abort, abort on BLE disconnect mid-pour. The planned "current step `F` plus
   all remaining `F` plus `$0=` reason" sequence works with the app as it is.
6. **Next protocol step, when you're ready:** job ack (`A=ok` / `A=busy` /
   `A=bad:<reason>`) and a version reply to `ehlo` (§9). These **do** need an app
   change first. Don't send them until iOS confirms the parser shipped.
   Today, `A…` is ignored (safe), but an unknown `$<type>` clears cup state.
