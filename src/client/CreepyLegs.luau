-- CreepyLegs.luau
-- Procedural tentacle appendages for CreepySoldier units.
-- 3 waving tentacles per unit, each with 2 segments + alternating teeth.
-- Design mirrors the Creepy/Mutant turret aesthetic: black body, bone-white teeth.
--!strict

local RunService = game:GetService("RunService")

local CreepyLegs = {}
local legsFolder: Folder
local camera:     Camera

-- ── Constants ─────────────────────────────────────────────────────────────────

local TENT_PHASES = { 0, math.pi * 2 / 3, math.pi * 4 / 3 }
local TENT_LEN    = 5.0   -- studs from body centre to tip
local SEG_W       = 0.40  -- tentacle thickness
local TOOTH_W     = 0.28
local TOOTH_H     = 1.1
local CULL_SQ     = 280 * 280

local C_BLACK = Color3.fromRGB(10, 10, 10)
local C_TOOTH = Color3.fromRGB(235, 235, 220)

-- ── Types ─────────────────────────────────────────────────────────────────────

type TentacleParts = {
	segs:  { BasePart },   -- 2 segment cylinders
	teeth: { BasePart },   -- 4 tooth spines (2 per segment, alternating sides)
}

type Entry = {
	body:      BasePart,
	tentacles: { TentacleParts },
	tipPos:    { Vector3 },
	conn:      RBXScriptConnection,
}

local active: { [string]: Entry } = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function bez3(t: number, P0: Vector3, P1: Vector3, P2: Vector3): Vector3
	local s = 1 - t
	return s*s*P0 + 2*s*t*P1 + t*t*P2
end

-- Orient a part so its long axis runs from A to B.
local function orientBetween(p: BasePart, a: Vector3, b: Vector3, w: number)
	local d   = b - a
	local len = d.Magnitude
	if len < 0.02 then return end
	-- CFrame.new(mid, b) points +Z toward b; rotate so +X becomes the length axis.
	p.CFrame = CFrame.new((a + b) * 0.5, b) * CFrame.Angles(0, math.pi / 2, 0)
	p.Size   = Vector3.new(len, w, w)
end

-- Place a tooth spiking outward perpendicular to the tentacle segment.
local function setTooth(tooth: BasePart, pt: Vector3, segDir: Vector3, sideScale: number)
	local worldUp = Vector3.new(0, 1, 0)
	local right   = segDir:Cross(worldUp)
	if right.Magnitude < 0.01 then right = segDir:Cross(Vector3.new(1, 0, 0)) end
	right = right.Unit

	local outDir  = (right * sideScale + Vector3.new(0, 0.4, 0)).Unit
	local toothPos = pt + outDir * (SEG_W * 0.5 + TOOTH_H * 0.3)
	-- Y-axis of tooth points outward from tentacle
	local side2   = segDir:Cross(outDir)
	if side2.Magnitude < 0.01 then side2 = Vector3.new(0, 0, 1) end
	tooth.CFrame  = CFrame.fromMatrix(toothPos, segDir, outDir, -side2)
	tooth.Size    = Vector3.new(TOOTH_W, TOOTH_H, TOOTH_W)
end

local function makePart(col: Color3): BasePart
	local p         = Instance.new("Part")
	p.Color         = col
	p.Material      = Enum.Material.SmoothPlastic
	p.Anchored      = true
	p.CanCollide    = false
	p.CastShadow    = false
	p.CanQuery      = false
	p.Parent        = legsFolder
	return p
end

local function buildTentacle(): TentacleParts
	local segs:  { BasePart } = {}
	local teeth: { BasePart } = {}
	for _ = 1, 2 do table.insert(segs,  makePart(C_BLACK)) end
	for _ = 1, 4 do table.insert(teeth, makePart(C_TOOTH))  end
	return { segs = segs, teeth = teeth }
end

-- ── Public API ────────────────────────────────────────────────────────────────

function CreepyLegs.attach(unitId: string, body: BasePart)
	if active[unitId] then return end

	local tentacles: { TentacleParts } = {}
	for _ = 1, 3 do
		table.insert(tentacles, buildTentacle())
	end

	local conn = body.Destroying:Connect(function()
		CreepyLegs.detach(unitId)
	end)

	-- Tag leg parts with UnitId so FogManager can control their visibility
	for _, tp in tentacles do
		for _, p in tp.segs  do p:SetAttribute("UnitId", unitId) end
		for _, p in tp.teeth do p:SetAttribute("UnitId", unitId) end
	end

	active[unitId] = {
		body      = body,
		tentacles = tentacles,
		tipPos    = {},
		conn      = conn,
	}
end

function CreepyLegs.detach(unitId: string)
	local e = active[unitId]
	if not e then return end
	active[unitId] = nil
	e.conn:Disconnect()
	for _, tp in e.tentacles do
		for _, p in tp.segs  do if p.Parent then p:Destroy() end end
		for _, p in tp.teeth do if p.Parent then p:Destroy() end end
	end
end

function CreepyLegs.init(cam: Camera)
	camera          = cam
	legsFolder      = Instance.new("Folder")
	legsFolder.Name = "_CreepyLegs"
	legsFolder.Parent = workspace

	RunService.RenderStepped:Connect(function(dt: number)
		local now    = os.clock()
		local camPos = camera.CFrame.Position

		for unitId, e in active do
			local body = e.body
			if not body.Parent then CreepyLegs.detach(unitId); continue end

			local bpos = body.Position
			local dx   = bpos.X - camPos.X
			local dz   = bpos.Z - camPos.Z
			if dx*dx + dz*dz > CULL_SQ then continue end

			-- Anchor point: just above body centre
			local headPos = bpos + Vector3.new(0, 1.2, 0)

			for t = 1, 3 do
				local phase = TENT_PHASES[t]
				local wT    = now * math.pi * 2 * 0.55 + phase

				-- Idle wave: sweep outward with sinusoidal height variation
				local swingAngle = phase + math.sin(wT) * 0.30 + now * 0.35
				local goalTip    = headPos
					+ Vector3.new(math.cos(swingAngle), 0, math.sin(swingAngle)) * TENT_LEN
					+ Vector3.new(0, math.sin(wT * 0.85) * 1.8 - 2.2, 0)

				-- Smooth tip toward goal
				local cur   = e.tipPos[t]
				local alpha = math.min(dt * 4.5, 1)
				local tip: Vector3
				if cur then
					tip = cur:Lerp(goalTip, alpha)
				else
					tip = goalTip
				end
				e.tipPos[t] = tip

				-- Bezier control point arcs gently upward
				local ctrl = (headPos + tip) * 0.5 + Vector3.new(0, 2.0, 0)

				-- Two segments: headPos→mid, mid→tip
				local mid  = bez3(0.5, headPos, ctrl, tip)
				local tp   = e.tentacles[t]

				orientBetween(tp.segs[1], headPos, mid, SEG_W)
				orientBetween(tp.segs[2], mid,     tip, SEG_W * 0.75)

				-- Teeth: 2 per segment, alternating sides (±1)
				local dir1 = (mid - headPos)
				if dir1.Magnitude > 0.01 then dir1 = dir1.Unit end
				local dir2 = (tip - mid)
				if dir2.Magnitude > 0.01 then dir2 = dir2.Unit end

				-- Seg 1 teeth at 35% and 70% along headPos→mid
				setTooth(tp.teeth[1], headPos:Lerp(mid, 0.35), dir1,  1)
				setTooth(tp.teeth[2], headPos:Lerp(mid, 0.70), dir1, -1)
				-- Seg 2 teeth at 30% and 65% along mid→tip
				setTooth(tp.teeth[3], mid:Lerp(tip, 0.30), dir2, -1)
				setTooth(tp.teeth[4], mid:Lerp(tip, 0.65), dir2,  1)
			end
		end
	end)
end

return CreepyLegs
