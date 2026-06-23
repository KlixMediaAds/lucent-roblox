local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local RemoteHandler     = require(Shared:WaitForChild("RemoteHandler"))
local FungiCluster      = require(Shared:WaitForChild("FungiCluster"))

local MineralManager = {}

local depositResources: { [string]: number } = {}  -- posKey → resources remaining
local depositList:      { Vector3 }           = {}
local depositThresholdBand:  { [string]: number }  = {}  -- posKey → last visual band (4/3/2/1/0)
local waveScheduled     = false

local depositsFolder: Folder
local resourceManager: any
local forestManagerRef: any
local terrainManagerRef: any

local function posKey(v: Vector3): string
	return math.round(v.X) .. "," .. math.round(v.Z)
end

-- ── Deposit visuals ───────────────────────────────────────────────────────────

local function makeDepositPart(pos: Vector3)
	-- Derive a stable seed from grid position so every deposit looks unique but
	-- regenerates identically on round reset.
	local seed    = math.abs(math.round(pos.X) * 1000 + math.round(pos.Z) * 7919) % 999983 + 1
	-- Sit the cluster on the real terrain surface it landed on (key stays XZ-only)
	-- so it isn't buried under a raised tier; matches the client deposit markers.
	local groundY = terrainManagerRef and terrainManagerRef.surfaceHeightAt(pos.X, pos.Z) or 0
	local cluster = FungiCluster.create(Vector3.new(pos.X, groundY, pos.Z), seed, 1.0)
	cluster.Name  = posKey(pos)
	cluster.Parent = depositsFolder
	depositThresholdBand[posKey(pos)] = 4
	-- Keep resources clear of trees (matters for ore-wave deposits that land
	-- after the forest already exists; initial generation avoids deposits too).
	if forestManagerRef then forestManagerRef.clearAround(pos, 16) end
end

local function depositBand(fullness: number): number
	if fullness >= 0.75 then return 4
	elseif fullness >= 0.50 then return 3
	elseif fullness >= 0.25 then return 2
	elseif fullness >= 0.10 then return 1
	else return 0
	end
end

local function checkColonyRebuild(pos: Vector3)
	local key      = posKey(pos)
	local cur      = depositResources[key] or 0
	local fullness = cur / Config.DEPOSIT_TOTAL_RESOURCES
	local band     = depositBand(fullness)
	if depositThresholdBand[key] == band then return end
	depositThresholdBand[key] = band
	local colonyModel = depositsFolder:FindFirstChild(key)
	if colonyModel and colonyModel:IsA("Model") then
		FungiCluster.rebuild(colonyModel, fullness)
	end
end

-- ── Deposit generation ────────────────────────────────────────────────────────

local function generateDeposits()
	local GRID     = Config.BUILDING_SIZE.X
	local SPREAD   = Config.DEPOSIT_SPREAD
	local MIN_DIST = GRID * 2

	local pairCount = math.floor(Config.CLUSTER_COUNT / 2)
	local zMin = math.ceil(Config.CLUSTER_MIN_DIST / 2 / GRID) * GRID
	local halfCenters: { Vector3 } = {}
	for _ = 1, 3000 do
		if #halfCenters >= pairCount then break end
		local x         = math.round(math.random(-SPREAD, SPREAD) / GRID) * GRID
		local z         = math.round(math.random(zMin, SPREAD)    / GRID) * GRID
		local candidate = Vector3.new(x, 0, z)
		if candidate.Magnitude < 60 then continue end

		local valid = true
		for _, c in halfCenters do
			if (c                             - candidate).Magnitude < Config.CLUSTER_MIN_DIST then valid = false; break end
			if (Vector3.new(c.X, 0, -c.Z)    - candidate).Magnitude < Config.CLUSTER_MIN_DIST then valid = false; break end
		end
		if valid then table.insert(halfCenters, candidate) end
	end

	for _, center in halfCenters do
		local clusterSize = math.random(Config.CLUSTER_SIZE_MIN, Config.CLUSTER_SIZE_MAX)
		local placed      = 0
		for _ = 1, 1000 do
			if placed >= clusterSize then break end
			local angle = math.random() * math.pi * 2
			local dist  = math.random() * Config.CLUSTER_RADIUS
			local x     = math.round((center.X + math.cos(angle) * dist) / GRID) * GRID
			local z     = math.round((center.Z + math.sin(angle) * dist) / GRID) * GRID

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
				depositResources[posKey(candidate)] = Config.DEPOSIT_TOTAL_RESOURCES
				table.insert(depositList, mirrored)
				depositResources[posKey(mirrored)]  = Config.DEPOSIT_TOTAL_RESOURCES
				placed += 1
			end
		end
	end
end

-- ── Ore wave system ───────────────────────────────────────────────────────────

local function countActiveDeposits(): number
	local n = 0
	for _, pos in depositList do
		if (depositResources[posKey(pos)] or 0) > 0 then n += 1 end
	end
	return n
end

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

local function scheduleOreWave()
	if waveScheduled then return end
	local current = countActiveDeposits()
	if current >= Config.ORE_WAVE_MAX_DEPOSITS then return end

	local t        = current / Config.ORE_WAVE_MAX_DEPOSITS
	local interval = Config.ORE_WAVE_MIN_INTERVAL
		+ (Config.ORE_WAVE_MAX_INTERVAL - Config.ORE_WAVE_MIN_INTERVAL) * t

	waveScheduled = true
	task.delay(interval, function()
		waveScheduled = false

		if countActiveDeposits() >= Config.ORE_WAVE_MAX_DEPOSITS then return end

		local GRID     = Config.BUILDING_SIZE.X
		local SPREAD   = Config.DEPOSIT_SPREAD
		local MIN_DIST = GRID * 2

		local center: Vector3? = nil
		for _ = 1, 600 do
			local x         = math.round(math.random(-SPREAD, SPREAD) / GRID) * GRID
			local z         = math.round(math.random(-SPREAD, SPREAD) / GRID) * GRID
			local candidate = Vector3.new(x, 0, z)
			if candidate.Magnitude < 60 then continue end
			if not isClearOfBuildings(candidate) then continue end

			local valid = true
			for _, p in depositList do
				if (depositResources[posKey(p)] or 0) > 0 then
					if (Vector3.new(p.X, 0, p.Z) - candidate).Magnitude < Config.CLUSTER_MIN_DIST then
						valid = false; break
					end
				end
			end
			if valid then center = candidate; break end
		end
		if not center then return end

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
			if depositResources[key] ~= nil then continue end  -- already exists
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

		local cometData: { { pos: Vector3, stagger: number } } = {}
		for i, pos in newPositions do
			table.insert(cometData, { pos = pos, stagger = (i - 1) * 0.4 })
		end
		RemoteHandler.get(Config.REMOTES.CometWave):FireAllClients(cometData)

		local travelTime = Config.ORE_COMET_HEIGHT / Config.ORE_COMET_SPEED
		for i, pos in newPositions do
			local stagger = (i - 1) * 0.4
			task.delay(travelTime + stagger, function()
				if not isClearOfBuildings(pos) then return end
				local key = posKey(pos)
				if depositResources[key] ~= nil then return end
				table.insert(depositList, pos)
				depositResources[key] = Config.DEPOSIT_TOTAL_RESOURCES
				makeDepositPart(pos)
				RemoteHandler.get(Config.REMOTES.SyncDeposits):FireAllClients(
					MineralManager.getUnclaimedPositions()
				)
			end)
		end
	end)
end

-- ── Foundry boost / drain API ───────────────────────────────────────────────────

-- Counts the active (non-empty) deposits within `radius` of `point`. Drives the
-- Foundry income boost (+X% per nearby deposit) without mutating anything.
function MineralManager.countActiveDepositsNear(point: Vector3, radius: number): number
	local r2 = radius * radius
	local n  = 0
	for _, pos in depositList do
		if (depositResources[posKey(pos)] or 0) <= 0 then continue end
		local dx = pos.X - point.X
		local dz = pos.Z - point.Z
		if dx * dx + dz * dz <= r2 then n += 1 end
	end
	return n
end

-- Drains EVERY active deposit within `radius` of `point` by up to `perDeposit` each
-- (unlike drainNear, which caps at the 3 nearest for harvester beam VFX). Applies the
-- band visuals, removes depleted deposits, schedules ore waves, and returns the number
-- of deposits that still had resources when the drain began — i.e. the count that
-- boosted the Foundry this tick. Used by the Foundry passive-income tick.
function MineralManager.drainAllNear(point: Vector3, radius: number, perDeposit: number): number
	local r2          = radius * radius
	local count       = 0
	local anyDepleted = false
	for _, pos in depositList do
		local key = posKey(pos)
		local res = depositResources[key] or 0
		if res <= 0 then continue end
		local dx = pos.X - point.X
		local dz = pos.Z - point.Z
		if dx * dx + dz * dz > r2 then continue end

		count += 1
		local extract = math.min(perDeposit, res)
		depositResources[key] = res - extract
		if depositResources[key] <= 0 then
			anyDepleted = true
		else
			checkColonyRebuild(pos)
		end
	end

	if anyDepleted then
		local i = #depositList
		while i >= 1 do
			local pos = depositList[i]
			local key = posKey(pos)
			if (depositResources[key] or 1) <= 0 then
				local model = depositsFolder:FindFirstChild(key)
				if model then model:Destroy() end
				table.remove(depositList, i)
				depositResources[key]     = nil
				depositThresholdBand[key] = nil
			end
			i -= 1
		end
		RemoteHandler.get(Config.REMOTES.SyncDeposits):FireAllClients(
			MineralManager.getUnclaimedPositions()
		)
		scheduleOreWave()
	end

	return count
end

-- ── Deposit API ───────────────────────────────────────────────────────────────

function MineralManager.getUnclaimedPositions(): { Vector3 }
	local out = {}
	for _, pos in depositList do
		if (depositResources[posKey(pos)] or 0) > 0 then
			table.insert(out, pos)
		end
	end
	return out
end

function MineralManager.rerollDeposits()
	depositList          = {}
	depositResources     = {}
	depositThresholdBand = {}
	waveScheduled        = false
	for _, model in depositsFolder:GetChildren() do model:Destroy() end
	generateDeposits()
	for _, pos in depositList do makeDepositPart(pos) end
	RemoteHandler.get(Config.REMOTES.SyncDeposits):FireAllClients(
		MineralManager.getUnclaimedPositions()
	)
end

-- Re-resolves every existing deposit's Y against the *current* terrain surface.
-- Deposits are generated once (at MineralManager.init, before any terrain exists)
-- and their cluster parts bake in a groundY at creation time. Whenever the terrain
-- is (re)generated afterwards — lobby start, reroll, toggle, gamemode change — the
-- baked Y goes stale and a deposit sitting on a raised tier ends up buried. Call
-- this after each terrain (re)generation so deposits rest on the surface they
-- actually landed on, mirroring how buildings snap via surfaceHeightAt at placement.
function MineralManager.resnapDeposits()
	if not (terrainManagerRef and depositsFolder) then return end
	for _, pos in depositList do
		local model = depositsFolder:FindFirstChild(posKey(pos))
		if model and model:IsA("Model") and model.PrimaryPart then
			local newY   = terrainManagerRef.surfaceHeightAt(pos.X, pos.Z)
			local curY   = model.PrimaryPart.Position.Y
			if math.abs(newY - curY) > 0.01 then
				model:PivotTo(model:GetPivot() + Vector3.new(0, newY - curY, 0))
				model:SetAttribute("ColonyOriginY", newY)
			end
		end
	end
end

function MineralManager.resetAll()
	depositList          = {}
	depositResources     = {}
	depositThresholdBand = {}
	waveScheduled        = false
	for _, model in depositsFolder:GetChildren() do model:Destroy() end
	generateDeposits()
	for _, pos in depositList do makeDepositPart(pos) end
	RemoteHandler.get(Config.REMOTES.SyncDeposits):FireAllClients(
		MineralManager.getUnclaimedPositions()
	)
end

function MineralManager.setBuildingManager(_bm: any) end
function MineralManager.setResearchManager(_rm: any) end
function MineralManager.setForestManager(fm: any) forestManagerRef = fm end
function MineralManager.setTerrainManager(tm: any) terrainManagerRef = tm end

-- Spawns `count` deposits clustered in the home direction of ccPos (away from map
-- centre), snapped to BUILDING_GRID.  Call after init() so depositsFolder exists.
function MineralManager.spawnDepositsForBase(ccPos: Vector3, count: number)
	local GRID    = Config.BUILDING_GRID
	local flatCC  = Vector3.new(ccPos.X, 0, ccPos.Z)
	local homeDir = flatCC.Magnitude > 0.1 and flatCC.Unit or Vector3.new(0, 0, 1)
	local perpDir = Vector3.new(-homeDir.Z, 0, homeDir.X)

	-- Fan-pattern offsets: (studs along homeDir, studs along perpDir)
	local OFFSETS = {
		{ h = 35, p =   0 },
		{ h = 45, p =  20 },
		{ h = 45, p = -20 },
		{ h = 60, p =  12 },
		{ h = 60, p = -12 },
	}

	for i = 1, math.min(count, #OFFSETS) do
		local o   = OFFSETS[i]
		local raw = flatCC + homeDir * o.h + perpDir * o.p
		local x   = math.round(raw.X / GRID) * GRID
		local z   = math.round(raw.Z / GRID) * GRID
		local pos = Vector3.new(x, 0, z)
		local key = posKey(pos)

		if depositResources[key] then continue end  -- already occupied

		table.insert(depositList, pos)
		depositResources[key] = Config.DEPOSIT_TOTAL_RESOURCES
		makeDepositPart(pos)
	end

	-- Sync the full updated deposit list to all connected clients
	RemoteHandler.get(Config.REMOTES.SyncDeposits):FireAllClients(
		MineralManager.getUnclaimedPositions()
	)
end

-- ── Init ──────────────────────────────────────────────────────────────────────

function MineralManager.init(rm)
	resourceManager = rm

	depositsFolder        = Instance.new("Folder")
	depositsFolder.Name   = "Deposits"
	depositsFolder.Parent = workspace

	generateDeposits()
	for _, pos in depositList do makeDepositPart(pos) end
	print("[MineralManager] Placed", #depositList, "deposits")

	Players.PlayerAdded:Connect(function(player)
		RemoteHandler.get(Config.REMOTES.SyncDeposits):FireClient(
			player, MineralManager.getUnclaimedPositions()
		)
	end)
end

return MineralManager
