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
-- Performance-graph timeline: every TIMELINE_DT seconds we snapshot every combatant's
-- (human players AND AI bots) cumulative kills, so the end screen can chart a universal
-- kills-over-time line per commander. Keyed by owner id string.
-- `matchGen` is bumped each match start/end so a stale sampler task self-exits.
local TIMELINE_DT         = 5
local killTimeline: { [string]: { number } } = {}
local matchGen            = 0

-- One timeline sample: append every combatant's current cumulative kills.
local function sampleTimeline()
	local tally = UnitManager.getKillTally()
	local function record(idStr: string)
		local arr = killTimeline[idStr]
		if not arr then arr = {}; killTimeline[idStr] = arr end
		arr[#arr + 1] = tally[idStr] or 0
	end
	for _, p in Players:GetPlayers() do
		if p.UserId > 0 then record(tostring(p.UserId)) end
	end
	for _, bot in AIManager.getBotsForGraph() do
		record(tostring(bot.userId))
	end
end

-- Universal graph payload: one series per combatant (players + AI), each with its
-- sampled kill timeline and final total. Stashed under statsTable["__graph"].
local function buildGraphData(winnerUserId: number): any
	local tally  = UnitManager.getKillTally()
	local series = {}
	local function add(idStr: string, name: string, isAI: boolean, userId: number)
		table.insert(series, {
			id       = idStr,
			name     = name,
			isAI     = isAI,
			isWinner = userId == winnerUserId,
			samples  = killTimeline[idStr] or {},
			final    = tally[idStr] or 0,
		})
	end
	for _, p in Players:GetPlayers() do
		if p.UserId > 0 then add(tostring(p.UserId), p.Name, false, p.UserId) end
	end
	for _, bot in AIManager.getBotsForGraph() do
		add(tostring(bot.userId), bot.name, true, bot.userId)
	end
	return { dt = TIMELINE_DT, series = series }
end
-- The match has been decided (an end screen is up). While true, a RETURN TO MENU
-- press resets straight to the ready-up lobby with no surrender vote.
local matchOver           = false
-- True from the moment a return-to-lobby reset begins until the lobby is re-opened, so
-- late/duplicate leave requests during that window are ignored (no spurious vote).
local returningToLobby    = false
-- A pending multiplayer surrender-restart vote, or nil. `needed` is the set of other
-- human userIds whose yes is required; `votes` records the yes answers received.
local pendingSurrender: { requester: Player, needed: { [number]: boolean }, votes: { [number]: boolean } }? = nil

-- Base-assignment + gamemode state. Hoisted here (above triggerEndGame /
-- onCCDestroyed) so every handler shares one set of variables rather than
-- closing over a later, separate declaration.
local nextBaseIndex   = 0
local nextLaneAIIdx   = 0
local currentGamemode = "Default"
local laneModeActive  = false   -- current match's lane flag (read by the persistent late-joiner handler)
local lateJoinerConnected = false

-- Default-mode base delivery (defined later; forward-declared so the reset /
-- elimination handlers above its definition can call it).
local playerBasePos: { [number]: Vector3 } = {}
local deliverBaseForPlayer: (Player) -> ()

-- Reset the whole match and re-open the ready-up lobby. Everyone lands back on the
-- ready-up menu; pressing READY starts a fresh match through the normal lobby handoff.
local function returnToLobby()
	if gameResetInProgress then return end
	gameResetInProgress = true
	returningToLobby = true
	pendingSurrender = nil
	matchOver        = false
	matchGen        += 1   -- stop any running timeline sampler

	UnitManager.resetAll()
	BuildingManager.resetAll()
	for _, player in Players:GetPlayers() do
		ResourceManager.reset(player)
		ResearchManager.resetPlayer(player)
	end
	MineralManager.resetAll()
	AIManager.resetAllBots()

	nextBaseIndex = 0
	nextLaneAIIdx = 0
	playerBasePos = {}
	gameStartTime = os.clock()

	-- Tell every client the match is over → show the ready-up menu again.
	RemoteHandler.get(Config.REMOTES.ReturnToLobby):FireAllClients()
	gameResetInProgress = false

	-- Re-open the server lobby a beat later so its LobbySync lands AFTER clients have
	-- rebuilt their ready-up UI (which they do on the ReturnToLobby event above).
	task.delay(0.35, function()
		LobbyManager.reopen()
		returningToLobby = false
	end)
end

-- Declare the match decided and show the end screen. Players return to the ready-up
-- menu only when they press RETURN TO MENU (no auto-return) → routes through
-- LeaveToLobby, which resets immediately because matchOver is set here.
local function triggerEndGame(winnerUserId: number, reason: string)
	if matchOver or gameResetInProgress then return end
	matchOver = true
	matchGen += 1   -- stop the timeline sampler

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
	statsTable["__graph"] = buildGraphData(winnerUserId)

	RemoteHandler.get(Config.REMOTES.ShowEndScreen):FireAllClients(winnerUserId, reason, statsTable, duration)
end

-- ── Elimination callback ──────────────────────────────────────────────────────
BuildingManager.setOnCCDestroyed(function(player)
	UnitManager.removeAllUnitsFor(player)
	BuildingManager.removeAllBuildingsFor(player)

	-- Who is still in the match — real players AND AI bots that own a Command Center?
	-- If exactly one commander is left and it is a real player, they've wiped out every
	-- enemy (including all AI bots in a solo skirmish) → declare their victory. This runs
	-- before the respawn logic below, so a defeated AI is not immediately rebuilt.
	local remaining = BuildingManager.getCommanderUserIdsWithCC()
	if #remaining == 1 and remaining[1] > 0 then
		triggerEndGame(remaining[1], "elimination")
		return
	end

	if player.UserId > 0 then
		-- The match isn't decided yet (enemies remain): show this player a DEFEAT screen
		-- with PLAY AGAIN instead of silently respawning. Gather their stats first.
		local rs    = ResearchManager.getStats(player)
		local stats = {
			[tostring(player.UserId)] = {
				kills           = rs.kills,
				unitsTrained    = rs.unitsTrained,
				buildingsBuilt  = rs.buildingsBuilt,
				resourcesEarned = ResourceManager.getTotalEarned(player),
			},
		}
		stats["__graph"] = buildGraphData(-1)
		local duration = math.max(0, math.floor(os.clock() - gameStartTime))

		ResourceManager.reset(player)
		ResearchManager.resetPlayer(player)
		playerBasePos[player.UserId] = nil
		-- NeedCommandCenter resets the client HUD (it hides the win overlay);
		-- fire it first so the defeat screen shows on top of a clean state.
		RemoteHandler.get(Config.REMOTES.NeedCommandCenter):FireClient(player)
		RemoteHandler.get(Config.REMOTES.ShowDefeatScreen):FireClient(player, stats, duration)
	else
		-- An AI bot lost its last CC but other commanders remain: eliminate it for the
		-- rest of this round (it won't rebuild) rather than respawning it, so the player
		-- can defeat every enemy and win. resetAllBots brings it back next round.
		ResourceManager.reset(player)
		ResearchManager.resetPlayer(player)
		AIManager.eliminateBot(player.UserId)
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

-- ── Leave / return to the ready-up lobby (+ multiplayer surrender vote) ────────
-- Solo (one human) or an already-decided match → reset straight to the ready-up menu.
-- Multiplayer mid-match → put a surrender-restart vote to the OTHER human players; the
-- reset only happens if every one of them accepts.
local function humanPlayers(): { Player }
	local list = {}
	for _, p in Players:GetPlayers() do
		if p.UserId > 0 then table.insert(list, p) end
	end
	return list
end

local function cancelSurrender(message: string)
	local ps = pendingSurrender
	if not ps then return end
	pendingSurrender = nil
	if ps.requester.Parent then
		RemoteHandler.get(Config.REMOTES.SurrenderCancel):FireClient(ps.requester, message)
	end
	for uid in ps.needed do
		local p = Players:GetPlayerByUserId(uid)
		if p then RemoteHandler.get(Config.REMOTES.SurrenderCancel):FireClient(p, "") end
	end
end

RemoteHandler.get(Config.REMOTES.LeaveToLobby).OnServerEvent:Connect(function(player)
	if player.UserId <= 0 then return end
	if returningToLobby or LobbyManager.isActive() then return end   -- already heading to / in the lobby
	local humans = humanPlayers()

	-- Immediate reset when solo, or when the match is already decided (end screen up).
	if matchOver or #humans <= 1 then
		returnToLobby()
		return
	end

	-- Multiplayer, mid-match: one vote at a time.
	if pendingSurrender then return end
	local needed: { [number]: boolean } = {}
	for _, p in humans do
		if p ~= player then needed[p.UserId] = true end
	end
	pendingSurrender = { requester = player, needed = needed, votes = {} }
	for _, p in humans do
		if p ~= player then
			RemoteHandler.get(Config.REMOTES.SurrenderVote):FireClient(p, player.Name)
		end
	end
end)

RemoteHandler.get(Config.REMOTES.SurrenderVoteResult).OnServerEvent:Connect(function(player, accept)
	local ps = pendingSurrender
	if not ps or not ps.needed[player.UserId] then return end

	if accept ~= true then
		cancelSurrender(player.Name .. " declined the restart.")
		return
	end

	ps.votes[player.UserId] = true
	for uid in ps.needed do
		if not ps.votes[uid] then return end   -- still waiting on someone
	end
	-- Everyone agreed → reset to the ready-up lobby.
	pendingSurrender = nil
	returnToLobby()
end)

-- Keep a pending vote sane if a participant leaves: requester leaving cancels it; a
-- voter leaving drops their requirement (and can complete the vote if they were last).
Players.PlayerRemoving:Connect(function(player)
	local ps = pendingSurrender
	if not ps then return end
	if ps.requester == player then
		cancelSurrender("")
		return
	end
	if ps.needed[player.UserId] then
		ps.needed[player.UserId] = nil
		ps.votes[player.UserId]  = nil
		for uid in ps.needed do
			if not ps.votes[uid] then return end
		end
		pendingSurrender = nil
		returnToLobby()
	end
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
-- Bases sit in the SE half of the map (below the main diagonal z = x). Their AI
-- counterparts (AIManager.AI_BASES) are the exact diagonal mirrors M(x,z) = (z,x) in
-- the NW half, so — with the forest and ore deposits also mirrored across z = x — a
-- human and the opposing AI start in identical surroundings. Assigned in join order.
-- Y = COMMAND_CENTER_SIZE.Y / 2 so the base sits on the Y=0 floor.
local PLAYER_BASES: { Vector3 } = {
	Vector3.new(250, Config.COMMAND_CENTER_SIZE.Y / 2, -250),  -- SE corner (primary)
	Vector3.new(290, Config.COMMAND_CENTER_SIZE.Y / 2,  -70),  -- east edge
	Vector3.new( 70, Config.COMMAND_CENTER_SIZE.Y / 2, -290),  -- south edge
	Vector3.new(170, Config.COMMAND_CENTER_SIZE.Y / 2, -170),  -- inner SE
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

	-- Start the performance-graph sampler: snapshot every combatant's (players + AI)
	-- cumulative kills each TIMELINE_DT seconds until the match ends (matchGen changes).
	killTimeline = {}
	matchGen += 1
	local myGen = matchGen
	task.spawn(function()
		while matchGen == myGen do
			sampleTimeline()
			task.wait(TIMELINE_DT)
		end
	end)

	local isLane = currentGamemode == "Lane"
	laneModeActive = isLane

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

	-- Late joiners also get auto-placed bases. Connect once (onLobbyEnd runs again each
	-- time the lobby is re-opened after a match, so guard against stacking handlers).
	if not lateJoinerConnected then
		lateJoinerConnected = true
		Players.PlayerAdded:Connect(function(player)
			task.delay(1, function()
				if player.Parent and not BuildingManager.hasCommandCenter(player)
					and not LobbyManager.isActive() then
					if laneModeActive then
						setupLanePlayerBase(player)
					else
						deliverBaseForPlayer(player)
					end
				end
			end)
		end)
	end

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
