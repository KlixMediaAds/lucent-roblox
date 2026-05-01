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

-- ── Map boundary walls ────────────────────────────────────────────────────────
-- Four permanent rock walls seal the ±432 play area.  Always present regardless
-- of the terrain toggle; units and buildings are clamped/rejected in code too.
do
	local BOUND     = 432
	local THICKNESS = 20
	local HEIGHT    = 20
	local OT        = THICKNESS / 2       -- 10: half-thickness
	local OVER      = BOUND + THICKNESS   -- 452: overhang fills the corners

	local folder        = Instance.new("Folder")
	folder.Name         = "MapBoundary"
	folder.Parent       = workspace

	local walls = {
		{ cx = 0,           cz =  BOUND + OT, hw = OVER, hd = OT   }, -- north
		{ cx = 0,           cz = -(BOUND+OT), hw = OVER, hd = OT   }, -- south
		{ cx =  BOUND + OT, cz = 0,           hw = OT,   hd = OVER }, -- east
		{ cx = -(BOUND+OT), cz = 0,           hw = OT,   hd = OVER }, -- west
	}
	for _, w in walls do
		local p         = Instance.new("Part")
		p.Name          = "BoundaryWall"
		p.Size          = Vector3.new(w.hw * 2, HEIGHT, w.hd * 2)
		p.CFrame        = CFrame.new(w.cx, HEIGHT / 2, w.cz)
		p.Material      = Enum.Material.Rock
		p.BrickColor    = BrickColor.new("Dark stone grey")
		p.Anchored      = true
		p.CanCollide    = false
		p.CanQuery      = false
		p.CastShadow    = true
		p.Parent        = folder
	end
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
local TerrainManager   = require(script:WaitForChild("TerrainManager"))

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

-- ── Game end / reset ──────────────────────────────────────────────────────────
local gameResetInProgress = false
local gameStartTime       = os.clock()

local function triggerEndGame(winnerUserId: number, reason: string)
	if gameResetInProgress then return end
	gameResetInProgress = true

	local statsTable = {}
	local duration   = math.max(0, math.floor(os.clock() - gameStartTime))
	for _, player in Players:GetPlayers() do
		if player.UserId > 0 then
			local rs = ResearchManager.getStats(player)
			statsTable[tostring(player.UserId)] = {
				kills           = rs.kills,
				unitsTrained    = rs.unitsTrained,
				buildingsBuilt  = rs.buildingsBuilt,
				resourcesEarned = ResourceManager.getTotalEarned(player),
			}
		end
	end

	RemoteHandler.get(Config.REMOTES.ShowEndScreen):FireAllClients(winnerUserId, reason, statsTable, duration)

	task.wait(10)

	UnitManager.resetAll()
	BuildingManager.resetAll()

	for _, player in Players:GetPlayers() do
		ResourceManager.reset(player)
		ResearchManager.resetPlayer(player)
	end

	MineralManager.resetAll()
	AIManager.resetAllBots()
	gameStartTime = os.clock()

	for _, player in Players:GetPlayers() do
		RemoteHandler.get(Config.REMOTES.NeedCommandCenter):FireClient(player)
	end

	gameResetInProgress = false
end

-- ── Elimination callback ──────────────────────────────────────────────────────
BuildingManager.setOnCCDestroyed(function(player)
	UnitManager.removeAllUnitsFor(player)
	BuildingManager.removeAllBuildingsFor(player)

	if player.UserId > 0 then
		local totalReal = 0
		local remainingWithCC = {}
		for _, p in Players:GetPlayers() do
			if p.UserId > 0 then
				totalReal += 1
				if BuildingManager.hasCommandCenter(p) then
					table.insert(remainingWithCC, p)
				end
			end
		end
		if totalReal >= 2 and #remainingWithCC == 1 then
			-- Don't reset stats yet — triggerEndGame collects them first
			triggerEndGame(remainingWithCC[1].UserId, "elimination")
		else
			ResourceManager.reset(player)
			ResearchManager.resetPlayer(player)
			RemoteHandler.get(Config.REMOTES.NeedCommandCenter):FireClient(player)
		end
	else
		ResourceManager.reset(player)
		ResearchManager.resetPlayer(player)
		AIManager.resetBot(player.UserId)
	end
end)

-- ── Monument win ──────────────────────────────────────────────────────────────
BuildingManager.setOnPlayerWon(function(winnerUserId: number)
	triggerEndGame(winnerUserId, "monument")
end)

-- ── Chat commands (always active, not gated by lobby) ────────────────────────
local function connectChatForPlayer(player: Player)
	player.Chatted:Connect(function(msg)
		local lower = msg:lower():match("^%s*(.-)%s*$")
		if lower == "/money" then
			ResourceManager.add(player, 10000)
		end
		if lower == "/end" then
			triggerEndGame(player.UserId, "debug")
		end
		local personality, lvStr = lower:match("^/ai%s+(%a+)%s*(%d*)$")
		if personality then
			AIManager.spawnAI(personality, tonumber(lvStr) or 3)
		end
	end)
end

Players.PlayerAdded:Connect(connectChatForPlayer)
for _, player in Players:GetPlayers() do
	connectChatForPlayer(player)
end

-- ── Lobby → game handoff ──────────────────────────────────────────────────────
LobbyManager.init(MineralManager, TerrainManager, function(aiQueue)
	gameStartTime = os.clock()

	-- Send all human players to CC placement mode
	local humanPlayers = Players:GetPlayers()
	for _, player in humanPlayers do
		task.delay(1, function()
			if player.Parent then
				RemoteHandler.get(Config.REMOTES.NeedCommandCenter):FireClient(player)
			end
		end)
	end

	Players.PlayerAdded:Connect(function(player)
		task.delay(2, function()
			if player.Parent then
				RemoteHandler.get(Config.REMOTES.NeedCommandCenter):FireClient(player)
			end
		end)
	end)

	-- Spawn AI bots AFTER all human players have placed their Command Centers.
	-- This prevents AI CCs from blocking player spawn locations.
	if #aiQueue > 0 then
		task.spawn(function()
			local CC_WAIT_TIMEOUT = 300  -- 5 minutes max
			local elapsed = 0

			while elapsed < CC_WAIT_TIMEOUT do
				task.wait(1)
				elapsed += 1

				local allPlaced = true
				local humanCount = 0
				for _, player in Players:GetPlayers() do
					humanCount += 1
					if not BuildingManager.hasCommandCenter(player) then
						allPlaced = false
					end
				end

				-- Proceed once all connected humans have placed, or if nobody remains
				if humanCount == 0 or allPlaced then break end
			end

			-- Spawn each queued AI with a small stagger so base-selection is accurate
			for _, entry in aiQueue do
				AIManager.spawnAI(entry.personality, entry.level)
				task.wait(0.8)
			end
		end)
	end
end)

print("[Server] RTS initialized")
