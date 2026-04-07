local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))

-- Create all RemoteEvents before other modules need them
local RemoteHandler   = require(Shared:WaitForChild("RemoteHandler"))

local TeamManager      = require(script:WaitForChild("TeamManager"))
local ResourceManager  = require(script:WaitForChild("ResourceManager"))
local UnitManager      = require(script:WaitForChild("UnitManager"))
local BuildingManager  = require(script:WaitForChild("BuildingManager"))
local MineralManager   = require(script:WaitForChild("MineralManager"))
local ResearchManager  = require(script:WaitForChild("ResearchManager"))
local AIManager        = require(script:WaitForChild("AIManager"))

TeamManager.init()
ResourceManager.init()
ResearchManager.init()
MineralManager.init(ResourceManager)
MineralManager.setResearchManager(ResearchManager)
UnitManager.init(ResourceManager)
UnitManager.setResearchManager(ResearchManager)
BuildingManager.init(ResourceManager, MineralManager)
UnitManager.setBuildingManager(BuildingManager)
BuildingManager.setUnitManager(UnitManager)
MineralManager.setBuildingManager(BuildingManager)
AIManager.init(UnitManager, BuildingManager, ResourceManager)
AIManager.setResearchManager(ResearchManager)

-- ── Elimination callback ──────────────────────────────────────────────────────
BuildingManager.setOnCCDestroyed(function(player)
	UnitManager.removeAllUnitsFor(player)
	BuildingManager.removeAllBuildingsFor(player)   -- also cleans up mines
	ResourceManager.reset(player)
	ResearchManager.resetPlayer(player)

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

-- ── Game reset after a player wins ───────────────────────────────────────────
local gameResetInProgress = false

BuildingManager.setOnPlayerWon(function()
	if gameResetInProgress then return end
	gameResetInProgress = true

	task.wait(8)   -- let players read the victory/defeat screen

	UnitManager.resetAll()
	BuildingManager.resetAll()

	for _, player in Players:GetPlayers() do
		ResourceManager.reset(player)
		ResearchManager.resetPlayer(player)
	end

	MineralManager.resetAll()
	AIManager.resetAllBots()

	for _, player in Players:GetPlayers() do
		RemoteHandler.get(Config.REMOTES.NeedCommandCenter):FireClient(player)
	end

	gameResetInProgress = false
end)

print("[Server] RTS initialized")
