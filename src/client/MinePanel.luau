--!strict
--[[
    MinePanel — Command-card page shown when a Foundry is selected.
    The Foundry has no upgrades/purchases yet, so it just shows a "coming soon"
    message (the structure itself is not shown as a tile).
]]

local CommandCard = require(script.Parent:WaitForChild("CommandCard"))

local MinePanel = {}
local OWNER     = "foundry"

local activeMineId: string? = nil
local networkRef:   any

function MinePanel.init(network, _getResourcesFn, _hasResearchFn)
	networkRef = network
end

function MinePanel.show(mineId: string)
	activeMineId = mineId
	CommandCard.showMessage(OWNER, "FOUNDRY", "Upgrades coming soon!")
end

function MinePanel.hide()
	activeMineId = nil
	CommandCard.hide(OWNER)
end

function MinePanel.refreshIfVisible()
	-- No dynamic content.
end

return MinePanel
