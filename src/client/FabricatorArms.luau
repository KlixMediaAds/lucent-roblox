--[[
	FabricatorArms — Client-side animation for Command Center fabrication arms.

	The server builds each CC's three arms in a static standby pose (see
	UnitVisuals.buildCommandCenterDecor). This module takes over the arm part
	CFrames locally and drives them:

	  • Idle: slow, heavy drift around the standby pose; warning lights blink.
	  • Fabricating (the CC model contains a "_Dropship" child): each arm
	    independently picks dropship parts near the current assembly index
	    (ship attribute "FabIndex"), swings over with eased momentum, pauses
	    to weld (sparks + flickering light), then repositions.

	Design follows SpiderLegs/MechLegs: a single shared Heartbeat connection
	drives every CC, with a distance-square cull for far-away bases.
]]

local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UnitVisuals       = require(Shared:WaitForChild("UnitVisuals"))

local FabricatorArms = {}

local FAB     = UnitVisuals.FAB
local HALF_H  = Config.COMMAND_CENTER_SIZE.Y / 2
local CULL_SQ = 420 * 420

local rng = Random.new()

type ArmRefs = {
	shoulder: BasePart, upper: BasePart, elbow: BasePart,
	fore: BasePart, tool: BasePart, tip: BasePart, piston: BasePart?,
}
type ArmState = {
	refs:      ArmRefs,
	dir:       Vector3,   -- radial mount direction (CC-local)
	p0:        Vector3,   -- shoulder pivot (CC-local, fixed)
	curElbow:  Vector3,   -- smoothed joint positions (CC-local)
	curTip:    Vector3,
	target:    Vector3,   -- current goal for the tool tip (CC-local)
	welding:   boolean,
	timer:     number,
	phase:     number,
	sparks:    ParticleEmitter?,
	weldLight: PointLight?,
}
type Entry = { base: BasePart, arms: { ArmState }, warnLights: { BasePart } }

local entries: { [Model]: Entry } = {}
local camera: Camera?

-- ── Two-link IK with telescoping forearm ──────────────────────────────────────
-- Returns elbow + clamped tip positions (same space as inputs), elbow-up.
local function solve(p0: Vector3, target: Vector3): (Vector3, Vector3)
	local d3   = target - p0
	local dist = d3.Magnitude
	if dist < 0.1 then
		d3   = Vector3.new(0.1, -0.05, 0)
		dist = d3.Magnitude
	end
	local L1      = FAB.UPPER_LEN
	local L2      = math.clamp(dist * 0.62, FAB.FORE_MIN, FAB.FORE_MAX)
	local clamped = math.clamp(dist, math.abs(L1 - L2) + 0.1, L1 + L2 - 0.1)
	local T       = p0 + d3 * (clamped / dist)

	local h    = Vector3.new(T.X - p0.X, 0, T.Z - p0.Z)
	local hm   = h.Magnitude
	local hdir = hm > 0.01 and h / hm or Vector3.xAxis
	local v    = T.Y - p0.Y
	local baseAng = math.atan2(v, hm)
	local cosA = math.clamp((clamped * clamped + L1 * L1 - L2 * L2) / (2 * clamped * L1), -1, 1)
	local a1   = baseAng + math.acos(cosA)
	local elbow = p0 + hdir * (math.cos(a1) * L1) + Vector3.new(0, math.sin(a1) * L1, 0)
	return elbow, T
end

-- Picks a work point on the dropship near the part currently being assembled.
-- Returns nil when the ship has no ordered parts yet.
local function pickTarget(ship: Model, groundCF: CFrame, armIndex: number): Vector3?
	local fabIndex = (ship:GetAttribute("FabIndex") :: number?) or 0
	local candidates: { BasePart } = {}
	for _, c in ship:GetChildren() do
		if c:IsA("BasePart") then
			local order = c:GetAttribute("BuildOrder") :: number?
			if order and order >= fabIndex - 1 and order <= fabIndex + 2 then
				table.insert(candidates, c)
			end
		end
	end
	if #candidates == 0 then
		for _, c in ship:GetChildren() do
			if c:IsA("BasePart") and c:GetAttribute("BuildOrder") then
				table.insert(candidates, c)
			end
		end
	end
	if #candidates == 0 then return nil end

	local part = candidates[((armIndex + rng:NextInteger(0, #candidates - 1)) % #candidates) + 1]
	local half = part.Size * 0.4
	local offset = Vector3.new(
		rng:NextNumber(-half.X, half.X),
		rng:NextNumber(-half.Y, half.Y),
		rng:NextNumber(-half.Z, half.Z)
	)
	return groundCF:PointToObjectSpace(part.Position) + offset
end

local function setSparks(arm: ArmState, on: boolean)
	if on and not arm.sparks then
		local pe          = Instance.new("ParticleEmitter")
		pe.Texture        = "rbxasset://textures/particles/sparkles_main.dds"
		pe.Color          = ColorSequence.new(Color3.fromRGB(255, 220, 150), Color3.fromRGB(255, 120, 30))
		pe.LightEmission  = 1
		pe.Size           = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.4),
			NumberSequenceKeypoint.new(1, 0.08),
		})
		pe.Lifetime       = NumberRange.new(0.15, 0.45)
		pe.Speed          = NumberRange.new(4, 11)
		pe.SpreadAngle    = Vector2.new(160, 160)
		pe.Rate           = 26
		pe.Enabled        = false
		pe.Parent         = arm.refs.tip
		arm.sparks        = pe

		local pl     = Instance.new("PointLight")
		pl.Color     = Color3.fromRGB(255, 190, 110)
		pl.Range     = 11
		pl.Enabled   = false
		pl.Parent    = arm.refs.tip
		arm.weldLight = pl
	end
	if arm.sparks then arm.sparks.Enabled = on end
	if arm.weldLight then
		arm.weldLight.Enabled = on
		if on then arm.weldLight.Brightness = 2 + rng:NextNumber(0, 2.5) end
	end
end

-- ── Attach / detach ───────────────────────────────────────────────────────────

local function tryAttach(model: Model)
	if entries[model] then return end

	local bt = model:WaitForChild("BuildingType", 5) :: StringValue?
	if not bt or bt.Value ~= "CommandCenter" then return end
	if entries[model] then return end
	local base = model:WaitForChild("Base", 5) :: BasePart?
	if not base then return end
	-- Wait for the last-created arm part so the whole decor set has replicated
	if not model:WaitForChild("FabPiston3", 5) then return end

	local arms: { ArmState } = {}
	for i, theta in FAB.ARM_ANGLES do
		local refs = {
			shoulder = model:FindFirstChild("FabShoulder" .. i),
			upper    = model:FindFirstChild("FabUpper" .. i),
			elbow    = model:FindFirstChild("FabElbow" .. i),
			fore     = model:FindFirstChild("FabFore" .. i),
			tool     = model:FindFirstChild("FabTool" .. i),
			tip      = model:FindFirstChild("FabTip" .. i),
			piston   = model:FindFirstChild("FabPiston" .. i),
		}
		if not (refs.shoulder and refs.upper and refs.elbow and refs.fore and refs.tool and refs.tip) then
			continue
		end
		local dir = Vector3.new(math.cos(theta), 0, math.sin(theta))
		local standTip = dir * FAB.STAND_TIP.X + Vector3.new(0, FAB.STAND_TIP.Y, 0)
		table.insert(arms, {
			refs     = refs :: any,
			dir      = dir,
			p0       = dir * FAB.MOUNT_R + Vector3.new(0, FAB.SHOULDER_Y, 0),
			curElbow = dir * FAB.STAND_ELBOW.X + Vector3.new(0, FAB.STAND_ELBOW.Y, 0),
			curTip   = standTip,
			target   = standTip,
			welding  = false,
			timer    = rng:NextNumber(0.5, 2),
			phase    = rng:NextNumber(0, math.pi * 2),
		})
	end
	if #arms == 0 then return end

	local warnLights: { BasePart } = {}
	for _, c in model:GetChildren() do
		if c.Name == "WarnLight" and c:IsA("BasePart") then
			table.insert(warnLights, c)
		end
	end

	entries[model] = { base = base, arms = arms, warnLights = warnLights }
end

-- ── Update loop ───────────────────────────────────────────────────────────────

local function update(dt: number)
	local clock  = os.clock()
	local camPos = camera and camera.CFrame.Position or Vector3.zero

	for model, e in entries do
		local base = e.base
		if not model.Parent or not base.Parent then
			entries[model] = nil
			continue
		end

		local dd = base.Position - camPos
		if dd:Dot(dd) > CULL_SQ then
			for _, arm in e.arms do setSparks(arm, false) end
			continue
		end

		local groundCF = base.CFrame * CFrame.new(0, -HALF_H, 0)
		local shipInst = model:FindFirstChild("_Dropship")
		local ship     = (shipInst and shipInst:IsA("Model")) and shipInst or nil

		-- Warning lights blink (urgent while fabricating)
		local blinkRate = ship and 6 or 2.2
		for li, wl in e.warnLights do
			if wl.Parent then
				wl.Transparency = (math.sin(clock * blinkRate + li * 2.1) > 0) and 0 or 0.65
			end
		end

		for ai, arm in e.arms do
			arm.timer -= dt

			if ship then
				if arm.timer <= 0 then
					if not arm.welding and (arm.curTip - arm.target).Magnitude < 1.2 then
						-- Arrived at the work point: pause and weld
						arm.welding = true
						arm.timer   = rng:NextNumber(0.9, 2.2)
					else
						-- Swing to a new portion of the vessel
						arm.welding = false
						local t = pickTarget(ship, groundCF, ai)
						if t then
							local d3   = t - arm.p0
							local maxR = FAB.UPPER_LEN + FAB.FORE_MAX - 0.2
							if d3.Magnitude > maxR then
								t = arm.p0 + d3.Unit * maxR
							end
							arm.target = t
						end
						arm.timer = rng:NextNumber(1.6, 3.2)
					end
				end
			else
				-- Standby: heavy idle drift around the rest pose
				arm.welding = false
				local sway = math.sin(clock * 0.5 + arm.phase) * 0.35
				local bob  = math.sin(clock * 0.7 + arm.phase * 1.7) * 0.25
				arm.target = arm.dir * (FAB.STAND_TIP.X + sway)
					+ Vector3.new(0, FAB.STAND_TIP.Y + bob, 0)
				arm.timer = 0.5
			end

			setSparks(arm, ship ~= nil and arm.welding)

			-- Ease joints toward the goal — slower easing reads as momentum
			local goalElbow, goalTip = solve(arm.p0, arm.target)
			local k     = ship and 2.6 or 1.4
			local alpha = 1 - math.exp(-k * dt)
			arm.curElbow = arm.curElbow:Lerp(goalElbow, alpha)
			arm.curTip   = arm.curTip:Lerp(goalTip, alpha)

			-- Write part CFrames in world space
			local refs = arm.refs
			local w0 = groundCF:PointToWorldSpace(arm.p0)
			local w1 = groundCF:PointToWorldSpace(arm.curElbow)
			local w2 = groundCF:PointToWorldSpace(arm.curTip)
			UnitVisuals.orientYBetween(refs.upper, w0, w1, 1.1)
			refs.elbow.CFrame = CFrame.new(w1)
			UnitVisuals.orientYBetween(refs.fore, w1, w2, 0.85)

			local fdir = w2 - w1
			fdir = fdir.Magnitude > 0.05 and fdir.Unit or -Vector3.yAxis
			refs.tool.CFrame = CFrame.lookAt(w2, w2 + fdir)
			refs.tip.CFrame  = CFrame.new(w2 + fdir * 1.25)

			local flat = Vector3.new(w1.X - w0.X, 0, w1.Z - w0.Z)
			if flat.Magnitude > 0.05 then
				refs.shoulder.CFrame = CFrame.lookAt(w0, w0 + flat)
			end
			if refs.piston then
				local pBase = groundCF:PointToWorldSpace(arm.dir * 6.0 + Vector3.new(0, 13.2, 0))
				UnitVisuals.orientYBetween(refs.piston, pBase, (w0 + w1) * 0.5, 0.38)
			end
		end
	end
end

-- ── Public API ────────────────────────────────────────────────────────────────

function FabricatorArms.init(cam: Camera)
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

return FabricatorArms
