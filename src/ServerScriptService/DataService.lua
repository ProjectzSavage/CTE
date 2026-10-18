--[[
	DataService (ServerScriptService.DataService)
	=============================================
	pcall-wrapped persistence for the whole meta layer:

	  Clout, Egg Fragments, ELO, pets, eggs (with hatch timers), the pity
	  counter (matches since last round win), lifetime hold time, match
	  stats (wins / MVPs / matches played).

	Design (per spec: SIMPLE, graceful):
	  * One key per player: "Player_<UserId>" in Config.Data.StoreName.
	  * Load on join with retries; if it still fails the player gets a
	    TEMPORARY in-memory profile (marked `Temporary = true`) so they can
	    play, and we NEVER save over real data from a failed load.
	  * Auto-save every Config.Data.AutoSaveSeconds, on PlayerRemoving and
	    in BindToClose (all pcall-wrapped with retries).
	  * Studio: Config.Data.UseRealStoreInStudio = false keeps profiles in a
	    memory table -- they still persist across rejoins inside the same
	    Studio session, so the full flow is testable without publishing.
	  * leaderstats (Clout / Frags / Pet) are created immediately and kept
	    in sync, so the stock Roblox leaderboard shows the economy.

	API:
	  DataService.Init()
	  DataService.OnProfileReady(callback)        -- callback(player, profile)
	  DataService.GetProfile(player) -> profile?  (nil until loaded)
	  DataService.IsLoaded(player) -> bool
	  DataService.Get(player, key, default)
	  DataService.Set(player, key, value)
	  DataService.AddNumeric(player, key, amount) -> newValue?
	  DataService.AddClout(player, amount) -> newClout?
	  DataService.AddFragments(player, amount) -> newFragments?
	  DataService.GetElo(player) / SetElo(player, elo)
	  DataService.AddLifetimeHold(player, seconds)
	  DataService.GetSnapshot(player) -> plain table for remotes
	  DataService.Save(player) / SaveAll()
	  DataService.DebugState()
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Config"))

local DataService = {}

local store = nil -- DataStoreService:GetDataStore(Config.Data.StoreName)
local useRealStore = false
local memoryStore = {}   -- Studio/testing fallback: { [key] = deepCopy }
local profiles = {}      -- { [Player] = profile }
local initialized = false
local profileReadyCallbacks = {}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function deepCopy(original)
	local copy = {}
	for key, value in pairs(original) do
		if type(value) == "table" then
			copy[key] = deepCopy(value)
		else
			copy[key] = value
		end
	end
	return copy
end

local function defaultProfile()
	return {
		Clout = Config.Economy.StartingClout,
		Fragments = 0,
		Elo = Config.Matchmaking.DefaultElo,
		LifetimeHoldTime = 0,
		MatchesPlayed = 0,
		RoundWins = 0,
		MVPs = 0,
		MatchesSinceRoundWin = 0,  -- pity counter
		Eggs = {},                 -- { {Id, Source, GuaranteedRare, UnlocksAt} }
		Pets = {},                 -- { {Id, Name, Species, Rarity, Size, Mutation?, GripBonus, CreatedAt} }
		EquippedPetId = nil,
	}
end

-- Merges a stored table into fresh defaults so schema additions never crash
-- on old profiles.
local function migrate(stored)
	local profile = defaultProfile()
	if type(stored) ~= "table" then
		return profile
	end
	for key, value in pairs(stored) do
		if key == "Eggs" or key == "Pets" then
			if type(value) == "table" then
				profile[key] = value
			end
		else
			profile[key] = value
		end
	end
	return profile
end

local function storeKey(player)
	return "Player_" .. player.UserId
end

local function rawGet(key)
	if not useRealStore then
		local existing = memoryStore[key]
		return existing and deepCopy(existing) or nil
	end
	return store:GetAsync(key) -- may throw; callers pcall
end

local function rawSet(key, value)
	if not useRealStore then
		memoryStore[key] = deepCopy(value)
		return
	end
	store:SetAsync(key, value) -- may throw; callers pcall
end

local function stripTransient(profile)
	local copy = deepCopy(profile)
	copy.Temporary = nil
	copy.LoadedAt = nil
	return copy
end

---------------------------------------------------------------------------
-- leaderstats (stock Roblox leaderboard: Clout, Frags, Pet)
---------------------------------------------------------------------------

local function getStat(player, name, className)
	local folder = player:FindFirstChild("leaderstats")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "leaderstats"
		folder.Parent = player
	end
	local stat = folder:FindFirstChild(name)
	if not stat then
		stat = Instance.new(className)
		stat.Name = name
		stat.Parent = folder
	end
	return stat
end

local function refreshLeaderstats(player)
	local profile = profiles[player]
	local clout = getStat(player, "Clout", "IntValue")
	clout.Value = profile and math.floor(profile.Clout or 0) or 0
	local frags = getStat(player, "Frags", "IntValue")
	frags.Value = profile and math.floor(profile.Fragments or 0) or 0

	local petStat = getStat(player, "Pet", "StringValue")
	local petName = "none"
	if profile and profile.EquippedPetId then
		for _, pet in ipairs(profile.Pets) do
			if pet.Id == profile.EquippedPetId then
				petName = pet.Rarity .. " " .. pet.Name
				break
			end
		end
	end
	petStat.Value = petName
end

---------------------------------------------------------------------------
-- Load / save
---------------------------------------------------------------------------

local function loadProfile(player)
	local key = storeKey(player)
	local stored = nil
	local ok = false

	for attempt = 1, Config.Data.LoadRetries do
		ok, stored = pcall(rawGet, key)
		if ok then
			break
		end
		warn(("[DataService] load attempt %d/%d failed for %s: %s"):format(
			attempt, Config.Data.LoadRetries, player.Name, tostring(stored)))
		if attempt < Config.Data.LoadRetries then
			task.wait(Config.Data.RetryDelaySeconds * attempt)
		end
	end

	local profile
	if ok then
		profile = migrate(stored)
	else
		-- Load failed: play on defaults but NEVER save (protects real data).
		profile = defaultProfile()
		profile.Temporary = true
		warn(("[DataService] %s is playing on a TEMPORARY profile (load failed)")
			:format(player.Name))
	end

	profile.LoadedAt = os.time()
	profiles[player] = profile
	refreshLeaderstats(player)

	for _, callback in ipairs(profileReadyCallbacks) do
		task.spawn(callback, player, profile)
	end
	if Config.DebugVerboseLogging then
		print(("[DataService] loaded %s (Clout=%d Frags=%d Pets=%d%s)"):format(
			player.Name, profile.Clout, profile.Fragments, #profile.Pets,
			profile.Temporary and " TEMPORARY" or ""))
	end
end

function DataService.Save(player)
	local profile = profiles[player]
	if not profile or profile.Temporary then
		return false -- nothing loaded or protecting real data
	end
	local payload = stripTransient(profile)
	for attempt = 1, Config.Data.SaveRetries do
		local ok, err = pcall(rawSet, storeKey(player), payload)
		if ok then
			return true
		end
		warn(("[DataService] save attempt %d/%d failed for %s: %s"):format(
			attempt, Config.Data.SaveRetries, player.Name, tostring(err)))
		if attempt < Config.Data.SaveRetries then
			task.wait(Config.Data.RetryDelaySeconds)
		end
	end
	return false
end

function DataService.SaveAll()
	for _, player in ipairs(Players:GetPlayers()) do
		DataService.Save(player)
	end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function DataService.Init()
	if initialized then
		return
	end
	initialized = true

	useRealStore = (not RunService:IsStudio()) or Config.Data.UseRealStoreInStudio
	if useRealStore then
		local ok, result = pcall(function()
			return DataStoreService:GetDataStore(Config.Data.StoreName)
		end)
		if ok then
			store = result
		else
			warn("[DataService] GetDataStore failed (" .. tostring(result)
				.. ") -- falling back to memory profiles")
			useRealStore = false
		end
	else
		print("[DataService] Studio mode: memory profiles (persist across rejoins this session)")
	end

	for _, player in ipairs(Players:GetPlayers()) do
		refreshLeaderstats(player)
		task.spawn(loadProfile, player)
	end
	Players.PlayerAdded:Connect(function(player)
		refreshLeaderstats(player) -- show zeros instantly, load fills them in
		task.spawn(loadProfile, player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		DataService.Save(player)
		profiles[player] = nil
	end)

	-- Auto-save loop.
	task.spawn(function()
		while true do
			task.wait(Config.Data.AutoSaveSeconds)
			for _, player in ipairs(Players:GetPlayers()) do
				local profile = profiles[player]
				if profile and not profile.Temporary then
					task.spawn(DataService.Save, player)
				end
			end
		end
	end)

	game:BindToClose(function()
		-- Best-effort final save; pcall-wrapped so shutdown never errors out.
		pcall(function()
			DataService.SaveAll()
		end)
		task.wait(1)
	end)

	print("[DataService] Initialized: persistence + leaderstats live ("
		.. (useRealStore and "DataStore" or "memory") .. ")")
end

function DataService.OnProfileReady(callback)
	table.insert(profileReadyCallbacks, callback)
end

function DataService.GetProfile(player)
	return profiles[player]
end

function DataService.IsLoaded(player)
	return profiles[player] ~= nil
end

function DataService.Get(player, key, default)
	local profile = profiles[player]
	if not profile or profile[key] == nil then
		return default
	end
	return profile[key]
end

function DataService.Set(player, key, value)
	local profile = profiles[player]
	if not profile then
		return nil
	end
	profile[key] = value
	if key == "Clout" or key == "Fragments" or key == "EquippedPetId" then
		refreshLeaderstats(player)
	end
	return value
end

function DataService.AddNumeric(player, key, amount)
	local profile = profiles[player]
	if not profile then
		return nil
	end
	profile[key] = (tonumber(profile[key]) or 0) + amount
	if key == "Clout" or key == "Fragments" then
		refreshLeaderstats(player)
	end
	return profile[key]
end

function DataService.AddClout(player, amount)
	return DataService.AddNumeric(player, "Clout", amount)
end

function DataService.AddFragments(player, amount)
	return DataService.AddNumeric(player, "Fragments", amount)
end

function DataService.GetElo(player)
	return DataService.Get(player, "Elo", Config.Matchmaking.DefaultElo)
end

function DataService.SetElo(player, elo)
	elo = math.clamp(math.floor(elo), Config.Matchmaking.MinElo, Config.Matchmaking.MaxElo)
	return DataService.Set(player, "Elo", elo)
end

function DataService.AddLifetimeHold(player, seconds)
	return DataService.AddNumeric(player, "LifetimeHoldTime", seconds)
end

-- Plain-table snapshot safe to send over remotes (HatcheryUpdated).
function DataService.GetSnapshot(player)
	local profile = profiles[player]
	if not profile then
		return nil
	end
	return {
		Clout = math.floor(profile.Clout or 0),
		Fragments = math.floor(profile.Fragments or 0),
		Elo = profile.Elo or Config.Matchmaking.DefaultElo,
		LifetimeHoldTime = math.floor(profile.LifetimeHoldTime or 0),
		MatchesPlayed = profile.MatchesPlayed or 0,
		RoundWins = profile.RoundWins or 0,
		MVPs = profile.MVPs or 0,
		PityProgress = {
			SinceRoundWin = profile.MatchesSinceRoundWin or 0,
			Needed = Config.Economy.PityMatchesWithoutRoundWin,
		},
		Eggs = deepCopy(profile.Eggs or {}),
		Pets = deepCopy(profile.Pets or {}),
		EquippedPetId = profile.EquippedPetId,
		StoreOK = not profile.Temporary,
		Now = os.time(), -- clients compute hatch countdowns from this
	}
end

function DataService.DebugState()
	local loaded, temporary = 0, 0
	for _, player in ipairs(Players:GetPlayers()) do
		local profile = profiles[player]
		if profile then
			loaded = loaded + 1
			if profile.Temporary then
				temporary = temporary + 1
			end
		end
	end
	return ("mode=%s loaded=%d/%d temporary=%d"):format(
		useRealStore and "DataStore" or "memory", loaded, #Players:GetPlayers(), temporary)
end

return DataService
