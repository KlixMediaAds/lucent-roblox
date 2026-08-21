--[[
	SelectionRing: the lit circle a selected unit or structure stands inside.

	Selection used to be a SelectionBox, a wireframe cage drawn around the model. A cage
	reads as an editor tool: it boxes the creature off from the scene it is standing in
	and, on anything tall or sprawling, it is most of what you look at. This is the RTS
	answer instead, the one StarCraft uses: a thin bright circle painted on the ground
	UNDER the thing, so the world stays the thing you are looking at.

	Each ring is two CylinderHandleAdornments -- a bright line and a soft halo around it.
	An adornment with an InnerRadius is a true annulus drawn straight by the renderer: no
	part, no mesh, no texture, nothing added to the workspace to collide with, cull or
	replicate, and no per-ring draw setup beyond the adornment itself.

	This matters at RTS scale. Selecting sixty units means sixty rings, so a ring MUST NOT
	cost anything that is measured per pixel. The first version of this module drew each
	ring as a SurfaceGui circle, which meant sixty GUI surfaces being rasterised every
	frame; it took the game to single-digit framerates on a full army. Nothing here may
	create a GUI, a decal, or geometry per selected unit.

	Rings follow their target every frame, so a selected unit keeps its ring while it
	walks. They sit at the target's FOOTING (its part's underside), which puts the ring on
	the ground on whichever terrain tier the target is standing on, and they are drawn in
	world space rather than bolted to the part so that a unit which tips over (a downed
	soldier lies pitched onto its back) keeps a ring lying flat on the ground.

	SelectionRing.attach(part, opts?) -> Ring   follows `part` until destroyed
	SelectionRing.destroy(ring)
	SelectionRing.radiusFor(part, pad?)         a footprint radius off a part's size
]]

local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PerfProbe = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PerfProbe"))
local SelectionRing = {}

export type Opts = {
	color:  Color3?,   -- ring colour (defaults to a cold cyan)
	radius: number?,   -- studs; defaults to the target part's footprint
	line:   number?,   -- ring line thickness in studs
	lift:   number?,   -- studs above the target's footing
}

export type Ring = {
	target: BasePart,
	core:   CylinderHandleAdornment,
	halo:   CylinderHandleAdornment,
	lift:   number,
}

-- Fog-of-war tiles top out at Y = 0.25, so the default lift clears them.
local LIFT     = 0.38
local HEIGHT   = 0.08   -- the annulus is a wafer; only its face is ever seen
-- A CylinderHandleAdornment runs along its own +Z, so this lays it flat, face up.
local FLAT     = CFrame.Angles(-math.pi / 2, 0, 0)
local GLOW_MUL = 4      -- halo width relative to the line
local CORE_T   = 0.18
local GLOW_T   = 0.84

local active: { Ring } = {}
local loop: RBXScriptConnection? = nil

-- One flat annulus of `width` studs whose OUTER edge sits at `outer`. Adorned to the
-- terrain, which is fixed at the origin, so its CFrame is a plain world CFrame.
local function band(color: Color3, outer: number, width: number,
	transparency: number, z: number): CylinderHandleAdornment
	local a        = Instance.new("CylinderHandleAdornment")
	a.Name         = "_SelectionRing"
	a.Adornee      = workspace.Terrain
	a.Radius       = outer
	a.InnerRadius  = math.max(0, outer - width)
	a.Height       = HEIGHT
	a.Color3       = color
	a.Transparency = transparency
	a.AlwaysOnTop  = false   -- the unit standing in it occludes it, as it should
	a.ZIndex       = z
	a.Parent       = workspace.Terrain
	return a
end

-- Drop the ring onto the ground under its target. Y comes off the underside of the
-- target's part rather than a raycast: units are spawned and driven standing ON the
-- surface, so their footing already is the surface, and no per-frame ray is needed.
local function place(r: Ring)
	local t   = r.target
	local pos = t.Position
	local cf  = CFrame.new(pos.X, pos.Y - t.Size.Y * 0.5 + r.lift, pos.Z) * FLAT
	r.core.CFrame = cf
	r.halo.CFrame = cf
end

local function ensureLoop()
	if loop then return end
	loop = PerfProbe.onRender("SelectionRing", function()
		for i = #active, 1, -1 do
			local r = active[i]
			-- The target dying takes its ring with it, so callers that lose track of a
			-- unit mid-selection never leave a circle sitting on empty ground.
			if not r.target.Parent then
				r.core:Destroy()
				r.halo:Destroy()
				table.remove(active, i)
				continue
			end
			place(r)
		end
		if #active == 0 and loop then
			loop:Disconnect()
			loop = nil
		end
	end)
end

-- A circle wide enough to sit around whatever `part` is, with a little air outside it.
function SelectionRing.radiusFor(part: BasePart, pad: number?): number
	local s = part.Size
	return math.max(1.7, math.max(s.X, s.Z) * 0.5 + (pad or 0.7))
end

function SelectionRing.attach(target: BasePart, opts: Opts?): Ring
	local o      = opts or {}
	local color  = o.color or Color3.fromRGB(90, 215, 255)
	local radius = o.radius or SelectionRing.radiusFor(target)
	-- Thicker line on bigger rings so a Broodmother's circle doesn't read as a hairline,
	-- but never so thick on a soldier that the ring becomes a donut.
	local line   = o.line or math.clamp(radius * 0.05, 0.16, 0.35)

	local ring: Ring = {
		target = target,
		lift   = o.lift or LIFT,
		halo   = band(color, radius + line * GLOW_MUL * 0.5, line * GLOW_MUL, GLOW_T, 0),
		core   = band(color, radius + line * 0.5, line, CORE_T, 1),
	}
	place(ring)   -- stand it up this frame, not the next one
	table.insert(active, ring)
	ensureLoop()
	return ring
end

function SelectionRing.destroy(ring: Ring?)
	if not ring then return end
	local r = ring :: Ring
	r.core:Destroy()
	r.halo:Destroy()
	for i = #active, 1, -1 do
		if active[i] == r then table.remove(active, i); break end
	end
end

return SelectionRing
