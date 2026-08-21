-- BodyLOD.luau
-- One shared animation budget for every procedural body animator.
--
-- The Hollowed creatures and the walking Human units are not models the engine animates:
-- each one is a rig of twenty to forty loose parts that a client module re-poses from
-- scratch, and it was doing that for every rig, every rendered frame. That is the cost
-- that grows with army size -- fifteen Lampreys is four hundred and fifty parts being
-- written every frame, before anything else on screen has been drawn.
--
-- Nothing about that work needs to happen at frame rate. The body part every rig hangs
-- off is an anchored part the SERVER moves, so it arrives in replication steps of roughly
-- a twentieth of a second: pose the rig sixty times a second and fifty of those poses are
-- drawn against a pivot that has not moved. So each rig gets a rate instead of a frame:
--
--   on screen, close      1/30 s   (indistinguishable from every frame, half the cost)
--   on screen, further    1/20 s
--   off screen or far     1/8  s   (nothing is looking at it)
--
-- `step` hands back the time BANKED since that rig last posed, not the frame's dt, so a
-- rig running at a third of the rate advances its walk cycle by three times as much and
-- animations play at exactly the speed they always did. Rigs are given a random offset
-- into their first window, so a squad that spawned on the same frame does not then spend
-- the rest of the match landing all of its updates on the same frame as each other.
--
-- This deliberately does NOT cull: every caller already has its own hard distance cull
-- and its own bookkeeping for coming back from one. The longest a rig can sit out here is
-- an eighth of a second, which is short enough that per-frame movement estimates stay
-- honest across a skip.
--!strict

local BodyLOD = {}

-- Distance bands, squared, measured from the camera.
local NEAR2 = 130 * 130
local MID2  = 240 * 240

-- Seconds between poses in each band.
local NEAR_STEP = 1 / 30
local MID_STEP  = 1 / 20
local OFF_STEP  = 1 / 8

-- How far behind the camera plane a rig may still sit and count as on screen. The RTS
-- camera looks down, so something a little behind the eye can still be in shot near the
-- bottom of the screen; past this it cannot be.
local BEHIND = -30

local camera: Camera? = nil

-- Banked time per rig. Keys are unit ids, which are never reused within a match but are
-- retired constantly, so the table is wiped wholesale once it has grown past anything a
-- live army could account for. A wipe costs nothing but a re-randomised first window.
local banked: { [string]: number } = {}
local bankedN = 0
local BANK_MAX = 600

function BodyLOD.init(cam: Camera)
	camera  = cam
	banked  = {}
	bankedN = 0
end

-- The dt this rig should animate with, or nil to leave it exactly as it is this frame.
function BodyLOD.step(key: string, pos: Vector3, dt: number): number?
	local cam = camera
	if not cam then return dt end

	local cf = cam.CFrame
	local ox = pos.X - cf.X
	local oy = pos.Y - cf.Y
	local oz = pos.Z - cf.Z
	local d2 = ox * ox + oy * oy + oz * oz

	local lv   = cf.LookVector
	local ahead = ox * lv.X + oy * lv.Y + oz * lv.Z

	local window: number
	if ahead < BEHIND then
		window = OFF_STEP
	elseif d2 < NEAR2 then
		window = NEAR_STEP
	elseif d2 < MID2 then
		window = MID_STEP
	else
		window = OFF_STEP
	end

	local a = banked[key]
	if a == nil then
		if bankedN >= BANK_MAX then
			banked  = {}
			bankedN = 0
		end
		bankedN += 1
		-- Somewhere inside the first window rather than the start of it: this is what
		-- spreads a squad's updates across frames instead of stacking them on one.
		a = math.random() * window
	end

	a += dt
	if a < window then
		banked[key] = a
		return nil
	end
	banked[key] = 0
	return a
end

return BodyLOD
