local Players = game:GetService("Players")

local Network        = require(script:WaitForChild("Network"))
local CameraModule   = require(script:WaitForChild("Camera"))
local BuildingPlacer = require(script:WaitForChild("BuildingPlacer"))
local UnitController = require(script:WaitForChild("UnitController"))
local BarracksPanel  = require(script:WaitForChild("BarracksPanel"))
local MinePanel      = require(script:WaitForChild("MinePanel"))
local HUD            = require(script:WaitForChild("HUD"))

-- Disable default character controls so WASD only moves the RTS camera.
task.spawn(function()
	local ok, PlayerModule = pcall(require,
		Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule"))
	if ok then PlayerModule:GetControls():Disable() end
end)

local function isBlocked(): boolean
	return BuildingPlacer.isActive()
end

-- Initialise in dependency order (earlier init = higher InputBegan priority)
CameraModule.init()
BuildingPlacer.init(Network, CameraModule)

-- HUD must be created before BarracksPanel / MinePanel (both attach to RTSHUD)
local dragFrame, buildBtn, mineBtn, cancelBtn = HUD.create()

UnitController.init(Network, CameraModule, dragFrame, isBlocked)

BarracksPanel.init(Network)
MinePanel.init()

HUD.wire(Network, UnitController, BuildingPlacer, buildBtn, mineBtn, cancelBtn)

-- ── Barracks panel ────────────────────────────────────────────────────────────
UnitController.onBarracksSelected(function(barrackId: string?)
	if barrackId then
		BarracksPanel.show(barrackId)
	else
		BarracksPanel.hide()
	end
end)

-- ── Mineral / Mine wiring ─────────────────────────────────────────────────────

-- Receive the initial deposit list and give it to BuildingPlacer for Mine snapping
Network.onSyncDeposits(function(positions: {Vector3})
	BuildingPlacer.setDepositPositions(positions)
end)

-- When a deposit is claimed, remove it from the Mine ghost's snap candidates
Network.onDepositClaimed(function(pos: Vector3)
	BuildingPlacer.removeDeposit(pos)
end)

local localUserId = Players.LocalPlayer.UserId

-- Track mines and miner counts for this player's MinePanel
Network.onBuildingPlaced(function(id: string, ownerId: number, _pos: Vector3, buildingType: string)
	if buildingType == "Mine" and ownerId == localUserId then
		MinePanel.registerMine(id)
	end
end)

Network.onMinerSpawned(function(mineId: string, ownerUserId: number, minerCount: number)
	if ownerUserId == localUserId then
		MinePanel.updateMinerCount(mineId, minerCount)
	end
end)
