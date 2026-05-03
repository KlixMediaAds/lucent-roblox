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

-- ── Symmetric player base positions ──────────────────────────────────────────
-- CCs are placed in 180°-opposite pairs so each player starts on a different
-- side of the map.  Assigned in join order (1st human gets index 1, etc.).
-- Y = COMMAND_CENTER_SIZE.Y / 2 so the base sits on the Y=0 floor.
local PLAYER_BASES: { Vector3 } = {
	Vector3.new(-120, Config.COMMAND_CENTER_SIZE.Y / 2, -280),  -- south-west
	Vector3.new( 120, Config.COMMAND_CENTER_SIZE.Y / 2,  280),  -- north-east (opposite)
	Vector3.new( 120, Config.COMMAND_CENTER_SIZE.Y / 2, -280),  -- south-east
	Vector3.new(-120, Config.COMMAND_CENTER_SIZE.Y / 2,  280),  -- north-west (opposite)
}
local nextBaseIndex = 0

-- Returns two mine positions offset from ccPos in its home direction.
local function minePositionsFor(ccPos: Vector3): (Vector3, Vector3)
	local GRID    = Config.BUILDING_GRID
	local mineY   = Config.BUILDING_SIZE.Y / 2
	local flat    = Vector3.new(ccPos.X, 0, ccPos.Z)
	local homeDir = flat.Magnitude > 0.1 and flat.Unit or Vector3.new(0, 0, 1)
	local perpDir = Vector3.new(-homeDir.Z, 0, homeDir.X)
	local function snap(v: Vector3): Vector3
		return Vector3.new(
			math.round(v.X / GRID) * GRID,
			mineY,
			math.round(v.Z / GRID) * GRID
		)
	end
	return
		snap(flat + homeDir * 28 + perpDir *  20),
		snap(flat + homeDir * 28 + perpDir * -20)
end

-- Seats the player's avatar on top of their CC and locks them there.
-- The Seat is parented to the CC model so model:PivotTo() (mobile CC) carries it along.
local function seatAvatarOnCC(player: Player, ccId: string)
	task.spawn(function()
		local buildingsF = workspace:FindFirstChild("Buildings") :: Folder?
		if not buildingsF then return end
		local ccModel = buildingsF:FindFirstChild(ccId) :: Model?
		if not ccModel or not ccModel:IsA("Model") then return end
		local ccBase = ccModel:FindFirstChild("Base") :: BasePart?
		if not ccBase then return end

		local seat        = Instance.new("Seat")
		seat.Name         = "AvatarSeat"
		seat.Size         = Vector3.new(4, 0.05, 4)
		seat.Transparency = 1
		seat.CanCollide   = false
		seat.Anchored     = false
		seat.CFrame       = ccBase.CFrame * CFrame.new(0, Config.COMMAND_CENTER_SIZE.Y / 2 + 0.05, 0)
		seat.Parent       = ccModel

		-- Weld keeps the seat rigid with the base even if physics nudges it
		local weld  = Instance.new("WeldConstraint")
		weld.Part0  = ccBase
		weld.Part1  = seat
		weld.Parent = seat

		local char = player.Character or player.CharacterAdded:Wait()
		local hum  = char:WaitForChild("Humanoid", 5) :: Humanoid?
		if not hum or not seat.Parent then return end

		task.wait(0.3)  -- let character physics settle before sitting
		if not seat.Parent then return end
		seat:Sit(hum)
		hum.JumpPower = 0
	end)
end

-- Auto-sets up a human player's starting base: CC + deposits + 2 instant mines.
local function setupPlayerBase(player: Player)
	nextBaseIndex += 1
	local base = PLAYER_BASES[nextBaseIndex] or PLAYER_BASES[1]

	local _, ccId = BuildingManager.placeForPlayer(player, base, "CommandCenter")
	MineralManager.spawnDepositsForBase(base, 5)

	local m1, m2 = minePositionsFor(base)
	ResourceManager.add(player, Config.MINE_COST)
	BuildingManager.placeInstantForPlayer(player, m1, "Mine")
	ResourceManager.add(player, Config.MINE_COST)
	BuildingManager.placeInstantForPlayer(player, m2, "Mine")

	if ccId then seatAvatarOnCC(player, ccId) end
end

-- ── Lobby → game handoff ──────────────────────────────────────────────────────
LobbyManager.init(MineralManager, TerrainManager, function(aiQueue)
	gameStartTime = os.clock()
	nextBaseIndex = 0

	-- Auto-place every human player's CC, deposits, and starter mines
	for _, player in Players:GetPlayers() do
		setupPlayerBase(player)
	end

	-- Late joiners also get auto-placed bases
	Players.PlayerAdded:Connect(function(player)
		task.delay(1, function()
			if player.Parent and not BuildingManager.hasCommandCenter(player) then
				setupPlayerBase(player)
			end
		end)
	end)

	-- Spawn AI bots immediately — no need to wait since CCs are already placed
	if #aiQueue > 0 then
		task.spawn(function()
			for _, entry in aiQueue do
				AIManager.spawnAI(entry.personality, entry.level)
				task.wait(0.8)
			end
		end)
	end
end)

print("[Server] RTS initialized")
