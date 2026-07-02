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
local terrainEnabled   = true   -- tiered terrain is on by default
local terrainManagerRef: any = nil
local currentGamemode  = "Default"

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

local function buildReadyList(): { { name: string, userId: number, ready: boolean } }
	local list = {}
	for _, player in Players:GetPlayers() do
		table.insert(list, {
			name   = player.Name,
			userId = player.UserId,
			ready  = readyMap[player.UserId] == true,
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
		terrainEnabled,
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

	-- Terrain defaults on, so generate the tiered map immediately for the lobby.
	-- Deposits were already placed by MineralManager.init (on flat Y=0 ground);
	-- resnap them onto the freshly raised tiers so none end up buried.
	if terrainEnabled and terrainManagerRef and currentGamemode == "Default" then
		terrainManagerRef.generate()
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
				terrainEnabled,
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
		-- Regenerate terrain first so the rerolled deposits snap onto the new tiers.
		if currentGamemode == "Lane" and terrainManagerRef then
			terrainManagerRef.generateLane()
		elseif terrainEnabled and terrainManagerRef then
			terrainManagerRef.generate()
		end
		mineralManager.rerollDeposits()
		syncAll(mineralManager)
		task.delay(3, function() rerollCooldown = false end)
	end)

	RemoteHandler.get(Config.REMOTES.LobbyTerrainToggle).OnServerEvent:Connect(function(_player)
		if not active then return end
		if currentGamemode == "Lane" then return end  -- terrain toggle disabled in lane mode
		terrainEnabled = not terrainEnabled
		resetAllReady()
		if terrainEnabled and terrainManagerRef then
			terrainManagerRef.generate()
		elseif not terrainEnabled and terrainManagerRef then
			terrainManagerRef.clear()
		end
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
		if currentGamemode == "Lane" and terrainManagerRef then
			terrainManagerRef.generateLane()
		elseif terrainEnabled and terrainManagerRef then
			terrainManagerRef.generate()
		else
			terrainManagerRef.clear()
		end
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
	end)

	for _, player in Players:GetPlayers() do
		readyMap[player.UserId] = false
	end
end

return LobbyManager
