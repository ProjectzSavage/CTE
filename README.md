# Clutch the Egg (CTE)

A 6-player physics party brawler for Roblox. An egg spawns in the center of a
small arena; touch it to grab it. While you carry it you accrue **hold time**.
A match is **best of 3 rounds x 75 seconds** — the round winner has the most
total hold time, and the match MVP has the most hold time across all rounds.

Abilities: **Attack** (only when NOT holding — punching the carrier knocks the
egg loose; "HANDS FULL" otherwise), **Throw** (only when holding — lob it to a
teammate or at an enemy), **Block** (always — reduces knockback; while holding
you still gain hold time but move 50% slower), **Dash** (always — while
holding it's shorter, has NO i-frames, and dashing into a player drops the
egg). If the egg leaves the arena it respawns at the center after 3 seconds
and hold time pauses.

---

## Current status: Task 3 — egg system + combat + client input are LIVE

Open **[`ClutchTheEgg.rbxlx`](ClutchTheEgg.rbxlx)** in Roblox Studio and press
Play. Everything below is server-authoritative; clients only send requests.

### Controls

| Ability | Keyboard / Mouse | Gamepad | Mobile |
| --- | --- | --- | --- |
| Attack (not carrying only) | **Left Mouse** | X | CAS touch button (placeholder) |
| Throw (carrying only) | **Q** or **F** | Y | CAS touch button (placeholder) |
| Block (hold) | **Right Mouse** or **E** | L1 | CAS touch button (placeholder) |
| Dash | **Left Shift** or **Space** (jump still works — air-dashes are legal) | R1 | CAS touch button (placeholder) |

The real mobile GUI comes in a later prompt and should call the exposed API:
`_G.CTEInput.Attack() / .Throw() / .Dash() / .Block(true|false)`.

### Ability rules implemented (all validated server-side)

* **Attack** — rejected with `HandsFull` feedback while carrying. Range
  `AttackRange` + forward hemisphere, 0.6 s cooldown, 10 stamina. Hits apply
  knockback 25 (+8 up) and 0.25 s hitstun; blocked victims take 60 % less and
  no hitstun; i-framed victims are untouched. **Hitting the carrier calls
  `EggService.Fumble(victim, "Attacked", knockLoosePop)` → `EggStolen`
  feedback** (the steal). Whiffs report `PunchWhiff` privately.
* **Throw** — rejected with `NotCarrying` when not holding. Launches the egg
  at `ThrowSpeed` 60 (+12 upward bias) where you face; hold time stops the
  instant it leaves your hands. For ~0.8 s (and while faster than 18 studs/s)
  the egg is **"hot"**: it knocks back any player it hits (14 + 6 up, 0.15 s
  stagger) and bounces loose — no catching in this version, plain loose-pickup
  once it slows (team catches come later). Thrower lockout 0.8 s.
* **Block** — always usable (hold). Incoming knockback ×(1−0.6), move speed
  ×0.5, drains 15 stamina/s, breaks automatically at 0 (`BlockBroken`).
  **A blocking carrier STILL accrues hold time** (EggService doesn't care
  about blocking). Blocking does *not* prevent being fumbled by a punch —
  only dash i-frames do.
* **Dash** — always usable. Not carrying: +24 speed for 0.25 s, 0.2 s
  i-frames, 25 stamina, 2.5 s cooldown. Carrying: +16 speed for 0.15 s, **no
  i-frames**, 30 stamina — and **colliding with a player within 4 studs
  fumbles the egg** (`DashFumble` feedback + small knockback to the victim).
* **Stamina** — max 100, regen 20/s starting 0.75 s after any spend.
  Published to clients as the rounded `Stamina` Player attribute (HUD-ready).
* **Speed authority** — CombatService is the only writer of `WalkSpeed`:
  base = carrier ? 12 : 16, ×0.5 while blocking, 0 while stunned, dash
  override during bursts. Recalculated at 20 Hz, written only on change.

### Testing in Studio

> **Note:** the Studio command bar runs in **client context** while playing,
> so it cannot see `ServerScriptService` children (that's why the old
> `require(...EggService).Fumble()` command-bar trick errored). Use the new
> Studio-only `DebugCommand` remote instead:

```lua
game.ReplicatedStorage.Remotes.DebugCommand:FireServer("fumble")            -- drop current carrier's egg
game.ReplicatedStorage.Remotes.DebugCommand:FireServer("fumble", "Name")    -- drop a specific player's egg
game.ReplicatedStorage.Remotes.DebugCommand:FireServer("respawn_egg")       -- force center respawn
game.ReplicatedStorage.Remotes.DebugCommand:FireServer("state")             -- egg + combat state dump
```

(Server-side/Run mode: `game.ServerScriptService.DebugCommands:Fire("fumble")`
still works too. Both paths are hard-gated to `RunService:IsStudio()` and
`Config.DebugAllowCommandBar`.)

**2-player checklist (Test → Local Server, 2 players):**

1. Player 1 grabs the egg (walk into it) → slower, `HasEgg` attribute on.
2. Player 2 punches Player 1 (LMB within 5 studs, facing) → knockback +
   hitstun, egg pops loose (`EggStolen` in server log), Player 2 grabs it.
3. Carrier throws (Q/F) → egg lobs out; a hot egg hitting the other player
   knocks them back and bounces loose; after it slows, either can pick it up.
4. Both hold block (RMB/E) → half speed; punches push them 60 % less; carrier
   blocker's hold time keeps climbing in `DebugCommand "state"`.
5. Both dash (Shift/Space) → non-carrier gets brief i-frames (punches whiff:
   `IFrameDodge`); carrier dash is shorter and **dashing into the other player
   fumbles the egg** (`DashFumble`).
6. Stamina: spam dash/attack/block → `NoStamina`/`OnCooldown` rejections,
   regen after 0.75 s idle; blocking to 0 breaks the block.

### Remote payload contracts (server → all clients)

| Remote | Payload |
| --- | --- |
| `EggPossessionChanged` | `(newCarrier: Player?, previousCarrier: Player?)` |
| `HoldTimeUpdated` | `(entries)` — array of `{ Player, HoldTime }`, sorted desc; ~10 Hz while carried + one final push after changes |
| `FeedbackEvent` | `(kind: string, data: table)` — see kinds below |
| `MatchStateChanged` / `RoundEnded` / `MatchEnded` | reserved for MatchService/ScoringService (later) |

Client → server: `RequestAttack`, `RequestThrow`, `RequestDash`,
`RequestBlockStart`, `RequestBlockEnd` — **all sent with no arguments**; the
server computes targets/directions itself and ignores any payload (cheaters
gain nothing). `DebugCommand` (`command`, `playerName?`) is Studio-gated.

`FeedbackEvent` kinds — world (FireAllClients): `PunchSwing`, `PunchHit`
(incl. `Result` = Hit/Blocked/IFramed), `BlockedHit`, `IFrameDodge`,
`EggStolen`, `EggThrown`, `EggImpact`, `DashStart` (incl. `Carrying`),
`DashFumble`, `BlockStart`, `BlockEnd`, `BlockBroken`, `EggPickup`,
`EggFumble`, `EggOutOfBounds`, `EggRespawn`. Personal (FireClient):
`HandsFull`, `NotCarrying`, `NoStamina`, `OnCooldown`, `Stunned`,
`PunchWhiff`.

### Service APIs (server)

*EggService:* `Init()`, `StartRound()`, `EndRound()`, `GetCarrier()`,
`GetEgg()`, `GetState()`, `GetHoldTime(p)`, `GetHoldTimes()`,
`ResetHoldTimes()`, `Fumble(target?, reason?, popVelocity?)`,
`ReleaseThrow(player, direction)`, `RespawnEggNow()`, `IsEggHot()`,
`GetThrower()`, `SetImpactHandler(fn)`, `DebugState()`.

*CombatService:* `Init()`, `ApplyKnockback(player, direction, force,
upwardForce?, stunTime?)` → `"Hit"/"Blocked"/"IFramed"/"Invalid"`,
`HandleEggImpact(player, eggVelocity)` (injected into EggService by Main),
`GetStamina(p)`, `IsBlocking(p)`, `IsDashing(p)`, `HasIFrames(p)`,
`IsStunned(p)`, `DebugState()`.

## Quick start (building the place)

**Option A — just open the place file (no tooling needed)**

Roblox Studio → *File → Open From File…* → `ClutchTheEgg.rbxlx`.

**Option B — rebuild the place file from source (pure Python, no Roblox/Rojo)**

```bash
python3 tools/build_place.py          # regenerates Arena.rbxmx + ClutchTheEgg.rbxlx
```

The builder parses `default.project.json`, embeds every `src/**` Lua file with
Rojo-style script-kind inference, and validates the result (all remotes
present, Config tunables intact, 6 spawn locations, etc.) before writing.

**Option C — Rojo (recommended for live iteration in Studio)**

The repo is a standard [Rojo](https://rojo.space) project:

```bash
rojo serve    # then connect the Rojo Studio plugin
# or
rojo build -o ClutchTheEgg.rbxlx
```

## Repository layout → DataModel mapping

| Repo path                                            | In Studio                                        | Kind          |
| ---------------------------------------------------- | ------------------------------------------------ | ------------- |
| `default.project.json`                               | structure manifest (also drives the Py builder)  | —             |
| `src/ReplicatedStorage/Modules/Config.lua`           | `ReplicatedStorage.Modules.Config`               | ModuleScript  |
| remotes (declared in `default.project.json`)         | `ReplicatedStorage.Remotes.*`                    | RemoteEvent   |
| `src/ServerScriptService/Main.server.lua`            | `ServerScriptService.Main` (+ `DebugCommands` BindableEvent at runtime) | Script |
| `src/ServerScriptService/MatchService.lua`           | `ServerScriptService.MatchService`               | ModuleScript  |
| `src/ServerScriptService/EggService.lua`             | `ServerScriptService.EggService` (**implemented**) | ModuleScript |
| `src/ServerScriptService/CombatService.lua`          | `ServerScriptService.CombatService` (**implemented**) | ModuleScript |
| `src/ServerScriptService/ScoringService.lua`         | `ServerScriptService.ScoringService`             | ModuleScript  |
| `src/ServerScriptService/DataService.lua`            | `ServerScriptService.DataService` (reserved)     | ModuleScript  |
| `src/StarterPlayer/StarterCharacterScripts/ClientInput.client.lua` | `StarterPlayer.StarterCharacterScripts.ClientInput` (**implemented**) | LocalScript |
| `src/Workspace/Arena.rbxmx`                          | `Workspace.Arena` (generated by `tools/gen_arena.py`) | Model    |
| `ClutchTheEgg.rbxlx`                                 | the runnable place file (build artifact)         | —             |

Script kinds follow Rojo conventions: `*.server.lua` → Script,
`*.client.lua` → LocalScript, plain `*.lua` → ModuleScript.

### The arena (`Workspace.Arena`)

* `Baseplate` — 128×128 floor slab, top face at Y=0.
* `BoundaryNorth/South/East/West` — translucent cyan walls, inner faces at
  ±60 (playable square 120×120), height 5.
* `CenterPad` — gold cylinder (Ø12, non-collidable) marking the egg zone.
* `EggSpawnPoint` — invisible marker at Y=3; EggService respawns the egg here.
* `Spawn1..Spawn6` — neutral SpawnLocations on a hex ring at radius 48, one
  per party color.

Geometry constants live in `tools/gen_arena.py` and are documented by the
`Config.Arena*` values — keep them in sync, then rebuild.

## Architecture rules (binding for all future work)

1. **Server-authoritative.** Clients only send input via RemoteEvents; the
   server validates (cooldowns, ranges, stamina, possession state) and
   applies everything.
2. **`ReplicatedStorage.Modules.Config` is the single source of truth** for
   all tunable numbers. Gameplay code never hard-codes values.
3. **Systems are ModuleScripts in ServerScriptService**
   (Match / Egg / Combat / Scoring / Data), initialized by `Main`.
4. **Keep visuals simple** (basic Parts). Anything cosmetic fires
   `FeedbackEvent` (or BindableEvents server-side) so VFX/SFX/GUI polish can
   hook in later without touching gameplay code.
5. **Clean, commented, modular, performant** — target 60fps, mobile-friendly.

## Next steps (future prompts)

- [x] Egg: spawn, auto-pickup, possession + hold-time accrual, fumble,
      out-of-arena respawn (Task 2)
- [x] Combat: attack/knockback/steal, throw with hot-egg impacts, block,
      dash with carry rules + i-frames, stamina (Task 3)
- [x] Client input: keyboard/mouse/gamepad + placeholder mobile touch
      buttons + `_G.CTEInput` API for the GUI (Task 3)
- [ ] Match: state machine, round clock, best-of-3, winners + MVP
      (calls `EggService.StartRound()/EndRound()/ResetHoldTimes()`)
- [ ] GUI: HUD — hold-time leaderboard (`HoldTimeUpdated`), stamina bar
      (`Stamina` attribute), cooldowns, real mobile buttons (`_G.CTEInput`),
      feedback toasts (`FeedbackEvent`)
- [ ] Data: persistence
- [ ] Polish: egg mesh, VFX/SFX via `FeedbackEvent` hooks; line-of-sight
      check for proximity pickup; catch mechanic for team mode
