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

## Current status: Tasks 6-7 — ECONOMY, BOTS, MATCHMAKING, ANTI-CHEAT are LIVE

Open **[`ClutchTheEgg.rbxlx`](ClutchTheEgg.rbxlx)** in Roblox Studio and just
press **F5** — a **lone player now starts a match against 5 AI bots** after a
short lobby grace. The GUI is minimal by request: no full-screen menus, just
the always-on HUD, a small collapsible **CONTROLS** panel on the right, a
**HATCHERY** button, results panels and settings. The server runs:

```
Lobby (1+ human; bots fill to 6 after grace) -> Countdown (3..2..1)
  -> RoundPlaying (75s) -> RoundEnd (4s) -> x3 rounds
  -> MatchEnd (MVP + standings + Clout/Fragment rewards, 8s) -> Lobby ...
```

Meta layer (all persisted): **Clout** + **Egg Fragments** awarded per match,
**Hatchery** (buy eggs / convert 10 fragments / hatch timed eggs into
**pets** with rarity + size + mutation), **pity** guaranteed-rare egg after
10 winless matches, **ELO** matchmaking deltas, lifetime hold time — see the
sections below.

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

Space is pure jump again. The in-game GUI ability buttons (ATTACK / THROW /
BLOCK / DASH) call `_G.CTEInput.Attack() / .Throw() / .Dash() / .Block(bool)`
— the same path as the keyboard, so the server stays the single authority.
(Sprint remains keyboard/gamepad-only for now.)

### GUI (`StarterGui.CTEGui`)

One `ScreenGui` (**`ResetOnSpawn = false`**) holds a `GuiMain` LocalScript
plus five ModuleScripts. Everything is built in code with `UiKit`, uses
**Scale-only sizing + `TextScaled`** (mobile-friendly — no offsets), and is
styled from a single `UiKit.Theme` table so the later restyle is one file.

| Screen | What it shows | Driven by |
| --- | --- | --- |
| **HUD** (always on) | Big center-top round timer + `Round 1/3` + lobby status line, 3-2-1-GO countdown overlay, 6-row hold-time board (players AND bots, sorted desc, relative fill bars, gold highlight + `(you)` for the carrier), stamina bar (red under 25%), steal/grip/event feed | `MatchStateChanged` ticks, `HoldTimeUpdated`, `EggPossessionChanged`, `Stamina` attribute |
| **Controls panel** | Small collapsible key/action list parked mid-right — the ONLY lobby furniture (no full-screen menus); auto-collapses when the countdown starts | static (`Config` keybinds) |
| **Ability buttons** | ATTACK / THROW / BLOCK(hold) / DASH → `_G.CTEInput`; contextual greys: *Hands Full* (attack while carrying), *Need Egg* (throw without), *No Stamina* (dash below carry-aware cost); cooldown wipe overlay from success feedback (`PunchSwing`, `DashStart`) so keyboard users see it too | `HasEgg`/`Stamina` attributes, `FeedbackEvent`, `Config` cooldowns (display only) |
| **Hatchery panel** | Wallet (Clout / Fragments / pity progress), BUY EGG + CONVERT buttons, egg hatch countdowns → OPEN, rarity-colored pet collection with grip% + EQUIP | `HatcheryUpdated` snapshots; actions via `HatcheryRequest` (server validates) |
| **Round end** | Winner line (or tie / no-winner) + ranked rows: round time, match total, rounds won; winner row gold | `RoundEnded` payload |
| **Match end** | ★ MVP banner (bots can win it!), final standings (incl. `left` ghosts), PLAY AGAIN / BACK TO LOBBY buttons (close the panel — server flow is automatic) | `MatchEnded` payload |
| **Rewards toast** | "+X Clout, +Y Fragments (rank #N)", MVP bonus, pity-egg announcements | `MatchRewards` (personal) |
| **Settings** | Mute toggle (sets `SoundService.Volume`), sensitivity stepper (**placeholder** → `_G.CTESettings`), opens from the HUD SET button | — |

**No game logic lives in the GUI** — it only renders remote/attribute state
and forwards button presses through `_G.CTEInput`. **Late joiners** are
resynced by the server: `MatchService.resyncPlayer` re-fires the current
state (+ live round `TimeLeft`) to each joining player 2s after join, and
`EggService` re-broadcasts hold times on the next bind.

### Economy & persistence (Tasks 6)

**DataService** (`ServerScriptService.DataService`) — pcall-wrapped
DataStore (`CTE_PlayerData_v1`, key `Player_<UserId>`) with load retries,
save retries, 60s auto-save, save on leave + `BindToClose`. Failed loads
give a **temporary** in-memory profile (playable, never saved over real
data). Studio runs in memory mode by default
(`Config.Data.UseRealStoreInStudio = false`) — profiles still persist across
rejoins inside the session, so the whole flow is testable unpublished.
Stores: Clout, Fragments, ELO, pets, eggs (+ hatch timers), pity counter,
lifetime hold time, matches/round-wins/MVPs. **leaderstats** shows
`Clout`, `Frags` and the equipped `Pet` on the stock leaderboard.

**EconomyService** — awards every completed match (real players only):

| Source | Clout |
| --- | --- |
| Participation | +25 |
| Hold time | +1 / second (match total) |
| Knockdowns (punches that hit) | +5 each (capped 40) |
| Steals (punch-steal or dash-fumble) | +8 each (capped 40) |
| Round win | +30 each |
| MVP | +100 |

**Fragments by final rank:** 1st→5, 2nd→4, 3rd→3, 4th/5th→2, 6th→1 (never
zero). Knockdowns/steals are counted from the server-side `ServerFeedback`
BindableEvent mirror — gameplay code doesn't know the economy exists.
**Pity:** 10 matches without a round win → the next win instantly grants a
**guaranteed-rare egg** (counter tracked in data). Rewards arrive per-player
over the `MatchRewards` remote (GUI toast + Output print).

### Hatchery & pets

**HatcheryService** — everything server-validated via the `HatcheryRequest`
remote (`"BuyEgg"`, `"ConvertFragments"`, `"OpenEgg" <id>`, `"EquipPet" <id>`,
`"Refresh"`); the client only ever receives an `HatcheryUpdated` snapshot.

* Buy an egg for **250 Clout**, or convert **10 fragments** → 1 egg.
* Eggs hatch after **45s** (`Config.Economy.HatchTimeSeconds`); OPEN rolls a
  pet: **rarity** (Common 60 / Rare 25 / Epic 10 / Legendary 4 / Mythic 1),
  **size** (Small→Giant), **10% mutation chance** (Golden/Neon/Void/Rainbow/
  Crystal). Pity eggs roll from the rare-and-up table.
* **Pets are not pay-to-win:** the single equipped pet grants only a tiny
  **capped grip bonus** — a % chance (Common 0.5 → Mythic 3, hard cap 3) to
  HOLD ON when a punch would knock the egg loose (`CombatService.AttemptSteal`,
  fires the `GripSave` feedback). Plus flex value: equipped pet shows in
  leaderstats and the hatch toast. Trading comes later.

### Bots (Task 7)

`BotService` builds **code-only R6 rigs** (no Toolbox assets — smiley face
included) in `Workspace.Bots`, registered through the dependency-free
**BotRegistry** so Egg/Combat/Scoring treat bots as normal participants:
they touch the egg to grab it, accrue hold time, appear on the HUD board as
`Name (bot)`, can win rounds and even be **MVP** (they earn no currency).

AI (all in `Config.Bots`, toggle `Enabled`): seek the loose egg → carry &
roam to random spots (re-targeting every 3s) → sometimes **throw** when
hunted → hunt the carrier (55% commitment per decision) → **punch** in range
off cooldown. Beatable: WalkSpeed 14 (vs 16), punch cooldown 1.1s (vs 0.6),
softer knockback, 0.35s reaction time, stagger when hit. Knocked out of the
arena → auto-respawn on the ring. A **lone player starts a match and gets 5
bots** after the lobby grace (8s; private servers 3s).

### Matchmaking (ELO queue)

Every profile carries an **ELO** (default 1000). When more than 6 humans
wait, `MatchmakingService` seeds the queue with the longest waiter and
selects the 6 closest ELOs inside a window that **widens over time**
(150 + 25/s up to 1000, forced after 20s); the rest spectate (they cannot
touch the egg or be hit — `BotRegistry.SetAllowedFilter`) and play next
match. After each match, rank deltas `{+25,+12,+4,-4,-12,-20}` are applied
(bots excluded) and saved. ≤6 players (the normal case) → everyone plays and
bots fill the rest.

### Anti-cheat

* **Ability validation** (already in CombatService, restated): every
  Request* handler ignores client arguments, re-checks context/cooldown/
  stamina/stun, and computes hits from **server positions only** —
  impossible attack ranges simply whiff.
* **Speed-hack detection** (`AntiCheatService`): 10 Hz horizontal position
  sampling against the max legitimate speed
  (Walk 16 + Sprint 6 + Dash 24 + tolerance 10 = 56 studs/s); jumps and
  server knockback stay under the cap, spawns get 2s grace. Exceeding it for
  **3 consecutive samples** → teleport back to the last valid position +
  logged `[AntiCheat]` warning + strike. **Remote spam** (>15 ability
  requests/s) → strike. **5 strikes → kick.**

### Private servers

`game.PrivateServerId ~= ""` (and `Config.PrivateServers.Enabled`): matches
start with **1 human** after a 3s grace, bots fill to 6 — friends can jump
in while the lobby waits. Everything else behaves identically.

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
game.ReplicatedStorage.Remotes.DebugCommand:FireServer("state")           -- FULL dump: match/egg/combat/score/bots/data/econ/hatchery/queue/anticheat
game.ReplicatedStorage.Remotes.DebugCommand:FireServer("grantegg")        -- free mystery egg (hatchery)
game.ReplicatedStorage.Remotes.DebugCommand:FireServer("grantegg", "rare")-- free GUARANTEED-RARE egg (pity test)
game.ReplicatedStorage.Remotes.DebugCommand:FireServer("clout", "1000")   -- add Clout
game.ReplicatedStorage.Remotes.DebugCommand:FireServer("frags", "10")     -- add fragments
game.ReplicatedStorage.Remotes.DebugCommand:FireServer("hatchnow")        -- finish all your hatch timers
```

**Solo checklist (plain F5 — the Task-7 deliverable):**

1. One player, press F5 → lobby status "Waiting for players… bots fill empty
   slots" → after ~8s countdown → **5 color-coded R6 bots** spawn on the ring.
2. Bots chase the egg, grab it (board shows `Name (bot)` with gold highlight),
   roam, sometimes throw it, hunt the carrier and punch you (softer/slower
   than players). Beat them up and they stagger.
3. Match runs the normal 3 rounds; bots appear in round/match standings and
   can even be MVP; `DebugCommand "state"` shows the `bots=` line.
4. Match end → rewards toast "**+X Clout, +Y Fragments (rank #N)**",
   leaderstats update, Output shows the `[Economy]` breakdown.

**Economy/hatchery checklist:**

1. `DebugCommand "frags", "10"` → HATCHERY → **CONVERT 10 FRAGMENTS** → egg
   appears with a 45s countdown (`"hatchnow"` finishes it) → **OPEN** →
   "You hatched …" toast, pet listed with rarity color + grip%.
2. `DebugCommand "clout", "1000"` → **BUY EGG — 250 CLOUT** deducts exactly.
3. EQUIP a pet → leaderstats `Pet` stat updates; punching YOU while you
   carry the egg can now fire "**X's pet GRIPPED the egg!**" (tiny % — use
   `grantegg rare` + hatch + equip to see it sooner).
4. Pity: `DebugCommand "grantegg", "rare"` simulates the pity reward; the
   real counter (`Pity: n/10` in the hatchery wallet) bumps each winless
   match and grants the rare egg on your next round win.
5. **Persistence:** leave and rejoin the same Studio session → Clout /
   fragments / pets / pity are all still there (memory store; real DataStore
   in production once published with API access enabled).

**Anti-cheat checklist:**

1. Normal play never triggers anything (jumps, dashes, knockback all stay
   under the 56 studs/s cap; spawns get 2s grace).
2. Spam abilities via script (`RequestAttack:FireServer()` in a loop) →
   `[AntiCheat] ability spam` warnings → strikes → kick at 5.
3. Speed hacks: any client moving >56 studs/s horizontally for 3+ samples
   gets teleported back with a logged strike.

**2-player checklist (Local Server, 2 players, `DebugQuickMatch = true`):**

1. Both join → countdown → round 1 starts with **4 bots filling the arena**
   (`Config.Bots.FillToMaxPlayers`; set `Config.Bots.Enabled = false` for
   humans-only legacy mode).
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

**GUI checklist (same session, look at either client):**

1. No full-screen menus: the idle HUD + small **CONTROLS** panel (right
   side, collapsible) + **HATCHERY**/**SET** buttons are all that show in
   the lobby; controls auto-collapse when the countdown starts.
2. Countdown → big **3…2…1…GO!** overlay; round starts → center-top timer
   counts down, `Round 1/3` label correct; board lists all 6 participants
   including `Name (bot)` rows.
3. Grab the egg → your row highlights gold on **both** clients, timer rows
   sort by hold time, ATTACK greys to *Hands Full* for the carrier while
   THROW greys to *Need Egg* for everyone else.
4. Steal → feed shows "**X stole the egg from Y!**"; punch/dash buttons show
   the cooldown wipe when used; stamina bar drains on sprint/dash and DASH
   greys to *No Stamina* when it dips below cost.
5. Round expires → round-end panel with winner + ranked times; next round
   replaces it. After round 3 → match-end panel with ★ MVP banner, final
   standings (ghost leavers tagged `left`), PLAY AGAIN / BACK TO LOBBY.
6. **Mobile:** Test → Local Server → device emulator (or Emulator → phone
   preset) → everything stays on-screen and tappable; the four ability
   buttons fire real attacks/throws/blocks/dashes.

### Remote payload contracts (server → all clients)

| Remote | Payload |
| --- | --- |
| `MatchStateChanged` | `(stateName, data)` — states: `"Lobby"` `{Players, MinPlayersToStart, MaxPlayers, BotsEnabled, PrivateServer, GraceSeconds}`, `"Countdown"` `{StartsIn}` (0 = GO), `"RoundPlaying"` `{Round, RoundsPerMatch, RoundLength?, TimeLeft}` (~1 Hz clock), `"RoundEnd"` `{Round, WinnerName?, NextRoundIn}`, `"MatchEnd"` `{MVPNames, BestTotalHoldTime, NextLobbyIn}` |
| `RoundEnded` | `(roundNumber, results)` — `results = {WinnerPlayer?, WinnerName?, Tied, TopTime, Entries = {{Player, Name, UserId, RoundTime, MatchTime, RoundsWon, IsWinner?}} sorted}` (`Player` may be a bot Model) |
| `MatchEnded` | `(final)` — `{Standings = {{Player?, Name, UserId, TotalHoldTime, RoundsWon, Left, IsMVP?}}, MVPs, MVPNames, BestTotalHoldTime}` (bots have negative fake `UserId`s) |
| `MatchRewards` | personal `(rewards)` — `{Rank, Clout, Fragments, NewClout, NewFragments, Knockdowns, Steals, HoldSeconds, RoundsWon, IsMVP, PityEgg, EggGranted, PityProgress}` |
| `HatcheryUpdated` | personal `(snapshot)` — `{Clout, Fragments, Elo, LifetimeHoldTime, MatchesPlayed, RoundWins, MVPs, PityProgress, Eggs = {{Id, Source, GuaranteedRare, UnlocksAt}}, Pets = {{Id, Name, Species, Rarity, Size, Mutation?, GripBonus}}, EquippedPetId, StoreOK, Now}` |
| `EggPossessionChanged` | `(newCarrier?, previousCarrier?)` — Player OR bot Model |
| `HoldTimeUpdated` | `(entries)` — array of `{Player, HoldTime}` (match-scoped live feed), sorted desc, ~10 Hz while carried; `Player` may be a bot Model |
| `FeedbackEvent` | `(kind, data)` — see catalog below |

Client → server: `RequestAttack`, `RequestThrow`, `RequestDash`,
`RequestBlockStart`, `RequestBlockEnd`, `RequestSprintStart`,
`RequestSprintEnd` (all **argument-free**, server computes everything), plus
`HatcheryRequest` (`action`, `id?` — see Hatchery section).
`DebugCommand` (`command`, `argument?`) is Studio-gated.

`FeedbackEvent` kind catalog — world (FireAllClients): `PunchSwing`,
`PunchHit` (`Result` = Hit/Blocked/IFramed), `BlockedHit`, `IFrameDodge`,
`EggStolen`, `GripSave` (pet held on!), `EggThrown`, `EggImpact`, `DashStart`
(`Carrying`), `DashFumble`, `BlockStart`, `BlockEnd`, `BlockBroken`,
`SprintStart`, `SprintEnd`, `EggPickup`, `EggFumble` (`Reason`),
`EggOutOfBounds`, `EggRespawn`. (`Player`/`Attacker`/`Victim` may be bot
Models.) Personal (FireClient): `HandsFull`, `NotCarrying`, `NoStamina`,
`OnCooldown`, `Stunned`, `PunchWhiff`, `Exhausted`, `GripSave`,
`PetHatched` (`{Pet}`), `EggGranted` (`{Egg}`), `NotEnoughClout`,
`NotEnoughFragments`, `EggNotReady`, `DataNotReady`.

### Service APIs (server)

*MatchService:* `Init()`, `GetState()`, `GetRound()`,
`SetMatchStartHandler(fn)`, `SetMatchEndHandler(fn)` (Main injects the
economy hooks), `DebugState()`.

*ScoringService:* `Init()`, `StartRound()`, `EndRound()` → ranked results,
`GetFinalStandings()`, `ResetMatch()`, `GetRoundTime(p)`, `GetMatchTime(p)`,
`GetRoundsWon(p)`, `DebugState()`. Scores players AND bots.

*EggService:* `Init()`, `StartRound()`, `EndRound()`, `SetEnabled(bool)`,
`IsEnabled()`, `GetCarrier()` (Player OR bot Model), `GetEgg()`, `GetState()`,
`GetHoldTime(p)`, `GetHoldTimes()`, `ResetHoldTimes()`,
`Fumble(target?, reason?, popVelocity?)`, `ReleaseThrow(entity, direction)`,
`RespawnEggNow()`, `IsEggHot()`, `GetThrower()`, `SetImpactHandler(fn)`,
`DebugState()`.

*CombatService:* `Init()`, `ApplyKnockback(player, dir, force, upForce?,
stunTime?)` → `"Hit"/"Blocked"/"IFramed"/"Invalid"`,
`AttemptSteal(attacker, victim, pushDir)` (grip roll + fumble + `EggStolen`;
used by player AND bot punches), `HandleEggImpact(p, v)`, `GetStamina(p)`,
`IsBlocking(p)`, `IsSprinting(p)`, `IsDashing(p)`, `HasIFrames(p)`,
`IsStunned(p)`, `DebugState()`.

*DataService:* `Init()`, `OnProfileReady(fn)`, `GetProfile(p)`, `IsLoaded(p)`,
`Get(p, key, default)`, `Set(p, key, value)`, `AddNumeric(p, key, n)`,
`AddClout(p, n)`, `AddFragments(p, n)`, `GetElo(p)`, `SetElo(p, elo)`,
`AddLifetimeHold(p, s)`, `GetSnapshot(p)`, `Save(p)`, `SaveAll()`,
`DebugState()`.

*EconomyService:* `Init()`, `ResetMatchStats()`, `SettleMatch(final)`,
`DebugState()`.

*HatcheryService:* `Init()`, `GrantEgg(p, source, guaranteedRare?)`,
`SendSnapshot(p)`, `GetGripBonus(entity)`, `GetEquippedPet(p)`,
`DebugState()`.

*BotService:* `Init()`, `SpawnBots(count)` → models, `DespawnAll()`,
`GetBots()`, `IsStunned(model)`, `DebugState()`.

*BotRegistry (dependency-free roster):* `Register/Unregister(model)`,
`IsBot(x)`, `GetBots()`, `CountBots()`, `GetParticipants()`,
`IsParticipant(x)`, `GetCharacter(x)`, `GetUserId(x)`,
`GetBotFromCharacter(model)`, `SetAllowedFilter(fn)`,
`SetKnockHandler(fn)`, `KnockbackBot(model, dir, force, up?, stun?)`.

*MatchmakingService:* `Init()`, `SelectParticipants(candidates, forceReady?)`,
`SettleMatch(final)`, `GetQueueInfo()`, `DebugState()`.

*AntiCheatService:* `Init()`, `AllowAbilityRequest(player)` (called by every
CombatService Request handler), `GiveGrace(player, seconds)`,
`GetStrikes(player)`, `DebugState()`.

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
| `src/ServerScriptService/DataService.lua`            | `ServerScriptService.DataService` (**implemented** — persistence + leaderstats) | ModuleScript |
| `src/ServerScriptService/EconomyService.lua`         | `ServerScriptService.EconomyService` (**implemented** — Clout/fragments/pity) | ModuleScript |
| `src/ServerScriptService/HatcheryService.lua`        | `ServerScriptService.HatcheryService` (**implemented** — eggs/pets/grip) | ModuleScript |
| `src/ServerScriptService/BotService.lua`             | `ServerScriptService.BotService` (**implemented** — R6 rig builder + AI) | ModuleScript |
| `src/ServerScriptService/BotRegistry.lua`            | `ServerScriptService.BotRegistry` (dependency-free participant roster) | ModuleScript |
| `src/ServerScriptService/MatchmakingService.lua`     | `ServerScriptService.MatchmakingService` (**implemented** — ELO queue) | ModuleScript |
| `src/ServerScriptService/AntiCheatService.lua`       | `ServerScriptService.AntiCheatService` (**implemented** — speed/spam net) | ModuleScript |
| `src/StarterPlayer/StarterCharacterScripts/ClientInput.client.lua` | `…StarterCharacterScripts.ClientInput` (**implemented**) | LocalScript |
| `src/StarterPlayer/StarterCharacterScripts/Animations.client.lua` | `…StarterCharacterScripts.Animations` (**implemented**) | LocalScript |
| `src/StarterGui/CTEGui/GuiMain.client.lua`           | `StarterGui.CTEGui.GuiMain` (**implemented**)    | LocalScript |
| `src/StarterGui/CTEGui/UiKit.lua`                    | `StarterGui.CTEGui.UiKit` (theme + builders, bot-safe names) | ModuleScript |
| `src/StarterGui/CTEGui/ControlsPanel.lua`            | `StarterGui.CTEGui.ControlsPanel` (small collapsible controls list) | ModuleScript |
| `src/StarterGui/CTEGui/HudScreen.lua`                | `StarterGui.CTEGui.HudScreen`                    | ModuleScript |
| `src/StarterGui/CTEGui/HatcheryPanel.lua`            | `StarterGui.CTEGui.HatcheryPanel` (buy/convert/hatch/equip) | ModuleScript |
| `src/StarterGui/CTEGui/ResultsScreens.lua`           | `StarterGui.CTEGui.ResultsScreens`               | ModuleScript |
| `src/StarterGui/CTEGui/SettingsPanel.lua`            | `StarterGui.CTEGui.SettingsPanel`                | ModuleScript |
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
- [x] GUI (Task 5): lobby screen, HUD (round clock, hold-time board, ability
      buttons with contextual states + cooldown wipes, stamina bar, steal
      feed), round/match results screens, settings panel — all remote-driven,
      Scale-only, mobile-friendly
- [x] Data + economy (Task 6): DataService persistence (Clout, fragments,
      pets, pity, ELO, lifetime hold), match rewards, Hatchery
      (buy/convert/hatch/equip), pets with tiny capped grip bonus,
      leaderstats
- [x] Production (Task 7): AI bots filling empty slots (solo → 5 bots),
      ELO matchmaking queue with widening range, anti-cheat (speed sampling
      + teleport-back + strikes/kick, remote rate limiting, server-computed
      attack ranges), private-server support; GUI slimmed to the always-on
      HUD + small controls panel (no full-screen lobby)
- [ ] Trading pets between players
- [ ] Real DataStore rollout: publish + enable Studio API access, consider
      ProfileService/session-locking for multi-server safety
- [ ] Polish: egg mesh, bot animations, VFX/SFX via `FeedbackEvent` hooks,
      upload animations into `Config.Animations`, line-of-sight for proximity
      pickup, team mode + catching, 2v2v2
