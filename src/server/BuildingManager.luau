local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local RemoteHandler     = require(Shared:WaitForChild("RemoteHandler"))

local BuildingManager    = {}
local buildingsFolder: Folder
local counter            = 0
local mineralManager: any
local resourceManagerRef: any
local unitManagerRef: any
local researchManagerRef: any
local onCCDestroyedCb: ((any) -> ())?

type BuildingData = { hp: number, maxHp: number, base: BasePart, owner: any, buildingType: string, head: BasePart?, barrel: BasePart?, isConstructing: boolean, turretUpgrade: string? }
local buildingData: { [string]: BuildingData } = {}
local playerHasCC:  { [number]: boolean }      = {}
local turretTimers: { [string]: number }        = {}   -- attackTimer per turret id
local onPlayerWonCb: (() -> ())?

local monumentByOwner:       { [number]: string } = {}  -- userId → buildingId
local monumentWinTimer:      { [string]: number } = {}  -- buildingId → active seconds elapsed
local monumentHeartbeatAccum = 0

local ccAttackThrottle: { [number]: number } = {}   -- userId → last-fire timestamp
local CC_ATTACK_THROTTLE = 5  -- seconds between CC attack notifications

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function buildingSize(buildingType: string): Vector3
	if buildingType == "CommandCenter" then return Config.COMMAND_CENTER_SIZE end
	if buildingType == "Monument"      then return Config.MONUMENT_SIZE end
	if buildingType == "Relay"         then return Config.RELAY_SIZE end
	return Config.BUILDING_SIZE
end

local function snapGrid(v: Vector3): Vector3
	local g = Config.BUILDING_GRID
	return Vector3.new(math.round(v.X / g) * g, 0, math.round(v.Z / g) * g)
end

-- Returns how many buildings of a given type the player currently owns.
local function getPlayerBuildingCount(player: any, buildingType: string): number
	local n = 0
	for _, data in buildingData do
		if data.owner == player and data.buildingType == buildingType then n += 1 end
	end
	return n
end

-- Returns true if the proposed footprint overlaps any existing building (AABB check).
-- pos is the snapped Y=0 centre; buildingType determines footprint size.
local function isOccupied(pos: Vector3, newType: string): boolean
	local ns = buildingSize(newType)
	for _, data in buildingData do
		local es  = buildingSize(data.buildingType)
		local halfX = (ns.X + es.X) / 2
		local halfZ = (ns.Z + es.Z) / 2
		-- base.Position X/Z always equals the original snapped centre
		local dx = math.abs(data.base.Position.X - pos.X)
		local dz = math.abs(data.base.Position.Z - pos.Z)
		if dx < halfX and dz < halfZ then
			return true
		end
	end
	return false
end

-- ── Health bar ────────────────────────────────────────────────────────────────

local function addHealthBar(part: BasePart)
	local bb            = Instance.new("BillboardGui")
	bb.Name             = "HealthBar"
	bb.Size             = UDim2.new(0, 80, 0, 9)
	bb.StudsOffset      = Vector3.new(0, part.Size.Y / 2 + 2.5, 0)
	bb.AlwaysOnTop      = false
	bb.Enabled          = true
	bb.Parent           = part

	local bg            = Instance.new("Frame")
	bg.Size             = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3 = Color3.fromRGB(40, 0, 0)
	bg.BorderSizePixel  = 0
	bg.Parent           = bb

	local fill          = Instance.new("Frame")
	fill.Name           = "Fill"
	fill.Size           = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = Color3.fromRGB(0, 200, 50)
	fill.BorderSizePixel  = 0
	fill.Parent         = bg
end

local function applyHP(data: BuildingData)
	local bb = data.base:FindFirstChild("HealthBar") :: BillboardGui?
	if not bb then return end
	local ratio = math.clamp(data.hp / data.maxHp, 0, 1)
	local bg    = bb:FindFirstChildWhichIsA("Frame")
	if not bg then return end
	local fill  = bg:FindFirstChild("Fill") :: Frame?
	if fill then
		fill.Size = UDim2.new(ratio, 0, 1, 0)
		local r = math.clamp(2 * (1 - ratio), 0, 1)
		local g = math.clamp(2 * ratio, 0, 1)
		fill.BackgroundColor3 = Color3.new(r, g, 0)
	end
	bb.Enabled = data.hp < data.maxHp
end

-- ── Building creation ─────────────────────────────────────────────────────────

local function createBuilding(player: any, position: Vector3, buildingType: string): string
	counter += 1
	local id   = "b" .. counter
	local size = buildingSize(buildingType)

	local model     = Instance.new("Model")
	model.Name      = id

	local base      = Instance.new("Part")
	base.Name       = "Base"
	base.Size       = size
	base.Position   = position + Vector3.new(0, size.Y / 2, 0)
	base.BrickColor = player.TeamColor
	base.Material   = Enum.Material.SmoothPlastic
	base.Anchored   = true
	base.Parent     = model

	if buildingType == "CommandCenter" then
		local spire        = Instance.new("Part")
		spire.Name         = "Spire"
		spire.Size         = Vector3.new(3, 18, 3)
		spire.Position     = position + Vector3.new(0, size.Y + 9, 0)
		spire.BrickColor   = BrickColor.new("Institutional white")
		spire.Material     = Enum.Material.Neon
		spire.Anchored     = true
		spire.CastShadow   = false
		spire.Parent       = model

	elseif buildingType == "Mine" then
		-- Dark-metal base platform
		base.Size     = Vector3.new(10, 2, 10)
		base.Position = position + Vector3.new(0, 1, 0)   -- center Y=1, bottom Y=0
		base.Material = Enum.Material.Metal
		base.BrickColor = BrickColor.new("Dark stone grey")

		-- Central emission shaft
		local shaft       = Instance.new("Part")
		shaft.Name        = "Shaft"
		shaft.Size        = Vector3.new(2, 9, 2)
		shaft.Position    = position + Vector3.new(0, 6.5, 0)  -- bottom Y=2, top Y=11
		shaft.BrickColor  = BrickColor.new("Dark stone grey")
		shaft.Material    = Enum.Material.Metal
		shaft.Anchored    = true
		shaft.CastShadow  = false
		shaft.CanCollide  = false
		shaft.Parent      = model

		-- Team-color neon emitter ring at top of shaft
		local ring        = Instance.new("Part")
		ring.Name         = "EmitterRing"
		ring.Shape        = Enum.PartType.Cylinder
		ring.Size         = Vector3.new(0.4, 7, 7)
		ring.CFrame       = CFrame.new(position + Vector3.new(0, 11.2, 0))
		                  * CFrame.Angles(0, 0, math.pi / 2)
		ring.BrickColor   = player.TeamColor
		ring.Material     = Enum.Material.Neon
		ring.Anchored     = true
		ring.CastShadow   = false
		ring.CanCollide   = false
		ring.Parent       = model

		-- Emitter orb — beam origin point, used by clients for VFX anchoring
		local emitter     = Instance.new("Part")
		emitter.Name      = "Emitter"
		emitter.Shape     = Enum.PartType.Ball
		emitter.Size      = Vector3.new(2, 2, 2)
		emitter.Position  = position + Vector3.new(0, 12.2, 0)
		emitter.BrickColor = player.TeamColor
		emitter.Material  = Enum.Material.Neon
		emitter.Anchored  = true
		emitter.CastShadow = false
		emitter.CanCollide = false
		emitter.Parent    = model

	elseif buildingType == "Turret" then
		-- Rotating head on top of the base
		local head         = Instance.new("Part")
		head.Name          = "Head"
		head.Size          = Vector3.new(5, 3, 5)
		head.Position      = position + Vector3.new(0, size.Y + 1.5, 0)
		head.BrickColor    = BrickColor.new("Dark stone grey")
		head.Material      = Enum.Material.Metal
		head.Anchored      = true
		head.Parent        = model
		-- Barrel: center offset 3.5 studs in +Z so back end starts at head center
		local barrel       = Instance.new("Part")
		barrel.Name        = "Barrel"
		barrel.Size        = Vector3.new(1.2, 1.2, 7)
		barrel.Position    = position + Vector3.new(0, size.Y + 1.5, 3.5)
		barrel.BrickColor  = BrickColor.new("Dark stone grey")
		barrel.Material    = Enum.Material.Metal
		barrel.Anchored    = true
		barrel.Parent      = model
		-- Neon ring accent at the base of the head
		local ring         = Instance.new("Part")
		ring.Name          = "Ring"
		ring.Size          = Vector3.new(7, 0.4, 7)
		ring.Position      = position + Vector3.new(0, size.Y + 0.2, 0)
		ring.BrickColor    = BrickColor.new("Bright red")
		ring.Material      = Enum.Material.Neon
		ring.Anchored      = true
		ring.CastShadow    = false
		ring.Parent        = model

	elseif buildingType == "Monument" then
		-- Shaft: stone-grey, non-neon so it's not blinding
		base.BrickColor = BrickColor.new("Light stone grey")
		base.Material   = Enum.Material.SmoothPlastic

		-- Small glowing orb at the tip
		local tip        = Instance.new("Part")
		tip.Name         = "Tip"
		tip.Shape        = Enum.PartType.Ball
		tip.Size         = Vector3.new(3.5, 3.5, 3.5)
		tip.Position     = position + Vector3.new(0, size.Y + 1.75, 0)
		tip.BrickColor   = BrickColor.new("Bright yellow")
		tip.Material     = Enum.Material.Neon
		tip.Anchored     = true
		tip.CastShadow   = false
		tip.Parent       = model

		-- Two thin gold ring accents at 35% and 70% of the shaft height
		for i = 1, 2 do
			local ring       = Instance.new("Part")
			ring.Name        = "Ring" .. i
			ring.Shape       = Enum.PartType.Cylinder
			ring.Size        = Vector3.new(0.35, 8, 8)
			ring.CFrame      = CFrame.new(position + Vector3.new(0, size.Y * (i / 3 + 0.05), 0))
				* CFrame.Angles(0, 0, math.pi / 2)
			ring.BrickColor  = BrickColor.new("Bright yellow")
			ring.Material    = Enum.Material.Neon
			ring.Anchored    = true
			ring.CastShadow  = false
			ring.Parent      = model
		end

	elseif buildingType == "Relay" then
		-- Slim antenna pole
		local pole       = Instance.new("Part")
		pole.Name        = "Pole"
		pole.Size        = Vector3.new(1, size.Y + 6, 1)
		pole.Position    = position + Vector3.new(0, (size.Y + 6) / 2, 0)
		pole.BrickColor  = BrickColor.new("Dark stone grey")
		pole.Material    = Enum.Material.Metal
		pole.Anchored    = true
		pole.CastShadow  = false
		pole.Parent      = model

		-- Glowing orb at the top in team color
		local orb        = Instance.new("Part")
		orb.Name         = "Orb"
		orb.Shape        = Enum.PartType.Ball
		orb.Size         = Vector3.new(2.5, 2.5, 2.5)
		orb.Position     = position + Vector3.new(0, size.Y + 7.25, 0)
		orb.BrickColor   = player.TeamColor
		orb.Material     = Enum.Material.Neon
		orb.Anchored     = true
		orb.CastShadow   = false
		orb.CanCollide   = false
		orb.Parent       = model

		-- Small accent ring around orb base
		local ring        = Instance.new("Part")
		ring.Name         = "Ring"
		ring.Shape        = Enum.PartType.Cylinder
		ring.Size         = Vector3.new(0.3, 4, 4)
		ring.CFrame       = CFrame.new(position + Vector3.new(0, size.Y + 6, 0))
		                  * CFrame.Angles(0, 0, math.pi / 2)
		ring.BrickColor   = player.TeamColor
		ring.Material     = Enum.Material.Neon
		ring.Anchored     = true
		ring.CastShadow   = false
		ring.CanCollide   = false
		ring.Parent       = model

	else
		-- Barracks flag
		local flag      = Instance.new("Part")
		flag.Name       = "Flag"
		flag.Size       = Vector3.new(0.6, 5, 0.6)
		flag.Position   = position + Vector3.new(0, size.Y + 2.5, 0)
		flag.BrickColor = player.TeamColor
		flag.Material   = Enum.Material.Neon
		flag.Anchored   = true
		flag.Parent     = model
	end

	local ov        = Instance.new("StringValue")
	ov.Name         = "OwnerId"
	ov.Value        = tostring(player.UserId)
	ov.Parent       = model

	local tv        = Instance.new("StringValue")
	tv.Name         = "BuildingType"
	tv.Value        = buildingType
	tv.Parent       = model

	model.PrimaryPart = base
	model.Parent      = buildingsFolder

	local maxHp     = (Config.BUILDING_HP :: any)[buildingType] or 400
	local buildTime = (buildingType ~= "CommandCenter")
		and ((Config.BUILD_TIME :: any)[buildingType] or 0)
		or 0

	addHealthBar(base)

	local startHp = (buildTime > 0) and 1 or maxHp
	buildingData[id] = {
		hp             = startHp,
		maxHp          = maxHp,
		base           = base,
		owner          = player,
		buildingType   = buildingType,
		head           = buildingType == "Turret" and (model:FindFirstChild("Head") :: BasePart?) or nil,
		barrel         = buildingType == "Turret" and (model:FindFirstChild("Barrel") :: BasePart?) or nil,
		isConstructing = buildTime > 0,
		turretUpgrade  = nil,
	}
	applyHP(buildingData[id])

	if buildingType == "CommandCenter" then
		playerHasCC[player.UserId] = true
	end
	if buildingType == "Turret" then
		turretTimers[id] = 0
	end

	RemoteHandler.get(Config.REMOTES.BuildingPlaced):FireAllClients(
		id, player.UserId, position, buildingType
	)

	-- ── Construction animation ────────────────────────────────────────────
	if buildTime > 0 then
		model:PivotTo(CFrame.new(position.X, 0, position.Z))

		task.spawn(function()
			local elapsed   = 0
			-- Mine uses a thin platform (center Y=1) instead of the full BUILDING_SIZE height
			local finalY    = buildingType == "Mine" and 1.0 or size.Y / 2

			while elapsed < buildTime do
				local dt = task.wait(0.05)
				if not buildingData[id] then return end

				elapsed = math.min(elapsed + dt, buildTime)
				local progress = elapsed / buildTime

				model:PivotTo(CFrame.new(position.X, progress * finalY, position.Z))

				local target = math.max(1, math.floor(progress * maxHp))
				local data   = buildingData[id]
				if data.hp < target then
					data.hp = target
					applyHP(data)
				end
			end

			local data = buildingData[id]
			if data then
				model:PivotTo(CFrame.new(position.X, finalY, position.Z))
				data.hp            = math.max(data.hp, maxHp)
				data.isConstructing = false
				applyHP(data)

				if buildingType == "Mine" and mineralManager then
					mineralManager.setMineReady(id)
				end

				if buildingType == "Monument" then
					monumentWinTimer[id] = 0
					RemoteHandler.get(Config.REMOTES.MonumentProgress)
						:FireAllClients(player.UserId, Config.MONUMENT_WIN_DURATION)
				end
			end
		end)
	end

	return id
end

-- ── Turret upgrade visuals ────────────────────────────────────────────────────

local function applyTurretUpgradeVisuals(id: string, upgradeType: string)
	local model = buildingsFolder:FindFirstChild(id)
	if not model then return end

	local head   = model:FindFirstChild("Head")   :: BasePart?
	local barrel = model:FindFirstChild("Barrel") :: BasePart?
	local ring   = model:FindFirstChild("Ring")   :: BasePart?

	if upgradeType == "Flamethrower" then
		if head then
			head.BrickColor = BrickColor.new("Bright orange")
			head.Material   = Enum.Material.Neon
		end
		if barrel then
			-- Shorter, wider nozzle
			barrel.BrickColor = BrickColor.new("Bright orange")
			barrel.Material   = Enum.Material.Neon
			barrel.Size       = Vector3.new(2.4, 2.4, 5)
		end
		if ring then
			ring.BrickColor = BrickColor.new("Deep orange")
			ring.Size       = ring.Size + Vector3.new(0, 0.4, 0)
		end

	elseif upgradeType == "RocketLauncher" then
		if head then
			head.BrickColor = BrickColor.new("Dark indigo")
			head.Material   = Enum.Material.SmoothPlastic
			head.Size       = head.Size + Vector3.new(1, 0.5, 1)
		end
		if barrel then
			-- Long, wide missile tube
			barrel.BrickColor = BrickColor.new("Medium blue")
			barrel.Material   = Enum.Material.Metal
			barrel.Size       = Vector3.new(2.4, 2.4, 11)
		end
		if ring then
			ring.BrickColor = BrickColor.new("Medium blue")
			ring.Material   = Enum.Material.Neon
		end

	elseif upgradeType == "Creepy" then
		if head then
			head.BrickColor = BrickColor.new("Black")
			head.Material   = Enum.Material.SmoothPlastic
			head.Size       = Vector3.new(6, 4, 6)
		end
		if barrel then barrel.Transparency = 1 end
		if ring then
			ring.BrickColor = BrickColor.new("Black")
			ring.Material   = Enum.Material.SmoothPlastic
			ring.Size       = ring.Size + Vector3.new(3, 0, 3)
		end

	elseif upgradeType == "Mutant" then
		-- Larger, more horrifying mass — pulsing black growth with bone-white teeth ring
		if head then
			head.BrickColor = BrickColor.new("Black")
			head.Material   = Enum.Material.SmoothPlastic
			head.Size       = Vector3.new(9, 6, 9)
		end
		if barrel then barrel.Transparency = 1 end
		if ring then
			ring.BrickColor = BrickColor.new("Black")
			ring.Material   = Enum.Material.SmoothPlastic
			ring.Size       = ring.Size + Vector3.new(7, 0, 7)
		end
		-- Bone-white tooth spines around the enlarged head
		if model and head then
			local toothCount = 8
			for i = 1, toothCount do
				local angle    = (i / toothCount) * math.pi * 2
				local r        = 5.0
				local toothPos = head.Position + Vector3.new(math.cos(angle) * r, -0.5, math.sin(angle) * r)
				local tooth         = Instance.new("Part")
				tooth.Name          = "MutantTooth_" .. i
				tooth.Size          = Vector3.new(0.9, 2.8, 0.9)
				tooth.BrickColor    = BrickColor.new("Institutional white")
				tooth.Material      = Enum.Material.SmoothPlastic
				tooth.Anchored      = true
				tooth.CanCollide    = false
				tooth.CastShadow    = false
				tooth.CFrame        = CFrame.new(toothPos)
					* CFrame.Angles(0, angle, math.pi * 0.12)
				tooth.Parent        = model
			end
		end
	end

	-- Tag the model so clients can read upgrade state (overwrite for tier-2 Mutant)
	local existing = model:FindFirstChild("Upgrade") :: StringValue?
	if existing then
		existing.Value = upgradeType
	else
		local uv  = Instance.new("StringValue")
		uv.Name   = "Upgrade"
		uv.Value  = upgradeType
		uv.Parent = model
	end
end

-- ── Mutant turret: creepy soldier spawning ────────────────────────────────────

local mutantSoldierParts: { [string]: { BasePart } } = {}

local function startMutantSoldierLoop(turretId: string, data: any, owner: Player)
	mutantSoldierParts[turretId] = {}
	task.spawn(function()
		-- Immediate first spawn attempt
		task.wait(2)
		while buildingData[turretId] and data.turretUpgrade == "Mutant" do
			local soldiers = mutantSoldierParts[turretId]
			if soldiers then
				-- Prune dead soldiers
				for i = #soldiers, 1, -1 do
					if not soldiers[i].Parent then table.remove(soldiers, i) end
				end
				-- Spawn a new one if below cap
				if #soldiers < Config.CREEPY_SOLDIER_MAX and unitManagerRef then
					local angle    = math.random() * math.pi * 2
					local offset   = Vector3.new(math.cos(angle) * 5, 0, math.sin(angle) * 5)
					local spawnPos = data.base.Position + offset
					local uid = unitManagerRef.spawnUnitNow(owner, spawnPos, "CreepySoldier")
					if uid then
						local unitsF = workspace:FindFirstChild("Units")
						local part   = unitsF and unitsF:FindFirstChild(uid)
						if part and part:IsA("BasePart") then
							table.insert(soldiers, part :: BasePart)
						end
					end
				end
			end
			task.wait(Config.CREEPY_SOLDIER_SPAWN_INTERVAL)
		end
		mutantSoldierParts[turretId] = nil
	end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function BuildingManager.hasCommandCenter(player: any): boolean
	return playerHasCC[player.UserId] == true
end

function BuildingManager.resetAll()
	for _, model in buildingsFolder:GetChildren() do model:Destroy() end
	buildingData             = {}
	playerHasCC              = {}
	turretTimers             = {}
	monumentByOwner          = {}
	monumentWinTimer         = {}
	monumentHeartbeatAccum   = 0
end

function BuildingManager.setOnCCDestroyed(fn: (any) -> ())
	onCCDestroyedCb = fn
end

function BuildingManager.setOnPlayerWon(fn: () -> ())
	onPlayerWonCb = fn
end

function BuildingManager.setUnitManager(um: any)
	unitManagerRef = um
end

function BuildingManager.setResearchManager(rm: any)
	researchManagerRef = rm
end

function BuildingManager.damage(id: string, amount: number)
	local data = buildingData[id]
	if not data then return end
	data.hp = math.max(0, data.hp - amount)
	applyHP(data)

	-- Notify owner when their CC is being attacked (throttled)
	if data.buildingType == "CommandCenter" and data.hp > 0 then
		local uid  = data.owner.UserId
		local now  = os.clock()
		if (ccAttackThrottle[uid] or 0) + CC_ATTACK_THROTTLE < now then
			ccAttackThrottle[uid] = now
			RemoteHandler.get(Config.REMOTES.CCAttacked):FireClient(data.owner)
		end
	end

	if data.hp > 0 then return end

	local wasCC       = data.buildingType == "CommandCenter"
	local wasMonument = data.buildingType == "Monument"
	local owner       = data.owner
	buildingData[id] = nil   -- nil BEFORE Destroy so construction coroutine exits cleanly
	turretTimers[id] = nil

	if data.buildingType == "Mine" and mineralManager then
		mineralManager.removeMine(id)
	end

	local model = buildingsFolder:FindFirstChild(id)
	if model then model:Destroy() end

	if wasCC then
		playerHasCC[owner.UserId] = nil
		if onCCDestroyedCb then onCCDestroyedCb(owner) end
	end

	if wasMonument then
		monumentByOwner[owner.UserId] = nil
		monumentWinTimer[id] = nil
		RemoteHandler.get(Config.REMOTES.MonumentProgress):FireAllClients(owner.UserId, nil)
	end
end

function BuildingManager.getNearestEnemyBuilding(fromPos: Vector3, attackerOwnerIdStr: string, range: number): (string?, Vector3?)
	local bestId, bestPos, bestDist = nil :: string?, nil :: Vector3?, math.huge
	for id, data in buildingData do
		if tostring(data.owner.UserId) == attackerOwnerIdStr then continue end
		local d = (data.base.Position - fromPos).Magnitude
		if d < range and d < bestDist then
			bestDist = d; bestId = id; bestPos = data.base.Position + Vector3.new(0, data.base.Size.Y * 0.5, 0)
		end
	end
	return bestId, bestPos
end

function BuildingManager.removeAllBuildingsFor(player: any)
	local toRemove = {}
	for id, data in buildingData do
		if data.owner == player then table.insert(toRemove, id) end
	end
	for _, id in toRemove do
		local data = buildingData[id]
		if not data then continue end
		buildingData[id] = nil
		turretTimers[id] = nil
		monumentWinTimer[id] = nil
		if data.buildingType == "Mine" and mineralManager then
			mineralManager.removeMine(id)
		end
		local model = buildingsFolder:FindFirstChild(id)
		if model then model:Destroy() end
	end
	playerHasCC[player.UserId] = nil
	monumentByOwner[player.UserId] = nil
end

function BuildingManager.placeForPlayer(player: any, position: Vector3, buildingType: string): boolean
	local snapped = snapGrid(position)

	-- Reject if the footprint overlaps any existing building
	if isOccupied(snapped, buildingType) then return false end

	if buildingType == "CommandCenter" then
		if playerHasCC[player.UserId] then return false end
		for _, data in buildingData do
			if data.buildingType ~= "CommandCenter" then continue end
			local d = Vector3.new(snapped.X, 0, snapped.Z)
				- Vector3.new(data.base.Position.X, 0, data.base.Position.Z)
			if d.Magnitude < Config.COMMAND_CENTER_MIN_DIST then return false end
		end
		local id = createBuilding(player, snapped, "CommandCenter")
		return true, id
	end

	if not playerHasCC[player.UserId] then return false end

	-- Build zone: all non-CC buildings must be within BUILD_RADIUS of the player's CC
	-- OR within RELAY_RADIUS of any owned Relay.
	do
		local inZone = false
		for _, data in buildingData do
			if data.owner ~= player then continue end
			if data.buildingType == "CommandCenter" then
				local d = Vector3.new(snapped.X, 0, snapped.Z)
					- Vector3.new(data.base.Position.X, 0, data.base.Position.Z)
				if d.Magnitude <= Config.BUILD_RADIUS then inZone = true; break end
			elseif data.buildingType == "Relay" then
				local d = Vector3.new(snapped.X, 0, snapped.Z)
					- Vector3.new(data.base.Position.X, 0, data.base.Position.Z)
				if d.Magnitude <= Config.RELAY_RADIUS then inZone = true; break end
			end
		end
		if not inZone then return false end
	end

	-- Mine cap
	if buildingType == "Mine" then
		if mineralManager and mineralManager.getMineCount(player) >= Config.MAX_MINES then return false end
	end

	-- Requirement check: Barracks needs a Mine; Turret needs a Barracks; Relay needs research
	if buildingType == "Barracks" and getPlayerBuildingCount(player, "Mine") < 1 then return false end
	if buildingType == "Turret"   and getPlayerBuildingCount(player, "Barracks") < 1 then return false end
	if buildingType == "Relay" then
		if not researchManagerRef or not researchManagerRef.hasResearch(player, "Relay") then return false end
	end

	local cost = buildingType == "Mine"   and Config.MINE_COST
		or buildingType == "Turret" and Config.TURRET_COST
		or buildingType == "Relay"  and Config.RELAY_COST
		or Config.BUILDING_COST
	if not resourceManagerRef or resourceManagerRef.get(player) < cost then return false end

	if buildingType == "Mine" then
		if not mineralManager or not mineralManager.tryClaimDeposit(snapped) then return false end
	end

	resourceManagerRef.spend(player, cost)
	local id = createBuilding(player, snapped, buildingType)

	if buildingType == "Mine" then
		mineralManager.registerMine(id, snapped, player)
	end
	if researchManagerRef and buildingType ~= "CommandCenter" then
		researchManagerRef.recordBuildingPlaced(player, buildingType)
	end
	return true, id
end

-- ── Init ──────────────────────────────────────────────────────────────────────

function BuildingManager.init(resourceManager, mineralManager_)
	resourceManagerRef    = resourceManager
	mineralManager        = mineralManager_
	buildingsFolder        = Instance.new("Folder")
	buildingsFolder.Name   = "Buildings"
	buildingsFolder.Parent = workspace

	-- ── Turret attack loop ────────────────────────────────────────────────
	RunService.Heartbeat:Connect(function(dt)
		for id, data in buildingData do
			if data.buildingType ~= "Turret" then continue end
			if data.isConstructing then continue end   -- still under construction

			-- Per-turret stats (may be upgraded)
			local upg      = data.turretUpgrade
			local isCreepy = upg == "Creepy" or upg == "Mutant"
			local tRate   = upg == "Flamethrower"  and Config.TURRET_FLAME.rate
			             or upg == "RocketLauncher" and Config.TURRET_ROCKET.rate
			             or isCreepy                and Config.TURRET_CREEPY.rate
			             or Config.TURRET_ATTACK_RATE
			local tRange  = upg == "Flamethrower"  and Config.TURRET_FLAME.range
			             or upg == "RocketLauncher" and Config.TURRET_ROCKET.range
			             or isCreepy                and Config.TURRET_CREEPY.range
			             or Config.TURRET_RANGE
			local tDamage = upg == "Flamethrower"  and Config.TURRET_FLAME.damage
			             or upg == "RocketLauncher" and Config.TURRET_ROCKET.damage
			             or isCreepy                and Config.TURRET_CREEPY.damage
			             or Config.TURRET_DAMAGE

			turretTimers[id] = (turretTimers[id] or 0) + dt
			if turretTimers[id] < tRate then continue end
			turretTimers[id] -= tRate

			local myPos      = data.base.Position
			local myOwnerStr = tostring(data.owner.UserId)

			-- Creepy / Mutant: 3 independent tentacle strikes, no projectile
			if isCreepy then
				local headPos = myPos + Vector3.new(0, Config.BUILDING_SIZE.Y + 1.5, 0)
				local t1: Vector3? = nil
				local t2: Vector3? = nil
				local t3: Vector3? = nil
				if unitManagerRef then
					local _, p1 = unitManagerRef.damageNearestUnit(myPos, myOwnerStr, tRange, tDamage)
					t1 = p1
					local _, p2 = unitManagerRef.damageNearestUnit(myPos, myOwnerStr, tRange, tDamage)
					t2 = p2
					local _, p3 = unitManagerRef.damageNearestUnit(myPos, myOwnerStr, tRange, tDamage)
					t3 = p3
				end
				RemoteHandler.get(Config.REMOTES.TentacleTargets):FireAllClients(id, headPos, t1, t2, t3)
				continue
			end

			local targetPos: Vector3? = nil

			-- Prefer hitting units → buildings → miners
			if unitManagerRef then
				local hitUnit, unitHitPos = unitManagerRef.damageNearestUnit(myPos, myOwnerStr, tRange, tDamage)
				if hitUnit then targetPos = unitHitPos end
			end
			if not targetPos then
				local bId, bPos = BuildingManager.getNearestEnemyBuilding(myPos, myOwnerStr, tRange)
				if bId then
					BuildingManager.damage(bId, tDamage)
					targetPos = bPos
				end
			end
			if not targetPos and mineralManager then
				local hit, mPos = mineralManager.damageNearestMiner(myPos, myOwnerStr, tRange, tDamage)
				if hit then targetPos = mPos end
			end

			if targetPos then
				local visualTarget = targetPos

				-- Aim head + barrel at the visual target
				local head    = data.head
				local barrel  = data.barrel
				local headPos = head and head.Position
					or (myPos + Vector3.new(0, Config.BUILDING_SIZE.Y + 1.5, 0))

				local aimDir    = visualTarget - headPos
				local barrelTip = headPos   -- fallback

				if aimDir.Magnitude > 0.1 then
					local aimUnit = aimDir.Unit
					barrelTip = headPos + aimUnit * 7

					if head then
						local flatDir = (visualTarget - headPos) * Vector3.new(1, 0, 1)
						if flatDir.Magnitude > 0.1 then
							head.CFrame = CFrame.new(headPos, headPos + flatDir.Unit)
						end
					end
					if barrel then
						local barrelCenter = headPos + aimUnit * 3.5
						barrel.CFrame = CFrame.new(barrelCenter, barrelCenter + aimUnit)
					end
				end

				-- Tell all clients to show a projectile
				RemoteHandler.get(Config.REMOTES.TurretShot):FireAllClients(barrelTip, visualTarget, data.turretUpgrade)
			end
		end

		-- ── Monument win timers ────────────────────────────────────────────────
		monumentHeartbeatAccum += dt
		local sendProgress = false
		if monumentHeartbeatAccum >= 1 then
			monumentHeartbeatAccum -= 1
			sendProgress = true
		end

		for userId, bid in monumentByOwner do
			local mdata = buildingData[bid]
			if not mdata or mdata.isConstructing then continue end

			monumentWinTimer[bid] = (monumentWinTimer[bid] or 0) + dt

			if monumentWinTimer[bid] >= Config.MONUMENT_WIN_DURATION then
				RemoteHandler.get(Config.REMOTES.PlayerWon):FireAllClients(userId)
				monumentByOwner[userId] = nil
				monumentWinTimer[bid]   = nil
				if onPlayerWonCb then task.spawn(onPlayerWonCb) end
				break
			end

			if sendProgress then
				local remaining = Config.MONUMENT_WIN_DURATION - monumentWinTimer[bid]
				RemoteHandler.get(Config.REMOTES.MonumentProgress):FireAllClients(userId, remaining)
			end
		end
	end)

	-- ── PlaceBuilding remote ──────────────────────────────────────────────
	RemoteHandler.get(Config.REMOTES.PlaceBuilding).OnServerEvent:Connect(function(player, pos, buildingType)
		if typeof(pos) ~= "Vector3" then return end
		if type(buildingType) ~= "string" then return end

		local snapped = snapGrid(pos)

		-- Reject if the footprint overlaps any existing building
		if isOccupied(snapped, buildingType) then return end

		if buildingType == "CommandCenter" then
			if playerHasCC[player.UserId] then return end
			for _, data in buildingData do
				if data.buildingType ~= "CommandCenter" then continue end
				local d = Vector3.new(snapped.X, 0, snapped.Z)
					- Vector3.new(data.base.Position.X, 0, data.base.Position.Z)
				if d.Magnitude < Config.COMMAND_CENTER_MIN_DIST then return end
			end
			createBuilding(player, snapped, "CommandCenter")
			return
		end

		if not playerHasCC[player.UserId] then return end

		-- Build zone: CC radius OR any owned Relay radius
		do
			local inZone = false
			for _, data in buildingData do
				if data.owner ~= player then continue end
				if data.buildingType == "CommandCenter" then
					local d = Vector3.new(snapped.X, 0, snapped.Z)
						- Vector3.new(data.base.Position.X, 0, data.base.Position.Z)
					if d.Magnitude <= Config.BUILD_RADIUS then inZone = true; break end
				elseif data.buildingType == "Relay" then
					local d = Vector3.new(snapped.X, 0, snapped.Z)
						- Vector3.new(data.base.Position.X, 0, data.base.Position.Z)
					if d.Magnitude <= Config.RELAY_RADIUS then inZone = true; break end
				end
			end
			if not inZone then return end
		end

		-- Mine cap
		if buildingType == "Mine" then
			if mineralManager and mineralManager.getMineCount(player) >= Config.MAX_MINES then return end
		end

		-- Requirement check: Barracks needs a Mine; Turret needs a Barracks; Relay needs research
		if buildingType == "Barracks" and getPlayerBuildingCount(player, "Mine") < 1 then return end
		if buildingType == "Turret"   and getPlayerBuildingCount(player, "Barracks") < 1 then return end
		if buildingType == "Relay" then
			if not researchManagerRef or not researchManagerRef.hasResearch(player, "Relay") then return end
		end

		local cost = buildingType == "Mine"   and Config.MINE_COST
			or buildingType == "Turret" and Config.TURRET_COST
			or buildingType == "Relay"  and Config.RELAY_COST
			or Config.BUILDING_COST
		if resourceManager.get(player) < cost then return end

		if buildingType == "Mine" then
			if not mineralManager or not mineralManager.tryClaimDeposit(snapped) then return end
		end

		resourceManager.spend(player, cost)
		local id = createBuilding(player, snapped, buildingType)

		if buildingType == "Mine" then
			mineralManager.registerMine(id, snapped, player)
		end
		if researchManagerRef and buildingType ~= "CommandCenter" then
			researchManagerRef.recordBuildingPlaced(player, buildingType)
		end
	end)

	-- ── BuildMonument remote ──────────────────────────────────────────────
	RemoteHandler.get(Config.REMOTES.BuildMonument).OnServerEvent:Connect(function(player)
		BuildingManager.buildMonument(player)
	end)

	-- ── UpgradeTurret remote ──────────────────────────────────────────────
	RemoteHandler.get(Config.REMOTES.UpgradeTurret).OnServerEvent:Connect(
		function(player, turretId, upgradeType)
			if type(turretId) ~= "string" or type(upgradeType) ~= "string" then return end

			local TIER1 = { Flamethrower = true, RocketLauncher = true, Creepy = true }
			local TIER2 = { Mutant = true }
			if not TIER1[upgradeType] and not TIER2[upgradeType] then return end

			local data = buildingData[turretId]
			if not data or data.buildingType ~= "Turret" then return end
			if data.owner ~= player then return end
			if data.isConstructing then return end

			if TIER2[upgradeType] then
				-- Mutant requires Creepy already applied, not yet mutated
				if data.turretUpgrade ~= "Creepy" then return end
			else
				-- Tier-1: no existing upgrade yet
				if data.turretUpgrade then return end
				-- Flamethrower and Rocket require TurretUpgrades research; Creepy does not
				if upgradeType ~= "Creepy" then
					if not researchManagerRef or not researchManagerRef.hasResearch(player, "TurretUpgrades") then return end
				end
			end

			local cost = (Config.TURRET_UPGRADE_COST :: any)[upgradeType] or 999
			if not resourceManagerRef or not resourceManagerRef.spend(player, cost) then return end

			data.turretUpgrade = upgradeType
			applyTurretUpgradeVisuals(turretId, upgradeType)

			if upgradeType == "Mutant" then
				startMutantSoldierLoop(turretId, data, player)
			end
		end
	)
end

-- ── Monument upgrade ──────────────────────────────────────────────────────────

function BuildingManager.buildMonument(player: any): boolean
	if monumentByOwner[player.UserId] then return false end
	if not playerHasCC[player.UserId] then return false end
	if not resourceManagerRef or resourceManagerRef.get(player) < Config.MONUMENT_COST then return false end

	-- Find CC ground-level position
	local ccPos: Vector3?
	for _, data in buildingData do
		if data.owner == player and data.buildingType == "CommandCenter" then
			ccPos = Vector3.new(data.base.Position.X, 0, data.base.Position.Z)
			break
		end
	end
	if not ccPos then return false end

	resourceManagerRef.spend(player, Config.MONUMENT_COST)
	local id = createBuilding(player, ccPos, "Monument")
	monumentByOwner[player.UserId] = id

	-- Signal construction started
	RemoteHandler.get(Config.REMOTES.MonumentProgress):FireAllClients(player.UserId, -1)
	return true
end

return BuildingManager
