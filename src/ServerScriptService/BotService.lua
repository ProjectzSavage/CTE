--[[
	BotService (ServerScriptService.BotService)
	===========================================
	Simple AI bots that fill empty slots so a match always has a full party
	(deliverable: a lone player starts a match and gets 5 bots).

	A bot is a code-built R6 rig (Model + Humanoid) registered in
	BotRegistry, so EggService/CombatService/ScoringService treat it as a
	normal participant: it touches the egg to pick it up, accrues hold time,
	can win rounds and even be MVP. Bots have NO data profile -> they earn
	no Clout/fragments.

	Behaviour (spec: walk toward the egg, pick it up, run to a random spot,
	punch nearby players, sometimes throw; beatable but not useless):
	  * egg loose/respawning -> walk to it (touch/proximity pickup is the
	    regular EggService path)
	  * carrying             -> roam to random spots, re-targeting every
	    RoamRetargetSeconds; if an enemy is close, sometimes THROW at them
	  * someone else carries -> hunt the carrier (Aggression chance per
	    decision, so hunting is not relentless); inside AttackRange and off
	    cooldown -> punch (softer + slower than a human: beatable)
	  * punched              -> stagger (StunTime), knockback applied

	Tunable entirely from Config.Bots; Enabled=false turns the whole system
	off (matches then need Config.MinPlayersToStart humans, as before).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Config"))
local EggService = require(ServerScriptService:WaitForChild("EggService"))
local CombatService = require(ServerScriptService:WaitForChild("CombatService"))
local BotRegistry = require(ServerScriptService:WaitForChild("BotRegistry"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local FeedbackEvent = Remotes:WaitForChild("FeedbackEvent")

local BotService = {}

local botsFolder = nil
local aiBots = {}        -- { {model, humanoid, root, ...ai state} }
local botIdCounter = 0
local initialized = false

local function now()
	return os.clock()
end

local function broadcastFeedback(kind, data)
	FeedbackEvent:FireAllClients(kind, data or {})
end

---------------------------------------------------------------------------
-- R6 rig builder (pure code -- no Toolbox assets needed)
---------------------------------------------------------------------------

local function makePart(name, size, color, parent)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CanCollide = true
	part.Parent = parent
	return part
end

local function makeMotor(name, part0, part1, c0, c1, parent)
	local motor = Instance.new("Motor6D")
	motor.Name = name
	motor.Part0 = part0
	motor.Part1 = part1
	motor.C0 = c0
	motor.C1 = c1
	motor.Parent = parent
	return motor
end

local function buildRig(displayName, bodyColor, legColor)
	local model = Instance.new("Model")
	model.Name = "Bot_" .. displayName

	local root = makePart("HumanoidRootPart", Vector3.new(2, 2, 1), bodyColor, model)
	root.Transparency = 1
	root.CanCollide = false

	local torso = makePart("Torso", Vector3.new(2, 2, 1), bodyColor, model)
	local head = makePart("Head", Vector3.new(2, 1, 1), bodyColor, model)
	local leftArm = makePart("Left Arm", Vector3.new(1, 2, 1), bodyColor, model)
	local rightArm = makePart("Right Arm", Vector3.new(1, 2, 1), bodyColor, model)
	local leftLeg = makePart("Left Leg", Vector3.new(1, 2, 1), legColor, model)
	local rightLeg = makePart("Right Leg", Vector3.new(1, 2, 1), legColor, model)

	-- Canonical R6 layout around the root at origin.
	torso.CFrame = root.CFrame
	head.CFrame = root.CFrame * CFrame.new(0, 1.5, 0)
	leftArm.CFrame = root.CFrame * CFrame.new(-1.5, 0, 0)
	rightArm.CFrame = root.CFrame * CFrame.new(1.5, 0, 0)
	leftLeg.CFrame = root.CFrame * CFrame.new(-0.5, -2, 0)
	rightLeg.CFrame = root.CFrame * CFrame.new(0.5, -2, 0)

	-- Classic smiley face (built-in Roblox texture, no upload needed).
	local face = Instance.new("Decal")
	face.Name = "face"
	face.Texture = "rbxasset://textures/face.png"
	face.Face = Enum.NormalId.Front
	face.Parent = head

	-- Standard R6 joints.
	makeMotor("RootJoint", root, torso,
		CFrame.new(0, 0, 0) * CFrame.Angles(-math.pi / 2, math.pi, 0),
		CFrame.new(0, 0, 0), torso)
	makeMotor("Neck", torso, head,
		CFrame.new(0, 1, 0) * CFrame.Angles(-math.pi / 2, math.pi, 0),
		CFrame.new(0, -0.5, 0), torso)
	makeMotor("Left Shoulder", torso, leftArm,
		CFrame.new(-1, 0.5, 0) * CFrame.Angles(0, -math.pi / 2, 0),
		CFrame.new(0.5, 0.5, 0), torso)
	makeMotor("Right Shoulder", torso, rightArm,
		CFrame.new(1, 0.5, 0) * CFrame.Angles(0, math.pi / 2, 0),
		CFrame.new(-0.5, 0.5, 0), torso)
	makeMotor("Left Hip", torso, leftLeg,
		CFrame.new(-1, -1, 0) * CFrame.Angles(0, -math.pi / 2, 0),
		CFrame.new(-0.5, 1, 0), torso)
	makeMotor("Right Hip", torso, rightLeg,
		CFrame.new(1, -1, 0) * CFrame.Angles(0, math.pi / 2, 0),
		CFrame.new(0.5, 1, 0), torso)

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R6
	humanoid.DisplayName = displayName
	humanoid.WalkSpeed = Config.Bots.WalkSpeed
	humanoid.JumpPower = 0 -- bots do not jump (keeps the AI simple + beatable)
	humanoid.MaxHealth = 100
	humanoid.Health = 100
	humanoid.Parent = model

	model.PrimaryPart = root
	return model, humanoid, root
end

---------------------------------------------------------------------------
-- Spawn / despawn
---------------------------------------------------------------------------

local function randomArenaPoint(radius)
	local angle = math.random() * math.pi * 2
	local distance = math.random() * (radius or 45)
	return Vector3.new(math.cos(angle) * distance, 4, math.sin(angle) * distance)
end

function BotService.SpawnBots(count)
	if not Config.Bots.Enabled or count <= 0 then
		return {}
	end
	count = math.min(count, Config.Bots.MaxBots)
	if not botsFolder then
		botsFolder = Workspace:FindFirstChild("Bots")
		if not botsFolder then
			botsFolder = Instance.new("Folder")
			botsFolder.Name = "Bots"
			botsFolder.Parent = Workspace
		end
	end

	-- Shuffle name/color pools so parties vary.
	local names = {}
	for _, name in ipairs(Config.Bots.Names) do
		table.insert(names, name)
	end
	for index = #names, 2, -1 do
		local swap = math.random(1, index)
		names[index], names[swap] = names[swap], names[index]
	end

	local spawned = {}
	for index = 1, count do
		botIdCounter = botIdCounter + 1
		local displayName = names[((index - 1) % #names) + 1]
		local colorName = Config.Bots.Colors[(botIdCounter % #Config.Bots.Colors) + 1]
		local bodyColor = BrickColor.new(colorName).Color
		local legColor = BrickColor.new("Dark stone grey").Color

		local model, humanoid, root = buildRig(displayName, bodyColor, legColor)
		model.Parent = botsFolder
		model:PivotTo(CFrame.new(randomArenaPoint(Config.ArenaSpawnRadius)))

		BotRegistry.Register(model, -(9000 + botIdCounter)) -- fake negative UserId
		table.insert(spawned, model)

		table.insert(aiBots, {
			model = model,
			humanoid = humanoid,
			root = root,
			nextDecisionAt = now() + math.random() * Config.Bots.ReactionTime,
			stunUntil = 0,
			lastAttackAt = -math.huge,
			roamTarget = nil,
			roamRetargetAt = 0,
		})

		-- Bots broadcast possession/feedback through the normal remotes:
		-- models replicate, so clients can render bot carriers and events.
		humanoid:SetAttribute("IsBot", true)
	end

	if Config.DebugVerboseLogging and count > 0 then
		print(("[BotService] spawned %d bot(s) -- arena now has %d participant(s)")
			:format(#spawned, #BotRegistry.GetParticipants()))
	end
	return spawned
end

function BotService.DespawnAll()
	for _, bot in ipairs(aiBots) do
		if EggService.GetCarrier() == bot.model then
			EggService.Fumble(bot.model, "BotDespawned")
		end
		BotRegistry.Unregister(bot.model)
		bot.model:Destroy()
	end
	aiBots = {}
	if Config.DebugVerboseLogging then
		print("[BotService] all bots despawned")
	end
end

---------------------------------------------------------------------------
-- Bot knockback (installed into BotRegistry; CombatService/EggService call)
---------------------------------------------------------------------------

local function knockBot(model, direction, force, upward, stunTime)
	for _, bot in ipairs(aiBots) do
		if bot.model == model then
			local flat = Vector3.new(direction.X, 0, direction.Z)
			if flat.Magnitude < 0.001 then
				flat = Vector3.new(0, 0, 1)
			end
			bot.root.AssemblyLinearVelocity =
				Vector3.new(flat.Unit.X * force, upward or 0, flat.Unit.Z * force)
			bot.stunUntil = now() + (stunTime or Config.Bots.StunTime)
			return "Hit"
		end
	end
	return "Invalid"
end

function BotService.IsStunned(model)
	for _, bot in ipairs(aiBots) do
		if bot.model == model then
			return now() < bot.stunUntil
		end
	end
	return false
end

---------------------------------------------------------------------------
-- AI
---------------------------------------------------------------------------

local function getRootOf(entity)
	local character = BotRegistry.GetCharacter(entity)
	return character and character:FindFirstChild("HumanoidRootPart")
end

-- Bot punch: mirror of the player attack, softer + slower (Config.Bots).
local function botPunch(bot)
	bot.lastAttackAt = now()
	broadcastFeedback("PunchSwing", { Player = bot.model, Position = bot.root.Position })

	local look = bot.root.CFrame.LookVector
	local lookFlat = Vector3.new(look.X, 0, look.Z)
	if lookFlat.Magnitude > 0.001 then
		lookFlat = lookFlat.Unit
	else
		lookFlat = nil
	end

	local carrier = EggService.GetCarrier()
	for _, victim in ipairs(BotRegistry.GetParticipants()) do
		if victim ~= bot.model then
			local victimRoot = getRootOf(victim)
			if victimRoot then
				local offset = victimRoot.Position - bot.root.Position
				if offset.Magnitude <= Config.Bots.AttackRange then
					local pushDir = Vector3.new(offset.X, 0, offset.Z)
					if pushDir.Magnitude < 0.001 then
						pushDir = lookFlat or Vector3.new(0, 0, 1)
					end
					pushDir = pushDir.Unit
					if (lookFlat == nil) or (lookFlat:Dot(pushDir) >= Config.AttackFacingDot) then
						local result
						if victim:IsA("Player") then
							result = CombatService.ApplyKnockback(
								victim, pushDir,
								Config.Bots.PunchKnockback, Config.Bots.PunchUpward,
								Config.AttackHitstun)
						else
							result = BotRegistry.KnockbackBot(
								victim, pushDir,
								Config.Bots.PunchKnockback, Config.Bots.PunchUpward,
								Config.Bots.StunTime)
						end
						broadcastFeedback("PunchHit", {
							Attacker = bot.model,
							Victim = victim,
							Position = victimRoot.Position,
							Result = result,
						})
						if victim == carrier and result == "Hit" then
							CombatService.AttemptSteal(bot.model, victim, pushDir)
						end
					end
				end
			end
		end
	end
end

local function nearestEnemy(bot)
	local best, bestDistance = nil, math.huge
	for _, entity in ipairs(BotRegistry.GetParticipants()) do
		if entity ~= bot.model then
			local root = getRootOf(entity)
			if root then
				local distance = (root.Position - bot.root.Position).Magnitude
				if distance < bestDistance then
					best, bestDistance = entity, distance
				end
			end
		end
	end
	return best, bestDistance
end

local function decide(bot)
	local carrier = EggService.GetCarrier()
	local egg = EggService.GetEgg()
	local eggState = EggService.GetState()

	if carrier == bot.model then
		-- CARRYING: run to random spots; sometimes throw when hunted.
		local enemy, enemyDistance = nearestEnemy(bot)
		if enemy and enemyDistance <= Config.Bots.ThrowRange
			and math.random() < Config.Bots.ThrowChance
		then
			local enemyRoot = getRootOf(enemy)
			if enemyRoot then
				local direction = enemyRoot.Position - bot.root.Position
				direction = Vector3.new(direction.X, 0, direction.Z)
				if direction.Magnitude > 0.001 then
					-- Slight spread: bots are not snipers.
					direction = direction.Unit * 1.0
					direction = direction + Vector3.new(
						(math.random() - 0.5) * 0.4, 0, (math.random() - 0.5) * 0.4)
					EggService.ReleaseThrow(bot.model, direction)
					bot.roamTarget = nil
					return
				end
			end
		end
		if not bot.roamTarget or now() >= bot.roamRetargetAt then
			bot.roamTarget = randomArenaPoint(45)
			bot.roamRetargetAt = now() + Config.Bots.RoamRetargetSeconds
		end
		bot.humanoid:MoveTo(bot.roamTarget)

	elseif carrier ~= nil then
		-- SOMEONE ELSE CARRIES: hunt them (not every tick -- beatable).
		local carrierRoot = getRootOf(carrier)
		if carrierRoot then
			if math.random() < Config.Bots.Aggression then
				bot.humanoid:MoveTo(carrierRoot.Position)
				local distance = (carrierRoot.Position - bot.root.Position).Magnitude
				if distance <= Config.Bots.AttackRange
					and now() >= bot.lastAttackAt + Config.Bots.AttackCooldown
				then
					botPunch(bot)
				end
			else
				-- Mill around near the carrier instead of beelining.
				if not bot.roamTarget or now() >= bot.roamRetargetAt then
					bot.roamTarget = carrierRoot.Position + randomArenaPoint(14)
					bot.roamRetargetAt = now() + Config.Bots.RoamRetargetSeconds
				end
				bot.humanoid:MoveTo(bot.roamTarget)
			end
		end

	else
		-- EGG LOOSE / RESPAWNING: go get it (or wait near center).
		bot.roamTarget = nil
		if egg and eggState == "Loose" then
			bot.humanoid:MoveTo(egg.Position)
		else
			bot.humanoid:MoveTo(Vector3.new(
				(math.random() - 0.5) * 16, 0, (math.random() - 0.5) * 16))
		end
	end
end

local function tickBots()
	local currentTime = now()
	for index = #aiBots, 1, -1 do
		local bot = aiBots[index]
		if not bot.model.Parent then
			table.remove(aiBots, index) -- despawned elsewhere
		elseif bot.root.Position.Y < Config.Bots.RespawnY then
			-- Knocked out of the arena: pop back onto the ring.
			bot.model:PivotTo(CFrame.new(randomArenaPoint(Config.ArenaSpawnRadius)))
			bot.root.AssemblyLinearVelocity = Vector3.zero
			bot.stunUntil = currentTime + Config.Bots.StunTime
		elseif currentTime < bot.stunUntil then
			bot.humanoid.WalkSpeed = 0 -- staggered
		else
			if bot.humanoid.WalkSpeed < 0.5 then
				bot.humanoid.WalkSpeed = (EggService.GetCarrier() == bot.model)
					and Config.Bots.CarrySpeed or Config.Bots.WalkSpeed
			end
			if currentTime >= bot.nextDecisionAt then
				bot.nextDecisionAt = currentTime + Config.Bots.ReactionTime
					+ math.random() * 0.15
				local ok, err = pcall(decide, bot)
				if not ok then
					warn("[BotService] AI error: " .. tostring(err))
				end
			end
		end
	end
end

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------

function BotService.Init()
	if initialized then
		return
	end
	initialized = true

	BotRegistry.SetKnockHandler(knockBot)

	task.spawn(function()
		while initialized do
			tickBots()
			task.wait(1 / Config.Bots.TickRate)
		end
	end)

	print("[BotService] Initialized: " .. (Config.Bots.Enabled
		and ("bots ENABLED (fill to %d, grace %ds)")
			:format(Config.MaxPlayers, Config.Bots.LobbyGraceSeconds)
		or "bots DISABLED"))
end

function BotService.GetBots()
	return BotRegistry.GetBots()
end

function BotService.DebugState()
	local parts = {}
	for _, bot in ipairs(aiBots) do
		if bot.model.Parent then
			local flags = {}
			if EggService.GetCarrier() == bot.model then
				table.insert(flags, "CARRYING")
			end
			if now() < bot.stunUntil then
				table.insert(flags, "stunned")
			end
			table.insert(parts, bot.model.Name
				.. (#flags > 0 and ("[" .. table.concat(flags, "+") .. "]") or ""))
		end
	end
	return ("bots=%d%s"):format(#parts, #parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or "")
end

return BotService
