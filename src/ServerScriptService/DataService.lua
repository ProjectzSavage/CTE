--[[
	DataService (ServerScriptService.DataService)
	=============================================
	STATUS: reserved for later -- intentionally empty.

	Future responsibilities
	-----------------------
	* ProfileStore/SessionLock persistence (wins, losses, MVPs, cosmetics).
	* Load on PlayerAdded, save on PlayerRemoving / BindToClose.

	No DataStore calls are made yet (the game is structure-only at this stage
	and DataStores need a published game + API access enabled).
]]

local DataService = {}

function DataService.Init()
	-- TODO(data): persistence, wired up in a later pass.
	print("[DataService] stub initialized (persistence comes later)")
end

return DataService
