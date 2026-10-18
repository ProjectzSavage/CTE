--[[
	Animations (StarterPlayer.StarterCharacterScripts.Animations)
	=============================================================
	Plays character animations in response to server FeedbackEvents for the
	LocalPlayer (dash, punch, throw) and replicated state (block/sprint
	loops, carry loop via the HasEgg attribute).

	Animation IDs live in Config.Animations. An EMPTY STRING means "not
	uploaded yet" and is skipped silently -- so this system is fully wired
	now and starts animating the moment real animation asset IDs are pasted
	into Config (Creator Dashboard -> Animations -> upload -> rbxassetid://).

	Mapping:
	  DashStart   -> Config.Animations.Dash    (one-shot)
	  PunchSwing  -> Config.Animations.Attack  (one-shot)
	  EggThrown   -> Config.Animations.Throw   (one-shot)
	  BlockStart/BlockEnd/BlockBroken -> Config.Animations.Block  (loop)
	  SprintStart/SprintEnd           -> Config.Animations.Sprint (loop)
	  HasEgg attribute true/false     -> Config.Animations.Carry  (loop)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Config"))
local FeedbackEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("FeedbackEvent")

local player = Players.LocalPlayer
local character = script.Parent
local humanoid = character:WaitForChild("Humanoid")
local animator = humanoid:WaitForChild("Animator")

local tracks = {} -- kind -> AnimationTrack | false (false = tried, unavailable)

local function getTrack(kind)
	if tracks[kind] ~= nil then
		return tracks[kind] or nil
	end

	local id = Config.Animations and Config.Animations[kind]
	if type(id) ~= "string" or id == "" then
		tracks[kind] = false -- not uploaded yet: skip silently
		return nil
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = id
	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	animation:Destroy()

	if ok and track then
		tracks[kind] = track
		return track
	end

	warn("[Animations] Could not load '" .. kind .. "' animation (" .. id .. ")")
	tracks[kind] = false
	return nil
end

local function playOneShot(kind)
	local track = getTrack(kind)
	if track then
		track:Stop(0)
		track:Play(0.1)
	end
end

local function startLoop(kind)
	local track = getTrack(kind)
	if track then
		track.Looped = true
		track:Play(0.15)
	end
end

local function stopLoop(kind)
	local track = getTrack(kind)
	if track then
		track:Stop(0.15)
	end
end

-- World feedback: only animate the LocalPlayer's own events.
FeedbackEvent.OnClientEvent:Connect(function(kind, data)
	if type(data) ~= "table" or data.Player ~= player then
		return
	end
	if kind == "DashStart" then
		playOneShot("Dash")
	elseif kind == "PunchSwing" then
		playOneShot("Attack")
	elseif kind == "EggThrown" then
		playOneShot("Throw")
	elseif kind == "BlockStart" then
		startLoop("Block")
	elseif kind == "BlockEnd" or kind == "BlockBroken" then
		stopLoop("Block")
	elseif kind == "SprintStart" then
		startLoop("Sprint")
	elseif kind == "SprintEnd" then
		stopLoop("Sprint")
	end
end)

-- Carry loop: driven by the replicated HasEgg attribute (survives across
-- pickup/fumble/throw without extra remotes).
local function updateCarryLoop()
	if player:GetAttribute("HasEgg") then
		startLoop("Carry")
	else
		stopLoop("Carry")
	end
end

player:GetAttributeChangedSignal("HasEgg"):Connect(updateCarryLoop)
updateCarryLoop()
