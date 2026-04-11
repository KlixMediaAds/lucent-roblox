local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))

-- ── Terrain generation ────────────────────────────────────────────────────────
-- Flat grass ground. The map is ±432 studs; we fill 960×960 to include a
-- small border beyond the play area. Top surface lands at Y = 0.
do
	local terrain = workspace.Terrain
	terrain:Clear()
	-- Voxels are on a 4-stud grid; filling Y=−8→0 placed the Y=0 voxel (top face
	-- at Y=+2) above all game objects.  Lower the fill so the topmost voxel tops
	-- out at Y≈−2, keeping the visual surface clearly below the Y=0 game floor.
	terrain:FillBlock(
		CFrame.new(0, -8, 0),          -- centre: fills Y = -12 → -4
		Vector3.new(960, 8, 960),
		Enum.Material.Grass
	)
end

-- Create all RemoteEvents before other modules need them
local RemoteHandler   = require(Shared:WaitForChild("RemoteHandler"))

local TeamManager      = require(script:WaitForChild("TeamManager"))
local ResourceManager  = require(script:WaitForChild("ResourceManager"))
local UnitManager      = require(script:WaitForChild("UnitManager"))
local BuildingManager  = require(script:WaitForChild("BuildingManager"))
local MineralManager   = require(script:WaitForChild("MineralManager"))
local ResearchManager  = require(script:WaitForChild("ResearchManager"))
local AIManager        = require(script:WaitForChild("AIManager"))
local LobbyManager     = require(script:WaitForChild("LobbyManager"))

TeamManager.init()
ResourceManager.init()
ResearchManager.init()
MineralManager.init(ResourceManager)
MineralManager.setResearchManager(ResearchManager)
UnitManager.init(ResourceManager)
UnitManager.setResearchManager(ResearchManager)
BuildingManager.init(ResourceManager, MineralManager)
UnitManager.setBuildingManager(BuildingManager)
UnitManager.setMineralManager(MineralManager)
BuildingManager.setUnitManager(UnitManager)
BuildingManager.setResearchManager(ResearchManager)
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

-- ── Chat commands (always active, not gated by lobby) ────────────────────────
Players.PlayerAdded:Connect(function(player)
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

-- ── Lobby → game handoff ──────────────────────────────────────────────────────
LobbyManager.init(MineralManager, function()
	-- Tell every connected player to place their Command Center
	for _, player in Players:GetPlayers() do
		task.delay(1, function()
			if player.Parent then
				RemoteHandler.get(Config.REMOTES.NeedCommandCenter):FireClient(player)
			end
		end)
	end
	-- Wire up late-joiners (shouldn't happen after lobby ends, but just in case)
	Players.PlayerAdded:Connect(function(player)
		task.delay(2, function()
			if player.Parent then
				RemoteHandler.get(Config.REMOTES.NeedCommandCenter):FireClient(player)
			end
		end)
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
