--[[
	MatchService (ServerScriptService.MatchService)
	===============================================
	STATUS: stub -- gameplay not implemented yet.

	Future responsibilities
	-----------------------
	* Own the match state machine:
	    Lobby -> Countdown -> Round (Config.RoundLength seconds)
	          -> RoundEnd -> (next round | MatchEnd) -> Lobby
	* Best of Config.RoundsPerMatch rounds; first to Config.RoundsToWinMatch
	  round wins takes the match.
	* Broadcast MatchStateChanged / RoundEnded / MatchEnded to all clients.
	* Coordinate the other services: tell EggService when to spawn/reset the
	  egg, freeze combat at round end, ask ScoringService for the round winner
	  (most total hold time) and the match MVP (most hold time across rounds).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Config"))

local MatchService = {}

function MatchService.Init()
	-- TODO(match): build the state machine described above.
	if Config.DebugVerboseLogging then
		print("[MatchService] stub initialized")
	end
end

return MatchService
