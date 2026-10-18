============================================================
CLUTCH THE EGG -- FINAL PROJECT README (Task 8)
============================================================
This text lives in ReplicatedStorage.Modules.GameREADME (StringValue) and is
printed to the Output on server boot, followed by a LIVE dump of every
Config value (so the config list can never go stale). Repo docs: README.md.

6-player physics party brawler. Touch the egg to grab it; carrying accrues
HOLD TIME. Best of 3 rounds x 75s. Round winner = most hold time. Match MVP
= most total hold time. Egg out of arena -> respawns at center after 3s
(hold time pauses while loose). Bots fill empty slots (solo -> 5 bots).

------------------------------------------------------------
1. SYSTEMS
------------------------------------------------------------
SERVER (ServerScriptService):
  Main              bootstrap: ServerFeedback bindable, remote checks,
                    service init order, cross-wiring, debug bridges,
                    prints THIS readme + live Config dump
  DataService       persistence (Clout, Fragments, ELO, pets, eggs, pity,
                    lifetime hold, leaderstats). pcall+retries, 60s
                    autosave, save-on-leave, BindToClose, temporary-profile
                    fallback, Studio memory mode
  EggService        spawn/auto-pickup/carry/hold-time ticker/fumble/hot
                    throw/OOB respawn; gates via SetEnabled
  CombatService     Attack/Throw/Block/Dash/Sprint + stamina; sole
                    WalkSpeed authority; AttemptSteal (pet grip roll);
                    anti-cheat rate limiting on every request
  ScoringService    10Hz hold accumulation, round winners (ties shared),
                    match totals, MVP, leaver ghosts; scores bots too
  MatchService      Lobby -> Countdown -> 3x RoundPlaying -> RoundEnd ->
                    MatchEnd loop; bot fill; private servers; late-joiner
                    resync; fires RoundStart/RoundEnd/MatchEnd feedback
  EconomyService    per-match Clout + fragments + pity (ServerFeedback
                    listener); MatchRewards remote
  HatcheryService   BuyEgg / ConvertFragments / OpenEgg / EquipPet (all
                    server-validated); pet rolls; grip bonus; snapshots
  BotService        code-built R6 rigs in Workspace.Bots + AI (seek egg,
                    roam, sometimes throw, hunt, punch); beatable tuning
  BotRegistry       dependency-free participant roster (players+bots),
                    knock handler, match roster filter
  MatchmakingService ELO queue: seed=longest waiter, widening window,
                    post-match rank deltas saved to data
  AntiCheatService  10Hz horizontal speed sampling -> teleport back +
                    strikes; remote spam limiter; 5 strikes -> kick
CLIENT:
  StarterCharacterScripts.ClientInput   keybinds -> Request* remotes;
                                        _G.CTEInput API for GUI buttons
  StarterCharacterScripts.Animations    FeedbackEvent-driven; IDs from
                                        Config.Animations (empty = skipped)
  StarterPlayerScripts.CameraController smooth native follow + damped FOV
                                        (carry zoom-out, sprint kick) +
                                        shake (_G.CTECamera.AddShake)
  StarterPlayerScripts.VFXBridge        THE polish file: PlayPunchVFX /
                                        PlayStealVFX / PlayCrackVFX /
                                        ScreenShake stubs + event routing
  StarterGui.CTEGui.GuiMain             builds + routes the code GUI
                                        (hierarchies in section 8 if you
                                        rebuild it manually)

------------------------------------------------------------
2. REMOTEEVENTS (ReplicatedStorage.Remotes) -- 17 total
------------------------------------------------------------
CLIENT -> SERVER (all argument-free; server computes targets/directions):
  RequestAttack / RequestThrow / RequestDash
  RequestBlockStart / RequestBlockEnd
  RequestSprintStart / RequestSprintEnd
  HatcheryRequest (action, id?)   actions: "BuyEgg" | "ConvertFragments"
                    | "OpenEgg" <eggId> | "EquipPet" <petId> | "Refresh"
  DebugCommand (command, argument?)  Studio-gated. Commands: fumble
                    [name] | respawn_egg | state | grantegg ["rare"] |
                    clout [n] | frags [n] | hatchnow
SERVER -> CLIENT:
  MatchStateChanged (stateName, data)
    Lobby        {Players, MinPlayersToStart, MaxPlayers, BotsEnabled,
                  PrivateServer, GraceSeconds}
    Countdown    {StartsIn}            (0 = GO)
    RoundPlaying {Round, RoundsPerMatch, RoundLength?, TimeLeft}  ~1Hz
    RoundEnd     {Round, WinnerName?, NextRoundIn}
    MatchEnd     {MVPNames, BestTotalHoldTime, NextLobbyIn}
  RoundEnded (roundNumber, results)
    results = {WinnerPlayer?, WinnerName?, Tied, TopTime, Entries}
    Entries = {{Player, Name, UserId, RoundTime, MatchTime, RoundsWon,
               IsWinner?}} sorted RoundTime desc (Player may be bot Model)
  MatchEnded (final)
    final = {Standings, MVPs, MVPNames, BestTotalHoldTime}
    Standings = {{Player?, Name, UserId, TotalHoldTime, RoundsWon, Left,
                 IsMVP?}} (Player nil = ghost leaver; bots have negative
                 fake UserIds)
  EggPossessionChanged (newCarrier?, previousCarrier?)  Player|bot Model
  HoldTimeUpdated (entries)  {{Player, HoldTime}} sorted desc ~10Hz while
                 carried (Player may be bot Model)
  MatchRewards (rewards)  PERSONAL: {Rank, Clout, Fragments, NewClout,
                 NewFragments, Knockdowns, Steals, HoldSeconds, RoundsWon,
                 IsMVP, PityEgg, EggGranted, PityProgress}
  HatcheryUpdated (snapshot)  PERSONAL: {Clout, Fragments, Elo,
                 LifetimeHoldTime, MatchesPlayed, RoundWins, MVPs,
                 PityProgress{SinceRoundWin,Needed},
                 Eggs{{Id,Source,GuaranteedRare,UnlocksAt}},
                 Pets{{Id,Name,Species,Rarity,Size,Mutation?,GripBonus,
                 CreatedAt}}, EquippedPetId, StoreOK, Now}
  FeedbackEvent (kind, data)  see section 3

------------------------------------------------------------
3. FeedbackEvent CATALOG (the VFX/SFX hook channel)
------------------------------------------------------------
WORLD (FireAllClients). Entity fields may be Players OR bot Models:
  PunchSwing    {Player, Position}          swing succeeded
  PunchHit      {Attacker, Victim, Position, Result}  Result: Hit|Blocked|IFramed
  BlockedHit    {Attacker, Victim, Position}
  IFrameDodge   {Attacker, Victim, Position}
  EggStolen     {Attacker, Victim, Position}  punch knocked egg loose
  GripSave      {Player, Attacker}            pet grip saved the steal
  EggThrown     {Player, Direction, Position} Direction = unit Vector3
  EggFumble     {Player, Reason, Position}    Reason: Attacked|DashCollision|
                Died|CharacterRemoved|Left|RoundStart|RoundEnd|BotDespawned|
                Manual|ForcedRespawn|DebugCommand
  DashStart     {Player, Carrying}
  DashFumble    {Player, Victim, Position}    carrier dashed into someone
  EggImpact     {Player, Position}            hot thrown egg hit someone
  EggPickup     {Player, Position}
  EggOutOfBounds{Position}
  EggRespawn    {Position}
  BlockStart / BlockEnd / BlockBroken {Player}
  SprintStart / SprintEnd {Player}
  RoundStart    {Round, RoundsPerMatch, RoundLength}   NEW in Task 8
  RoundEnd      {Round, WinnerName?, WinnerPlayer?, Tied, TopTime,
                 NextRoundIn}                          NEW in Task 8
  MatchEnd      {MVPNames, MVPs, BestTotalHoldTime, NextLobbyIn} NEW Task 8
PERSONAL (FireClient to involved player only):
  PetHatched    {Pet}                       you opened an egg
  EggGranted    {Egg}                       you received an egg (pity/debug)
  HandsFull / NotCarrying / NoStamina / OnCooldown / Stunned / PunchWhiff
                {Ability}
  Exhausted     {Ability}
  GripSave      {Ability="Grip", ByPet=true}   (personal echo)
  NotEnoughClout / NotEnoughFragments {Need, Have}
  EggNotReady   {ReadyAt}
  DataNotReady  {}
SERVER-SIDE mirror: every Egg/Combat feedback kind also fires
ServerScriptService.ServerFeedback (BindableEvent) for EconomyService.

REPLICATED PLAYER ATTRIBUTES: HasEgg (bool), Stamina (int ~20Hz).
Bot models carry HasEgg + IsBot attributes too.

------------------------------------------------------------
4. CONFIG VALUES (snapshot -- boot log prints the LIVE dump)
------------------------------------------------------------
Match:      MaxPlayers=6 MinPlayersToStart=2 RoundLength=75 RoundsPerMatch=3
            RoundsToWinMatch=2(reserved) RoundStartCountdown=3
            RoundEndFreeze=4 IntermissionLength=8 HoldTimeSyncInterval=0.1
Movement:   WalkSpeed=16 CarrySpeed=12 JumpPower=50
Dash:       SpeedBonus=24 Duration=0.25 Cooldown=2.5 StaminaCost=25 IFrames=0.2
            Carrying: 16/0.15/2.5/30/0; CollisionRadius=4 Knockback=12
            Upward=4 EggDropOnDashCollision=true
Sprint:     SpeedBonus=6 StaminaDrain=12/s ResumeStamina=25
Attack:     Range=5 Knockback=25 Upward=8 Cooldown=0.6 StaminaCost=10
            Hitstun=0.25 FacingDot=0
Throw:      Speed=60 UpwardBias=12 SelfPickupDelay=0.8; hot egg:
            DangerTime=0.8 ImpactMinSpeed=18 ImpactKnockback=14 Upward=6
            Stun=0.15 ImpactPickupDelay=0.5
Block:      KnockbackReduction=0.6 SpeedMultiplier=0.5 StaminaDrain=15/s
Stamina:    Max=100 Regen=20/s Delay=0.75
Egg:        Radius=1 CarryOffsetUp=0.75 Forward=1.5 RespawnDelay=3
            KnockLooseSpeed=20 Upward=10 ProximityPickupRadius=3
            OutOfBoundsY=-40 Horizontal=70 LooseResetRadius=8 FumblePop=4
Arena:      Floor=128 Play=120 WallHeight=5 WallThickness=2 SpawnRadius=48
            SpawnCount=6 EggSpawnHeight=3
Data:       StoreName=CTE_PlayerData_v1 AutoSave=60s LoadRetries=3
            SaveRetries=2 RetryDelay=2s UseRealStoreInStudio=false
Economy:    StartingClout=150 Participation=25 PerHoldSecond=1
            PerKnockdown=5 PerSteal=8 PerRoundWin=30 MVPBonus=100
            Caps: 40 kd/40 steals; FragmentsByRank={5,4,3,2,2,1}
            EggCloutCost=250 EggFragmentCost=10 HatchTime=45s
            PityMatchesWithoutRoundWin=10
Pets:       RarityWeights Common60/Rare25/Epic10/Legendary4/Mythic1;
            RareGuaranteed Rare70/Epic20/Legendary8/Mythic2; 6 species;
            Sizes Small..Giant; MutationChance=0.1 (5 mutations);
            GripByRarity 0.5/1/1.5/2/3 (MaxGripBonus=3) MaxEquipped=1
Bots:       Enabled=true FillToMaxPlayers=true MaxBots=5 LobbyGrace=8s
            TickRate=5 WalkSpeed=14 CarrySpeed=11 ReactionTime=0.35
            AttackRange=6 AttackCooldown=1.1 PunchKnockback=20 Upward=6
            Aggression=0.55 ThrowChance=0.25 ThrowRange=25
            RoamRetarget=3s StunTime=0.4 RespawnY=-30 Elo=900
            Names: Rex/Kev/Ziggy/Nova/Bolt/Mochi/Turbo/Pixel
Matchmaking: DefaultElo=1000 Min100 Max3000 BaseRange=150 MaxRange=1000
            WidenPerSecond=25 MaxWait=20s EloByRank={25,12,4,-4,-12,-20}
AntiCheat:  Enabled=true SampleRate=10 SpeedTolerance=10
            ConsecutiveSamples=3 MaxStrikes=5 SpawnGrace=2s
            MaxAbilityRequestsPerSecond=15 LogViolations=true
PrivateServers: Enabled=true MinPlayersToStart=1 BotGrace=3s
Camera:     BaseFOV=70 CarryFOVBonus=8 SprintFOVBonus=3 FovLerpSpeed=4
            ShakeDecay=6 ShakeMaxDegrees=2.5 ShakePerPunchHit=0.5
            ShakePerDashFumble=0.9 ShakePerEggImpact=0.7 ShakePerEggOut=0.4
            ShakeRadius=40
Animations: Dash/Attack/Throw/Block/Sprint/Carry all "" (paste uploaded
            rbxassetid URLs; empty = skipped silently)
Debug:      VerboseLogging=true AllowCommandBar=true QuickMatch=false
            QuickMatchRoundLength=15

------------------------------------------------------------
5. MOBILE SCHEME
------------------------------------------------------------
  * Movement: NATIVE left thumbstick (Roblox default touch controls; no
    script touches it). Bottom-left HUD corner intentionally kept clear.
  * Abilities: the 4 HUD buttons (ATTACK/THROW/BLOCK-hold/DASH) call
    _G.CTEInput -- same contextual rules as keyboard; server enforces.
  * CAS touch buttons DISABLED (no duplicates). Sprint = keyboard/gamepad
    only (spec's 4-button layout).
  * All GUI is Scale-based + TextScaled; ScreenInsets=DeviceSafeArea.
  * A mobile player can fully win MVP: buttons steal/throw/dash, thumbstick
    navigates; hold time accrues identically.

------------------------------------------------------------
6. CAMERA
------------------------------------------------------------
Native Custom camera (smooth follow + full look/zoom control) is kept.
CameraController adds ONLY: damped FOV zoom-out while carrying (+8),
sprint kick (+3), and subtle rotational shake on big hits (VFXBridge ->
_G.CTECamera.AddShake). Tunables: Config.Camera.

------------------------------------------------------------
7. KNOWN PLACEHOLDERS / POLISH AREAS
------------------------------------------------------------
  [ ] VFXBridge stubs: PlayPunchVFX / PlayStealVFX / PlayCrackVFX /
      ScreenShake (+ OnOtherEvent catch-all) -- THE file to fill in.
  [ ] Config.Animations: all six slots empty (upload + paste IDs).
  [ ] Bots slide (no animation rig scripts); egg is a neon ball (no mesh);
      arena is grey slabs (art pass).
  [ ] Settings: sensitivity stepper is a placeholder (_G.CTESettings);
      mute is real (SoundService.Volume).
  [ ] 2v2v2 team mode: not implemented (FFA only).
  [ ] Pet trading: not implemented (MaxEquipped=1 reserved).
  [ ] GUI is code-built by GuiMain+UiKit; if you rebuild it manually, use
      the hierarchies in section 8 and keep ResetOnSpawn=false.
  [ ] DataStore: Studio runs memory-only (UseRealStoreInStudio=false).
      Production: publish game + enable API access; consider ProfileService
      session locking before multi-server scaling.
  [ ] AntiCheat: horizontal speed only (vertical fly detection future);
      kicks at 5 strikes; ranges are server-computed by design.

------------------------------------------------------------
8. GUI HIERARCHY (what GuiMain builds at runtime -- for manual rebuilds)
------------------------------------------------------------
StarterGui
  CTEGui (ScreenGui)  ResetOnSpawn=false, ScreenInsets=DeviceSafeArea
    GuiMain (LocalScript)          -- routes remotes -> screens below
    UiKit (ModuleScript)           -- Theme table + Scale-only builders
    ControlsPanel (ModuleScript)
    HudScreen (ModuleScript)
    HatcheryPanel (ModuleScript)
    ResultsScreens (ModuleScript)
    SettingsPanel (ModuleScript)
Runtime tree produced inside CTEGui (all UDim2.fromScale, TextScaled):
  HUD (Frame, transparent, full-screen)
    RoundTimer (TextLabel .38,.012 .24x.085, gold, GothamBlack "--"/seconds)
    RoundIndicator (TextLabel .38,.10 .24x.035 dim "Round 1/3")
    Status (TextLabel .34,.138 .32x.035 dim lobby status line)
    Countdown (TextLabel .2,.30 .6x.22 gold hidden "3..2..1..GO!")
    HoldTimeBoard (Frame .015,.145 .31x.385, translucent)
      Header (TextLabel "HOLD TIME")
      Row1..Row6 (Frame .96 x ~.123 each)
        Fill (Frame width=hold/max, dark gold)
        PlayerName (TextLabel left, "(you)" suffix, gold bg when carrier)
        HoldTime (TextLabel right "%.1fs")
    Feed (Frame .015,.55 .31x.20 + UIListLayout; max 4 fading labels)
    StaminaBar (Frame .38,.80 .24x.032; Fill + "STAMINA n" label; red<25%)
    Abilities (Frame .26,.845 .48x.14, transparent)
      ATTACK / THROW / BLOCK / DASH (TextButton .235x.92 each)
        Title (TextLabel), StateLabel ("Hands Full"/"Need Egg"/"No Stamina")
        Cooldown (Frame black .45 alpha, top-down shrink tween)
    SettingsButton "SET" (TextButton .905,.025 .075x.055)
    HatcheryButton "HATCHERY" (TextButton .805,.025 .09x.055)
  RoundEndPanel + RoundEndPanelScrim (Frame .19,.19 .62x.62 + full scrim)
    Title "ROUND n" / Winner line / Row0 header / Row1..6
      (cols: # | PLAYER | ROUND | MATCH | WON; winner row gold)
  MatchEndPanel + MatchEndPanelScrim (Frame .17,.11 .66x.78 + scrim)
    Title "MATCH OVER" / MVP banner (gold star) / Row0 header / Row1..6
      (cols: # | PLAYER | TOTAL HOLD | WON | star/left tag)
    PlayAgain + BackToLobby (TextButtons .36x.085)
  SettingsScrim + SettingsPanel (Frame .28,.27 .44x.46)
    Title / Close "X" / Sound label + MuteToggle / Sensitivity label +
    SensDown "-" + SensValue + SensUp "+" / placeholder note
  HatcheryScrim + HatcheryPanel (Frame .21,.13 .58x.74)
    Title / Close / Wallet label (Clout, Fragments, Pity n/10)
    BuyEgg + ConvertFragments buttons / "EGGS" header + Eggs
    (ScrollingFrame: rows w/ timer or OPEN) / "PETS (n)" header + Pets
    (ScrollingFrame: rarity-colored rows w/ grip% + EQUIP/ON) / Note
  ControlsPanel (Frame right edge .30, .235 wide, collapsible)
    Header button "CONTROLS -/+" / Body: 6 key+action rows / footer
  Toasts (Frame .25,.18 .5x.16 + UIListLayout; fading info toasts)
============================================================
