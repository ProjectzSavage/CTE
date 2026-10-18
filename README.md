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
egg), **Sprint** (hold — the main stamina drain). If the egg leaves the arena
it respawns at the center after 3 seconds and hold time pauses.

---

## Current status: Task 4 — FULL MATCH LOOP is LIVE

Open **[`ClutchTheEgg.rbxlx`](ClutchTheEgg.rbxlx)** in Roblox Studio, press
**Test → Local Server → 2 players** (a match needs 2+; solo F5 waits in the
lobby by design). The server runs:

```
Lobby (2+ of 6 players) -> Countdown (3..2..1) -> RoundPlaying (75s)
  -> RoundEnd (winner announced, 4s) -> x3 rounds
  -> MatchEnd (MVP + final standings, 8s) -> Lobby ...
```

Round winners, per-round standings, the MVP and final standings are **printed
to the server Output** and fired over `RoundEnded` / `MatchEnded` /
`MatchStateChanged` remotes for the future GUI.

**Fast testing:** set `Config.DebugQuickMatch = true` → 15-second rounds
(a full 3-round match takes ~1 minute instead of ~4.5).

### Controls

| Ability | Keyboard / Mouse | Gamepad | Mobile |
| --- | --- | --- | --- |
| Attack (not carrying only) | **Left Mouse** | X | CAS touch button (placeholder) |
| Throw (carrying only) | **Q** or **F** | Y | CAS touch button (placeholder) |
| Block (hold) | **Right Mouse** | L1 | CAS touch button (placeholder) |
| Dash | **E** | R1 | CAS touch button (placeholder) |
| Sprint (hold — drains stamina) | **Left Shift** | R2 | CAS touch button (placeholder) |

Space is pure jump again. The real mobile GUI comes later and should call
`_G.CTEInput.Attack() / .Throw() / .Dash() / .Block(bool) / .Sprint(bool)`.

### Animations (wired, awaiting assets)

`StarterCharacterScripts.Animations` plays character animations from
**`Config.Animations`** — upload animations via the Creator Dashboard and
paste the `rbxassetid://...` URLs into the matching slots (`Dash`, `Attack`,
`Throw`, `Block` loop, `Sprint` loop, `Carry` loop). Empty string = skipped
silently, so everything runs before any asset exists. Triggers are the
`FeedbackEvent` kinds listed below plus the replicated `HasEgg` attribute.

### Match / scoring rules implemented

* Lobby starts the countdown at `MinPlayersToStart` (2) players, cap 6.
  Countdown aborts back to Lobby if players drop below the minimum.
* Hold time accrues per-round for the current carrier at 10 Hz
  (ScoringService); it **pauses automatically while the egg is loose or
  respawning** (no carrier). A carrier at the **exact expiry keeps their
  partial-second time** (scoring settles before the egg is parked).
* Round winner = most round hold time (exact ties share the win; an all-zero
  round has no winner). Round times clear each round; **match totals persist**.
* After 3 rounds: **MVP = highest total match hold time** (ties shared;
  only players still in the server are MVP-eligible).
* **Leavers:** leaving fumbles the egg (EggService); their match totals
  become "ghost" standings entries (`Player = nil`, `Left = true`) so the
  final standings stay complete; the in-progress round partial is forfeited.
* Egg out of bounds mid-round: unchanged EggService behavior — hold time
  pauses, egg respawns at center after 3 s, the round keeps running.
* Pickups are gated to `RoundPlaying` only (`EggService.SetEnabled`); between
  rounds the egg sits visible at center but cannot be grabbed.

### Sprint & stamina

Sprint (hold Shift) adds `SprintSpeedBonus` (6) to base speed — even while
carrying — and drains `SprintStaminaDrain` (12/s). Blocking, stun and dash
suppress sprinting. At 0 stamina you're **exhausted** until stamina recovers
to `SprintResumeStamina` (25). Block drains 15/s and breaks at 0. Dash costs
25 (30 carrying), attack 10. Regen is 20/s starting 0.75 s after any spend.
The rounded value is published as the replicated **`Stamina` player
attribute** for the future HUD.

### Testing in Studio (command bar)

> The command bar runs in **client context** while playing, so use the
> Studio-only `DebugCommand` remote (ServerScriptService is invisible there):

```lua
game.ReplicatedStorage.Remotes.DebugCommand:FireServer("fumble")          -- drop current carrier's egg
game.ReplicatedStorage.Remotes.DebugCommand:FireServer("respawn_egg")     -- force center respawn
game.ReplicatedStorage.Remotes.DebugCommand:FireServer("state")           -- match/egg/combat/score dump
```

**2-player checklist (Local Server, 2 players, `DebugQuickMatch = true`):**

1. Both join → countdown → round 1 starts, egg drops at center.
2. Grab/steal/throw/dash-fumble as before; hold times accrue for whoever
   carries (`DebugCommand "state"` shows round/match totals live).
3. Round expires → Output prints winner + per-player standings;
   `RoundEnded` fires; egg resets to center; pickups locked during the pause.
4. After 3 rounds → Output prints **MVP + final standings**; `MatchEnded`
   fires; intermission; back to Lobby.
5. Mid-round, close one client → remaining player's round continues, leaver
   shows as `left match` in the final standings.
6. Sprint with Shift → faster, stamina drops; hold until 0 → `Exhausted`,
   walk speed back to normal, regen resumes.

### Remote payload contracts (server → all clients)

| Remote | Payload |
| --- | --- |
| `MatchStateChanged` | `(stateName, data)` — states: `"Lobby"` `{Players, MinPlayersToStart, MaxPlayers}`, `"Countdown"` `{StartsIn}` (0 = GO), `"RoundPlaying"` `{Round, RoundsPerMatch, RoundLength?, TimeLeft}` (~1 Hz clock), `"RoundEnd"` `{Round, WinnerName?, NextRoundIn}`, `"MatchEnd"` `{MVPNames, BestTotalHoldTime, NextLobbyIn}` |
| `RoundEnded` | `(roundNumber, results)` — `results = {WinnerPlayer?, WinnerName?, Tied, TopTime, Entries = {{Player, Name, UserId, RoundTime, MatchTime, RoundsWon, IsWinner?}} sorted}` |
| `MatchEnded` | `(final)` — `{Standings = {{Player?, Name, UserId, TotalHoldTime, RoundsWon, Left, IsMVP?}}, MVPs, MVPNames, BestTotalHoldTime}` |
| `EggPossessionChanged` | `(newCarrier: Player?, previousCarrier: Player?)` |
| `HoldTimeUpdated` | `(entries)` — array of `{Player, HoldTime}` (match-scoped live feed), sorted desc, ~10 Hz while carried |
| `FeedbackEvent` | `(kind, data)` — see catalog below |

Client → server (all **argument-free**, server computes everything):
`RequestAttack`, `RequestThrow`, `RequestDash`, `RequestBlockStart`,
`RequestBlockEnd`, `RequestSprintStart`, `RequestSprintEnd`.
`DebugCommand` (`command`, `playerName?`) is Studio-gated.

`FeedbackEvent` kind catalog — world (FireAllClients): `PunchSwing`,
`PunchHit` (`Result` = Hit/Blocked/IFramed), `BlockedHit`, `IFrameDodge`,
`EggStolen`, `EggThrown`, `EggImpact`, `DashStart` (`Carrying`), `DashFumble`,
`BlockStart`, `BlockEnd`, `BlockBroken`, `SprintStart`, `SprintEnd`,
`EggPickup`, `EggFumble` (`Reason`), `EggOutOfBounds`, `EggRespawn`.
Personal (FireClient): `HandsFull`, `NotCarrying`, `NoStamina`, `OnCooldown`,
`Stunned`, `PunchWhiff`, `Exhausted`.

### Service APIs (server)

*MatchService:* `Init()`, `GetState()`, `GetRound()`, `DebugState()`.

*ScoringService:* `Init()`, `StartRound()`, `EndRound()` → ranked results,
`GetFinalStandings()`, `ResetMatch()`, `GetRoundTime(p)`, `GetMatchTime(p)`,
`GetRoundsWon(p)`, `DebugState()`.

*EggService:* `Init()`, `StartRound()`, `EndRound()`, `SetEnabled(bool)`,
`IsEnabled()`, `GetCarrier()`, `GetEgg()`, `GetState()`, `GetHoldTime(p)`,
`GetHoldTimes()`, `ResetHoldTimes()`, `Fumble(target?, reason?, popVelocity?)`,
`ReleaseThrow(player, direction)`, `RespawnEggNow()`, `IsEggHot()`,
`GetThrower()`, `SetImpactHandler(fn)`, `DebugState()`.

*CombatService:* `Init()`, `ApplyKnockback(player, dir, force, upForce?,
stunTime?)` → `"Hit"/"Blocked"/"IFramed"/"Invalid"`, `HandleEggImpact(p, v)`,
`GetStamina(p)`, `IsBlocking(p)`, `IsSprinting(p)`, `IsDashing(p)`,
`HasIFrames(p)`, `IsStunned(p)`, `DebugState()`.

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
| `src/ServerScriptService/MatchService.lua`           | `ServerScriptService.MatchService` (**implemented**) | ModuleScript |
| `src/ServerScriptService/EggService.lua`             | `ServerScriptService.EggService` (**implemented**) | ModuleScript |
| `src/ServerScriptService/CombatService.lua`          | `ServerScriptService.CombatService` (**implemented**) | ModuleScript |
| `src/ServerScriptService/ScoringService.lua`         | `ServerScriptService.ScoringService` (**implemented**) | ModuleScript |
| `src/ServerScriptService/DataService.lua`            | `ServerScriptService.DataService` (reserved)     | ModuleScript  |
| `src/StarterPlayer/StarterCharacterScripts/ClientInput.client.lua` | `…StarterCharacterScripts.ClientInput` (**implemented**) | LocalScript |
| `src/StarterPlayer/StarterCharacterScripts/Animations.client.lua` | `…StarterCharacterScripts.Animations` (**implemented**) | LocalScript |
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

- [x] Egg system (Task 2)
- [x] Combat: attack/throw/block/dash + stamina (Task 3)
- [x] Match: lobby → countdown → 3×75 s rounds → MVP + standings; scoring
      bookkeeping; sprint stamina sink; E/Shift rebinds; animation wiring
      (Task 4)
- [ ] GUI: HUD — round clock + state (`MatchStateChanged`), hold-time
      leaderboard (`HoldTimeUpdated`), round/match results screens
      (`RoundEnded`/`MatchEnded`), stamina bar (`Stamina` attribute), real
      mobile buttons (`_G.CTEInput`), feedback toasts (`FeedbackEvent`)
- [ ] Data: persistence (wins, MVPs) via DataService
- [ ] Polish: egg mesh, VFX/SFX via `FeedbackEvent` hooks, upload animations
      into `Config.Animations`, line-of-sight for proximity pickup, team mode
      + catching
