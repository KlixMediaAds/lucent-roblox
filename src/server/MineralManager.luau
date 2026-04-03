local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local RemoteHandler     = require(Shared:WaitForChild("RemoteHandler"))

local MineralManager = {}

type MineData = {
	pos:    Vector3,
	owner:  Player,
	miners: number,
}

-- "X,Z" key -> false (unclaimed) or true (claimed)
local depositClaimed: {[string]: boolean} = {}
local depositList:    {Vector3}            = {}   -- all generated positions
local mines:          {[string]: MineData} = {}

local depositsFolder: Folder
local minersFolder:   Folder
local resourceManager: any

local function posKey(v: Vector3): string
	return math.round(v.X) .. "," .. math.round(v.Z)
end

-- ── Deposit generation ───────────────────────────────────────────────────────

local function generateDeposits()
	local GRID     = Config.BUILDING_SIZE.X   -- 10 studs
	local SPREAD   = Config.DEPOSIT_SPREAD    -- 150
	local MIN_DIST = GRID * 3                 -- 30 studs min between deposits

	local attempts = 0
	while #depositList < Config.DEPOSIT_COUNT and attempts < 3000 do
		attempts += 1
		local x         = math.round(math.random(-SPREAD, SPREAD) / GRID) * GRID
		local z         = math.round(math.random(-SPREAD, SPREAD) / GRID) * GRID
		local candidate = Vector3.new(x, 0, z)

		-- Keep deposits away from the spawn/origin area
		if candidate.Magnitude < 45 then continue end

		local valid = true
		for _, p in depositList do
			if (Vector3.new(p.X, 0, p.Z) - candidate).Magnitude < MIN_DIST then
				valid = false
				break
			end
		end

		if valid then
			table.insert(depositList, candidate)
			depositClaimed[posKey(candidate)] = false
		end
	end
end

local function makeDepositPart(pos: Vector3)
	local p           = Instance.new("Part")
	p.Name            = posKey(pos)
	p.Size            = Config.DEPOSIT_SIZE
	p.Position        = Vector3.new(pos.X, Config.DEPOSIT_SIZE.Y / 2, pos.Z)
	p.BrickColor      = BrickColor.new("Bright yellow")
	p.Material        = Enum.Material.Neon
	p.Anchored        = true
	p.CanCollide      = false
	p.CastShadow      = false
	p.Parent          = depositsFolder
end

-- ── Deposit API (used by BuildingManager) ────────────────────────────────────

-- Returns true and claims the deposit if one exists at the snapped position.
function MineralManager.tryClaimDeposit(pos: Vector3): boolean
	local key = posKey(pos)
	if depositClaimed[key] ~= false then return false end  -- missing or already claimed

	depositClaimed[key] = true

	local part = depositsFolder:FindFirstChild(key)
	if part then part:Destroy() end

	RemoteHandler.get(Config.REMOTES.DepositClaimed):FireAllClients(pos)
	return true
end

-- Returns all currently-unclaimed deposit positions (for new-player sync).
function MineralManager.getUnclaimedPositions(): {Vector3}
	local out = {}
	for _, pos in depositList do
		if depositClaimed[posKey(pos)] == false then
			table.insert(out, pos)
		end
	end
	return out
end

-- ── Mine registration ────────────────────────────────────────────────────────

function MineralManager.registerMine(mineId: string, minePos: Vector3, player: Player)
	mines[mineId] = { pos = minePos, owner = player, miners = 0 }

	local spacing = Config.BUILDING_SIZE.X   -- 10 studs per grid cell

	local function spawnNextMiner()
		local data = mines[mineId]
		if not data then return end
		if data.miners >= Config.MINI_MINER_MAX then return end

		local slot      = data.miners + 1
		local offset    = Config.MINER_OFFSETS[slot]
		local minerPos  = minePos + Vector3.new(offset.X * spacing, 0, offset.Z * spacing)

		-- Build the Mini Miner part
		local p           = Instance.new("Part")
		p.Name            = mineId .. "_miner" .. slot
		p.Size            = Config.MINI_MINER_SIZE
		p.Position        = Vector3.new(minerPos.X, Config.MINI_MINER_SIZE.Y / 2 + 0.1, minerPos.Z)
		p.BrickColor      = player.TeamColor
		p.Material        = Enum.Material.DiamondPlate
		p.Anchored        = true
		p.CastShadow      = false
		p.Parent          = minersFolder

		-- Ownership tag (visible in Studio for debugging)
		local ov      = Instance.new("StringValue")
		ov.Name       = "OwnerId"
		ov.Value      = tostring(player.UserId)
		ov.Parent     = p

		local mv      = Instance.new("StringValue")
		mv.Name       = "MineId"
		mv.Value      = mineId
		mv.Parent     = p

		data.miners += 1

		-- Notify clients: mineId, ownerUserId, new total miner count
		RemoteHandler.get(Config.REMOTES.MinerSpawned):FireAllClients(
			mineId, player.UserId, data.miners
		)
	end

	-- Spawn first miner immediately, then one every MINI_MINER_SPAWN_INTERVAL
	spawnNextMiner()

	task.spawn(function()
		while true do
			task.wait(Config.MINI_MINER_SPAWN_INTERVAL)
			local data = mines[mineId]
			if not data then break end
			if data.miners >= Config.MINI_MINER_MAX then break end
			spawnNextMiner()
		end
	end)
end

-- ── Initialisation ───────────────────────────────────────────────────────────

function MineralManager.init(rm)
	resourceManager = rm

	depositsFolder        = Instance.new("Folder")
	depositsFolder.Name   = "Deposits"
	depositsFolder.Parent = workspace

	minersFolder          = Instance.new("Folder")
	minersFolder.Name     = "Miners"
	minersFolder.Parent   = workspace

	generateDeposits()
	for _, pos in depositList do
		makeDepositPart(pos)
	end
	print("[MineralManager] Placed", #depositList, "deposits")

	-- Send deposit positions to each player on join
	Players.PlayerAdded:Connect(function(player)
		RemoteHandler.get(Config.REMOTES.SyncDeposits):FireClient(
			player, MineralManager.getUnclaimedPositions()
		)
	end)

	-- Clean up when a player leaves
	Players.PlayerRemoving:Connect(function(player)
		local toRemove = {}
		for id, data in mines do
			if data.owner == player then table.insert(toRemove, id) end
		end
		for _, id in toRemove do mines[id] = nil end
	end)

	-- Passive income loop: runs once per MINI_MINER_INCOME_INTERVAL
	task.spawn(function()
		while true do
			task.wait(Config.MINI_MINER_INCOME_INTERVAL)
			for _, data in mines do
				if data.miners > 0 and data.owner.Parent ~= nil then
					resourceManager.add(data.owner, data.miners * Config.MINI_MINER_INCOME)
				end
			end
		end
	end)
end

return MineralManager
