--[[
	FoundryRotor — Client-side animation for the Foundry's two angled struts.

	The server builds each Foundry's struts (named "FoundryArm1"/"FoundryArm2") in a
	static home pose via UnitVisuals.buildFoundryDecor. This module takes over their
	CFrames locally and slowly spins them around the central hub, recomputing each
	frame from the shared UnitVisuals.foundryArms() geometry so the spin never drifts
	from the built pose.

	Follows the FabricatorArms pattern: one shared Heartbeat connection drives every
	Foundry, with a distance-square cull for far-away buildings. Animation is held off
	until construction finishes (model scale ≈ 1) so the build-up rise isn't fought.
]]

local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UnitVisuals       = require(Shared:WaitForChild("UnitVisuals"))

local FoundryRotor = {}

local HALF_H    = Config.FOUNDRY_SIZE.Y / 2
local CULL_SQ   = 420 * 420
local ROT_SPEED = 0.6   -- radians/sec

type Entry = { base: BasePart, arms: { { cf: CFrame, size: Vector3 } }, parts: { BasePart } }
local entries: { [Model]: Entry } = {}
local camera: Camera?

local function tryAttach(model: Model)
	if entries[model] then return end
	local bt = model:WaitForChild("BuildingType", 5) :: StringValue?
	if not bt or bt.Value ~= "Foundry" then return end
	if entries[model] then return end
	local base = model:WaitForChild("Base", 5) :: BasePart?
	if not base then return end

	local arms = UnitVisuals.foundryArms()
	local parts: { BasePart } = {}
	for i = 1, #arms do
		local p = model:WaitForChild("FoundryArm" .. i, 5) :: BasePart?
		if not p then return end
		parts[i] = p
	end

	entries[model] = { base = base, arms = arms, parts = parts }
end

local function update(_dt: number)
	local clock  = os.clock()
	local camPos = camera and camera.CFrame.Position or Vector3.zero
	local angle  = clock * ROT_SPEED

	for model, e in entries do
		local base = e.base
		if not model.Parent or not base.Parent then
			entries[model] = nil
			continue
		end

		local dd = base.Position - camPos
		if dd:Dot(dd) > CULL_SQ then continue end

		-- Leave the struts to the server's build-up scale until fully constructed.
		if model:GetScale() < 0.99 then continue end

		local groundCF = base.CFrame * CFrame.new(0, -HALF_H, 0)
		local spin     = CFrame.fromAxisAngle(Vector3.yAxis, angle)
		for i, a in e.arms do
			local part = e.parts[i]
			if part and part.Parent then
				part.CFrame = groundCF * spin * a.cf
			end
		end
	end
end

function FoundryRotor.init(cam: Camera)
	camera = cam

	task.spawn(function()
		local folder = workspace:WaitForChild("Buildings", 30)
		if not folder then return end
		for _, m in folder:GetChildren() do
			if m:IsA("Model") then task.spawn(tryAttach, m) end
		end
		folder.ChildAdded:Connect(function(m)
			if m:IsA("Model") then task.spawn(tryAttach, m) end
		end)
		folder.ChildRemoved:Connect(function(m)
			if m:IsA("Model") then entries[m] = nil end
		end)
	end)

	RunService.Heartbeat:Connect(update)
end

return FoundryRotor
