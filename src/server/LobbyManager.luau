--[[
	LobbyManager — server-side pre-game lobby controller.

	Flow:
	  1. All joining players are tracked with ready = false.
	  2. Any client can fire LobbyReady to toggle their own ready state.
	  3. Any client can fire LobbyReroll to regenerate mineral deposits
	     (3-second server-enforced cooldown; resets all ready states).
	  4. AI is configured with two cycling settings instead of a personality queue:
	       • LobbySetAICount      — cycles the number of AI opponents 0 → 1 → 2 → 3 → 0
	       • LobbySetAIDifficulty — cycles Easy → Medium → Hard → Nightmare
	     Teams are FFA-only for now (the lobby Teams control is "coming soon").
	  5. When every connected player is ready, LobbyStart fires to all clients,
	     then onLobbyEnd(aiQueue) is called ~3.5 s later to kick off the game.
	     AI bots are spawned AFTER human players place their CCs.
]]

local Players       = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared        = ReplicatedStorage:WaitForChild("Shared")
local Config        = require(Shared:WaitForChild("Config"))
local RemoteHandler = require(Shared:WaitForChild("RemoteHandler"))

local LobbyManager = {}

-- ── State ──────────────────────────────────────────────────────────────────────

local readyMap:        { [number]: boolean } = {}
local rerollCooldown   = false
local active           = true
local mineralManagerRef: any = nil   -- stored in init so reopen() can re-sync deposits
-- Terrain style cycles Layered → Walled → Off (the lobby "TERRAIN" button).
--   Layered — the tiered, ramped plateau map.
--   Walled  — winding rock walls units must route around (no ramps).
--   Off     — flat ground (default).
local TERRAIN_ORDER    = { "Layered", "Walled", "Off" }
local terrainMode      = "Off"
local terrainManagerRef: any = nil
local currentGamemode  = "Default"

-- Regenerate the world terrain for the current gamemode + terrain style. Lane mode
-- always uses its corridor walls regardless of the terrain style.
local function regenTerrain()
	if not terrainManagerRef then return end
	if currentGamemode == "Lane" then
		terrainManagerRef.generateLane()
	elseif terrainMode == "Layered" then
		terrainManagerRef.generate()
	elseif terrainMode == "Walled" then
		terrainManagerRef.generateWalled()
	else
		terrainManagerRef.clear()
	end
end

-- AI configuration (replaces the old per-personality queue).
local MAX_AI           = 3
local aiCount          = 1          -- number of AI opponents, 0..MAX_AI
local aiDifficulty     = "Medium"   -- one of DIFFICULTY_ORDER

local DIFFICULTY_ORDER = { "Easy", "Medium", "Hard", "Nightmare" }
-- Each difficulty maps onto the existing personality + 1-5 level system.
local DIFFICULTY = {
	Easy      = { personality = "balanced",  level = 1 },
	Medium    = { personality = "balanced",  level = 3 },
	Hard      = { personality = "balanced",  level = 5 },
	Nightmare = { personality = "nightmare", level = 5 },
}

type AIEntry = { personality: string, level: number }

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function buildReadyList(): { { name: string, userId: number, ready: boolean, faction: string } }
	local list = {}
	for _, player in Players:GetPlayers() do
		table.insert(list, {
			name    = player.Name,
			userId  = player.UserId,
			ready   = readyMap[player.UserId] == true,
			faction = player:GetAttribute("Faction") or "Humans",
		})
	end
	return list
end

local function buildSettings(): { aiCount: number, aiDifficulty: string }
	return { aiCount = aiCount, aiDifficulty = aiDifficulty }
end

local function syncAll(mineralManager)
	RemoteHandler.get(Config.REMOTES.LobbySync):FireAllClients(
		buildReadyList(),
		mineralManager.getUnclaimedPositions(),
		terrainMode,
		buildSettings(),
		currentGamemode
	)
end

local function resetAllReady()
	for userId in readyMap do readyMap[userId] = false end
end

-- Expand the AI settings into a concrete spawn list for the game handoff.
local function buildAISnapshot(): { AIEntry }
	local d = DIFFICULTY[aiDifficulty] or DIFFICULTY.Medium
	local snapshot: { AIEntry } = {}
	for _ = 1, aiCount do
		table.insert(snapshot, { personality = d.personality, level = d.level })
	end
	return snapshot
end

local function checkAllReady(mineralManager, onLobbyEnd)
	local players = Players:GetPlayers()
	if #players == 0 then return end
	for _, player in players do
		if not readyMap[player.UserId] then return end
	end

	active = false
	RemoteHandler.get(Config.REMOTES.LobbyStart):FireAllClients()

	task.delay(3.5, function()
		RemoteHandler.get(Config.REMOTES.SyncDeposits):FireAllClients(
			mineralManager.getUnclaimedPositions()
		)
		onLobbyEnd(buildAISnapshot(), currentGamemode)
	end)
end

-- ── Public init ───────────────────────────────────────────────────────────────

function LobbyManager.init(mineralManager, terrainManager, onLobbyEnd: ({ AIEntry }, string) -> ())

	terrainManagerRef = terrainManager
	mineralManagerRef = mineralManager

	-- Apply the default terrain style (Off = flat) for the lobby immediately. Deposits
	-- were already placed by MineralManager.init (on flat Y=0 ground); resnap them in case
	-- the style raises tiers under them (a no-op change for flat, but keeps this robust
	-- if the default is ever set back to Layered/Walled).
	if terrainManagerRef and currentGamemode == "Default" then
		regenTerrain()
		mineralManager.resnapDeposits()
	end

	Players.PlayerAdded:Connect(function(player)
		if not active then return end
		readyMap[player.UserId] = false
		task.delay(1.5, function()
			if not active or not player.Parent then return end
			RemoteHandler.get(Config.REMOTES.LobbySync):FireClient(
				player,
				buildReadyList(),
				mineralManager.getUnclaimedPositions(),
				terrainMode,
				buildSettings(),
				currentGamemode
			)
		end)
		syncAll(mineralManager)
	end)

	Players.PlayerRemoving:Connect(function(player)
		if not active then return end
		readyMap[player.UserId] = nil
		syncAll(mineralManager)
		checkAllReady(mineralManager, onLobbyEnd)
	end)

	RemoteHandler.get(Config.REMOTES.LobbyReady).OnServerEvent:Connect(function(player)
		if not active then return end
		readyMap[player.UserId] = not (readyMap[player.UserId] == true)
		syncAll(mineralManager)
		checkAllReady(mineralManager, onLobbyEnd)
	end)

	RemoteHandler.get(Config.REMOTES.LobbyReroll).OnServerEvent:Connect(function(_player)
		if not active then return end
		if rerollCooldown then return end
		rerollCooldown = true
		resetAllReady()
		-- Regenerate terrain first so the rerolled deposits snap onto the new layout.
		regenTerrain()
		mineralManager.rerollDeposits()
		syncAll(mineralManager)
		task.delay(3, function() rerollCooldown = false end)
	end)

	-- Cycle the terrain style: Layered → Walled → Off → Layered.
	RemoteHandler.get(Config.REMOTES.LobbyTerrainToggle).OnServerEvent:Connect(function(_player)
		if not active then return end
		if currentGamemode == "Lane" then return end  -- terrain style locked in lane mode
		local idx = table.find(TERRAIN_ORDER, terrainMode) or 1
		terrainMode = TERRAIN_ORDER[(idx % #TERRAIN_ORDER) + 1]
		resetAllReady()
		regenTerrain()
		-- Terrain heights changed under the existing deposits — resnap them.
		mineralManager.resnapDeposits()
		syncAll(mineralManager)
	end)

	RemoteHandler.get(Config.REMOTES.LobbySetGamemode).OnServerEvent:Connect(function(_player, gamemode: any)
		if not active then return end
		if type(gamemode) ~= "string" then return end
		if gamemode ~= "Default" and gamemode ~= "Lane" and gamemode ~= "Swarm" then return end
		if currentGamemode == gamemode then return end
		currentGamemode = gamemode
		resetAllReady()
		regenTerrain()
		-- Terrain heights changed under the existing deposits — resnap them.
		mineralManager.resnapDeposits()
		syncAll(mineralManager)
	end)

	-- Cycle the number of AI opponents: 0 → 1 → 2 → 3 → 0.
	RemoteHandler.get(Config.REMOTES.LobbySetAICount).OnServerEvent:Connect(function(_player)
		if not active then return end
		aiCount = (aiCount + 1) % (MAX_AI + 1)
		resetAllReady()
		syncAll(mineralManager)
	end)

	-- Cycle the AI difficulty: Easy → Medium → Hard → Nightmare → Easy.
	RemoteHandler.get(Config.REMOTES.LobbySetAIDifficulty).OnServerEvent:Connect(function(_player)
		if not active then return end
		local idx = table.find(DIFFICULTY_ORDER, aiDifficulty) or 2
		aiDifficulty = DIFFICULTY_ORDER[(idx % #DIFFICULTY_ORDER) + 1]
		resetAllReady()
		syncAll(mineralManager)
	end)

	RemoteHandler.get(Config.REMOTES.LobbySetColor).OnServerEvent:Connect(function(player, colorName: string)
		if not active then return end
		player.TeamColor = BrickColor.new(colorName)
	end)

	-- Per-player team/faction pick (Humans / Hollowed). Stored as a player attribute
	-- so match setup can read it later; defaults to Humans if never chosen.
	RemoteHandler.get(Config.REMOTES.LobbySetFaction).OnServerEvent:Connect(function(player, faction: string)
		if not active then return end
		if faction ~= "Humans" and faction ~= "Hollowed" then return end
		player:SetAttribute("Faction", faction)
		-- Re-sync so every client's player banners reflect the new race choice.
		syncAll(mineralManager)
	end)

	for _, player in Players:GetPlayers() do
		readyMap[player.UserId] = false
	end
end

-- Re-open the lobby after a match (return to the ready-up menu). Re-activates the
-- lobby, clears every ready flag, and re-syncs all clients so the reopened ready-up
-- menu shows the current roster/settings. The persistent LobbyReady/… connections made
-- in init keep working, so readying up starts a fresh match through the same handoff.
function LobbyManager.reopen()
	active = true
	for _, player in Players:GetPlayers() do
		readyMap[player.UserId] = false
	end
	if mineralManagerRef then
		syncAll(mineralManagerRef)
	end
end

function LobbyManager.isActive(): boolean
	return active
end

return LobbyManager
