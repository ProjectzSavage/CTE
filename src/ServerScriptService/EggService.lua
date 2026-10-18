--[[
	EggService (ServerScriptService.EggService)
	===========================================
	Server-authoritative egg system: spawn, auto-pickup, carry, hold time,
	fumble, and out-of-arena respawn. Visuals are intentionally simple (a
	glowing sphere); every cosmetic moment fires FeedbackEvent so polish can
	hook in later without touching this module.

	Behaviour summary
	-----------------
	Spawn     : A ball Part is created once at Init() and respawned at
	            Workspace.Arena.EggSpawnPoint on StartRound() / after being
	            lost. (Later, MatchService calls StartRound()/EndRound().)
	Pickup    : Loose egg + character touch (or proximity scan backup) ->
	            that player becomes the carrier. No button. The egg is welded
	            in front of the torso, CanCollide/CanTouch turn off and the
	            Player gets attribute HasEgg = true. NOTE: the carry speed
	            penalty (Config.CarrySpeed) is applied by CombatService, which
	            owns all WalkSpeed math (carry/block/dash/stun modifiers).
	Hold time : The current carrier accrues seconds on the service ticker.
	            HoldTimeUpdated broadcasts every Config.HoldTimeSyncInterval
	            (only while carried, plus one final push after changes).
	Fumble    : EggService.Fumble(target, reason [, popVelocity]) detaches
	            the egg, drops it loose at the carrier's position, clears
	            HasEgg. Also fires automatically on death, respawn and
	            leaving the game.
	Throw     : EggService.ReleaseThrow(player, direction) launches the egg
	            (CombatService validates the request first). For a short
	            window the thrown egg is "hot": it knocks players back and
	            bounces loose instead of being caught; once it slows down it
	            is a normal loose egg again (loose-pickup only for now).
	Loose egg : Unclaimed for Config.EggRespawnDelay while away from the
	            center pad, OR out of bounds (below Config.EggOutOfBoundsY /
	            past Config.EggOutOfBoundsHorizontal) -> respawns at center.
	            Hold time is paused whenever the egg is loose (nobody carries).

	Remote payloads (server -> all clients)
	---------------------------------------
	EggPossessionChanged(newCarrier: Player?, previousCarrier: Player?)
	HoldTimeUpdated(entries)  -- array of {Player = Player, HoldTime = number},
	                          -- sorted by HoldTime descending (leaderboard order)
	FeedbackEvent(kind, data) -- kinds fired here: "EggPickup", "EggFumble",
	                          -- "EggOutOfBounds", "EggRespawn", "EggThrown",
	                          -- "EggImpact"

	Debugging from the Studio command bar while playing (the command bar runs
	in CLIENT context, so use the DebugCommand remote in ReplicatedStorage):
	  game.ReplicatedStorage.Remotes.DebugCommand:FireServer("fumble")
	  game.ReplicatedStorage.Remotes.DebugCommand:FireServer("fumble", "PlayerName")
	  game.ReplicatedStorage.Remotes.DebugCommand:FireServer("respawn_egg")
	  game.ReplicatedStorage.Remotes.DebugCommand:FireServer("state")
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Config"))
-- Shared participant roster: real Players + bot Models (BotService builds
-- them; BotRegistry is dependency-free so requiring it is always safe).
local BotRegistry = require(ServerScriptService:WaitForChild("BotRegistry"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local EggPossessionChanged = Remotes:WaitForChild("EggPossessionChanged")
local HoldTimeUpdated = Remotes:WaitForChild("HoldTimeUpdated")
local FeedbackEvent = Remotes:WaitForChild("FeedbackEvent")

local EggService = {}

---------------------------------------------------------------------------
-- Runtime state (server only)
---------------------------------------------------------------------------

-- Egg state machine.
local STATE_MISSING = "Missing"         -- egg part not created yet
local STATE_LOOSE = "Loose"             -- free in the world, pickable
local STATE_CARRIED = "Carried"         -- welded to the carrier
local STATE_RESPAWNING = "Respawning"   -- lost/out of bounds, hidden, counting down

local TICK_INTERVAL = math.max(0.05, Config.HoldTimeSyncInterval)

local egg = nil                  -- BasePart
local state = STATE_MISSING
local carrier = nil              -- Player?
local carryWeld = nil            -- WeldConstraint?

local holdTimes = {}             -- { [Player] = seconds }
local pickupLockout = {}         -- { [Player] = os.clock() earliest re-grab }
local looseSince = nil           -- os.clock() when the egg became loose
local respawnAt = nil            -- os.clock() when STATE_RESPAWNING completes
local thrower = nil              -- Player? who last threw the egg (self-pickup lockout)
local thrownHotUntil = 0         -- os.clock() deadline for the thrown egg's impact window
local impactHandler = nil        -- function(player, eggVelocity) injected by Main (CombatService)
local pickupsEnabled = true      -- MatchService gates this: pickups only during RoundPlaying
local broadcastNeeded = false    -- push one more HoldTimeUpdated after a change
local lastTickTime = 0
local initialized = false

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function now()
	return os.clock()
end

local function getSpawnPointPosition()
	local arena = Workspace:FindFirstChild("Arena")
	local point = arena and arena:FindFirstChild("EggSpawnPoint")
	if point and point:IsA("BasePart") then
		return point.Position
	end
	warn("[EggService] Workspace.Arena.EggSpawnPoint missing; falling back to world origin")
	return Vector3.new(0, Config.ArenaEggSpawnHeight, 0)
end

local function getTorso(character)
	if not character then
		return nil
	end
	return character:FindFirstChild("UpperTorso")
		or character:FindFirstChild("Torso")
		or character:FindFirstChild("HumanoidRootPart")
end

local function getAliveHumanoid(character)
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		return humanoid
	end
	return nil
end

-- Server-side mirror of every feedback event (Main creates the bindable;
-- EconomyService listens for knockdown/steal counting). Cached lazily;
-- `false` means "looked, not there" so we never re-search every tick.
local serverFeedback = nil

local function broadcastFeedback(kind, data)
	if serverFeedback == nil then
		serverFeedback = ServerScriptService:FindFirstChild("ServerFeedback") or false
	end
	if serverFeedback then
		serverFeedback:Fire(kind, data or {})
	end
	FeedbackEvent:FireAllClients(kind, data or {})
end

local function broadcastPossession(newCarrier, previousCarrier)
	broadcastNeeded = true
	EggPossessionChanged:FireAllClients(newCarrier, previousCarrier)
end

-- A thrown egg stays "hot" for a short window (and while still fast): it
-- knocks players back instead of being picked up.
local function isEggHot()
	return state == STATE_LOOSE
		and egg ~= nil
		and thrownHotUntil > now()
		and egg.AssemblyLinearVelocity.Magnitude >= Config.EggThrowImpactMinSpeed
end

local function createEgg()
	local part = Instance.new("Part")
	part.Name = "Egg"
	part.Shape = Enum.PartType.Ball
	-- Slightly egg-shaped sphere (taller than wide), sized from Config.
	local diameter = Config.EggRadius * 2
	part.Size = Vector3.new(diameter * 0.9, diameter * 1.15, diameter * 0.9)
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(255, 214, 90)
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	-- Light, slippery and a little bouncy: rolls around the arena nicely.
	part.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.3, 0.5)
	part.Anchored = true -- released by applyLooseVisual()/spawnAtCenter()
	part.CanCollide = false
	part.CanTouch = false

	-- "Slightly glowing": a soft point light so the egg reads from anywhere.
	local light = Instance.new("PointLight")
	light.Brightness = 0.8
	light.Range = 10
	light.Color = part.Color
	light.Parent = part

	part.Parent = Workspace
	return part
end

local function applyLooseVisual()
	egg.Transparency = 0
	egg.Anchored = false
	egg.CanCollide = true
	egg.CanTouch = true
end

local function applyHiddenVisual()
	egg.Transparency = 1
	egg.Anchored = true
	egg.CanCollide = false
	egg.CanTouch = false
end

local function applyCarriedVisual()
	egg.Transparency = 0
	egg.CanCollide = false -- never fight the weld or snag on walls
	egg.CanTouch = false   -- only LOOSE eggs are pickable
end

---------------------------------------------------------------------------
-- State transitions
---------------------------------------------------------------------------

-- Forward declaration so spawnAtCenter/scheduleRespawn can reference it.
local scheduleRespawn

local function spawnAtCenter()
	if not egg then
		return
	end
	if carryWeld then
		carryWeld:Destroy()
		carryWeld = nil
	end

	local spawnPosition = getSpawnPointPosition()
	applyLooseVisual()
	egg.CFrame = CFrame.new(spawnPosition)
	egg.AssemblyLinearVelocity = Vector3.zero
	egg.AssemblyAngularVelocity = Vector3.zero

	state = STATE_LOOSE
	looseSince = now()
	respawnAt = nil
	thrower = nil
	thrownHotUntil = 0
	pickupLockout = {} -- fresh center drop: everyone may contest it
	broadcastNeeded = true

	broadcastFeedback("EggRespawn", { Position = spawnPosition })
	if Config.DebugVerboseLogging then
		print("[EggService] Egg respawned at center")
	end
end

-- Egg is lost (out of bounds): hide it and respawn at center after
-- Config.EggRespawnDelay seconds.
scheduleRespawn = function()
	if not egg or state == STATE_RESPAWNING then
		return
	end
	state = STATE_RESPAWNING
	respawnAt = now() + Config.EggRespawnDelay
	applyHiddenVisual()
	looseSince = nil
	broadcastNeeded = true

	broadcastFeedback("EggOutOfBounds", { Position = egg.Position })
	if Config.DebugVerboseLogging then
		print("[EggService] Egg out of bounds; respawning in " .. Config.EggRespawnDelay .. "s")
	end
end

---------------------------------------------------------------------------
-- Pickup
---------------------------------------------------------------------------

local function tryPickup(player)
	-- All guards first: no yields inside this function, so two touches in the
	-- same frame can never produce two carriers.
	if not pickupsEnabled then
		return false -- match is not in RoundPlaying
	end
	if state ~= STATE_LOOSE or not egg then
		return false
	end
	if not BotRegistry.IsParticipant(player) then
		return false -- spectators (>MaxPlayers servers) and junk cannot grab
	end

	local lockUntil = pickupLockout[player]
	if lockUntil and now() < lockUntil then
		return false -- just fumbled/threw it or just got beaned: cannot instantly re-grab
	end

	-- A hot thrown egg is not catchable (yet) -- it impacts instead.
	if isEggHot() and player ~= thrower then
		return false
	end

	-- Works for Players (their Character) and bots (the Model itself).
	local character = BotRegistry.GetCharacter(player)
	local humanoid = getAliveHumanoid(character)
	local torso = getTorso(character)
	if not humanoid or not torso then
		return false
	end

	-- Become the carrier.
	carrier = player
	state = STATE_CARRIED
	looseSince = nil

	applyCarriedVisual()
	egg.AssemblyLinearVelocity = Vector3.zero
	egg.AssemblyAngularVelocity = Vector3.zero
	-- Held out in front of the chest, clearly visible to everyone.
	egg.CFrame = torso.CFrame * CFrame.new(0, Config.EggCarryOffsetUp, -Config.EggCarryOffsetForward)

	carryWeld = Instance.new("WeldConstraint")
	carryWeld.Part0 = torso
	carryWeld.Part1 = egg
	carryWeld.Parent = egg

	-- Carry penalty (Config.CarrySpeed) is applied by CombatService, which
	-- watches the HasEgg attribute and owns all WalkSpeed math.
	player:SetAttribute("HasEgg", true)
	if holdTimes[player] == nil then
		holdTimes[player] = 0
	end

	broadcastPossession(player, nil)
	broadcastFeedback("EggPickup", { Player = player, Position = egg.Position })

	if Config.DebugVerboseLogging then
		print("[EggService] " .. player.Name .. " picked up the egg")
	end
	return true
end

local function onEggTouched(hit)
	if state ~= STATE_LOOSE or not egg then
		return
	end
	local character = hit:FindFirstAncestorOfClass("Model")
	local player = character and (Players:GetPlayerFromCharacter(character)
		or BotRegistry.GetBotFromCharacter(character))
	if not player or not BotRegistry.IsParticipant(player) then
		return
	end

	-- Hot thrown egg: knock the struck player back (via the injected
	-- CombatService handler), defuse the egg and bounce it loose.
	if isEggHot() and player ~= thrower then
		local impactVelocity = egg.AssemblyLinearVelocity
		thrownHotUntil = 0 -- defuse: it is a normal loose egg again
		pickupLockout[player] = now() + Config.EggImpactPickupDelay
		egg.AssemblyLinearVelocity = impactVelocity * -0.2 + Vector3.new(0, 5, 0)
		broadcastFeedback("EggImpact", { Player = player, Position = egg.Position })
		if impactHandler then
			impactHandler(player, impactVelocity)
		end
		return
	end

	tryPickup(player)
end

---------------------------------------------------------------------------
-- Fumble / drop
---------------------------------------------------------------------------

local function doFumble(player, reason, popVelocity)
	if carrier ~= player or not egg then
		return false -- idempotent: Died + CharacterRemoving can both fire
	end
	local previousCarrier = carrier
	carrier = nil

	previousCarrier:SetAttribute("HasEgg", false)
	-- WalkSpeed restoration happens in CombatService (HasEgg attribute watch).

	-- Detach from the torso.
	if carryWeld then
		carryWeld:Destroy()
		carryWeld = nil
	end
	thrower = nil
	thrownHotUntil = 0

	-- Place the egg loose at the carrier's position (slightly forward+up so
	-- it does not spawn inside the character), clamped inside the arena so a
	-- fumble against a wall cannot push it out of bounds.
	local carrierCharacter = BotRegistry.GetCharacter(previousCarrier)
	local root = carrierCharacter and carrierCharacter:FindFirstChild("HumanoidRootPart")
	local dropPosition
	if root then
		dropPosition = root.CFrame:PointToWorldSpace(Vector3.new(0, 1, -2))
	else
		dropPosition = egg.Position + Vector3.new(0, 1, 0)
	end
	local halfBounds = Config.ArenaPlaySize / 2 - Config.EggRadius - 0.5
	dropPosition = Vector3.new(
		math.clamp(dropPosition.X, -halfBounds, halfBounds),
		dropPosition.Y,
		math.clamp(dropPosition.Z, -halfBounds, halfBounds)
	)

	applyLooseVisual()
	egg.CFrame = CFrame.new(dropPosition)
	egg.AssemblyLinearVelocity = popVelocity or Vector3.new(0, Config.EggFumblePop, 0)
	egg.AssemblyAngularVelocity = Vector3.zero

	state = STATE_LOOSE
	looseSince = now()

	-- The dropper cannot instantly re-grab their own fumble.
	pickupLockout[previousCarrier] = now() + Config.ThrowSelfPickupDelay

	broadcastPossession(nil, previousCarrier)
	broadcastFeedback("EggFumble", {
		Player = previousCarrier,
		Reason = reason or "Unknown",
		Position = egg.Position,
	})

	if Config.DebugVerboseLogging then
		print("[EggService] " .. previousCarrier.Name .. " fumbled the egg (" .. tostring(reason) .. ")")
	end
	return true
end

---------------------------------------------------------------------------
-- Player lifecycle (death / respawn / leaving drops the egg)
---------------------------------------------------------------------------

local function bindCharacter(player, character)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
		or character:WaitForChild("Humanoid", 10)
	if humanoid then
		-- Base WalkSpeed on (re)spawn is applied by CombatService, which owns
		-- all speed modifiers (carry / block / dash / stun).
		humanoid.Died:Connect(function()
			doFumble(player, "Died")
		end)
	end
end

local function bindPlayer(player)
	player:SetAttribute("HasEgg", false)
	broadcastNeeded = true -- late joiner: push the current hold-time table once

	player.CharacterAdded:Connect(function(character)
		bindCharacter(player, character)
	end)

	-- Covers deaths, manual respawns and teleports.
	player.CharacterRemoving:Connect(function()
		doFumble(player, "CharacterRemoved")
	end)
end

local function onPlayerRemoving(player)
	doFumble(player, "Left")
	holdTimes[player] = nil
	pickupLockout[player] = nil
end

---------------------------------------------------------------------------
-- Ticker: hold time, world checks, proximity pickup, broadcasts (10 Hz)
---------------------------------------------------------------------------

local function tickOnce()
	local currentTime = now()
	local dt = currentTime - lastTickTime
	lastTickTime = currentTime
	-- Clamp so a server hitch cannot award a burst of hold time.
	if dt > TICK_INTERVAL * 3 then
		dt = TICK_INTERVAL * 3
	end

	-- 1) Hold time accrues for the carrier only (pauses automatically while
	--    the egg is loose/respawning -- there is no carrier then).
	if carrier and state == STATE_CARRIED then
		holdTimes[carrier] = (holdTimes[carrier] or 0) + dt
	end

	if egg then
		if state == STATE_LOOSE then
			local position = egg.Position

			-- 2a) Fell out of the arena?
			if position.Y < Config.EggOutOfBoundsY
				or math.abs(position.X) > Config.EggOutOfBoundsHorizontal
				or math.abs(position.Z) > Config.EggOutOfBoundsHorizontal
			then
				scheduleRespawn()
			elseif looseSince and (currentTime - looseSince) >= Config.EggRespawnDelay then
				-- 2b) Unclaimed timeout: reset to center, unless it is already
				-- resting on the center pad (no annoying idle pop-loop there).
				local centerOffset = Vector3.new(position.X, 0, position.Z).Magnitude
				if centerOffset > Config.EggLooseResetRadius then
					spawnAtCenter()
				else
					looseSince = currentTime -- parked at center: restart the clock
				end
			end
		elseif state == STATE_RESPAWNING then
			-- 2c) Respawn countdown finished?
			if respawnAt and currentTime >= respawnAt then
				spawnAtCenter()
			end
		end

		-- 3) Proximity pickup scan: cheap backup to Touched so grabs also
		--    register reliably at low framerates / on mobile.
		--    TODO(polish): add line-of-sight check so it cannot grab through walls.
		if state == STATE_LOOSE then
			for _, entity in ipairs(BotRegistry.GetParticipants()) do
				local character = BotRegistry.GetCharacter(entity)
				local humanoid = getAliveHumanoid(character)
				if humanoid then
					local root = character:FindFirstChild("HumanoidRootPart")
					if root
						and (root.Position - egg.Position).Magnitude <= Config.EggProximityPickupRadius
					then
						if tryPickup(entity) then
							break -- one pickup per tick maximum
						end
					end
				end
			end
		end
	end

	-- 4) Broadcast hold times: continuously while carried (live leaderboard),
	--    plus one final push after any possession change.
	if state == STATE_CARRIED or broadcastNeeded then
		local entries = {}
		for player, time in pairs(holdTimes) do
			if player.Parent then
				table.insert(entries, { Player = player, HoldTime = time })
			else
				holdTimes[player] = nil -- scrub players who slipped out
			end
		end
		table.sort(entries, function(a, b)
			return a.HoldTime > b.HoldTime
		end)
		HoldTimeUpdated:FireAllClients(entries)
		broadcastNeeded = false
	end
end

local function startTicker()
	task.spawn(function()
		lastTickTime = now()
		while initialized do
			tickOnce()
			task.wait(TICK_INTERVAL)
		end
	end)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function EggService.Init()
	if initialized then
		return
	end
	initialized = true

	egg = createEgg()
	egg.Touched:Connect(onEggTouched)

	for _, player in ipairs(Players:GetPlayers()) do
		bindPlayer(player)
		if player.Character then
			bindCharacter(player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(bindPlayer)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	-- No MatchService yet: spawn the egg immediately so the arena is live.
	-- Once MatchService exists it will call StartRound()/EndRound() instead.
	spawnAtCenter()
	startTicker()

	print("[EggService] Initialized: egg spawned at center (auto-pickup live)")
end

-- Called by MatchService (later) at the start of every round.
function EggService.StartRound()
	if carrier then
		doFumble(carrier, "RoundStart")
	end
	spawnAtCenter()
end

-- Called by MatchService (later) at the end of every round: fumble any
-- carrier and park the egg at center for the results pause.
function EggService.EndRound()
	if carrier then
		doFumble(carrier, "RoundEnd")
	end
	spawnAtCenter()
end

-- MatchService gate: pickups are only allowed while a round is playing.
-- The egg stays visible at center between rounds but cannot be grabbed.
function EggService.SetEnabled(enabled)
	pickupsEnabled = (enabled == true)
end

function EggService.IsEnabled()
	return pickupsEnabled
end

-- Current carrier (Player?) -- the hook ScoringService/GUI read.
function EggService.GetCarrier()
	return carrier
end

-- The egg Part itself (may be hidden while respawning).
function EggService.GetEgg()
	return egg
end

-- Internal state string: "Loose" | "Carried" | "Respawning" | "Missing".
function EggService.GetState()
	return state
end

-- Accumulated hold seconds for one player this match.
function EggService.GetHoldTime(player)
	return holdTimes[player] or 0
end

-- Shallow copy of { [Player] = seconds } for ScoringService snapshots.
function EggService.GetHoldTimes()
	local copy = {}
	for player, time in pairs(holdTimes) do
		if player.Parent then
			copy[player] = time
		end
	end
	return copy
end

-- Full-match reset (new match, not new round -- per-round bookkeeping is
-- ScoringService's job).
function EggService.ResetHoldTimes()
	holdTimes = {}
	broadcastNeeded = true
end

--[[
	Drop the egg.

	EggService.Fumble(target?, reason?, popVelocity?)
	  target       : Player | player name | nil (nil = whoever carries it now)
	  reason       : string for logs/feedback ("Attacked", "DashCollision", ...)
	  popVelocity  : optional Vector3 launch velocity (CombatService will pass
	                 the knock-loose pop when attacks land)

	Also callable as EggService:Fumble(target, reason) -- an accidental `self`
	first argument is detected and shifted out.
]]
function EggService.Fumble(target, reason, popVelocity)
	if target == EggService then -- colon-call: shift the implicit self away
		target, reason, popVelocity = reason, popVelocity, nil
	end

	if target == nil then
		target = carrier
	end
	if typeof(target) == "string" then
		local resolved = Players:FindFirstChild(target)
		if not resolved then
			for _, model in ipairs(BotRegistry.GetBots()) do
				if model.Name == target then
					resolved = model
					break
				end
			end
		end
		target = resolved
	end
	if not BotRegistry.IsParticipant(target) then
		warn("[EggService] Fumble: could not resolve target (" .. tostring(target) .. ")")
		return false
	end
	if not carrier then
		warn("[EggService] Fumble: nobody is carrying the egg")
		return false
	end
	if target ~= carrier then
		warn("[EggService] Fumble: " .. target.Name .. " is not the carrier ("
			.. carrier.Name .. " is)")
		return false
	end
	if popVelocity ~= nil and typeof(popVelocity) ~= "Vector3" then
		warn("[EggService] Fumble: popVelocity must be a Vector3; ignoring it")
		popVelocity = nil
	end

	return doFumble(carrier, reason or "Manual", popVelocity)
end

-- Force the egg back to center immediately (debug / round flow).
function EggService.RespawnEggNow()
	if not egg then
		return
	end
	if carrier then
		doFumble(carrier, "ForcedRespawn")
	end
	spawnAtCenter()
end

--[[
	Throw the egg. Called by CombatService AFTER it has validated the request
	(caller must be the carrier, alive, not stunned).

	EggService.ReleaseThrow(player, direction)
	  player    : the current carrier
	  direction : Vector3 launch direction (unit-ized internally); the lob comes
	              from Config.ThrowUpwardBias added on top of Config.ThrowSpeed

	Possession ends immediately (hold time stops). The egg is "hot" for
	Config.EggThrowDangerTime / until it slows below Config.EggThrowImpactMinSpeed:
	hitting a player knocks them back and bounces the egg loose instead of being
	caught. The thrower is locked out of re-grabbing (ThrowSelfPickupDelay).
]]
function EggService.ReleaseThrow(player, direction)
	if carrier ~= player or not egg then
		return false
	end
	if typeof(direction) ~= "Vector3" or direction.Magnitude < 0.001 then
		direction = Vector3.new(0, 0, -1)
	end
	direction = direction.Unit

	local previousCarrier = carrier
	carrier = nil
	previousCarrier:SetAttribute("HasEgg", false)

	if carryWeld then
		carryWeld:Destroy()
		carryWeld = nil
	end

	-- The egg is already welded in front of the chest; launch from there.
	applyLooseVisual()
	egg.AssemblyAngularVelocity = Vector3.zero
	egg.AssemblyLinearVelocity = direction * Config.ThrowSpeed
		+ Vector3.new(0, Config.ThrowUpwardBias, 0)

	state = STATE_LOOSE
	looseSince = now()
	thrower = previousCarrier
	thrownHotUntil = now() + Config.EggThrowDangerTime
	pickupLockout[previousCarrier] = now() + Config.ThrowSelfPickupDelay
	broadcastNeeded = true

	broadcastPossession(nil, previousCarrier)
	broadcastFeedback("EggThrown", {
		Player = previousCarrier,
		Direction = direction,
		Position = egg.Position,
	})

	if Config.DebugVerboseLogging then
		print("[EggService] " .. previousCarrier.Name .. " threw the egg")
	end
	return true
end

-- True while a thrown egg would knock players back instead of being caught.
function EggService.IsEggHot()
	return isEggHot()
end

-- Who last threw the egg (Player?) -- used for throw-impact exemptions.
function EggService.GetThrower()
	return thrower
end

-- Main injects CombatService.HandleEggImpact here. Dependency injection keeps
-- the require graph one-directional (CombatService -> EggService only).
function EggService.SetImpactHandler(handler)
	impactHandler = (typeof(handler) == "function") and handler or nil
end

-- One-line snapshot for the console / DebugCommands "state".
function EggService.DebugState()
	local parts = {}
	for player, time in pairs(holdTimes) do
		if player.Parent then
			table.insert(parts, player.Name .. "=" .. string.format("%.1f", time) .. "s")
		end
	end
	table.sort(parts)
	local carrierName = carrier and carrier.Name or "nobody"
	local timesText = #parts > 0 and table.concat(parts, ", ") or "(none)"
	return "state=" .. state .. " | carrier=" .. carrierName .. " | holdTimes: " .. timesText
end

return EggService
