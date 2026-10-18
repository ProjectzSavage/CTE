--[[
	HatcheryService (ServerScriptService.HatcheryService)
	=====================================================
	The egg/pet economy on the server:

	  * BUY an egg with Clout (Config.Economy.EggCloutCost)
	  * CONVERT 10 Egg Fragments into an egg (Config.Economy.EggFragmentCost)
	  * Every egg carries a hatch timer (Config.Economy.HatchTimeSeconds);
	    opening a READY egg rolls a pet: rarity (weighted), size, optional
	    mutation, and a tiny capped grip bonus (Config.Pets.GripByRarity).
	  * Pity eggs (granted by EconomyService after 10 winless matches + a
	    round win) roll from RareGuaranteedWeights instead.
	  * Pets live in the player's data profile (DataService) -- persisted.
	  * Equipped pet's grip = % chance to survive a punch that would knock
	    the egg loose (CombatService calls GetGripBonus). Cosmetic flex:
	    the equipped pet shows in leaderstats.

	Remotes:
	  HatcheryRequest  (client -> server): action [, id]
	    actions: "BuyEgg" | "ConvertFragments" | "OpenEgg" <eggId>
	           | "EquipPet" <petId> | "Refresh"
	  HatcheryUpdated  (server -> client): full profile snapshot
	  FeedbackEvent    (server -> one client): "PetHatched" {Pet}
	                                     ... "EggGranted" {Egg}

	ALL validation is server-side; clients only ask.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Config"))
local DataService = require(ServerScriptService:WaitForChild("DataService"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local HatcheryRequest = Remotes:WaitForChild("HatcheryRequest")
local HatcheryUpdated = Remotes:WaitForChild("HatcheryUpdated")
local FeedbackEvent = Remotes:WaitForChild("FeedbackEvent")

local HatcheryService = {}

local idCounter = 0
local initialized = false

local function nextId(prefix)
	idCounter = idCounter + 1
	return ("%s_%d_%d"):format(prefix, os.time(), idCounter)
end

local function personalFeedback(player, kind, data)
	if player:IsA("Player") then
		FeedbackEvent:FireClient(player, kind, data or {})
	end
end

function HatcheryService.SendSnapshot(player)
	local snapshot = DataService.GetSnapshot(player)
	if snapshot then
		HatcheryUpdated:FireClient(player, snapshot)
	end
end

---------------------------------------------------------------------------
-- Egg creation
---------------------------------------------------------------------------

local function addEgg(player, source, guaranteedRare)
	local profile = DataService.GetProfile(player)
	if not profile then
		return nil
	end
	local egg = {
		Id = nextId("egg"),
		Source = source or "Bought",          -- Bought | Converted | Pity | Debug
		GuaranteedRare = guaranteedRare and true or false,
		UnlocksAt = os.time() + Config.Economy.HatchTimeSeconds,
	}
	table.insert(profile.Eggs, egg)
	personalFeedback(player, "EggGranted", { Egg = egg })
	HatcheryService.SendSnapshot(player)
	if Config.DebugVerboseLogging then
		print(("[Hatchery] %s got a %s egg (ready in %ds)"):format(
			player.Name, egg.GuaranteedRare and "guaranteed-rare" or "mystery",
			Config.Economy.HatchTimeSeconds))
	end
	return egg
end

-- EconomyService (pity wins) and debug commands call this.
function HatcheryService.GrantEgg(player, source, guaranteedRare)
	return addEgg(player, source, guaranteedRare)
end

---------------------------------------------------------------------------
-- Pet rolling
---------------------------------------------------------------------------

local function pickWeighted(weights)
	local total = 0
	for _, weight in pairs(weights) do
		total = total + weight
	end
	if total <= 0 then
		return nil
	end
	local roll = math.random() * total
	for name, weight in pairs(weights) do
		roll = roll - weight
		if roll <= 0 then
			return name
		end
	end
	return nil
end

local function pickFrom(list)
	return list[math.random(1, #list)]
end

local function rollPet(guaranteedRare)
	local rarity = pickWeighted(guaranteedRare
		and Config.Pets.RareGuaranteedWeights
		or Config.Pets.RarityWeights) or "Common"
	local species = pickFrom(Config.Pets.Species)
	local mutation = nil
	if math.random() < Config.Pets.MutationChance then
		mutation = pickFrom(Config.Pets.Mutations)
	end
	local grip = math.min(
		Config.Pets.GripByRarity[rarity] or 0,
		Config.Pets.MaxGripBonus
	)
	local name = (mutation and (mutation .. " ") or "") .. species
	return {
		Id = nextId("pet"),
		Name = name,
		Species = species,
		Rarity = rarity,
		Size = pickFrom(Config.Pets.Sizes),
		Mutation = mutation,
		GripBonus = grip,
		CreatedAt = os.time(),
	}
end

---------------------------------------------------------------------------
-- Actions (all server-validated)
---------------------------------------------------------------------------

local function buyEgg(player)
	local profile = DataService.GetProfile(player)
	if not profile then
		return
	end
	if profile.Clout < Config.Economy.EggCloutCost then
		personalFeedback(player, "NotEnoughClout", {
			Need = Config.Economy.EggCloutCost, Have = math.floor(profile.Clout) })
		return
	end
	DataService.AddClout(player, -Config.Economy.EggCloutCost)
	addEgg(player, "Bought", false)
end

local function convertFragments(player)
	local profile = DataService.GetProfile(player)
	if not profile then
		return
	end
	if profile.Fragments < Config.Economy.EggFragmentCost then
		personalFeedback(player, "NotEnoughFragments", {
			Need = Config.Economy.EggFragmentCost, Have = math.floor(profile.Fragments) })
		return
	end
	DataService.AddFragments(player, -Config.Economy.EggFragmentCost)
	addEgg(player, "Converted", false)
end

local function openEgg(player, eggId)
	local profile = DataService.GetProfile(player)
	if not profile or type(eggId) ~= "string" then
		return
	end
	local eggIndex = nil
	for index, egg in ipairs(profile.Eggs) do
		if egg.Id == eggId then
			eggIndex = index
			break
		end
	end
	if not eggIndex then
		return
	end
	local egg = profile.Eggs[eggIndex]
	if os.time() < (egg.UnlocksAt or 0) then
		personalFeedback(player, "EggNotReady", { ReadyAt = egg.UnlocksAt })
		return
	end

	table.remove(profile.Eggs, eggIndex)
	local pet = rollPet(egg.GuaranteedRare == true)
	table.insert(profile.Pets, pet)

	-- First pet auto-equips.
	if not profile.EquippedPetId then
		DataService.Set(player, "EquippedPetId", pet.Id)
	end

	personalFeedback(player, "PetHatched", { Pet = pet })
	HatcheryService.SendSnapshot(player)
	if Config.DebugVerboseLogging then
		print(("[Hatchery] %s hatched %s (%s, %s, grip +%.1f%%)"):format(
			player.Name, pet.Name, pet.Rarity, pet.Size, pet.GripBonus))
	end
end

local function equipPet(player, petId)
	local profile = DataService.GetProfile(player)
	if not profile or type(petId) ~= "string" then
		return
	end
	for _, pet in ipairs(profile.Pets) do
		if pet.Id == petId then
			DataService.Set(player, "EquippedPetId", petId)
			HatcheryService.SendSnapshot(player)
			return
		end
	end
end

---------------------------------------------------------------------------
-- Grip bonus (CombatService consults this on would-be steals)
---------------------------------------------------------------------------

function HatcheryService.GetGripBonus(entity)
	if entity == nil or not entity:IsA("Player") then
		return 0 -- bots have no pets
	end
	local profile = DataService.GetProfile(entity)
	if not profile or not profile.EquippedPetId then
		return 0
	end
	for _, pet in ipairs(profile.Pets) do
		if pet.Id == profile.EquippedPetId then
			return math.min(pet.GripBonus or 0, Config.Pets.MaxGripBonus)
		end
	end
	return 0
end

function HatcheryService.GetEquippedPet(player)
	local profile = DataService.GetProfile(player)
	if not profile or not profile.EquippedPetId then
		return nil
	end
	for _, pet in ipairs(profile.Pets) do
		if pet.Id == profile.EquippedPetId then
			return pet
		end
	end
	return nil
end

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------

function HatcheryService.Init()
	if initialized then
		return
	end
	initialized = true

	HatcheryRequest.OnServerEvent:Connect(function(player, action, id)
		if type(action) ~= "string" then
			return
		end
		if not DataService.IsLoaded(player) then
			personalFeedback(player, "DataNotReady", {})
			return
		end
		if action == "BuyEgg" then
			buyEgg(player)
		elseif action == "ConvertFragments" then
			convertFragments(player)
		elseif action == "OpenEgg" then
			openEgg(player, id)
		elseif action == "EquipPet" then
			equipPet(player, id)
		elseif action == "Refresh" then
			HatcheryService.SendSnapshot(player)
		end
	end)

	-- Send a snapshot as soon as each profile finishes loading.
	DataService.OnProfileReady(function(player)
		HatcheryService.SendSnapshot(player)
	end)

	print("[HatcheryService] Initialized: buy/convert/hatch/equip live")
end

function HatcheryService.DebugState()
	local eggs, pets = 0, 0
	for _, player in ipairs(Players:GetPlayers()) do
		local profile = DataService.GetProfile(player)
		if profile then
			eggs = eggs + #profile.Eggs
			pets = pets + #profile.Pets
		end
	end
	return ("eggs-hatching=%d pets-owned=%d"):format(eggs, pets)
end

return HatcheryService
