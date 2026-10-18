--[[
	CombatService (ServerScriptService.CombatService)
	=================================================
	Server-authoritative abilities: Attack, Throw, Block, Dash, Sprint + the
	shared stamina pool. Clients only fire Request* RemoteEvents; EVERY rule
	is checked here (context, cooldown, stamina, alive/stun state). Cheaters
	get rejected and nothing happens.

	Ability rules (from the game spec)
	----------------------------------
	Attack : ONLY when NOT holding the egg ("HandsFull" feedback otherwise).
	         Short-range punch (Config.AttackRange + forward hemisphere).
	         On hit: knockback (Config.AttackKnockback) + brief hitstun.
	         If the victim is the carrier: EggService.Fumble with a knock-loose
	         pop -> "EggStolen" feedback. Cooldown Config.AttackCooldown.
	Throw  : ONLY when holding the egg. Launches it via EggService.ReleaseThrow
	         at Config.ThrowSpeed with an upward lob. While "hot", the thrown
	         egg knocks players back and bounces loose (HandleEggImpact).
	Block  : ALWAYS usable (hold). Incoming knockback reduced by
	         Config.BlockKnockbackReduction, move speed multiplied by
	         Config.BlockSpeedMultiplier, drains Config.BlockStaminaDrain/s.
	         A blocking carrier STILL accrues hold time (EggService does not
	         care about blocking). Block breaks automatically at 0 stamina.
	Dash   : ALWAYS usable (default key E). Speed burst for
	         Config.DashDuration. NOT carrying: brief i-frames
	         (Config.DashIFrames). Carrying: shorter dash, NO i-frames, and
	         colliding with a player within Config.DashCollisionRadius
	         fumbles the egg ("DashFumble" + small knockback to the victim).
	Sprint : ALWAYS usable (hold, default key Shift) -- the main stamina
	         sink. +Config.SprintSpeedBonus speed (works while carrying too),
	         drains Config.SprintStaminaDrain/s. Blocking, stun and dash
	         suppress sprinting; at 0 stamina the sprinter is "exhausted"
	         until stamina recovers to Config.SprintResumeStamina.

	Stamina: max Config.StaminaMax, regenerates Config.StaminaRegenPerSecond
	         after Config.StaminaRegenDelay without spending. Dash and Attack
	         cost stamina up front; Block and Sprint drain while active.
	         Published to clients as the rounded "Stamina" Player attribute
	         (HUD-ready).

	Speed ownership: this module is the ONLY writer of Humanoid.WalkSpeed.
	         Base = carrier ? CarrySpeed : WalkSpeed, + SprintSpeedBonus while
	         sprinting, x BlockSpeedMultiplier while blocking, 0 while
	         stunned, dash override during bursts. Recalculated every tick
	         (writes only on change) plus on HasEgg attribute changes.

	FeedbackEvent kinds fired here
	------------------------------
	FireAllClients : PunchSwing, PunchHit, BlockedHit, IFrameDodge, EggStolen,
	                 DashStart, DashFumble, BlockStart, BlockEnd, BlockBroken,
	                 SprintStart, SprintEnd
	FireClient     : HandsFull, NotCarrying, NoStamina, OnCooldown, Stunned,
	                 PunchWhiff, Exhausted
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Config"))
-- One-directional dependency: CombatService may use EggService, never the
-- reverse (EggService calls back through the injected impact handler).
local EggService = require(ServerScriptService:WaitForChild("EggService"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local RequestAttack = Remotes:WaitForChild("RequestAttack")
local RequestThrow = Remotes:WaitForChild("RequestThrow")
local RequestDash = Remotes:WaitForChild("RequestDash")
local RequestBlockStart = Remotes:WaitForChild("RequestBlockStart")
local RequestBlockEnd = Remotes:WaitForChild("RequestBlockEnd")
local RequestSprintStart = Remotes:WaitForChild("RequestSprintStart")
local RequestSprintEnd = Remotes:WaitForChild("RequestSprintEnd")
local FeedbackEvent = Remotes:WaitForChild("FeedbackEvent")

local CombatService = {}

local COMBAT_TICK = 0.05 -- 20 Hz: stamina, dash windows, collisions, speed recalc

---------------------------------------------------------------------------
-- Per-player combat state (server only)
---------------------------------------------------------------------------

local statuses = {} -- { [Player] = status }
local lastTickTime = 0
local initialized = false

local function now()
	return os.clock()
end

local function newStatus()
	return {
		stamina = Config.StaminaMax,
		publishedStamina = -1, -- forces the first attribute publish
		lastSpendTime = -math.huge,
		blocking = false,
		sprinting = false,       -- client is HOLDING the sprint input
		sprintEffective = false, -- sprint is actually active (not suppressed)
		sprintLocked = false,    -- exhausted: locked until SprintResumeStamina
		attackReadyAt = 0,
		dashReadyAt = 0,
		dashUntil = 0,
		dashSpeed = Config.WalkSpeed,
		dashCollisionDone = false,
		iFramesUntil = 0,
		stunUntil = 0,
	}
end

local function getStatus(player)
	local status = statuses[player]
	if not status then
		status = newStatus()
		statuses[player] = status
	end
	return status
end

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function getAliveCharacter(player)
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	return character
end

local function getRoot(player)
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

local function broadcastFeedback(kind, data)
	FeedbackEvent:FireAllClients(kind, data or {})
end

local function rejectClient(player, kind, data)
	data = data or {}
	FeedbackEvent:FireClient(player, kind, data)
end

local function spendStamina(status, amount)
	if status.stamina < amount then
		return false
	end
	status.stamina = status.stamina - amount
	status.lastSpendTime = now()
	return true
end

-- Sprint is suppressed by blocking, stun, dash and exhaustion.
local function computeSprintEffective(status, nowv)
	return status.sprinting
		and not status.blocking
		and not status.sprintLocked
		and status.stamina > 0
		and nowv >= status.stunUntil
		and nowv >= status.dashUntil
end

-- The single authority for movement speed. Called every tick and on state
-- flips; only writes when the value actually changes (no property churn).
local function recalcSpeed(player)
	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local status = getStatus(player)
	local nowv = now()
	local speed

	if nowv < status.stunUntil then
		speed = 0 -- hitstun: rooted in place
	elseif nowv < status.dashUntil then
		speed = status.dashSpeed -- dash burst overrides everything
	else
		local isCarrier = (EggService.GetCarrier() == player)
		speed = isCarrier and Config.CarrySpeed or Config.WalkSpeed
		if computeSprintEffective(status, nowv) then
			speed = speed + Config.SprintSpeedBonus
		end
		if status.blocking then
			speed = speed * Config.BlockSpeedMultiplier
		end
	end

	if math.abs(humanoid.WalkSpeed - speed) > 0.01 then
		humanoid.WalkSpeed = speed
	end
end

---------------------------------------------------------------------------
-- Knockback (shared by punches, thrown-egg impacts and dash collisions)
---------------------------------------------------------------------------

--[[
	CombatService.ApplyKnockback(player, direction, force, upwardForce, stunTime)
	  direction   : Vector3 push direction (flattened to horizontal internally)
	  force       : horizontal speed applied (studs/s)
	  upwardForce : vertical pop (studs/s), optional
	  stunTime    : seconds of rooted hitstun, optional (blocked victims skip it)

	Returns "Hit" | "Blocked" | "IFramed" | "Invalid".
]]
function CombatService.ApplyKnockback(player, direction, force, upwardForce, stunTime)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return "Invalid"
	end
	if typeof(direction) ~= "Vector3" then
		return "Invalid"
	end

	local status = getStatus(player)
	local nowv = now()
	if nowv < status.iFramesUntil then
		return "IFramed"
	end

	local root = getRoot(player)
	if not root then
		return "Invalid"
	end

	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 0.001 then
		flat = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
		if flat.Magnitude < 0.001 then
			flat = Vector3.new(0, 0, 1)
		end
	end
	flat = flat.Unit

	local appliedForce = force
	local appliedUp = upwardForce or 0
	local blocked = status.blocking
	if blocked then
		appliedForce = appliedForce * (1 - Config.BlockKnockbackReduction)
		appliedUp = appliedUp * (1 - Config.BlockKnockbackReduction)
	end

	root.AssemblyLinearVelocity = Vector3.new(flat.X * appliedForce, appliedUp, flat.Z * appliedForce)

	if stunTime and stunTime > 0 and not blocked then
		status.stunUntil = nowv + stunTime
	end
	recalcSpeed(player)

	return blocked and "Blocked" or "Hit"
end

---------------------------------------------------------------------------
-- Attack
---------------------------------------------------------------------------

local function handleAttack(player)
	local character = getAliveCharacter(player)
	if not character then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	local status = getStatus(player)
	local nowv = now()

	-- Contextual rule: HANDS FULL -- no punching while carrying the egg.
	if EggService.GetCarrier() == player then
		rejectClient(player, "HandsFull", { Ability = "Attack" })
		return
	end
	if nowv < status.stunUntil then
		rejectClient(player, "Stunned", { Ability = "Attack" })
		return
	end
	if nowv < status.attackReadyAt then
		rejectClient(player, "OnCooldown", { Ability = "Attack" })
		return
	end
	if not spendStamina(status, Config.AttackStaminaCost) then
		rejectClient(player, "NoStamina", { Ability = "Attack" })
		return
	end

	status.attackReadyAt = nowv + Config.AttackCooldown
	broadcastFeedback("PunchSwing", { Player = player, Position = root.Position })

	-- Hit detection: everyone inside range AND in the forward hemisphere.
	local look = root.CFrame.LookVector
	local lookFlat = Vector3.new(look.X, 0, look.Z)
	if lookFlat.Magnitude > 0.001 then
		lookFlat = lookFlat.Unit
	else
		lookFlat = nil -- looking straight up/down: accept any direction
	end

	local hits = 0
	for _, victim in ipairs(Players:GetPlayers()) do
		if victim ~= player then
			local victimRoot = getRoot(victim)
			local victimCharacter = getAliveCharacter(victim)
			if victimRoot and victimCharacter then
				local offset = victimRoot.Position - root.Position
				local distance = offset.Magnitude
				-- +1 stud accounts for the victim's body radius.
				if distance <= Config.AttackRange + 1 then
					local pushDir = Vector3.new(offset.X, 0, offset.Z)
					if pushDir.Magnitude < 0.001 then
						-- Point-blank (dead center): push wherever we face.
						pushDir = lookFlat or Vector3.new(0, 0, 1)
					end
					pushDir = pushDir.Unit

					local inCone = (lookFlat == nil)
						or (lookFlat:Dot(pushDir) >= Config.AttackFacingDot)
					if inCone then
						hits = hits + 1

						local victimWasCarrier = (EggService.GetCarrier() == victim)
						local victimIFramed = (nowv < getStatus(victim).iFramesUntil)

						local result = CombatService.ApplyKnockback(
							victim, pushDir,
							Config.AttackKnockback, Config.AttackUpwardKnockback,
							Config.AttackHitstun
						)

						broadcastFeedback("PunchHit", {
							Attacker = player,
							Victim = victim,
							Position = victimRoot.Position,
							Result = result,
						})
						if result == "Blocked" then
							broadcastFeedback("BlockedHit", {
								Attacker = player,
								Victim = victim,
								Position = victimRoot.Position,
							})
						elseif result == "IFramed" then
							broadcastFeedback("IFrameDodge", {
								Attacker = player,
								Victim = victim,
								Position = victimRoot.Position,
							})
						end

						-- Steal: punching the carrier knocks the egg loose
						-- (i-framed carriers keep it -- the punch fully whiffed).
						if victimWasCarrier and not victimIFramed then
							EggService.Fumble(
								victim,
								"Attacked",
								Vector3.new(
									pushDir.X * Config.EggKnockLooseSpeed,
									Config.EggKnockLooseUpward,
									pushDir.Z * Config.EggKnockLooseSpeed
								)
							)
							broadcastFeedback("EggStolen", {
								Attacker = player,
								Victim = victim,
								Position = victimRoot.Position,
							})
						end
					end
				end
			end
		end
	end

	if hits == 0 then
		rejectClient(player, "PunchWhiff", {})
	end

	if Config.DebugVerboseLogging and hits > 0 then
		print("[CombatService] " .. player.Name .. " punched " .. hits .. " target(s)")
	end
end

---------------------------------------------------------------------------
-- Throw
---------------------------------------------------------------------------

local function handleThrow(player)
	local character = getAliveCharacter(player)
	if not character then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	local status = getStatus(player)

	-- Contextual rule: can only throw WHILE carrying.
	if EggService.GetCarrier() ~= player then
		rejectClient(player, "NotCarrying", { Ability = "Throw" })
		return
	end
	if now() < status.stunUntil then
		rejectClient(player, "Stunned", { Ability = "Throw" })
		return
	end

	-- Throw where the character faces; EggService adds the lob + "hot" window
	-- and fires the "EggThrown" feedback. Hold time stops the instant it
	-- leaves the hands (possession ends inside ReleaseThrow).
	EggService.ReleaseThrow(player, root.CFrame.LookVector)
end

---------------------------------------------------------------------------
-- Dash
---------------------------------------------------------------------------

local function handleDash(player)
	local character = getAliveCharacter(player)
	if not character then
		return
	end

	local status = getStatus(player)
	local nowv = now()
	if nowv < status.stunUntil then
		rejectClient(player, "Stunned", { Ability = "Dash" })
		return
	end

	local isCarrier = (EggService.GetCarrier() == player)
	local cooldown = isCarrier and Config.DashCooldownCarrying or Config.DashCooldown
	if nowv < status.dashReadyAt then
		rejectClient(player, "OnCooldown", { Ability = "Dash" })
		return
	end

	local cost = isCarrier and Config.DashStaminaCostCarrying or Config.DashStaminaCost
	if not spendStamina(status, cost) then
		rejectClient(player, "NoStamina", { Ability = "Dash" })
		return
	end

	local duration = isCarrier and Config.DashDurationCarrying or Config.DashDuration
	local bonus = isCarrier and Config.DashSpeedBonusCarrying or Config.DashSpeedBonus

	status.dashReadyAt = nowv + cooldown
	status.dashUntil = nowv + duration
	status.dashSpeed = (isCarrier and Config.CarrySpeed or Config.WalkSpeed) + bonus
	status.dashCollisionDone = false

	-- I-frames ONLY when not carrying the egg.
	if not isCarrier and Config.DashIFrames > 0 then
		status.iFramesUntil = nowv + Config.DashIFrames
	end

	broadcastFeedback("DashStart", { Player = player, Carrying = isCarrier })
	recalcSpeed(player)
end

-- Carrier dash collision check (runs in the ticker while dashing): bumping
-- into another player fumbles the egg and nudges the victim.
local function checkDashCollision(player, status)
	local root = getRoot(player)
	if not root then
		return
	end
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			local otherRoot = getRoot(other)
			if otherRoot and getAliveCharacter(other) then
				local offset = otherRoot.Position - root.Position
				if offset.Magnitude <= Config.DashCollisionRadius then
					status.dashCollisionDone = true

					local pushDir = Vector3.new(offset.X, 0, offset.Z)
					if pushDir.Magnitude < 0.001 then
						pushDir = root.CFrame.LookVector
					end

					EggService.Fumble(player, "DashCollision")
					broadcastFeedback("DashFumble", {
						Player = player,
						Victim = other,
						Position = root.Position,
					})
					CombatService.ApplyKnockback(
						other, pushDir,
						Config.DashCollisionKnockback, Config.DashCollisionUpward,
						nil
					)
					return
				end
			end
		end
	end
end

---------------------------------------------------------------------------
-- Block
---------------------------------------------------------------------------

local function handleBlockStart(player)
	if not getAliveCharacter(player) then
		return
	end
	local status = getStatus(player)
	if now() < status.stunUntil then
		rejectClient(player, "Stunned", { Ability = "Block" })
		return
	end
	if not status.blocking then
		status.blocking = true
		broadcastFeedback("BlockStart", { Player = player })
		recalcSpeed(player) -- blocking also suppresses sprint (recalc handles it)
	end
end

local function handleBlockEnd(player)
	local status = getStatus(player)
	if status.blocking then
		status.blocking = false
		broadcastFeedback("BlockEnd", { Player = player })
		recalcSpeed(player)
	end
end

---------------------------------------------------------------------------
-- Sprint (hold Shift: the main stamina drain)
---------------------------------------------------------------------------

local function handleSprintStart(player)
	if not getAliveCharacter(player) then
		return
	end
	-- No stamina gate here: the tick decides effectiveness (exhaustion
	-- hysteresis lives there so SprintStart/SprintEnd feedback is truthful).
	getStatus(player).sprinting = true
end

local function handleSprintEnd(player)
	getStatus(player).sprinting = false
end

---------------------------------------------------------------------------
-- Thrown-egg impacts (injected into EggService by Main)
---------------------------------------------------------------------------

function CombatService.HandleEggImpact(player, eggVelocity)
	local direction = Vector3.new(eggVelocity.X, 0, eggVelocity.Z)
	if direction.Magnitude < 0.001 then
		direction = Vector3.new(0, 0, 1)
	end
	local result = CombatService.ApplyKnockback(
		player, direction,
		Config.EggThrowImpactKnockback, Config.EggThrowImpactUpward,
		Config.EggThrowImpactStun
	)
	if Config.DebugVerboseLogging then
		print("[CombatService] Thrown egg hit " .. player.Name .. " (" .. result .. ")")
	end
end

---------------------------------------------------------------------------
-- Player lifecycle
---------------------------------------------------------------------------

local function bindPlayer(player)
	statuses[player] = newStatus()

	player.CharacterAdded:Connect(function()
		-- Fresh life: clear transient states, refill stamina, re-apply speed.
		local status = getStatus(player)
		if status.sprintEffective then
			broadcastFeedback("SprintEnd", { Player = player })
		end
		status.blocking = false
		status.sprinting = false
		status.sprintEffective = false
		status.sprintLocked = false
		status.dashUntil = 0
		status.dashCollisionDone = false
		status.iFramesUntil = 0
		status.stunUntil = 0
		status.stamina = Config.StaminaMax
		status.lastSpendTime = -math.huge
		recalcSpeed(player)
	end)

	-- Possession flips (pickup / fumble / throw) change base speed instantly.
	player:GetAttributeChangedSignal("HasEgg"):Connect(function()
		recalcSpeed(player)
	end)

	if player.Character then
		recalcSpeed(player)
	end
end

---------------------------------------------------------------------------
-- Ticker (20 Hz): stamina, sprint/block drains, dash windows, collisions
---------------------------------------------------------------------------

local function tickOnce()
	local nowv = now()
	local dt = nowv - lastTickTime
	lastTickTime = nowv
	if dt > COMBAT_TICK * 3 then
		dt = COMBAT_TICK * 3 -- clamp: server hitches must not drain/regen in bulk
	end

	for _, player in ipairs(Players:GetPlayers()) do
		local status = getStatus(player)
		local drained = false

		-- Block drain (breaks the block at 0 stamina).
		if status.blocking then
			status.stamina = status.stamina - Config.BlockStaminaDrain * dt
			drained = true
			if status.stamina <= 0 then
				status.stamina = 0
				status.blocking = false
				broadcastFeedback("BlockBroken", { Player = player })
				if Config.DebugVerboseLogging then
					print("[CombatService] " .. player.Name .. "'s block broke (out of stamina)")
				end
			end
		end

		-- Sprint: effectiveness (blocking/stun/dash/exhaustion suppress it),
		-- drain while effective, exhaustion hysteresis, edge feedback.
		local sprintEffective = computeSprintEffective(status, nowv)
		if sprintEffective then
			status.stamina = status.stamina - Config.SprintStaminaDrain * dt
			drained = true
			if status.stamina <= 0 then
				status.stamina = 0
				status.sprintLocked = true -- exhausted until SprintResumeStamina
				sprintEffective = false
				rejectClient(player, "Exhausted", { Ability = "Sprint" })
			end
		elseif status.sprintLocked and status.stamina >= Config.SprintResumeStamina then
			status.sprintLocked = false
		end
		if sprintEffective ~= status.sprintEffective then
			status.sprintEffective = sprintEffective
			broadcastFeedback(sprintEffective and "SprintStart" or "SprintEnd", { Player = player })
		end

		-- Regen only when nothing drained this tick, after a short delay.
		if drained then
			status.lastSpendTime = nowv
		elseif nowv - status.lastSpendTime >= Config.StaminaRegenDelay then
			status.stamina = math.min(Config.StaminaMax,
				status.stamina + Config.StaminaRegenPerSecond * dt)
		end

		-- Publish rounded stamina as a replicated attribute for the future HUD
		-- (only writes when the rounded value actually changes).
		local rounded = math.floor(status.stamina + 0.5)
		if rounded ~= status.publishedStamina then
			status.publishedStamina = rounded
			player:SetAttribute("Stamina", rounded)
		end

		-- Carrier dash collision -> fumble (spec: EggDropOnDashCollision).
		if not status.dashCollisionDone
			and nowv < status.dashUntil
			and Config.EggDropOnDashCollision
			and EggService.GetCarrier() == player
		then
			checkDashCollision(player, status)
		end

		-- Single speed authority (handles dash/stun expiry, block, sprint, carry).
		recalcSpeed(player)
	end
end

local function startTicker()
	task.spawn(function()
		lastTickTime = now()
		while initialized do
			tickOnce()
			task.wait(COMBAT_TICK)
		end
	end)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function CombatService.Init()
	if initialized then
		return
	end
	initialized = true

	-- Remote handlers: ignore ALL client-sent arguments (server computes
	-- targets/directions itself; nothing from the client is trusted).
	RequestAttack.OnServerEvent:Connect(function(player)
		handleAttack(player)
	end)
	RequestThrow.OnServerEvent:Connect(function(player)
		handleThrow(player)
	end)
	RequestDash.OnServerEvent:Connect(function(player)
		handleDash(player)
	end)
	RequestBlockStart.OnServerEvent:Connect(function(player)
		handleBlockStart(player)
	end)
	RequestBlockEnd.OnServerEvent:Connect(function(player)
		handleBlockEnd(player)
	end)
	RequestSprintStart.OnServerEvent:Connect(function(player)
		handleSprintStart(player)
	end)
	RequestSprintEnd.OnServerEvent:Connect(function(player)
		handleSprintEnd(player)
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		bindPlayer(player)
	end
	Players.PlayerAdded:Connect(bindPlayer)
	Players.PlayerRemoving:Connect(function(player)
		statuses[player] = nil
	end)

	startTicker()
	print("[CombatService] Initialized: attack/throw/block/dash/sprint + stamina live")
end

-- Read-only snapshots for other systems / the future GUI.
function CombatService.GetStamina(player)
	return getStatus(player).stamina
end

function CombatService.IsBlocking(player)
	return getStatus(player).blocking
end

function CombatService.IsSprinting(player)
	return getStatus(player).sprintEffective
end

function CombatService.IsDashing(player)
	return now() < getStatus(player).dashUntil
end

function CombatService.HasIFrames(player)
	return now() < getStatus(player).iFramesUntil
end

function CombatService.IsStunned(player)
	return now() < getStatus(player).stunUntil
end

-- One-line snapshot for the DebugCommand "state".
function CombatService.DebugState()
	local parts = {}
	for player, status in pairs(statuses) do
		if player.Parent then
			local flags = {}
			if status.blocking then table.insert(flags, "blocking") end
			if status.sprintEffective then table.insert(flags, "sprinting") end
			if now() < status.dashUntil then table.insert(flags, "dashing") end
			if now() < status.iFramesUntil then table.insert(flags, "iframes") end
			if now() < status.stunUntil then table.insert(flags, "stunned") end
			table.insert(parts, ("%s[sta=%d %s]"):format(
				player.Name, math.floor(status.stamina + 0.5), table.concat(flags, "+")))
		end
	end
	table.sort(parts)
	return #parts > 0 and table.concat(parts, ", ") or "(no players)"
end

return CombatService
