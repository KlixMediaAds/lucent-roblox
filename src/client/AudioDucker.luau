-- AudioDucker.luau
-- The RTS camera teleports ("hops") often — the eye camera-jumper, minimap
-- click-to-pan, etc. Because the audio listener rides the camera, an instant jump
-- makes every playing 3D sound lurch in volume/pan for a frame, a nasty zipper/pop.
--
-- This routes every spatial (workspace-parented) Sound through one shared SoundGroup
-- so the whole 3D mix can be faded as a unit, and exposes duckTeleport(): a short
-- fade-out to silence, the camera jump performed at the silent low point, then a
-- fade-in as it lands. 2D audio (ambience / music / UI) lives under SoundService, not
-- workspace, so it is never touched.
--!strict

local SoundService = game:GetService("SoundService")
local RunService   = game:GetService("RunService")

local AudioDucker = {}

local FADE_OUT = 0.12   -- s to duck the 3D mix before a teleport (within the 0.1–0.2 band)
local FADE_IN  = 0.2    -- s to bring it back once the camera lands

local group: SoundGroup? = nil
local fadeToken = 0      -- bumped on every teleport; cancels an in-flight fade if interrupted

-- Route a Sound into the 3D group (only if it isn't already assigned to one, so a
-- caller that deliberately picked a group keeps it).
local function hook(inst: Instance)
	if inst:IsA("Sound") and inst.SoundGroup == nil then
		inst.SoundGroup = group
	end
end

function AudioDucker.init()
	if group then return end
	local g   = Instance.new("SoundGroup")
	g.Name    = "Spatial3D"
	g.Volume  = 1
	g.Parent  = SoundService
	group     = g

	-- Existing + all future workspace Sounds (including server-replicated ones) join
	-- the group. DescendantAdded is event-driven, so this costs a cheap type check
	-- only when instances are actually added — not per frame.
	for _, d in workspace:GetDescendants() do hook(d) end
	workspace.DescendantAdded:Connect(hook)
end

-- Tween the group volume to `target` over `dur` seconds on the calling thread. Returns
-- true if it ran to completion, false if a newer teleport superseded it mid-fade.
local function fadeTo(target: number, dur: number, token: number): boolean
	local g = group :: SoundGroup
	local start = g.Volume
	local t0    = os.clock()
	while true do
		if fadeToken ~= token then return false end
		local a = if dur <= 0 then 1 else math.clamp((os.clock() - t0) / dur, 0, 1)
		g.Volume = start + (target - start) * a
		if a >= 1 then return true end
		RunService.RenderStepped:Wait()
	end
end

-- Duck the 3D mix for a camera teleport. `jump` (the actual camera move) is invoked
-- once, at the silent low point between the fade-out and fade-in. If another teleport
-- interrupts the fade-out, this one is abandoned WITHOUT jumping — the newer teleport
-- owns the camera's destination — so the camera never lands on a stale target.
function AudioDucker.duckTeleport(jump: () -> ())
	if not group then jump(); return end   -- not initialised yet: just move
	fadeToken += 1
	local token = fadeToken
	task.spawn(function()
		if not fadeTo(0, FADE_OUT, token) then return end
		jump()
		fadeTo(1, FADE_IN, token)
	end)
end

return AudioDucker
