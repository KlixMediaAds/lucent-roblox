local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local RemoteHandler     = require(Shared:WaitForChild("RemoteHandler"))

local MineralManager = {}

type MineData = {
	pos:          Vector3,
	owner:        Player,
	miners:       number,
	depositTotal: number,   -- remaining resource pool; 0 = depleted
	depleted:     boolean,
}

-- "X,Z" key -> false (unclaimed) | true (claimed)
local depositClaimed: { [string]: boolean } = {}
local depositList:    { Vector3 }           = {}
local mines:          { [string]: MineData } = {}

local depositsFolder: Folder
local minersFolder:   Folder
local resourceManager:  any
local buildingManagerRef: any   -- set via setBuildingManager after init

local function posKey(v: Vector3): string
	return math.round(v.X) .. "," .. math.round(v.Z)
end

-- ── Deposit visuals ───────────────────────────────────────────────────────────

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

-- ── Deposit generation ────────────────────────────────────────────────────────

local function generateDeposits()
	local GRID     = Config.BUILDING_SIZE.X
	local SPREAD   = Config.DEPOSIT_SPREAD
	local MIN_DIST = GRID * 3

	local attempts = 0
	while #depositList < Config.DEPOSIT_COUNT and attempts < 3000 do
		attempts += 1
		local x         = math.round(math.random(-SPREAD, SPREAD) / GRID) * GRID
		local z         = math.round(math.random(-SPREAD, SPREAD) / GRID) * GRID
		local candidate = Vector3.new(x, 0, z)

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

-- Tries to add one fresh deposit at a random valid location.
local function spawnReplacementDeposit()
	local GRID     = Config.BUILDING_SIZE.X
	local SPREAD   = Config.DEPOSIT_SPREAD
	local MIN_DIST = GRID * 3

	for _ = 1, 500 do
		local x         = math.round(math.random(-SPREAD, SPREAD) / GRID) * GRID
		local z         = math.round(math.random(-SPREAD, SPREAD) / GRID) * GRID
		local candidate = Vector3.new(x, 0, z)

		if candidate.Magnitude < 45 then continue end

		local key = posKey(candidate)
		if depositClaimed[key] ~= nil then continue end  -- already tracked

		local valid = true
		for _, p in depositList do
			if (Vector3.new(p.X, 0, p.Z) - candidate).Magnitude < MIN_DIST then
				valid = false
				break
			end
		end

		if valid then
			table.insert(depositList, candidate)
			depositClaimed[key] = false
			makeDepositPart(candidate)
			-- Broadcast updated unclaimed list to all clients (for Mine ghost snapping)
			RemoteHandler.get(Config.REMOTES.SyncDeposits):FireAllClients(
				MineralManager.getUnclaimedPositions()
			)
			return
		end
	end
	-- If no valid spot found after 500 attempts, skip silently
end

-- ── Depletion ─────────────────────────────────────────────────────────────────

-- Apply depleted visuals to the mine building in workspace.
local function applyDepletedVisuals(mineId: string)
	local buildingsFolder = workspace:FindFirstChild("Buildings")
	if not buildingsFolder then return end
	local model = buildingsFolder:FindFirstChild(mineId)
	if not model then return end

	-- Grey out the crystal
	local crystal = model:FindFirstChild("Crystal") :: BasePart?
	if crystal then
		crystal.BrickColor = BrickColor.new("Dark stone grey")
		crystal.Material   = Enum.Material.SmoothPlastic
	end

	-- Add a "Depleted" warning billboard above the base
	local base = model:FindFirstChild("Base") :: BasePart?
	if not base then return end

	local existing = base:FindFirstChild("DepletedSign")
	if existing then return end  -- already added

	local bb              = Instance.new("BillboardGui")
	bb.Name               = "DepletedSign"
	bb.Size               = UDim2.fromOffset(110, 28)
	bb.StudsOffset        = Vector3.new(0, base.Size.Y / 2 + 5.5, 0)
	bb.AlwaysOnTop        = false
	bb.Parent             = base

	local bg              = Instance.new("Frame")
	bg.Size               = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3   = Color3.fromRGB(80, 10, 10)
	bg.BackgroundTransparency = 0.15
	bg.BorderSizePixel    = 0
	bg.Parent             = bb

	local label           = Instance.new("TextLabel")
	label.Text            = "DEPLETED"
	label.Size            = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.TextColor3      = Color3.fromRGB(255, 80, 50)
	label.Font            = Enum.Font.GothamBold
	label.TextScaled      = true
	label.Parent          = bg
end

-- Begin draining HP from a depleted mine building.
local function startMineDecay(mineId: string)
	task.spawn(function()
		while mines[mineId] do
			task.wait(1)
			if mines[mineId] and buildingManagerRef then
				buildingManagerRef.damage(mineId, Config.MINE_DECAY_RATE)
			end
		end
	end)
end

-- Called when the deposit's resource pool reaches zero.
local function depleteMineSite(mineId: string)
	local data = mines[mineId]
	if not data or data.depleted then return end

	data.depleted     = true
	data.depositTotal = 0

	applyDepletedVisuals(mineId)
	startMineDecay(mineId)
	spawnReplacementDeposit()
end

-- ── Deposit API (used by BuildingManager) ────────────────────────────────────

function MineralManager.tryClaimDeposit(pos: Vector3): boolean
	local key = posKey(pos)
	if depositClaimed[key] ~= false then return false end

	depositClaimed[key] = true

	local part = depositsFolder:FindFirstChild(key)
	if part then part:Destroy() end

	RemoteHandler.get(Config.REMOTES.DepositClaimed):FireAllClients(pos)
	return true
end

function MineralManager.getUnclaimedPositions(): { Vector3 }
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
	mines[mineId] = {
		pos          = minePos,
		owner        = player,
		miners       = 0,
		depositTotal = Config.DEPOSIT_TOTAL_RESOURCES,
		depleted     = false,
	}

	local spacing = Config.BUILDING_SIZE.X

	local function spawnNextMiner()
		local data = mines[mineId]
		if not data or data.depleted then return end
		if data.miners >= Config.MINI_MINER_MAX then return end

		local slot     = data.miners + 1
		local offset   = Config.MINER_OFFSETS[slot]
		local minerPos = minePos + Vector3.new(offset.X * spacing, 0, offset.Z * spacing)

		local p           = Instance.new("Part")
		p.Name            = mineId .. "_miner" .. slot
		p.Size            = Config.MINI_MINER_SIZE
		p.Position        = Vector3.new(minerPos.X, Config.MINI_MINER_SIZE.Y / 2 + 0.1, minerPos.Z)
		p.BrickColor      = player.TeamColor
		p.Material        = Enum.Material.DiamondPlate
		p.Anchored        = true
		p.CastShadow      = false
		p.Parent          = minersFolder

		local ov      = Instance.new("StringValue")
		ov.Name       = "OwnerId"
		ov.Value      = tostring(player.UserId)
		ov.Parent     = p

		local mv      = Instance.new("StringValue")
		mv.Name       = "MineId"
		mv.Value      = mineId
		mv.Parent     = p

		data.miners += 1

		RemoteHandler.get(Config.REMOTES.MinerSpawned):FireAllClients(
			mineId, player.UserId, data.miners
		)
	end

	spawnNextMiner()

	task.spawn(function()
		while true do
			task.wait(Config.MINI_MINER_SPAWN_INTERVAL)
			local data = mines[mineId]
			if not data then break end
			if data.depleted then break end           -- no new miners after depletion
			if data.miners >= Config.MINI_MINER_MAX then break end
			spawnNextMiner()
		end
	end)
end

-- ── Count helper (used by BuildingManager for max-mine enforcement) ───────────

function MineralManager.getMineCount(player: any): number
	local n = 0
	for _, data in mines do
		if data.owner == player and not data.depleted then n += 1 end
	end
	return n
end

-- ── Removal ───────────────────────────────────────────────────────────────────

function MineralManager.removeMine(mineId: string)
	mines[mineId] = nil   -- stops the decay loop too
	for _, part in minersFolder:GetChildren() do
		local mv = part:FindFirstChild("MineId")
		if mv and mv.Value == mineId then
			part:Destroy()
		end
	end
end

function MineralManager.removeAllMinesFor(player: any)
	local toRemove = {}
	for id, data in mines do
		if data.owner == player then table.insert(toRemove, id) end
	end
	for _, id in toRemove do
		MineralManager.removeMine(id)
	end
end

-- ── Setter for circular cross-reference ──────────────────────────────────────

function MineralManager.setBuildingManager(bm: any)
	buildingManagerRef = bm
end

-- ── Init ──────────────────────────────────────────────────────────────────────

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

	-- Passive income + depletion loop
	task.spawn(function()
		while true do
			task.wait(Config.MINI_MINER_INCOME_INTERVAL)
			for mineId, data in mines do
				if data.depleted then continue end
				if data.miners <= 0 then continue end
				if not data.owner.Parent then continue end

				local income = data.miners * Config.MINI_MINER_INCOME
				resourceManager.add(data.owner, income)

				-- Drain the deposit
				data.depositTotal -= income
				if data.depositTotal <= 0 then
					depleteMineSite(mineId)
				end
			end
		end
	end)
end

return MineralManager
