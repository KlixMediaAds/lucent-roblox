--!strict
--[[
	MotherEggBody — client-side animator for the tentacles that envelop a Mother egg.

	When a Mother egg settles the server fires MotherEggLand with the egg part; here we
	sprout a ring of dark tentacles around the egg's BASE and, over ~1.3s, grow them up
	the sides — each one hugging the egg's surface along a meridian. They read the egg's
	LIVE size every frame, so as the egg breathes the tentacles pulse and hug right along
	with it. All parts are client-only children of the egg, so nothing replicates and they
	vanish with the egg when it hatches.

	Same pattern as MotherCrown / LeechBody: parts are shaped once, re-CFramed per frame.
]]

local RunService = game:GetService("RunService")

local MotherEggBody = {}

-- ── Look ────────────────────────────────────────────────────────────────────────
local C_VEIN   = Color3.fromRGB(14, 9, 16)     -- near-black tentacle flesh
local C_GLOW   = Color3.fromRGB(255, 120, 60)  -- warm orange glowing tip (Hagfish-eye)
local T_COUNT  = 6                             -- tentacles around the egg
local T_SEGS   = 4                             -- segments per tentacle
local GROW_TIME = 1.3                          -- sprout-and-climb duration (s)
local THETA_MIN = 0.42                         -- root angle up from the bottom pole (~24°)
local THETA_MAX = 2.35                         -- how far up they climb (~135°) — crown stays open
local HUG       = 1.06                         -- ride just off the surface
local CULL_SQ   = 320 * 320

-- ── State ────────────────────────────────────────────────────────────────────────
type Tent = { segs: { BasePart }, glow: BasePart, phi: number, seed: number }
type Entry = { egg: BasePart, t0: number, tents: { Tent } }
local active: { [BasePart]: Entry } = {}
local camera: Camera?

-- ── Helpers ──────────────────────────────────────────────────────────────────────
local function mkPart(parent: Instance, color: Color3, material: Enum.Material, shape: Enum.PartType?): BasePart
	local p = Instance.new("Part")
	if shape then (p :: any).Shape = shape end
	p.Size       = Vector3.new(0.2, 0.2, 0.2)
	p.Color      = color
	p.Material   = material
	p.Anchored   = true
	p.CanCollide = false
	p.CanQuery   = false
	p.CanTouch   = false
	p.CastShadow = false
	p.Parent     = parent
	return p
end

-- Unit direction on the sphere at polar angle `theta` up from the bottom pole (0 =
-- straight down, π = straight up) and longitude `phi`.
local function dirAt(theta: number, phi: number): Vector3
	local st = math.sin(theta)
	return Vector3.new(st * math.cos(phi), -math.cos(theta), st * math.sin(phi))
end

-- ── Public API ───────────────────────────────────────────────────────────────────
function MotherEggBody.init(cam: Camera)
	camera = cam

	RunService.RenderStepped:Connect(function()
		local now    = os.clock()
		local camPos = camera and camera.CFrame.Position or Vector3.zero

		for egg, e in active do
			if not egg.Parent then
				active[egg] = nil
				continue
			end

			local center = egg.Position
			local dd     = center - camPos
			if dd:Dot(dd) > CULL_SQ then continue end

			local R = egg.Size.X * 0.5                      -- live → pulses with the egg
			local g = math.clamp((now - e.t0) / GROW_TIME, 0, 1)
			local gg = 1 - (1 - g) * (1 - g)                -- ease-out climb

			for _, tent in e.tents do
				local top   = THETA_MIN + gg * (THETA_MAX - THETA_MIN)
				local segs  = tent.segs
				local prev  = center + dirAt(THETA_MIN, tent.phi) * (R * HUG)
				for j = 1, #segs do
					local frac  = j / #segs
					local theta = THETA_MIN + (top - THETA_MIN) * frac
					-- Gentle living sway that grows toward the tip.
					local sway  = math.sin(now * 1.6 + tent.seed + j * 0.6) * 0.05 * frac
					local pt    = center + dirAt(theta, tent.phi + sway) * (R * HUG)
					local mid   = (prev + pt) * 0.5
					local len   = (pt - prev).Magnitude
					local width = R * (0.4 - 0.24 * (frac - 1 / #segs))   -- taper base → tip
					local seg   = segs[j]
					seg.Size    = Vector3.new(width, width * 0.8, len + R * 0.06)
					seg.CFrame  = CFrame.lookAt(mid, pt, (mid - center).Unit)
					prev = pt
				end
				-- Glowing bud at the growing tip.
				local tipDir = dirAt(top, tent.phi)
				tent.glow.Size   = Vector3.new(1, 1, 1) * (R * 0.3 * (0.35 + 0.65 * gg))
				tent.glow.CFrame = CFrame.new(center + tipDir * (R * HUG))
			end
		end
	end)
end

-- Begin the enveloping animation on a freshly-landed Mother egg.
function MotherEggBody.sprout(egg: BasePart)
	if not egg or active[egg] then return end

	local tents: { Tent } = {}
	for i = 1, T_COUNT do
		local segs: { BasePart } = {}
		for _ = 1, T_SEGS do
			segs[#segs + 1] = mkPart(egg, C_VEIN, Enum.Material.Slate)
		end
		tents[i] = {
			segs = segs,
			glow = mkPart(egg, C_GLOW, Enum.Material.Neon, Enum.PartType.Ball),
			phi  = (i / T_COUNT) * math.pi * 2,
			seed = math.random() * 100,
		}
	end

	active[egg] = { egg = egg, t0 = os.clock(), tents = tents }
	egg.Destroying:Once(function() active[egg] = nil end)
end

return MotherEggBody
