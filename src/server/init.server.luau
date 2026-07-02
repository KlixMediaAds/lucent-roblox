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
local ForestManager    = require(script:WaitForChild("ForestManager"))
local NavGrid          = require(script:WaitForChild("NavGrid"))

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

ForestManager.init(MineralManager)
ForestManager.setTerrainManager(TerrainManager)
BuildingManager.setForestManager(ForestManager)
BuildingManager.setTerrainManager(TerrainManager)
UnitManager.setForestManager(ForestManager)
MineralManager.setForestManager(ForestManager)

NavGrid.setTerrainManager(TerrainManager)
UnitManager.setTerrainManager(TerrainManager)
UnitManager.setNavGrid(NavGrid)
MineralManager.setTerrainManager(TerrainManager)

-- ── Game end / reset ──────────────────────────────────────────────────────────
local gameResetInProgress = false
local gameStartTime       = os.clock()

-- Base-assignment + gamemode state. Hoisted here (above triggerEndGame /
-- onCCDestroyed) so every handler shares one set of variables rather than
-- closing over a later, separate declaration.
local nextBaseIndex   = 0
local nextLaneAIIdx   = 0
local currentGamemode = "Default"

-- Default-mode base delivery (defined later; forward-declared so the reset /
-- elimination handlers above its definition can call it).
local playerBasePos: { [number]: Vector3 } = {}
local deliverBaseForPlayer: (Player) -> ()

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

	-- Notify clients to reset their CC state
	for _, player in Players:GetPlayers() do
		RemoteHandler.get(Config.REMOTES.NeedCommandCenter):FireClient(player)
	end

	-- Re-establish bases for the new round.
	if currentGamemode == "Lane" then
		nextBaseIndex = 0
		nextLaneAIIdx = 0
		task.wait(0.1)  -- let NeedCommandCenter process first
		for _, player in Players:GetPlayers() do
			setupLanePlayerBase(player)
		end
	else
		-- Default mode: place a fresh Command Center for every player.
		nextBaseIndex = 0
		playerBasePos = {}
		task.wait(0.1)  -- let NeedCommandCenter reset client state first
		for _, player in Players:GetPlayers() do
			deliverBaseForPlayer(player)
		end
	end

	-- Regrow the forest for the new round (CCs carve their own clearing).
	ForestManager.generate()

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
			-- Not the final 1v1: show this player a DEFEAT screen with PLAY AGAIN
			-- instead of silently respawning. Gather their stats before resetting.
			local rs    = ResearchManager.getStats(player)
			local stats = {
				[tostring(player.UserId)] = {
					kills           = rs.kills,
					unitsTrained    = rs.unitsTrained,
					buildingsBuilt  = rs.buildingsBuilt,
					resourcesEarned = ResourceManager.getTotalEarned(player),
				},
			}
			local duration = math.max(0, math.floor(os.clock() - gameStartTime))

			ResourceManager.reset(player)
			ResearchManager.resetPlayer(player)
			playerBasePos[player.UserId] = nil
			-- NeedCommandCenter resets the client HUD (it hides the win overlay);
			-- fire it first so the defeat screen shows on top of a clean state.
			RemoteHandler.get(Config.REMOTES.NeedCommandCenter):FireClient(player)
			RemoteHandler.get(Config.REMOTES.ShowDefeatScreen):FireClient(player, stats, duration)
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

-- ── Forfeit (player chose "Leave Match" from the in-game menu) ─────────────────
-- Destroys the forfeiter's Command Center, routing through the normal elimination
-- flow (DEFEAT screen vs others, or a base reset in solo/AI matches).
RemoteHandler.get(Config.REMOTES.ForfeitMatch).OnServerEvent:Connect(function(player)
	BuildingManager.forfeit(player)
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

-- Lane mode bases: players at the south end (Z≈−290), AI at the north end (Z≈+290)
local LANE_PLAYER_BASES: { Vector3 } = {
	Vector3.new(  0, Config.COMMAND_CENTER_SIZE.Y / 2, -290),
	Vector3.new(-50, Config.COMMAND_CENTER_SIZE.Y / 2, -290),
	Vector3.new( 50, Config.COMMAND_CENTER_SIZE.Y / 2, -290),
	Vector3.new(  0, Config.COMMAND_CENTER_SIZE.Y / 2, -310),
}
local LANE_AI_BASES: { Vector3 } = {
	Vector3.new(  0, Config.COMMAND_CENTER_SIZE.Y / 2,  290),
	Vector3.new(-50, Config.COMMAND_CENTER_SIZE.Y / 2,  290),
	Vector3.new( 50, Config.COMMAND_CENTER_SIZE.Y / 2,  290),
}

-- Nudges a desired XZ spot to the nearest grid-snapped position whose
-- footprint sits entirely on one terrain level, searching outward in a
-- small spiral. Falls back to the (grid-snapped) desired spot if nothing
-- flat turns up nearby — shouldn't happen given how wide the plateaus are.
local function findFlatSpot(desired: Vector3, halfX: number, halfZ: number): Vector3
	local GRID = Config.BUILDING_GRID
	local function snap(v: Vector3): Vector3
		return Vector3.new(math.round(v.X / GRID) * GRID, 0, math.round(v.Z / GRID) * GRID)
	end
	local base = snap(desired)
	if TerrainManager.isFootprintFlat(base.X, base.Z, halfX, halfZ) then
		return base
	end
	for radius = 1, 12 do
		local d = radius * GRID
		for _, offset in { Vector3.new(d, 0, 0), Vector3.new(-d, 0, 0),
			Vector3.new(0, 0, d), Vector3.new(0, 0, -d),
			Vector3.new(d, 0, d), Vector3.new(-d, 0, d),
			Vector3.new(d, 0, -d), Vector3.new(-d, 0, -d) } do
			local cand = snap(base + offset)
			if TerrainManager.isFootprintFlat(cand.X, cand.Z, halfX, halfZ) then
				return cand
			end
		end
	end
	return base
end

-- Seats the player's avatar on the CC's operator pulpit (the roof centre is
-- now the reactor pit / dropship fabrication bay).
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
		if ccModel:GetAttribute("SwarmCC") then
			-- The Hollowed spike has no operator pulpit; perch the avatar on top of the
			-- base at centre instead of floating where the Human pulpit would be.
			seat.CFrame = ccBase.CFrame * CFrame.new(0, Config.COMMAND_CENTER_SIZE.Y / 2 + 0.65, 0)
		else
			-- Pulpit deck top sits 0.6 studs above the roof at local (-5.6, 0); face the reactor
			seat.CFrame = ccBase.CFrame
				* CFrame.new(-5.6, Config.COMMAND_CENTER_SIZE.Y / 2 + 0.65, 0)
				* CFrame.Angles(0, -math.pi / 2, 0)
		end
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

-- Sets up a player base for lane mode: auto-placed CC + extra starting resources.
local function setupLanePlayerBase(player: Player)
	nextBaseIndex += 1
	local base = LANE_PLAYER_BASES[((nextBaseIndex - 1) % #LANE_PLAYER_BASES) + 1]
	local _, ccId = BuildingManager.placeForPlayer(player, base, "CommandCenter")
	ResourceManager.add(player, 600)  -- extra resources since there are no mines
	if ccId then seatAvatarOnCC(player, ccId) end
end

-- ── Base delivery (default mode) ──────────────────────────────────────────────
-- Default mode places the player's Command Center instantly at their base spot
-- (and seeds nearby deposits). Lane mode uses setupLanePlayerBase instead.
function deliverBaseForPlayer(player: Player)
	-- Idempotent: never place a second CC.
	if BuildingManager.hasCommandCenter(player) then return end

	local uid  = player.UserId
	local base = playerBasePos[uid]
	if not base then
		nextBaseIndex += 1
		local desired = PLAYER_BASES[nextBaseIndex] or PLAYER_BASES[1]
		local ccHalf  = Config.COMMAND_CENTER_SIZE.X / 2
		base = findFlatSpot(desired, ccHalf, ccHalf)
		playerBasePos[uid] = base
		-- Seed deposits near the chosen base so there's ore to mine.
		MineralManager.spawnDepositsForBase(base, 5)
	end

	local _, ccId = BuildingManager.placeForPlayer(player, base, "CommandCenter")
	if ccId then seatAvatarOnCC(player, ccId) end
end

-- ── Play Again (clicked PLAY AGAIN on the defeat screen) ──────────────────────
-- Respawns the player's base into the still-running match. Defined after the base
-- helpers so they're in lexical scope.
RemoteHandler.get(Config.REMOTES.PlayAgain).OnServerEvent:Connect(function(player)
	if player.UserId <= 0 then return end
	if BuildingManager.hasCommandCenter(player) then return end
	playerBasePos[player.UserId] = nil
	if currentGamemode == "Lane" then
		setupLanePlayerBase(player)
	else
		deliverBaseForPlayer(player)
	end
end)

-- ── Lobby → game handoff ──────────────────────────────────────────────────────
LobbyManager.init(MineralManager, TerrainManager, function(aiQueue, gamemode)
	gameStartTime     = os.clock()
	nextBaseIndex     = 0
	nextLaneAIIdx     = 0
	currentGamemode   = gamemode or "Default"

	local isLane = currentGamemode == "Lane"

	BuildingManager.setLaneMode(isLane)
	UnitManager.setLaneMode(isLane)

	if isLane then
		TerrainManager.generateLane()
	end

	-- Build the navigation grid from the now-final terrain so units route around
	-- cliffs and up ramps.
	NavGrid.rebuild()

	-- Auto-place every human player's base: an instant Command Center at their
	-- base spot (lane mode adds extra resources via setupLanePlayerBase).
	for _, player in Players:GetPlayers() do
		if isLane then
			setupLanePlayerBase(player)
		else
			deliverBaseForPlayer(player)
		end
	end

	-- Grow the forest now that bases/deposits exist (it avoids both).
	ForestManager.generate()

	-- Late joiners also get auto-placed bases
	Players.PlayerAdded:Connect(function(player)
		task.delay(1, function()
			if player.Parent and not BuildingManager.hasCommandCenter(player) then
				if isLane then
					setupLanePlayerBase(player)
				else
					deliverBaseForPlayer(player)
				end
			end
		end)
	end)

	-- Swarm gamemode: every AI bot fields a nest/creepy army instead of the
	-- standard Barracks composition.
	AIManager.setSwarmMode(currentGamemode == "Swarm")

	-- Spawn AI bots
	if #aiQueue > 0 then
		task.spawn(function()
			for _, entry in aiQueue do
				if isLane then
					local laneBase = LANE_AI_BASES[(nextLaneAIIdx % #LANE_AI_BASES) + 1]
					nextLaneAIIdx += 1
					AIManager.spawnAI(entry.personality, entry.level, laneBase)
				else
					AIManager.spawnAI(entry.personality, entry.level)
				end
				task.wait(0.8)
			end
		end)
	end
end)

print("[Server] RTS initialized")
