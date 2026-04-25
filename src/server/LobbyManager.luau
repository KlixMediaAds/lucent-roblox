--[[
	LobbyManager — server-side pre-game lobby controller.

	Flow:
	  1. All joining players are tracked with ready = false.
	  2. Any client can fire LobbyReady to toggle their own ready state.
	  3. Any client can fire LobbyReroll to regenerate mineral deposits
	     (3-second server-enforced cooldown; resets all ready states).
	  4. When every connected player is ready, LobbyStart fires to all clients,
	     then onLobbyEnd() is called ~3 s later to kick off the actual game.
]]

local Players       = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared        = ReplicatedStorage:WaitForChild("Shared")
local Config        = require(Shared:WaitForChild("Config"))
local RemoteHandler = require(Shared:WaitForChild("RemoteHandler"))

local LobbyManager = {}

-- ── State ──────────────────────────────────────────────────────────────────────

local readyMap:        { [number]: boolean } = {}  -- userId → ready
local rerollCooldown   = false
local active           = true   -- false once lobby has ended
local terrainEnabled   = false
local terrainManagerRef: any = nil

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
		terrainEnabled
	)
end

local function checkAllReady(mineralManager, onLobbyEnd)
	local players = Players:GetPlayers()
	if #players == 0 then return end
	for _, player in players do
		if not readyMap[player.UserId] then return end
	end

	-- Everyone is ready — start the game
	active = false
	RemoteHandler.get(Config.REMOTES.LobbyStart):FireAllClients()

	-- Give clients time to animate the transition, then start server game logic.
	-- Also re-fire SyncDeposits so BuildingPlacer is populated after startGame().
	task.delay(3.5, function()
		RemoteHandler.get(Config.REMOTES.SyncDeposits):FireAllClients(
			mineralManager.getUnclaimedPositions()
		)
		onLobbyEnd()
	end)
end

-- ── Public init ───────────────────────────────────────────────────────────────

function LobbyManager.init(mineralManager, terrainManager, onLobbyEnd: () -> ())

	terrainManagerRef = terrainManager

	-- Players who join while the lobby is live
	Players.PlayerAdded:Connect(function(player)
		if not active then return end
		readyMap[player.UserId] = false
		-- Small delay so the client ScreenGui has loaded
		task.delay(1.5, function()
			if not active or not player.Parent then return end
			RemoteHandler.get(Config.REMOTES.LobbySync):FireClient(
				player,
				buildReadyList(),
				mineralManager.getUnclaimedPositions(),
				terrainEnabled
			)
		end)
		syncAll(mineralManager)
	end)

	-- Players who disconnect during lobby
	Players.PlayerRemoving:Connect(function(player)
		if not active then return end
		readyMap[player.UserId] = nil
		syncAll(mineralManager)
		checkAllReady(mineralManager, onLobbyEnd)
	end)

	-- Ready toggle
	RemoteHandler.get(Config.REMOTES.LobbyReady).OnServerEvent:Connect(function(player)
		if not active then return end
		readyMap[player.UserId] = not (readyMap[player.UserId] == true)
		syncAll(mineralManager)
		checkAllReady(mineralManager, onLobbyEnd)
	end)

	-- Re-roll (3-second server cooldown; resets all ready states + regenerates terrain if enabled)
	RemoteHandler.get(Config.REMOTES.LobbyReroll).OnServerEvent:Connect(function(_player)
		if not active then return end
		if rerollCooldown then return end
		rerollCooldown = true
		for userId in readyMap do readyMap[userId] = false end
		mineralManager.rerollDeposits()
		if terrainEnabled and terrainManagerRef then
			terrainManagerRef.generate()
		end
		syncAll(mineralManager)
		task.delay(3, function() rerollCooldown = false end)
	end)

	-- Terrain toggle (any player can toggle; resets all ready states)
	RemoteHandler.get(Config.REMOTES.LobbyTerrainToggle).OnServerEvent:Connect(function(_player)
		if not active then return end
		terrainEnabled = not terrainEnabled
		for userId in readyMap do readyMap[userId] = false end
		if terrainEnabled and terrainManagerRef then
			terrainManagerRef.generate()
		elseif not terrainEnabled and terrainManagerRef then
			terrainManagerRef.clear()
		end
		syncAll(mineralManager)
	end)

	-- Color picker
	RemoteHandler.get(Config.REMOTES.LobbySetColor).OnServerEvent:Connect(function(player, colorName: string)
		if not active then return end
		player.TeamColor = BrickColor.new(colorName)
	end)

	-- Seed the ready map for players already in-server (e.g. solo testing)
	for _, player in Players:GetPlayers() do
		readyMap[player.UserId] = false
	end
end

return LobbyManager
