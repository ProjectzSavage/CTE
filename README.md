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

## Current status: Task 2 — the egg system is LIVE

Open **[`ClutchTheEgg.rbxlx`](ClutchTheEgg.rbxlx)** in Roblox Studio and press
Play:

* A glowing golden egg drops onto the center pad at server start.
* **Walk into it → you pick it up automatically** (no button). It welds in
  front of your torso, your `WalkSpeed` drops to `Config.CarrySpeed` (12), and
  your `Player` gets attribute `HasEgg = true`.
* Hold time accrues while you carry it; `HoldTimeUpdated` broadcasts a
  per-player leaderboard array at 10 Hz.
* Death / respawn / leaving the game fumbles the egg automatically.
* A loose egg nobody claims for 3 s (away from the center pad) — or that falls
  out of the arena — respawns at center after `Config.EggRespawnDelay`.

Match flow, combat, scoring and GUI are still documented stubs.

### Testing in Studio

**Solo (F5):** spawn, walk onto the gold pad, grab the egg, walk around.
Then open the **command bar** (View → Command Bar) and fumble yourself:

```lua
-- Option A: direct require (works in Play Solo)
require(game:GetService("ServerScriptService").EggService).Fumble()

-- Option B: the debug BindableEvent created by Main (always works)
game:GetService("ServerScriptService").DebugCommands:Fire("fumble")           -- current carrier
game:GetService("ServerScriptService").DebugCommands:Fire("fumble", "Name")   -- specific player
game:GetService("ServerScriptService").DebugCommands:Fire("respawn_egg")      -- force center respawn
game:GetService("ServerScriptService").DebugCommands:Fire("state")            -- print state + hold times
```

After `Fumble()` the egg drops loose at your feet (you are locked out of
re-grabbing it for `Config.ThrowSelfPickupDelay = 0.8 s`, another player can
grab it instantly). Walk away and leave it untouched for 3 s → it respawns at
center.

**Two players:** Test tab → *Local Server* → Players: 2 → Start. Both clients
see possession/hold-time updates; player 2 can snatch the egg after player 1
fumbles.

### Remote payload contracts (server → all clients)

| Remote | Payload |
| --- | --- |
| `EggPossessionChanged` | `(newCarrier: Player?, previousCarrier: Player?)` |
| `HoldTimeUpdated` | `(entries)` — array of `{ Player = Player, HoldTime = number }`, sorted desc; ~10 Hz while carried + one final push after changes |
| `FeedbackEvent` | `(kind: string, data: table)` — kinds from EggService: `"EggPickup"`, `"EggFumble"`, `"EggOutOfBounds"`, `"EggRespawn"` |
| `MatchStateChanged` / `RoundEnded` / `MatchEnded` | reserved for MatchService/ScoringService (later) |

Client → server remotes (`RequestAttack`, `RequestThrow`, `RequestDash`,
`RequestBlockStart`, `RequestBlockEnd`) exist but nothing listens yet —
CombatService owns them in the next pass.

### EggService public API (server)

`Init()`, `StartRound()`, `EndRound()`, `GetCarrier()`, `GetEgg()`,
`GetState()`, `GetHoldTime(player)`, `GetHoldTimes()`, `ResetHoldTimes()`,
`Fumble(target?, reason?, popVelocity?)`, `RespawnEggNow()`, `DebugState()`.
`Fumble` accepts a `Player`, a player name, or `nil` (= current carrier), and
an optional `Vector3` pop velocity (CombatService will pass the knock-loose
impulse later). Both `EggService.Fumble(...)` and `EggService:Fumble(...)`
call styles work.

## Quick start (building the place)

**Option A — just open the place file (no tooling needed)**

Roblox Studio → *File → Open From File…* → `ClutchTheEgg.rbxlx`.

**Option B — rebuild the place file from source (pure Python, no Roblox/Rojo)**

```bash
python3 tools/build_place.py          # regenerates Arena.rbxmx + ClutchTheEgg.rbxlx
```

The builder parses `default.project.json`, embeds every `src/**` Lua file with
Rojo-style script-kind inference, and validates the result (all 11 remotes
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
| `src/ServerScriptService/CombatService.lua`          | `ServerScriptService.CombatService`              | ModuleScript  |
| `src/ServerScriptService/ScoringService.lua`         | `ServerScriptService.ScoringService`             | ModuleScript  |
| `src/ServerScriptService/DataService.lua`            | `ServerScriptService.DataService` (reserved)     | ModuleScript  |
| `src/StarterPlayer/StarterCharacterScripts/ClientInput.client.lua` | `StarterPlayer.StarterCharacterScripts.ClientInput` | LocalScript |
| `src/Workspace/Arena.rbxmx`                          | `Workspace.Arena` (generated by `tools/gen_arena.py`) | Model    |
| `ClutchTheEgg.rbxlx`                                 | the runnable place file (build artifact)         | —             |

Script kinds follow Rojo conventions: `*.server.lua` → Script,
`*.client.lua` → LocalScript, plain `*.lua` → ModuleScript.

### RemoteEvents (`ReplicatedStorage.Remotes`)

Client → server (input requests; the server validates everything):
`RequestAttack`, `RequestThrow`, `RequestDash`, `RequestBlockStart`,
`RequestBlockEnd`

Server → client (replicated state + polish hooks):
`EggPossessionChanged`, `HoldTimeUpdated`, `MatchStateChanged`, `RoundEnded`,
`MatchEnded`, `FeedbackEvent` (VFX/SFX/GUI hook for later polish)

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
- [ ] Combat: attack validation/knockback (knocks the egg loose via
      `EggService.Fumble(victim, "Attacked", popVelocity)`), throw handling,
      block state, dash, stamina
- [ ] Match: state machine, round clock, best-of-3, winners + MVP
- [ ] GUI: HUD (hold-time leaderboard from `HoldTimeUpdated`, stamina,
      ability buttons for mobile)
- [ ] Data: persistence
- [ ] Polish: egg mesh, VFX/SFX via `FeedbackEvent` hooks; line-of-sight
      check for the proximity pickup scan
