local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local RemoteHandler     = require(Shared:WaitForChild("RemoteHandler"))

local UnitManager = {}

type UnitData = { part: BasePart, owner: Player, target: Vector3? }
local units: {[string]: UnitData} = {}
local counter    = 0
local unitsFolder: Folder

local function spawnUnit(player: Player, position: Vector3, unitType: string)
	local typeDef = Config.UNIT_TYPES[unitType]
	if not typeDef then return end

	counter += 1
	local id = "u" .. counter

	local part          = Instance.new("Part")
	part.Name           = id
	part.Size           = typeDef.size
	part.Position       = Vector3.new(position.X, typeDef.size.Y / 2 + 0.1, position.Z)
	part.BrickColor     = player.TeamColor
	part.Material       = Enum.Material.SmoothPlastic
	part.Anchored       = true
	part.CastShadow     = false

	local ov        = Instance.new("StringValue")
	ov.Name         = "OwnerId"
	ov.Value        = tostring(player.UserId)
	ov.Parent       = part

	local tv        = Instance.new("StringValue")
	tv.Name         = "UnitType"
	tv.Value        = unitType
	tv.Parent       = part

	part.Parent = unitsFolder

	units[id] = { part = part, owner = player, target = nil }
	RemoteHandler.get(Config.REMOTES.UnitSpawned):FireAllClients(id, player.UserId, part.Position)
end

local function moveUnits(player: Player, ids: {string}, targetPos: Vector3)
	local valid = {}
	for _, id in ids do
		if units[id] and units[id].owner == player then
			table.insert(valid, id)
		end
	end

	local cols = math.max(1, math.ceil(math.sqrt(#valid)))
	for i, id in valid do
		local c = (i - 1) % cols
		local r = math.floor((i - 1) / cols)
		units[id].target = Vector3.new(
			targetPos.X + (c - (cols - 1) / 2) * Config.UNIT_FORMATION_SPACING,
			0,
			targetPos.Z + r * Config.UNIT_FORMATION_SPACING
		)
	end
	RemoteHandler.get(Config.REMOTES.UnitsOrderedMove):FireAllClients(valid, targetPos)
end

function UnitManager.init(resourceManager)
	unitsFolder        = Instance.new("Folder")
	unitsFolder.Name   = "Units"
	unitsFolder.Parent = workspace

	-- Server-side movement
	RunService.Heartbeat:Connect(function(dt)
		for _, data in units do
			if not data.target then continue end
			local pos  = data.part.Position
			local flat = Vector3.new(data.target.X, pos.Y, data.target.Z)
			local delta = flat - pos
			if delta.Magnitude < 0.5 then
				data.target = nil
			else
				local step        = math.min(Config.UNIT_MOVE_SPEED * dt, delta.Magnitude)
				data.part.Position = pos + delta.Unit * step
			end
		end
	end)

	-- Train a unit from a barracks
	RemoteHandler.get(Config.REMOTES.TrainUnit).OnServerEvent:Connect(function(player, barrackId, unitType)
		if type(barrackId) ~= "string" or type(unitType) ~= "string" then return end
		local typeDef = Config.UNIT_TYPES[unitType]
		if not typeDef then return end

		-- Find and validate the barracks
		local buildingsFolder = workspace:FindFirstChild("Buildings")
		if not buildingsFolder then return end
		local building = buildingsFolder:FindFirstChild(barrackId)
		if not building then return end

		local ownerVal = building:FindFirstChild("OwnerId")
		if not ownerVal or ownerVal.Value ~= tostring(player.UserId) then return end

		local base = building:FindFirstChild("Base") :: BasePart
		if not base then return end

		if not resourceManager.spend(player, typeDef.cost) then return end

		-- Spawn just outside the barracks on the right side
		local spawnPos = base.Position + Vector3.new(Config.BUILDING_SIZE.X + typeDef.size.X, 0, 0)
		spawnUnit(player, spawnPos, unitType)
	end)

	RemoteHandler.get(Config.REMOTES.MoveUnits).OnServerEvent:Connect(function(player, ids, targetPos)
		if type(ids) ~= "table" or typeof(targetPos) ~= "Vector3" then return end
		moveUnits(player, ids, targetPos)
	end)

	Players.PlayerRemoving:Connect(function(player)
		local toRemove = {}
		for id, data in units do
			if data.owner == player then table.insert(toRemove, id) end
		end
		for _, id in toRemove do
			units[id].part:Destroy()
			units[id] = nil
		end
	end)
end

return UnitManager
