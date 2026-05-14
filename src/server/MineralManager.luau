local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local RemoteHandler     = require(Shared:WaitForChild("RemoteHandler"))
local FungiCluster      = require(Shared:WaitForChild("FungiCluster"))

local MineralManager = {}

type MineData = {
	pos:   Vector3,
	owner: Player,
	ready: boolean,  -- false while building is still under construction
}

local depositResources: { [string]: number } = {}  -- posKey → resources remaining
local depositList:      { Vector3 }           = {}
local mines:            { [string]: MineData } = {}
local mineActive:            { [string]: boolean } = {}  -- tracks which mines currently have deposits in range
local depositThresholdBand:  { [string]: number }  = {}  -- posKey → last visual band (4/3/2/1/0)
local waveScheduled     = false
local extractAccum      = 0

local depositsFolder: Folder
local resourceManager: any

local function posKey(v: Vector3): string
	return math.round(v.X) .. "," .. math.round(v.Z)
end

-- ── Deposit visuals ───────────────────────────────────────────────────────────

local function makeDepositPart(pos: Vector3)
	-- Derive a stable seed from grid position so every deposit looks unique but
	-- regenerates identically on round reset.
	local seed    = math.abs(math.round(pos.X) * 1000 + math.round(pos.Z) * 7919) % 999983 + 1
	local cluster = FungiCluster.create(pos, seed, 1.0)
	cluster.Name  = posKey(pos)
	cluster.Parent = depositsFolder
	depositThresholdBand[posKey(pos)] = 4
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

-- ── Extraction heartbeat ──────────────────────────────────────────────────────

local function extractionTick()
	local anyDepleted = false

	for mineId, data in mines do
		if not (data.owner :: any).Parent then continue end
		if not data.ready then continue end  -- still under construction

		-- Find all deposits in range with resources remaining
		local found: { Vector3 } = {}
		for _, pos in depositList do
			local key = posKey(pos)
			if (depositResources[key] or 0) <= 0 then continue end
			local d = (Vector3.new(data.pos.X, 0, data.pos.Z) - Vector3.new(pos.X, 0, pos.Z)).Magnitude
			if d <= Config.MINE_EXTRACT_RANGE then
				table.insert(found, pos)
			end
		end

		-- Resolve emitter world position from the mine model
		local emitterPos = data.pos + Vector3.new(0, 12.2, 0)
		local bf = workspace:FindFirstChild("Buildings")
		if bf then
			local model = bf:FindFirstChild(mineId)
			if model then
				local em = model:FindFirstChild("Emitter") :: BasePart?
				if em then emitterPos = em.Position end
			end
		end

		if #found == 0 then
			-- Send a stop signal once when the mine transitions from active to idle
			if mineActive[mineId] then
				mineActive[mineId] = nil
				RemoteHandler.get(Config.REMOTES.MineBeams):FireAllClients(mineId, emitterPos, {})
			end
			continue
		end

		-- Limit to the nearest 3 deposits (one arm per deposit)
		if #found > 3 then
			local mineXZ = Vector3.new(data.pos.X, 0, data.pos.Z)
			table.sort(found, function(a, b)
				return (Vector3.new(a.X, 0, a.Z) - mineXZ).Magnitude
				     < (Vector3.new(b.X, 0, b.Z) - mineXZ).Magnitude
			end)
			while #found > 3 do table.remove(found, #found) end
		end

		-- Extract from each deposit and tally income
		local totalIncome = 0
		for _, pos in found do
			local key = posKey(pos)
			local res = depositResources[key] or 0
			if res <= 0 then continue end
			local extract = math.min(Config.MINE_INCOME_PER_DEPOSIT, res)
			depositResources[key] = res - extract
			totalIncome += extract
			if depositResources[key] <= 0 then
				anyDepleted = true
			else
				checkColonyRebuild(pos)
			end
		end

		if totalIncome > 0 then
			resourceManager.add(data.owner, totalIncome)
			RemoteHandler.get(Config.REMOTES.MineIncome):FireClient(data.owner, mineId, totalIncome)
		end

		mineActive[mineId] = true
		RemoteHandler.get(Config.REMOTES.MineBeams):FireAllClients(mineId, emitterPos, found)
	end

	-- Remove any fully-depleted deposits
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
end

-- ── Deposit API ───────────────────────────────────────────────────────────────

-- No-op stub kept for BuildingManager compatibility.
-- Mines no longer claim deposits; they can be placed anywhere.
function MineralManager.tryClaimDeposit(_pos: Vector3): boolean
	return true
end

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

-- ── Mine registration ────────────────────────────────────────────────────────

function MineralManager.registerMine(mineId: string, minePos: Vector3, player: Player)
	mines[mineId] = {
		pos   = minePos,
		owner = player,
		ready = false,  -- set to true by BuildingManager once construction completes
	}
end

-- Called by BuildingManager when a mine's construction animation finishes.
function MineralManager.setMineReady(mineId: string)
	local data = mines[mineId]
	if data then data.ready = true end
end

-- ── Count / removal ───────────────────────────────────────────────────────────

function MineralManager.getMineCount(player: any): number
	local n = 0
	for _, data in mines do
		if data.owner == player then n += 1 end
	end
	return n
end

function MineralManager.removeMine(mineId: string)
	mines[mineId]      = nil
	mineActive[mineId] = nil
end

function MineralManager.removeAllMinesFor(player: any)
	local toRemove = {}
	for id, data in mines do
		if data.owner == player then table.insert(toRemove, id) end
	end
	for _, id in toRemove do
		mines[id]      = nil
		mineActive[id] = nil
	end
end

function MineralManager.resetAll()
	mines                = {}
	mineActive           = {}
	depositList          = {}
	depositResources     = {}
	depositThresholdBand = {}
	waveScheduled        = false
	extractAccum     = 0
	for _, model in depositsFolder:GetChildren() do model:Destroy() end
	generateDeposits()
	for _, pos in depositList do makeDepositPart(pos) end
	RemoteHandler.get(Config.REMOTES.SyncDeposits):FireAllClients(
		MineralManager.getUnclaimedPositions()
	)
end

-- ── Stubs for backward compatibility ─────────────────────────────────────────

-- No miners in new system; always returns no hit.
function MineralManager.damageNearestMiner(_fromPos: Vector3, _attackerOwnerIdStr: string, _range: number, _damage: number): (boolean, Vector3?)
	return false, nil
end

function MineralManager.setBuildingManager(_bm: any) end
function MineralManager.setResearchManager(_rm: any) end

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

	Players.PlayerRemoving:Connect(function(player)
		local toRemove = {}
		for id, data in mines do
			if data.owner == player then table.insert(toRemove, id) end
		end
		for _, id in toRemove do mines[id] = nil end
	end)

	-- Extraction heartbeat
	RunService.Heartbeat:Connect(function(dt)
		extractAccum += dt
		if extractAccum >= Config.MINE_EXTRACT_INTERVAL then
			extractAccum -= Config.MINE_EXTRACT_INTERVAL
			extractionTick()
		end
	end)
end

return MineralManager
