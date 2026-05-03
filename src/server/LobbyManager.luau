--[[
	LobbyManager — server-side pre-game lobby controller.

	Flow:
	  1. All joining players are tracked with ready = false.
	  2. Any client can fire LobbyReady to toggle their own ready state.
	  3. Any client can fire LobbyReroll to regenerate mineral deposits
	     (3-second server-enforced cooldown; resets all ready states).
	  4. Any client can fire LobbyAddAI / LobbyRemoveAI to manage the AI queue.
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
local terrainEnabled   = false
local terrainManagerRef: any = nil

type AIEntry = { personality: string, level: number }
local aiQueue: { AIEntry } = {}

local VALID_PERSONALITIES = { balanced = true, territorial = true, waves = true }

local function findAIEntry(personality: string): (number?, AIEntry?)
	for i, entry in aiQueue do
		if entry.personality == personality then return i, entry end
	end
	return nil, nil
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function buildReadyList(): { { name: string, ready: boolean } }
	local list = {}
	for _, player in Players:GetPlayers() do
		table.insert(list, {
			name  = player.Name,
			ready = readyMap[player.UserId] == true,
		})
	end
	return list
end

local function syncAll(mineralManager)
	RemoteHandler.get(Config.REMOTES.LobbySync):FireAllClients(
		buildReadyList(),
		mineralManager.getUnclaimedPositions(),
		terrainEnabled,
		aiQueue
	)
end

local function resetAllReady()
	for userId in readyMap do readyMap[userId] = false end
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
		-- Pass a copy of the AI queue to the game
		local snapshot: { AIEntry } = {}
		for _, entry in aiQueue do
			table.insert(snapshot, { personality = entry.personality, level = entry.level })
		end
		onLobbyEnd(snapshot)
	end)
end

-- ── Public init ───────────────────────────────────────────────────────────────

function LobbyManager.init(mineralManager, terrainManager, onLobbyEnd: ({ AIEntry }) -> ())

	terrainManagerRef = terrainManager

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
				aiQueue
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
		mineralManager.rerollDeposits()
		if terrainEnabled and terrainManagerRef then
			terrainManagerRef.generate()
		end
		syncAll(mineralManager)
		task.delay(3, function() rerollCooldown = false end)
	end)

	RemoteHandler.get(Config.REMOTES.LobbyTerrainToggle).OnServerEvent:Connect(function(_player)
		if not active then return end
		terrainEnabled = not terrainEnabled
		resetAllReady()
		if terrainEnabled and terrainManagerRef then
			terrainManagerRef.generate()
		elseif not terrainEnabled and terrainManagerRef then
			terrainManagerRef.clear()
		end
		syncAll(mineralManager)
	end)

	-- Left-click a personality button: increment level (1→5) or add at level 1
	RemoteHandler.get(Config.REMOTES.LobbyAddAI).OnServerEvent:Connect(function(_player, personality: any)
		if not active then return end
		if type(personality) ~= "string" then return end
		if not VALID_PERSONALITIES[personality] then return end

		local idx, entry = findAIEntry(personality)
		if entry then
			if entry.level < 5 then entry.level += 1 end
		else
			if #aiQueue >= 3 then return end  -- max one of each personality (3 total)
			table.insert(aiQueue, { personality = personality, level = 1 })
		end
		resetAllReady()
		syncAll(mineralManager)
	end)

	-- Right-click a personality button: decrement level, remove at 0
	RemoteHandler.get(Config.REMOTES.LobbyRemoveAI).OnServerEvent:Connect(function(_player, personality: any)
		if not active then return end
		if type(personality) ~= "string" then return end
		local idx, entry = findAIEntry(personality)
		if not entry then return end
		entry.level -= 1
		if entry.level <= 0 then table.remove(aiQueue, idx) end
		resetAllReady()
		syncAll(mineralManager)
	end)

	-- × button on queue entry: fully remove the personality
	RemoteHandler.get(Config.REMOTES.LobbyRemoveAIFull).OnServerEvent:Connect(function(_player, personality: any)
		if not active then return end
		if type(personality) ~= "string" then return end
		local idx = findAIEntry(personality)
		if idx then
			table.remove(aiQueue, idx)
			resetAllReady()
			syncAll(mineralManager)
		end
	end)

	RemoteHandler.get(Config.REMOTES.LobbySetColor).OnServerEvent:Connect(function(player, colorName: string)
		if not active then return end
		player.TeamColor = BrickColor.new(colorName)
	end)

	-- Default AI so solo players always have an opponent
	table.insert(aiQueue, { personality = "balanced", level = 3 })

	for _, player in Players:GetPlayers() do
		readyMap[player.UserId] = false
	end
end

return LobbyManager
