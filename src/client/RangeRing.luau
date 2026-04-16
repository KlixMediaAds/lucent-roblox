local RangeRing = {}

local N = 32  -- arc segments per ring layer

local function makeLayer(radius: number, width: number, transparency: number, y: number, parent: Model)
	local TWO_PI = 2 * math.pi
	local arcLen = TWO_PI * radius / N + 0.1
	for i = 0, N - 1 do
		local angle = i * TWO_PI / N
		local cosA  = math.cos(angle)
		local sinA  = math.sin(angle)
		local p     = Instance.new("Part")
		p.Size         = Vector3.new(arcLen, 0.05, width)
		p.Anchored     = true
		p.CanCollide   = false
		p.CanQuery     = false
		p.CastShadow   = false
		p.Material     = Enum.Material.Neon
		p.Color        = Color3.new(1, 1, 1)
		p.Transparency = transparency
		-- X axis = tangent direction, Y axis = up, Z axis = inward (auto-computed)
		p.CFrame = CFrame.fromMatrix(
			Vector3.new(cosA * radius, y, sinA * radius),
			Vector3.new(-sinA, 0, cosA),
			Vector3.new(0, 1, 0)
		)
		p.Parent = parent
	end
end

-- Creates a movable radius ring centred at (cx, cz).
-- Sits above fog-of-war tiles so it is always visible.
-- Returns a Model; reposition with RangeRing.moveTo or Model:PivotTo(CFrame.new(cx,0,cz)).
function RangeRing.create(radius: number, cx: number, cz: number): Model
	local model = Instance.new("Model")
	model.Name  = "_RangeRing"

	local pivot       = Instance.new("Part")
	pivot.Name        = "Pivot"
	pivot.Size        = Vector3.new(0.05, 0.05, 0.05)
	pivot.Transparency = 1
	pivot.Anchored    = true
	pivot.CanCollide  = false
	pivot.CanQuery    = false
	pivot.CastShadow  = false
	pivot.CFrame      = CFrame.new(0, 0, 0)
	pivot.Parent      = model
	model.PrimaryPart = pivot

	-- Y positions are above fog-of-war tiles (black Y=0.15, shroud Y=0.20, top at 0.25)
	makeLayer(radius,       0.4, 0.15, 0.30, model)  -- bright perimeter line
	makeLayer(radius - 1.0, 2.0, 0.85, 0.29, model)  -- 2-stud inner fade

	model.Parent = workspace
	model:PivotTo(CFrame.new(cx, 0, cz))
	return model
end

-- Moves a ring to a new XZ position without recreating it.
function RangeRing.moveTo(model: Model, cx: number, cz: number)
	model:PivotTo(CFrame.new(cx, 0, cz))
end

function RangeRing.destroy(model: Model?)
	if model and model.Parent then model:Destroy() end
end

-- Creates a merged build-zone ring for one or more circles (CC + Relays).
-- Arc segments whose centres fall inside another circle are hidden, producing
-- a single outer perimeter when circles overlap.
-- zones: { {cx: number, cz: number, radius: number} }
type Zone = { cx: number, cz: number, radius: number }
function RangeRing.createBuildZone(zones: { Zone }): Model
	local model = Instance.new("Model")
	model.Name  = "_BuildZoneRing"

	local pivot       = Instance.new("Part")
	pivot.Name        = "Pivot"
	pivot.Size        = Vector3.new(0.05, 0.05, 0.05)
	pivot.Transparency = 1
	pivot.Anchored    = true
	pivot.CanCollide  = false
	pivot.CanQuery    = false
	pivot.CastShadow  = false
	pivot.CFrame      = CFrame.new(0, 0, 0)
	pivot.Parent      = model
	model.PrimaryPart = pivot

	local TWO_PI = 2 * math.pi

	for _, zone in zones do
		local cx, cz, radius = zone.cx, zone.cz, zone.radius
		local arcLen = TWO_PI * radius / N + 0.1
		local innerRadius = radius - 1.0

		for i = 0, N - 1 do
			local angle = i * TWO_PI / N
			local cosA  = math.cos(angle)
			local sinA  = math.sin(angle)

			-- Perimeter segment world position
			local wx = cx + cosA * radius
			local wz = cz + sinA * radius

			-- Hide this segment if its centre is inside any other zone
			local insideOther = false
			for _, other in zones do
				if other == zone then continue end
				local dx = wx - other.cx
				local dz = wz - other.cz
				if dx * dx + dz * dz < other.radius * other.radius then
					insideOther = true
					break
				end
			end
			if insideOther then continue end

			-- Bright perimeter line
			local p        = Instance.new("Part")
			p.Size         = Vector3.new(arcLen, 0.05, 0.4)
			p.Anchored     = true
			p.CanCollide   = false
			p.CanQuery     = false
			p.CastShadow   = false
			p.Material     = Enum.Material.Neon
			p.Color        = Color3.new(1, 1, 1)
			p.Transparency = 0.15
			p.CFrame = CFrame.fromMatrix(
				Vector3.new(wx, 0.30, wz),
				Vector3.new(-sinA, 0, cosA),
				Vector3.new(0, 1, 0)
			)
			p.Parent = model

			-- Inner fade (check inner ring position too)
			local ix = cx + cosA * innerRadius
			local iz = cz + sinA * innerRadius
			local innerInside = false
			for _, other in zones do
				if other == zone then continue end
				local dx = ix - other.cx
				local dz = iz - other.cz
				if dx * dx + dz * dz < other.radius * other.radius then
					innerInside = true
					break
				end
			end
			if not innerInside then
				local f        = Instance.new("Part")
				f.Size         = Vector3.new(arcLen, 0.05, 2.0)
				f.Anchored     = true
				f.CanCollide   = false
				f.CanQuery     = false
				f.CastShadow   = false
				f.Material     = Enum.Material.Neon
				f.Color        = Color3.new(1, 1, 1)
				f.Transparency = 0.85
				f.CFrame = CFrame.fromMatrix(
					Vector3.new(ix, 0.29, iz),
					Vector3.new(-sinA, 0, cosA),
					Vector3.new(0, 1, 0)
				)
				f.Parent = model
			end
		end
	end

	model.Parent = workspace
	return model
end

return RangeRing
