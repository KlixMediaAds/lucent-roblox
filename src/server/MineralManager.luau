local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local RemoteHandler     = require(Shared:WaitForChild("RemoteHandler"))

local MineralManager = {}

type MineData = {
	pos:              Vector3,
	owner:            Player,
	miners:           number,
	depositTotal:     number,
	depleted:         boolean,
	upgrade:          string?,   -- "Efficiency" | "Capacity" | nil
	incomeMultiplier: number,    -- 1 (base) or MINE_UPGRADE_EFFICIENCY_MULT
	minerCap:         number,    -- dynamic; raised by Capacity upgrade
}

local depositClaimed: { [string]: boolean } = {}
local depositList:    { Vector3 }           = {}
local mines:          { [string]: MineData } = {}

local depositsFolder: Folder
local minersFolder:   Folder
local resourceManager:    any
local buildingManagerRef: any
local researchManagerRef: any

local function posKey(v: Vector3): string
	return math.round(v.X) .. "," .. math.round(v.Z)
end

-- ── Deposit visuals ───────────────────────────────────────────────────────────

local function makeDepositPart(pos: Vector3)
	local model      = Instance.new("Model")
	model.Name       = posKey(pos)
	model.Parent     = depositsFolder

	-- Shared properties for every crystal shard
	local COLOR    = BrickColor.new("Bright yellow")
	local MAT      = Enum.Material.Neon

	local function shard(size: Vector3, offset: Vector3, rx: number, ry: number, rz: number): Part
		local p         = Instance.new("Part")
		p.Size          = size
		p.CFrame        = CFrame.new(pos.X + offset.X, offset.Y, pos.Z + offset.Z)
		                * CFrame.Angles(rx, ry, rz)
		p.BrickColor    = COLOR
		p.Material      = MAT
		p.Anchored      = true
		p.CanCollide    = false
		p.CanQuery      = false
		p.CastShadow    = false
		p.Parent        = model
		return p
	end

	local r = math.rad   -- shorthand

	-- Central dominant spike
	local center = shard(Vector3.new(2.4, 9, 2.4),   Vector3.new( 0,   4.5,  0),   r(6),  r(0),  r(-4))
	-- Left leaning shard
	              shard(Vector3.new(1.8, 7, 1.8),    Vector3.new(-2.2, 3.5,  0.4), r(0),  r(15), r(22))
	-- Right shard
	              shard(Vector3.new(1.5, 6, 1.5),    Vector3.new( 2.1, 3.0, -0.6), r(-4), r(-12),r(-18))
	-- Back shard
	              shard(Vector3.new(1.3, 5.5, 1.3),  Vector3.new( 0.6, 2.8, -2.0), r(16), r(5),  r(4))
	-- Small front crystal
	              shard(Vector3.new(1.0, 4, 1.0),    Vector3.new(-1.4, 2.0,  1.8), r(-10),r(8),  r(-7))
	-- Tiny ground chip
	              shard(Vector3.new(0.8, 2.5, 0.8),  Vector3.new( 1.5, 1.2, -1.2), r(-5), r(20), r(12))

	model.PrimaryPart = center
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
				valid = false; break
			end
		end

		if valid then
			table.insert(depositList, candidate)
			depositClaimed[posKey(candidate)] = false
		end
	end
end

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
		if depositClaimed[key] ~= nil then continue end

		local valid = true
		for _, p in depositList do
			if (Vector3.new(p.X, 0, p.Z) - candidate).Magnitude < MIN_DIST then
				valid = false; break
			end
		end

		if valid then
			table.insert(depositList, candidate)
			depositClaimed[key] = false
			makeDepositPart(candidate)
			RemoteHandler.get(Config.REMOTES.SyncDeposits):FireAllClients(
				MineralManager.getUnclaimedPositions()
			)
			return
		end
	end
end

-- ── Depletion ─────────────────────────────────────────────────────────────────

local function applyDepletedVisuals(mineId: string)
	local buildingsFolder = workspace:FindFirstChild("Buildings")
	if not buildingsFolder then return end
	local model = buildingsFolder:FindFirstChild(mineId)
	if not model then return end

	local crystal = model:FindFirstChild("Crystal") :: BasePart?
	if crystal then
		crystal.BrickColor = BrickColor.new("Dark stone grey")
		crystal.Material   = Enum.Material.SmoothPlastic
	end

	-- Remove upgrade ring if present (depleted mine loses its glow)
	local ring = model:FindFirstChild("UpgradeRing")
	if ring then ring:Destroy() end

	local base = model:FindFirstChild("Base") :: BasePart?
	if not base then return end

	local existing = base:FindFirstChild("DepletedSign")
	if existing then return end

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

local function depleteMineSite(mineId: string)
	local data = mines[mineId]
	if not data or data.depleted then return end
	data.depleted     = true
	data.depositTotal = 0
	applyDepletedVisuals(mineId)
	startMineDecay(mineId)
	spawnReplacementDeposit()
end

-- ── Miner spawning (module-level so applyUpgrade can call it) ────────────────

local function spawnMiner(mineId: string)
	local data = mines[mineId]
	if not data or data.depleted then return end
	if data.miners >= data.minerCap then return end

	local player  = data.owner
	local spacing = Config.BUILDING_SIZE.X
	local slot    = data.miners + 1
	local offset  = Config.MINER_OFFSETS[slot]
	if not offset then return end   -- no offset defined for this slot

	local minerPos = data.pos + Vector3.new(offset.X * spacing, 0, offset.Z * spacing)

	local p           = Instance.new("Part")
	p.Name            = mineId .. "_miner" .. slot
	p.Size            = Config.MINI_MINER_SIZE
	p.Position        = Vector3.new(minerPos.X, Config.MINI_MINER_SIZE.Y / 2 + 0.1, minerPos.Z)
	p.BrickColor      = player.TeamColor
	p.Material        = Enum.Material.DiamondPlate
	p.Anchored        = true
	p.CastShadow      = false
	p.Parent          = minersFolder

	local ov = Instance.new("StringValue"); ov.Name = "OwnerId"
	ov.Value = tostring(player.UserId); ov.Parent = p

	local mv = Instance.new("StringValue"); mv.Name = "MineId"
	mv.Value = mineId; mv.Parent = p

	data.miners += 1

	RemoteHandler.get(Config.REMOTES.MinerSpawned):FireAllClients(
		mineId, player.UserId, data.miners
	)
end

-- ── Upgrade visuals ───────────────────────────────────────────────────────────

local function applyUpgradeVisuals(mineId: string, upgradeType: string)
	local buildingsFolder = workspace:FindFirstChild("Buildings")
	if not buildingsFolder then return end
	local model = buildingsFolder:FindFirstChild(mineId)
	if not model then return end

	local crystal = model:FindFirstChild("Crystal") :: BasePart?
	local base    = model:FindFirstChild("Base")    :: BasePart?

	-- Remove any previous upgrade ring
	local oldRing = model:FindFirstChild("UpgradeRing")
	if oldRing then oldRing:Destroy() end

	local ringColor: BrickColor
	if upgradeType == "Efficiency" then
		ringColor = BrickColor.new("Cyan")
		if crystal then
			crystal.BrickColor = BrickColor.new("Cyan")
			crystal.Material   = Enum.Material.Neon
			crystal.Size       = crystal.Size + Vector3.new(0, 1, 0)
		end
	else  -- Capacity
		ringColor = BrickColor.new("Bright orange")
		if crystal then
			crystal.BrickColor = BrickColor.new("Bright orange")
			crystal.Material   = Enum.Material.Neon
			crystal.Size       = crystal.Size + Vector3.new(1, 2, 1)
		end
	end

	-- Glowing ring around the base (same style as turret ring)
	if base then
		local ring        = Instance.new("Part")
		ring.Name         = "UpgradeRing"
		ring.Size         = Vector3.new(base.Size.X + 2, 0.4, base.Size.Z + 2)
		ring.Position     = base.Position - Vector3.new(0, base.Size.Y / 2 - 0.2, 0)
		ring.BrickColor   = ringColor
		ring.Material     = Enum.Material.Neon
		ring.Anchored     = true
		ring.CanCollide   = false
		ring.CastShadow   = false
		ring.Parent       = model
	end

	-- StringValue so clients can read upgrade state from the workspace model
	local existing = model:FindFirstChild("Upgrade")
	if not existing then
		local uv  = Instance.new("StringValue")
		uv.Name   = "Upgrade"
		uv.Value  = upgradeType
		uv.Parent = model
	end
end

-- ── Upgrade application ───────────────────────────────────────────────────────

function MineralManager.applyUpgrade(mineId: string, upgradeType: string, player: any): boolean
	local data = mines[mineId]
	if not data then return false end
	if data.depleted then return false end
	if data.upgrade then return false end  -- already upgraded
	if data.owner ~= player then return false end

	-- Requires BetterMines research from Workshop
	if researchManagerRef and not researchManagerRef.hasResearch(player, "BetterMines") then return false end

	if upgradeType ~= "Efficiency" and upgradeType ~= "Capacity" then return false end

	local cost = (Config.MINE_UPGRADE_COST :: any)[upgradeType] or 999
	if not resourceManager.spend(player, cost) then return false end

	data.upgrade = upgradeType

	if upgradeType == "Efficiency" then
		data.incomeMultiplier = Config.MINE_UPGRADE_EFFICIENCY_MULT
	else
		data.minerCap += Config.MINE_UPGRADE_CAPACITY_EXTRA
		-- Kick off a new spawning loop for the extra miner slots
		task.spawn(function()
			while true do
				task.wait(Config.MINI_MINER_SPAWN_INTERVAL)
				local d = mines[mineId]
				if not d then break end
				if d.depleted then break end
				if d.miners >= d.minerCap then break end
				spawnMiner(mineId)
			end
		end)
	end

	applyUpgradeVisuals(mineId, upgradeType)
	return true
end

-- ── Deposit API ───────────────────────────────────────────────────────────────

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
		pos              = minePos,
		owner            = player,
		miners           = 0,
		depositTotal     = Config.DEPOSIT_TOTAL_RESOURCES,
		depleted         = false,
		upgrade          = nil,
		incomeMultiplier = 1,
		minerCap         = Config.MINI_MINER_MAX,
	}

	spawnMiner(mineId)

	task.spawn(function()
		while true do
			task.wait(Config.MINI_MINER_SPAWN_INTERVAL)
			local data = mines[mineId]
			if not data then break end
			if data.depleted then break end
			if data.miners >= data.minerCap then break end
			spawnMiner(mineId)
		end
	end)
end

-- ── Count / removal ───────────────────────────────────────────────────────────

function MineralManager.getMineCount(player: any): number
	local n = 0
	for _, data in mines do
		if data.owner == player and not data.depleted then n += 1 end
	end
	return n
end

function MineralManager.removeMine(mineId: string)
	mines[mineId] = nil
	for _, part in minersFolder:GetChildren() do
		local mv = part:FindFirstChild("MineId")
		if mv and mv.Value == mineId then part:Destroy() end
	end
end

function MineralManager.removeAllMinesFor(player: any)
	local toRemove = {}
	for id, data in mines do
		if data.owner == player then table.insert(toRemove, id) end
	end
	for _, id in toRemove do MineralManager.removeMine(id) end
end

function MineralManager.setBuildingManager(bm: any)
	buildingManagerRef = bm
end

function MineralManager.setResearchManager(rm: any)
	researchManagerRef = rm
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
	for _, pos in depositList do makeDepositPart(pos) end
	print("[MineralManager] Placed", #depositList, "deposits")

	Players.PlayerAdded:Connect(function(player)
		RemoteHandler.get(Config.REMOTES.SyncDeposits):FireClient(
			player, MineralManager.getUnclaimedPositions()
		)
	end)

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

				local income = data.miners * Config.MINI_MINER_INCOME * data.incomeMultiplier
				resourceManager.add(data.owner, income)

				data.depositTotal -= income
				if data.depositTotal <= 0 then
					depleteMineSite(mineId)
				end
			end
		end
	end)

	-- Upgrade remote
	RemoteHandler.get(Config.REMOTES.UpgradeMine).OnServerEvent:Connect(
		function(player, mineId, upgradeType)
			if type(mineId) ~= "string" or type(upgradeType) ~= "string" then return end
			MineralManager.applyUpgrade(mineId, upgradeType, player)
		end
	)
end

return MineralManager
