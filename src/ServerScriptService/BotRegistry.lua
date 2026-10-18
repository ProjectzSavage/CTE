--[[
	BotRegistry (ServerScriptService.BotRegistry)
	=============================================
	Dependency-free shared roster of "participants": real Players + bot
	Models (built by BotService). Every gameplay service requires THIS
	module instead of BotService, which keeps the require graph acyclic
	(BotService needs Combat/Egg; Combat/Egg need only the registry).

	A bot is a plain Model (R6 rig) with a Humanoid, living in
	Workspace.Bots. Models support attributes, so bots carry the same
	replicated "HasEgg" attribute as players and can be sent through
	RemoteEvents (clients see them because Workspace replicates).

	Also holds two cross-service hooks so nobody has to require anybody:
	  * knockHandler  -- BotService installs the real bot-knockback logic
	  * allowedFilter -- MatchService limits a match to its chosen roster
	                     (relevant only when >6 humans are in the server)
]]

local Players = game:GetService("Players")

local BotRegistry = {}

local bots = {}          -- { [Model] = info }  info = { UserId = fake id }
local knockHandler = nil -- function(model, direction, force, upward, stunTime)
local allowedFilter = nil -- function(player) -> bool (nil = everyone allowed)

function BotRegistry.Register(model, fakeUserId)
	bots[model] = { UserId = fakeUserId }
end

function BotRegistry.Unregister(model)
	bots[model] = nil
end

function BotRegistry.IsBot(instance)
	return instance ~= nil and bots[instance] ~= nil
end

-- Character-equivalent for any participant: a player's Character, or the
-- bot Model itself.
function BotRegistry.GetCharacter(entity)
	if entity == nil then
		return nil
	end
	if entity:IsA("Player") then
		return entity.Character
	end
	if BotRegistry.IsBot(entity) then
		return entity
	end
	return nil
end

function BotRegistry.GetUserId(entity)
	if entity == nil then
		return nil
	end
	if entity:IsA("Player") then
		return entity.UserId
	end
	local info = bots[entity]
	return info and info.UserId or nil
end

-- True when a bot's Model is the given character (EggService touch events).
function BotRegistry.GetBotFromCharacter(character)
	for model in pairs(bots) do
		if model == character then
			return model
		end
	end
	return nil
end

-- Live bots (Parent check scrubs despawned models).
function BotRegistry.GetBots()
	local list = {}
	for model in pairs(bots) do
		if model.Parent then
			table.insert(list, model)
		else
			bots[model] = nil
		end
	end
	return list
end

function BotRegistry.CountBots()
	local count = 0
	for model in pairs(bots) do
		if model.Parent then
			count = count + 1
		else
			bots[model] = nil
		end
	end
	return count
end

-- Every participant allowed to touch the egg / be hit / be scored right now.
function BotRegistry.GetParticipants()
	local list = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if not allowedFilter or allowedFilter(player) then
			table.insert(list, player)
		end
	end
	for _, model in ipairs(BotRegistry.GetBots()) do
		table.insert(list, model)
	end
	return list
end

function BotRegistry.IsParticipant(entity)
	if entity == nil then
		return false
	end
	if entity:IsA("Player") then
		return (not allowedFilter or allowedFilter(entity)) and entity.Parent ~= nil
	end
	return bots[entity] ~= nil and entity.Parent ~= nil
end

-- MatchService sets this while a match runs (nil = no filtering).
function BotRegistry.SetAllowedFilter(fn)
	allowedFilter = (typeof(fn) == "function") and fn or nil
end

-- BotService installs the real knockback implementation here; CombatService
-- and EggService call through without requiring BotService.
function BotRegistry.SetKnockHandler(fn)
	knockHandler = (typeof(fn) == "function") and fn or nil
end

-- Returns "Hit" | "Invalid" (bots cannot block or i-frame).
function BotRegistry.KnockbackBot(model, direction, force, upward, stunTime)
	if not BotRegistry.IsBot(model) or not knockHandler then
		return "Invalid"
	end
	return knockHandler(model, direction, force, upward, stunTime)
end

return BotRegistry
