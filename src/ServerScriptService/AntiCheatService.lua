--[[
	AntiCheatService (ServerScriptService.AntiCheatService)
	=======================================================
	Server-side cheat resistance. Two layers:

	1) ABILITY VALIDATION (already lives in CombatService, restated here):
	   every Request* remote handler ignores client arguments entirely and
	   re-checks context (egg possession), cooldown, stamina, stun and
	   server-computed ranges/targets. Client positions are NEVER trusted,
	   so impossible attack ranges cannot land: a punch only hits what the
	   SERVER sees inside Config.AttackRange of the SERVER's attacker
	   position. On top of that this service rate-limits remote spam.

	2) SPEED-HACK DETECTION:
	   Each player's position is sampled Config.AntiCheat.SampleRate times
	   per second. The maximum LEGITIMATE horizontal speed is
	     WalkSpeed + SprintSpeedBonus + DashSpeedBonus + SpeedTolerance.
	   (Knockback impulses top out far below that; jumps are vertical and
	   ignored; spawns/respawns get SpawnGraceSeconds of amnesty.)
	   If a player exceeds it for ConsecutiveSamples samples in a row they
	   are teleported back to their last valid position, the violation is
	   logged, and a strike is recorded. MaxStrikes -> kick.

	CombatService calls AllowAbilityRequest() at the top of every Request
	handler; everything else runs on its own sampler loop.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Config"))

local AntiCheatService = {}

local trackers = {} -- { [Player] = tracker }
local initialized = false

local function now()
	return os.clock()
end

local function maxLegitimateSpeed()
	return Config.WalkSpeed + Config.SprintSpeedBonus + Config.DashSpeedBonus
		+ Config.AntiCheat.SpeedTolerance
end

local function log(player, message)
	if Config.AntiCheat.LogViolations then
		warn(("[AntiCheat] %s: %s"):format(player.Name, message))
	end
end

local function strike(player, reason)
	local tracker = trackers[player]
	if not tracker then
		return
	end
	tracker.strikes = tracker.strikes + 1
	log(player, ("STRIKE %d/%d (%s)"):format(
		tracker.strikes, Config.AntiCheat.MaxStrikes, reason))
	if tracker.strikes >= Config.AntiCheat.MaxStrikes then
		pcall(function()
			player:Kick("[AntiCheat] Too many movement/ability violations (" .. reason .. ")")
		end)
	end
end

local function newTracker()
	return {
		lastPosition = nil,
		lastValidPosition = nil,
		lastSampleTime = 0,
		fastStreak = 0,
		graceUntil = 0,
		strikes = 0,
		requestTimes = {}, -- sliding window for ability spam
	}
end

local function getTracker(player)
	local tracker = trackers[player]
	if not tracker then
		tracker = newTracker()
		trackers[player] = tracker
	end
	return tracker
end

---------------------------------------------------------------------------
-- Sampler
---------------------------------------------------------------------------

local function samplePlayer(player, tracker, currentTime)
	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root then
		return
	end
	if currentTime < tracker.graceUntil then
		-- Spawn/respawn amnesty: just re-anchor our notion of "valid".
		tracker.lastValidPosition = root.Position
		tracker.lastPosition = root.Position
		tracker.lastSampleTime = currentTime
		tracker.fastStreak = 0
		return
	end

	if tracker.lastPosition == nil or tracker.lastSampleTime == 0 then
		tracker.lastPosition = root.Position
		tracker.lastValidPosition = root.Position
		tracker.lastSampleTime = currentTime
		return
	end

	local dt = currentTime - tracker.lastSampleTime
	tracker.lastSampleTime = currentTime
	tracker.lastPosition = root.Position
	if dt <= 0 or dt > 0.5 then
		return -- server hitch or first tick: never judge these
	end

	-- Horizontal-only: jumps/knockback pops are vertical and legitimate.
	local delta = root.Position - tracker.lastValidPosition
	local horizontal = Vector3.new(delta.X, 0, delta.Z).Magnitude
	-- Measured against the LAST VALID position over the whole streak window,
	-- so brief legit bursts (dash momentum decay) self-clear.
	local window = currentTime - (tracker.validSince or currentTime)
	if window < dt then
		window = dt
	end
	local allowed = maxLegitimateSpeed() * window

	if horizontal > allowed then
		tracker.fastStreak = tracker.fastStreak + 1
		if tracker.fastStreak >= Config.AntiCheat.ConsecutiveSamples then
			local speed = horizontal / window
			log(player, ("speed violation: %.1f studs/s sustained (max legitimate %.1f) -> teleporting back")
				:format(speed, maxLegitimateSpeed()))
			-- Teleport back to the last valid position.
			root.AssemblyLinearVelocity = Vector3.zero
			root.CFrame = CFrame.new(tracker.lastValidPosition + Vector3.new(0, 1, 0))
			strike(player, "speed hack suspected")
			tracker.fastStreak = 0
			tracker.lastPosition = root.Position
			tracker.validSince = currentTime
		end
	else
		tracker.fastStreak = 0
		tracker.lastValidPosition = root.Position
		tracker.validSince = currentTime
	end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- CombatService calls this at the top of EVERY Request* handler.
-- Returns false when the player is spamming (request dropped + strike).
function AntiCheatService.AllowAbilityRequest(player)
	if not Config.AntiCheat.Enabled then
		return true
	end
	local tracker = getTracker(player)
	local currentTime = now()

	-- Sliding 1-second window.
	local window = tracker.requestTimes
	while #window > 0 and currentTime - window[1] > 1 do
		table.remove(window, 1)
	end
	table.insert(window, currentTime)
	if #window > Config.AntiCheat.MaxAbilityRequestsPerSecond then
		log(player, ("ability spam: %d requests in 1s (max %d)")
			:format(#window, Config.AntiCheat.MaxAbilityRequestsPerSecond))
		tracker.requestTimes = {}
		strike(player, "remote spam")
		return false
	end
	return true
end

-- Called by anything that legally teleports/impulses a player (spawns).
function AntiCheatService.GiveGrace(player, seconds)
	local tracker = getTracker(player)
	tracker.graceUntil = now() + (seconds or Config.AntiCheat.SpawnGraceSeconds)
	tracker.fastStreak = 0
end

function AntiCheatService.GetStrikes(player)
	local tracker = trackers[player]
	return tracker and tracker.strikes or 0
end

function AntiCheatService.Init()
	if initialized then
		return
	end
	initialized = true

	Players.PlayerAdded:Connect(function(player)
		trackers[player] = newTracker()
		player.CharacterAdded:Connect(function()
			AntiCheatService.GiveGrace(player, Config.AntiCheat.SpawnGraceSeconds)
		end)
		if player.Character then
			AntiCheatService.GiveGrace(player, Config.AntiCheat.SpawnGraceSeconds)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		trackers[player] = nil
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		trackers[player] = newTracker()
		player.CharacterAdded:Connect(function()
			AntiCheatService.GiveGrace(player, Config.AntiCheat.SpawnGraceSeconds)
		end)
		if player.Character then
			AntiCheatService.GiveGrace(player, Config.AntiCheat.SpawnGraceSeconds)
		end
	end

	if Config.AntiCheat.Enabled then
		task.spawn(function()
			local interval = 1 / Config.AntiCheat.SampleRate
			while initialized do
				local currentTime = now()
				for _, player in ipairs(Players:GetPlayers()) do
					local tracker = trackers[player]
					if tracker then
						samplePlayer(player, tracker, currentTime)
					end
				end
				task.wait(interval)
			end
		end)
	end

	print("[AntiCheatService] Initialized: " .. (Config.AntiCheat.Enabled
		and ("speed sampling %dHz, tolerance +%d, %d strikes -> kick")
			:format(Config.AntiCheat.SampleRate, Config.AntiCheat.SpeedTolerance,
				Config.AntiCheat.MaxStrikes)
		or "DISABLED"))
end

function AntiCheatService.DebugState()
	local parts = {}
	for player, tracker in pairs(trackers) do
		if player.Parent and tracker.strikes > 0 then
			table.insert(parts, ("%s[strikes=%d]"):format(player.Name, tracker.strikes))
		end
	end
	return ("enabled=%s maxSpeed=%.0f%s"):format(
		tostring(Config.AntiCheat.Enabled), maxLegitimateSpeed(),
		#parts > 0 and (" | " .. table.concat(parts, ", ")) or "")
end

return AntiCheatService
