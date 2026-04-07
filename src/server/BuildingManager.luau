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
local onCCDestroyedCb: ((any) -> ())?

type BuildingData = { hp: number, maxHp: number, base: BasePart, owner: any, buildingType: string, head: BasePart?, barrel: BasePart?, isConstructing: boolean }
local buildingData: { [string]: BuildingData } = {}
local playerHasCC:  { [number]: boolean }      = {}
local turretTimers: { [string]: number }        = {}   -- attackTimer per turret id

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function buildingSize(buildingType: string): Vector3
	if buildingType == "CommandCenter" then return Config.COMMAND_CENTER_SIZE end
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
		local crystal      = Instance.new("Part")
		crystal.Name       = "Crystal"
		crystal.Size       = Vector3.new(2, 4, 2)
		crystal.Position   = position + Vector3.new(0, size.Y + 2, 0)
		crystal.BrickColor = BrickColor.new("Bright yellow")
		crystal.Material   = Enum.Material.Neon
		crystal.Anchored   = true
		crystal.Parent     = model

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
			local finalY    = size.Y / 2

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
			end
		end)
	end

	return id
end

-- ── Public API ────────────────────────────────────────────────────────────────

function BuildingManager.hasCommandCenter(player: any): boolean
	return playerHasCC[player.UserId] == true
end

function BuildingManager.setOnCCDestroyed(fn: (any) -> ())
	onCCDestroyedCb = fn
end

function BuildingManager.setUnitManager(um: any)
	unitManagerRef = um
end

function BuildingManager.damage(id: string, amount: number)
	local data = buildingData[id]
	if not data then return end
	data.hp = math.max(0, data.hp - amount)
	applyHP(data)
	if data.hp > 0 then return end

	local wasCC = data.buildingType == "CommandCenter"
	local owner = data.owner
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
end

function BuildingManager.getNearestEnemyBuilding(fromPos: Vector3, attackerOwnerIdStr: string, range: number): (string?, Vector3?)
	local bestId, bestPos, bestDist = nil :: string?, nil :: Vector3?, math.huge
	for id, data in buildingData do
		if tostring(data.owner.UserId) == attackerOwnerIdStr then continue end
		local d = (data.base.Position - fromPos).Magnitude
		if d < range and d < bestDist then
			bestDist = d; bestId = id; bestPos = data.base.Position
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
		if data.buildingType == "Mine" and mineralManager then
			mineralManager.removeMine(id)
		end
		local model = buildingsFolder:FindFirstChild(id)
		if model then model:Destroy() end
	end
	playerHasCC[player.UserId] = nil
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

	-- Mine cap
	if buildingType == "Mine" then
		if mineralManager and mineralManager.getMineCount(player) >= Config.MAX_MINES then return false end
	end

	-- Requirement check: Barracks needs a Mine; Turret needs a Barracks
	if buildingType == "Barracks" and getPlayerBuildingCount(player, "Mine") < 1 then return false end
	if buildingType == "Turret"   and getPlayerBuildingCount(player, "Barracks") < 1 then return false end

	local cost = buildingType == "Mine"   and Config.MINE_COST
		or buildingType == "Turret" and Config.TURRET_COST
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

			turretTimers[id] = (turretTimers[id] or 0) + dt
			if turretTimers[id] < Config.TURRET_ATTACK_RATE then continue end
			turretTimers[id] -= Config.TURRET_ATTACK_RATE

			local myPos      = data.base.Position
			local myOwnerStr = tostring(data.owner.UserId)
			local targetPos: Vector3? = nil

			-- Prefer hitting units; fall back to enemy buildings
			if unitManagerRef then
				local hitUnit, unitHitPos = unitManagerRef.damageNearestUnit(myPos, myOwnerStr, Config.TURRET_RANGE, Config.TURRET_DAMAGE)
				if hitUnit then targetPos = unitHitPos end
			end
			if not targetPos then
				local bId, bPos = BuildingManager.getNearestEnemyBuilding(myPos, myOwnerStr, Config.TURRET_RANGE)
				if bId then
					BuildingManager.damage(bId, Config.TURRET_DAMAGE)
					targetPos = bPos
				end
			end

			if targetPos then
				-- Aim head + barrel at the target
				local head   = data.head
				local barrel = data.barrel
				local headPos = head and head.Position
					or (myPos + Vector3.new(0, Config.BUILDING_SIZE.Y + 1.5, 0))

				local aimDir = targetPos - headPos
				local barrelTip = headPos   -- fallback

				if aimDir.Magnitude > 0.1 then
					local aimUnit = aimDir.Unit
					barrelTip = headPos + aimUnit * 7

					if head then
						local flatDir = (targetPos - headPos) * Vector3.new(1, 0, 1)
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
				RemoteHandler.get(Config.REMOTES.TurretShot):FireAllClients(barrelTip, targetPos)
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

		-- Mine cap
		if buildingType == "Mine" then
			if mineralManager and mineralManager.getMineCount(player) >= Config.MAX_MINES then return end
		end

		-- Requirement check: Barracks needs a Mine; Turret needs a Barracks
		if buildingType == "Barracks" and getPlayerBuildingCount(player, "Mine") < 1 then return end
		if buildingType == "Turret"   and getPlayerBuildingCount(player, "Barracks") < 1 then return end

		local cost = buildingType == "Mine"   and Config.MINE_COST
			or buildingType == "Turret" and Config.TURRET_COST
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
	end)
end

return BuildingManager
