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

local function spawnUnit(player: Player, position: Vector3)
	counter += 1
	local id = "u" .. counter

	local part          = Instance.new("Part")
	part.Name           = id
	part.Size           = Config.UNIT_SIZE
	part.Position       = Vector3.new(position.X, Config.UNIT_SIZE.Y / 2 + 0.1, position.Z)
	part.BrickColor     = player.TeamColor
	part.Material       = Enum.Material.SmoothPlastic
	part.Anchored       = true
	part.CastShadow     = false

	local ov        = Instance.new("StringValue")
	ov.Name         = "OwnerId"
	ov.Value        = tostring(player.UserId)
	ov.Parent       = part
	part.Parent     = unitsFolder

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

	RemoteHandler.get(Config.REMOTES.SpawnUnit).OnServerEvent:Connect(function(player, pos)
		if typeof(pos) ~= "Vector3" then return end
		if not resourceManager.spend(player, Config.UNIT_COST) then return end
		spawnUnit(player, pos)
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
