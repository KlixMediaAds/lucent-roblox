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
local waveScheduled   = false
local minerHpTable:   { [any]: number }      = {}   -- miner Model → current HP

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
	local MIN_DIST = GRID * 2

	-- Mirror symmetry across the X axis (Z = 0 line).
	-- We generate pairCount cluster centres in the Z > 0 half, then reflect
	-- every deposit to Z < 0 so the map is exactly symmetric north/south.
	local pairCount = math.floor(Config.CLUSTER_COUNT / 2)

	-- 1. Pick cluster centres in the positive-Z half.
	--    Minimum starting Z keeps each centre far enough from the mirror line
	--    so its reflected twin stays CLUSTER_MIN_DIST away.
	local zMin = math.ceil(Config.CLUSTER_MIN_DIST / 2 / GRID) * GRID  -- e.g. 70
	local halfCenters: { Vector3 } = {}
	for _ = 1, 3000 do
		if #halfCenters >= pairCount then break end
		local x         = math.round(math.random(-SPREAD, SPREAD) / GRID) * GRID
		local z         = math.round(math.random(zMin, SPREAD)    / GRID) * GRID
		local candidate = Vector3.new(x, 0, z)
		if candidate.Magnitude < 60 then continue end

		local valid = true
		for _, c in halfCenters do
			-- Enforce spacing vs. both the original and its Z-reflected twin
			if (c                             - candidate).Magnitude < Config.CLUSTER_MIN_DIST then valid = false; break end
			if (Vector3.new(c.X, 0, -c.Z)    - candidate).Magnitude < Config.CLUSTER_MIN_DIST then valid = false; break end
		end
		if valid then table.insert(halfCenters, candidate) end
	end

	-- 2. Scatter deposits around each centre and simultaneously place the mirror.
	for _, center in halfCenters do
		local clusterSize = math.random(Config.CLUSTER_SIZE_MIN, Config.CLUSTER_SIZE_MAX)
		local placed      = 0
		for _ = 1, 1000 do
			if placed >= clusterSize then break end
			local angle = math.random() * math.pi * 2
			local dist  = math.random() * Config.CLUSTER_RADIUS
			local x     = math.round((center.X + math.cos(angle) * dist) / GRID) * GRID
			local z     = math.round((center.Z + math.sin(angle) * dist) / GRID) * GRID

			-- Reject z ≈ 0: the mirror would land almost on top of the original
			if math.abs(z) < GRID * 2 then continue end

			local candidate = Vector3.new(x, 0,  z)
			local mirrored  = Vector3.new(x, 0, -z)
			if candidate.Magnitude < 60 then continue end
			if mirrored.Magnitude  < 60 then continue end

			local valid = true
			for _, p in depositList do
				local pf = Vector3.new(p.X, 0, p.Z)
				if (pf - candidate).Magnitude < MIN_DIST then valid = false; break end
				if (pf - mirrored).Magnitude  < MIN_DIST then valid = false; break end
			end

			if valid then
				table.insert(depositList, candidate)
				depositClaimed[posKey(candidate)] = false
				table.insert(depositList, mirrored)
				depositClaimed[posKey(mirrored)]  = false
				placed += 1
			end
		end
	end
end

-- ── Ore wave system ───────────────────────────────────────────────────────────

-- Returns how many unclaimed (unbuilt-on) deposits currently exist.
local function countUnclaimedDeposits(): number
	local n = 0
	for _, pos in depositList do
		if depositClaimed[posKey(pos)] == false then n += 1 end
	end
	return n
end

-- Returns true if the XZ position is far enough from all placed buildings.
local function isClearOfBuildings(pos: Vector3): boolean
	local safe = Config.BUILDING_SIZE.X * 1.5
	local buildingsFolder = workspace:FindFirstChild("Buildings")
	if not buildingsFolder then return true end
	for _, model in buildingsFolder:GetChildren() do
		local base = model:FindFirstChild("Base") :: BasePart?
		if base then
			local dx = base.Position.X - pos.X
			local dz = base.Position.Z - pos.Z
			if dx * dx + dz * dz < safe * safe then return false end
		end
	end
	return true
end

-- Fires a comet wave: picks a new cluster center, validates positions,
-- fires the visual remote, then adds deposits after the travel time.
local function spawnCometWave()
	waveScheduled = false

	-- Bail if already near the deposit cap
	if countUnclaimedDeposits() >= Config.ORE_WAVE_MAX_DEPOSITS then return end

	local GRID     = Config.BUILDING_SIZE.X
	local SPREAD   = Config.DEPOSIT_SPREAD
	local MIN_DIST = GRID * 2

	-- Find a valid cluster center
	local center: Vector3? = nil
	for _ = 1, 600 do
		local x         = math.round(math.random(-SPREAD, SPREAD) / GRID) * GRID
		local z         = math.round(math.random(-SPREAD, SPREAD) / GRID) * GRID
		local candidate = Vector3.new(x, 0, z)
		if candidate.Magnitude < 60 then continue end
		if not isClearOfBuildings(candidate) then continue end

		-- Not too close to existing unclaimed clusters
		local valid = true
		for _, p in depositList do
			if depositClaimed[posKey(p)] == false then
				if (Vector3.new(p.X, 0, p.Z) - candidate).Magnitude < Config.CLUSTER_MIN_DIST then
					valid = false; break
				end
			end
		end
		if valid then center = candidate; break end
	end
	if not center then return end

	-- Scatter comet targets around the center
	local clusterSize    = math.random(Config.ORE_COMET_CLUSTER_SIZE_MIN, Config.ORE_COMET_CLUSTER_SIZE_MAX)
	local newPositions: { Vector3 } = {}
	for _ = 1, 600 do
		if #newPositions >= clusterSize then break end
		local angle     = math.random() * math.pi * 2
		local dist      = math.random() * Config.CLUSTER_RADIUS
		local x         = math.round(((center :: Vector3).X + math.cos(angle) * dist) / GRID) * GRID
		local z         = math.round(((center :: Vector3).Z + math.sin(angle) * dist) / GRID) * GRID
		local candidate = Vector3.new(x, 0, z)
		if candidate.Magnitude < 60 then continue end
		local key = posKey(candidate)
		if depositClaimed[key] ~= nil then continue end
		if not isClearOfBuildings(candidate) then continue end

		local valid = true
		for _, p in depositList do
			if (Vector3.new(p.X, 0, p.Z) - candidate).Magnitude < MIN_DIST then
				valid = false; break
			end
		end
		for _, np in newPositions do
			if (np - candidate).Magnitude < MIN_DIST then valid = false; break end
		end
		if valid then table.insert(newPositions, candidate) end
	end
	if #newPositions == 0 then return end

	-- Build comet data for clients: stagger each comet 0.4 s apart
	local cometData: { { pos: Vector3, stagger: number } } = {}
	for i, pos in newPositions do
		table.insert(cometData, { pos = pos, stagger = (i - 1) * 0.4 })
	end
	RemoteHandler.get(Config.REMOTES.CometWave):FireAllClients(cometData)

	-- After each comet lands, add the deposit (re-check buildings in case one was built during flight)
	local travelTime = Config.ORE_COMET_HEIGHT / Config.ORE_COMET_SPEED
	for i, pos in newPositions do
		local stagger = (i - 1) * 0.4
		task.delay(travelTime + stagger, function()
			if not isClearOfBuildings(pos) then return end
			local key = posKey(pos)
			if depositClaimed[key] ~= nil then return end
			table.insert(depositList, pos)
			depositClaimed[key] = false
			makeDepositPart(pos)
			RemoteHandler.get(Config.REMOTES.SyncDeposits):FireAllClients(
				MineralManager.getUnclaimedPositions()
			)
		end)
	end
end

-- Schedules a comet wave after a delay based on current unclaimed ore count.
-- Only one wave can be pending at a time.
local function scheduleOreWave()
	if waveScheduled then return end
	local current = countUnclaimedDeposits()
	if current >= Config.ORE_WAVE_MAX_DEPOSITS then return end

	-- Fewer ores → shorter interval
	local t        = current / Config.ORE_WAVE_MAX_DEPOSITS
	local interval = Config.ORE_WAVE_MIN_INTERVAL
		+ (Config.ORE_WAVE_MAX_INTERVAL - Config.ORE_WAVE_MIN_INTERVAL) * t

	waveScheduled = true
	task.delay(interval, spawnCometWave)
end

-- ── Depletion ─────────────────────────────────────────────────────────────────

local function applyDepletedVisuals(mineId: string)
	local buildingsFolder = workspace:FindFirstChild("Buildings")
	if not buildingsFolder then return end
	local model = buildingsFolder:FindFirstChild(mineId)
	if not model then return end

	-- Grey out crystals and dim the extraction disk
	for _, part in model:GetChildren() do
		if part.Name == "Crystal" or part:IsA("BasePart") and (part :: BasePart).Material == Enum.Material.Neon
			and part.Name ~= "UpgradeRing" and part.Name ~= "ExtractionDisk" then
			if part:IsA("BasePart") then
				local bp = part :: BasePart
				bp.BrickColor = BrickColor.new("Dark stone grey")
				bp.Material   = Enum.Material.SmoothPlastic
			end
		end
	end
	local disk = model:FindFirstChild("ExtractionDisk") :: BasePart?
	if disk then disk.Transparency = 0.92 end

	-- Remove upgrade ring (depleted mine loses its glow)
	local ring = model:FindFirstChild("UpgradeRing")
	if ring then ring:Destroy() end

	local base = model:FindFirstChild("Base") :: BasePart?
	if not base then return end

	local existing = base:FindFirstChild("DepletedSign")
	if existing then return end

	-- Sign floats above the structure; for the new open-frame mine use a higher offset
	local isFrameMine = model:FindFirstChild("ExtractionDisk") ~= nil
	local signOffset  = isFrameMine and 11 or (base.Size.Y / 2 + 5.5)

	local bb              = Instance.new("BillboardGui")
	bb.Name               = "DepletedSign"
	bb.Size               = UDim2.fromOffset(110, 28)
	bb.StudsOffset        = Vector3.new(0, signOffset, 0)
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
	scheduleOreWave()
	-- Notify the mine owner
	RemoteHandler.get(Config.REMOTES.MineDepletionWarning):FireClient(data.owner, mineId)
end

-- ── Miner health helpers ─────────────────────────────────────────────────────

local MINER_MAX_HP = Config.MINI_MINER_HP

local function addMinerHealthBar(body: BasePart)
	local bb            = Instance.new("BillboardGui")
	bb.Name             = "HealthBar"
	bb.Size             = UDim2.fromOffset(50, 6)
	bb.StudsOffset      = Vector3.new(0, body.Size.Y / 2 + 1, 0)
	bb.AlwaysOnTop      = false
	bb.Enabled          = false
	bb.Parent           = body

	local bg            = Instance.new("Frame")
	bg.Size             = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3 = Color3.fromRGB(40, 0, 0)
	bg.BorderSizePixel  = 0
	bg.Parent           = bb

	local fill          = Instance.new("Frame")
	fill.Name           = "Fill"
	fill.Size           = UDim2.new(1, 0, 1, 0)
	fill.BackgroundColor3 = Color3.fromRGB(0, 200, 50)
	fill.BorderSizePixel  = 0
	fill.Parent         = bg
end

local function applyMinerHP(model: any, hp: number)
	local body = model:FindFirstChild("Body") :: BasePart?
	if not body then return end
	local bb = body:FindFirstChild("HealthBar") :: BillboardGui?
	if not bb then return end
	local ratio = math.clamp(hp / MINER_MAX_HP, 0, 1)
	local bg    = bb:FindFirstChildWhichIsA("Frame")
	if not bg then return end
	local fill  = bg:FindFirstChild("Fill") :: Frame?
	if fill then
		fill.Size = UDim2.new(ratio, 0, 1, 0)
		local r = math.clamp(2 * (1 - ratio), 0, 1)
		local g = math.clamp(2 * ratio, 0, 1)
		fill.BackgroundColor3 = Color3.new(r, g, 0)
	end
	bb.Enabled = hp < MINER_MAX_HP
end

-- ── Miner visual constants ────────────────────────────────────────────────────

local MINER_BASE_SIZE  = Vector3.new(4,   1.5, 4)
local MINER_BODY_SIZE  = Vector3.new(2.5, 3.5, 2.5)
local MINER_ARM_W      = 1.2   -- arm cross-section (square)
local MINER_BODY_HALF  = MINER_BODY_SIZE.X / 2
local MINER_ARM_MIN    = 0.1   -- fully retracted length

-- Move the extraction arm to the given extension length.
-- bodyEdge   : world pos of the body's face nearest to the mine (at arm height)
-- toMineDir  : unit XZ vector pointing from miner toward mine center
-- mineTarget : Vector3 of mine center at arm height (used for CFrame orientation)
local function setArmExtension(
	arm: Part,
	bodyEdge: Vector3,
	toMineDir: Vector3,
	mineTarget: Vector3,
	armLen: number
)
	local safeLen  = math.max(armLen, 0.01)
	local armCenter = bodyEdge + toMineDir * (safeLen / 2)
	arm.Size   = Vector3.new(MINER_ARM_W, MINER_ARM_W, safeLen)
	-- CFrame.new(pos, lookAt): front face (-Z local) faces toward mineTarget,
	-- so the arm's length extends between the miner body and the mine.
	arm.CFrame = CFrame.new(armCenter, Vector3.new(mineTarget.X, armCenter.Y, mineTarget.Z))
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
	if not offset then return end

	local minerPos = data.pos + Vector3.new(offset.X * spacing, 0, offset.Z * spacing)

	-- Direction from this miner toward the mine center (XZ only)
	local toMineXZ   = Vector3.new(data.pos.X - minerPos.X, 0, data.pos.Z - minerPos.Z)
	local distToMine = toMineXZ.Magnitude
	local toMineDir  = distToMine > 0.001 and toMineXZ.Unit or Vector3.new(0, 0, 1)

	-- Arm geometry
	local groundY     = 0.1
	local armY        = groundY + MINER_BASE_SIZE.Y + MINER_BODY_SIZE.Y * 0.65
	local bodyEdge    = Vector3.new(
		minerPos.X + toMineDir.X * MINER_BODY_HALF,
		armY,
		minerPos.Z + toMineDir.Z * MINER_BODY_HALF
	)
	local mineTarget = Vector3.new(data.pos.X, armY, data.pos.Z)
	local ARM_MAX    = (distToMine - MINER_BODY_HALF) * 0.85

	-- ── Build the miner model ─────────────────────────────────────────────────

	local model     = Instance.new("Model")
	model.Name      = mineId .. "_miner" .. slot

	-- Flat base slab
	local base      = Instance.new("Part")
	base.Name       = "Base"
	base.Size       = MINER_BASE_SIZE
	base.Position   = Vector3.new(minerPos.X, groundY + MINER_BASE_SIZE.Y / 2, minerPos.Z)
	base.BrickColor = player.TeamColor
	base.Material   = Enum.Material.DiamondPlate
	base.Anchored   = true
	base.CastShadow = false
	base.CanCollide = false
	base.Parent     = model

	-- Boxy machine body
	local body      = Instance.new("Part")
	body.Name       = "Body"
	body.Size       = MINER_BODY_SIZE
	body.Position   = Vector3.new(
		minerPos.X,
		groundY + MINER_BASE_SIZE.Y + MINER_BODY_SIZE.Y / 2,
		minerPos.Z
	)
	body.BrickColor = BrickColor.new("Dark stone grey")
	body.Material   = Enum.Material.Metal
	body.Anchored   = true
	body.CastShadow = false
	body.CanCollide = false
	body.Parent     = model

	-- Extraction arm (neon team-colour, starts fully retracted)
	local arm       = Instance.new("Part")
	arm.Name        = "Arm"
	arm.BrickColor  = player.TeamColor
	arm.Material    = Enum.Material.Neon
	arm.Anchored    = true
	arm.CastShadow  = false
	arm.CanCollide  = false
	arm.Parent      = model
	setArmExtension(arm, bodyEdge, toMineDir, mineTarget, MINER_ARM_MIN)

	-- Metadata
	local ov = Instance.new("StringValue"); ov.Name = "OwnerId"
	ov.Value = tostring(player.UserId); ov.Parent = model

	local mv = Instance.new("StringValue"); mv.Name = "MineId"
	mv.Value = mineId; mv.Parent = model

	addMinerHealthBar(body)

	model.PrimaryPart = base
	model.Parent      = minersFolder

	-- Initialise HP and clean up on destruction
	minerHpTable[model] = MINER_MAX_HP
	model.Destroying:Connect(function()
		minerHpTable[model] = nil
	end)

	data.miners += 1

	RemoteHandler.get(Config.REMOTES.MinerSpawned):FireAllClients(
		mineId, player.UserId, data.miners
	)

	-- ── Per-miner extraction coroutine ────────────────────────────────────────
	-- Phases (fractions of MINI_MINER_INCOME_INTERVAL):
	--   40 % extend → 15 % hold/jitter → give income → 30 % retract → 15 % pause
	-- Miners are staggered by their slot index so they collect independently.

	local CYCLE       = Config.MINI_MINER_INCOME_INTERVAL
	local staggerFrac = (slot - 1) / math.max(data.minerCap, 1)
	local stagger     = staggerFrac * CYCLE

	task.spawn(function()
		if stagger > 0 then task.wait(stagger) end

		local function alive(): boolean
			local d = mines[mineId]
			return arm.Parent ~= nil and d ~= nil and not d.depleted
		end

		while alive() do
			-- Extend ──────────────────────────────────────────────────────────
			local extendDur = CYCLE * 0.40
			local t0 = os.clock()
			while alive() and (os.clock() - t0) < extendDur do
				local t = math.clamp((os.clock() - t0) / extendDur, 0, 1)
				setArmExtension(arm, bodyEdge, toMineDir, mineTarget,
					MINER_ARM_MIN + (ARM_MAX - MINER_ARM_MIN) * t)
				task.wait(0.05)
			end
			if not alive() then break end

			-- Hold / drill jitter ─────────────────────────────────────────────
			local holdDur = CYCLE * 0.15
			t0 = os.clock()
			while alive() and (os.clock() - t0) < holdDur do
				local jitter = math.sin((os.clock() - t0) * 22) * 0.15
				setArmExtension(arm, bodyEdge, toMineDir, mineTarget, ARM_MAX + jitter)
				task.wait(0.05)
			end
			if not alive() then break end

			-- Give income ─────────────────────────────────────────────────────
			local mdata = mines[mineId]
			if mdata and mdata.owner.Parent then
				local income = Config.MINI_MINER_INCOME * mdata.incomeMultiplier
				resourceManager.add(mdata.owner, income)
				if typeof(mdata.owner) == "Instance" and mdata.owner:IsA("Player") then
					RemoteHandler.get(Config.REMOTES.MineIncome):FireClient(
						mdata.owner, mineId, income
					)
				end
				mdata.depositTotal -= income
				if mdata.depositTotal <= 0 then
					depleteMineSite(mineId)
					break
				end
			else
				break
			end

			-- Retract ─────────────────────────────────────────────────────────
			local retractDur = CYCLE * 0.30
			t0 = os.clock()
			while alive() and (os.clock() - t0) < retractDur do
				local t = math.clamp((os.clock() - t0) / retractDur, 0, 1)
				setArmExtension(arm, bodyEdge, toMineDir, mineTarget,
					ARM_MAX + (MINER_ARM_MIN - ARM_MAX) * t)
				task.wait(0.05)
			end
			if not alive() then break end
			setArmExtension(arm, bodyEdge, toMineDir, mineTarget, MINER_ARM_MIN)

			-- Pause ───────────────────────────────────────────────────────────
			task.wait(CYCLE * 0.15)
		end
	end)
end

-- ── Upgrade visuals ───────────────────────────────────────────────────────────

local function applyUpgradeVisuals(mineId: string, upgradeType: string)
	local buildingsFolder = workspace:FindFirstChild("Buildings")
	if not buildingsFolder then return end
	local model = buildingsFolder:FindFirstChild(mineId)
	if not model then return end

	-- Remove any previous upgrade ring
	local oldRing = model:FindFirstChild("UpgradeRing")
	if oldRing then oldRing:Destroy() end

	local upgradeColor: BrickColor
	local upgradeMat: Enum.Material
	if upgradeType == "Efficiency" then
		upgradeColor = BrickColor.new("Sand blue")
		upgradeMat   = Enum.Material.Metal
	else  -- Capacity
		upgradeColor = BrickColor.new("Sand red")
		upgradeMat   = Enum.Material.DiamondPlate
	end

	-- Recolor the 4 frame pillars to a structural painted-metal look.
	-- Crystal is untouched so the yellow shard stays visible.
	for _, child in model:GetChildren() do
		if child.Name == "Pillar" and child:IsA("BasePart") then
			local bp = child :: BasePart
			bp.BrickColor = upgradeColor
			bp.Material   = upgradeMat
		end
	end

	-- Solid structural band around the base platform.
	local base    = model:FindFirstChild("Base") :: BasePart?
	local centerX = base and base.Position.X or 0
	local centerZ = base and base.Position.Z or 0
	local ringY   = base and (base.Position.Y + base.Size.Y / 2 + 0.25) or 1.25

	local ring        = Instance.new("Part")
	ring.Name         = "UpgradeRing"
	ring.Size         = Vector3.new(11, 0.5, 11)
	ring.Position     = Vector3.new(centerX, ringY, centerZ)
	ring.BrickColor   = upgradeColor
	ring.Material     = upgradeMat
	ring.Anchored     = true
	ring.CanCollide   = false
	ring.CastShadow   = false
	ring.Parent       = model

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
		-- Raise the cap; the persistent spawn loop in registerMine will fill the new slots.
		data.minerCap += Config.MINE_UPGRADE_CAPACITY_EXTRA
	end

	applyUpgradeVisuals(mineId, upgradeType)
	return true
end

-- ── Miner combat API ─────────────────────────────────────────────────────────

-- Damage the nearest enemy miner within range. Returns (hit, hitPos).
function MineralManager.damageNearestMiner(
	fromPos: Vector3,
	attackerOwnerIdStr: string,
	range: number,
	damage: number
): (boolean, Vector3?)
	local bestModel: any = nil
	local bestDist  = math.huge

	for model, hp in minerHpTable do
		if hp <= 0 then continue end
		local ov = model:FindFirstChild("OwnerId")
		if not ov then continue end
		if ov.Value == attackerOwnerIdStr then continue end   -- same team
		local base = model:FindFirstChild("Base") :: BasePart?
		if not base or not base.Parent then continue end
		local d = (base.Position - fromPos).Magnitude
		if d <= range and d < bestDist then
			bestDist  = d
			bestModel = model
		end
	end

	if not bestModel then return false, nil end

	local base   = bestModel:FindFirstChild("Base") :: BasePart
	local hitPos = base.Position + Vector3.new(0, MINER_BASE_SIZE.Y + MINER_BODY_SIZE.Y * 0.5, 0)

	local newHp = math.max(0, (minerHpTable[bestModel] or 0) - damage)
	minerHpTable[bestModel] = newHp
	applyMinerHP(bestModel, newHp)

	if newHp <= 0 then
		local mv = bestModel:FindFirstChild("MineId")
		if mv then
			local mineId = mv.Value
			local mdata  = mines[mineId]
			if mdata then
				mdata.miners = math.max(0, mdata.miners - 1)
				-- Sync client miner count so HUD income display stays accurate
				RemoteHandler.get(Config.REMOTES.MinerSpawned):FireAllClients(
					mineId, mdata.owner.UserId, mdata.miners
				)
			end
		end
		minerHpTable[bestModel] = nil
		bestModel:Destroy()
	end

	return true, hitPos
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

-- Regenerates the deposit layout (used by the lobby re-roll).
-- Safe to call before any mines exist.
function MineralManager.rerollDeposits()
	depositList    = {}
	depositClaimed = {}
	waveScheduled  = false
	for _, model in depositsFolder:GetChildren() do model:Destroy() end
	generateDeposits()
	for _, pos in depositList do makeDepositPart(pos) end
	RemoteHandler.get(Config.REMOTES.SyncDeposits):FireAllClients(
		MineralManager.getUnclaimedPositions()
	)
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

	-- Persistent loop: fills slots up to cap on initial spawn AND after combat losses.
	task.spawn(function()
		while true do
			task.wait(Config.MINI_MINER_SPAWN_INTERVAL)
			local data = mines[mineId]
			if not data then break end
			if data.depleted then break end
			if data.miners < data.minerCap then
				spawnMiner(mineId)
			end
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

function MineralManager.resetAll()
	-- Clear mines and miners
	mines = {}
	for _, part in minersFolder:GetChildren() do part:Destroy() end

	-- Clear deposit state and visuals
	depositList    = {}
	depositClaimed = {}
	waveScheduled  = false
	for _, model in depositsFolder:GetChildren() do model:Destroy() end

	-- Regenerate fresh deposits and sync to all clients
	generateDeposits()
	for _, pos in depositList do makeDepositPart(pos) end
	RemoteHandler.get(Config.REMOTES.SyncDeposits):FireAllClients(
		MineralManager.getUnclaimedPositions()
	)
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

	-- Upgrade remote
	RemoteHandler.get(Config.REMOTES.UpgradeMine).OnServerEvent:Connect(
		function(player, mineId, upgradeType)
			if type(mineId) ~= "string" or type(upgradeType) ~= "string" then return end
			MineralManager.applyUpgrade(mineId, upgradeType, player)
		end
	)
end

return MineralManager
