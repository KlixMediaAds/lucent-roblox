local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))

-- Create all RemoteEvents before other modules need them
local RemoteHandler   = require(Shared:WaitForChild("RemoteHandler"))

local TeamManager     = require(script:WaitForChild("TeamManager"))
local ResourceManager = require(script:WaitForChild("ResourceManager"))
local UnitManager     = require(script:WaitForChild("UnitManager"))
local BuildingManager = require(script:WaitForChild("BuildingManager"))
local MineralManager  = require(script:WaitForChild("MineralManager"))
local AIManager       = require(script:WaitForChild("AIManager"))

TeamManager.init()
ResourceManager.init()
MineralManager.init(ResourceManager)
UnitManager.init(ResourceManager)
BuildingManager.init(ResourceManager, MineralManager)
UnitManager.setBuildingManager(BuildingManager)
BuildingManager.setUnitManager(UnitManager)
MineralManager.setBuildingManager(BuildingManager)
AIManager.init(UnitManager, BuildingManager, ResourceManager)

-- ── Elimination callback ──────────────────────────────────────────────────────
BuildingManager.setOnCCDestroyed(function(player)
	UnitManager.removeAllUnitsFor(player)
	BuildingManager.removeAllBuildingsFor(player)   -- also cleans up mines
	ResourceManager.reset(player)

	if player.UserId > 0 then
		-- Real player: tell their client to enter CC placement mode again
		RemoteHandler.get(Config.REMOTES.NeedCommandCenter):FireClient(player)
	else
		-- AI bot: reset its state so it rebuilds
		AIManager.resetBot(player.UserId)
	end
end)

-- ── Player joined ─────────────────────────────────────────────────────────────
Players.PlayerAdded:Connect(function(player)
	-- Tell the client to place their Command Center first
	-- Small delay so the client scripts have time to initialize
	task.delay(2, function()
		if player.Parent then   -- still connected
			RemoteHandler.get(Config.REMOTES.NeedCommandCenter):FireClient(player)
		end
	end)

	-- ── Chat commands ──────────────────────────────────────────────────────
	player.Chatted:Connect(function(msg)
		local lower = msg:lower():match("^%s*(.-)%s*$")
		if lower == "/money" then
			ResourceManager.add(player, 10000)
		end
		local difficulty = lower:match("^/ai%s+(%a+)$")
		if difficulty then
			AIManager.spawnAI(difficulty)
		end
	end)
end)

print("[Server] RTS initialized")
