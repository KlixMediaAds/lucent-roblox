-- AmbientAudio.luau
-- The match's environmental audio bed:
--   • a constant 2D wind loop parented to SoundService, so it plays at full volume
--     everywhere regardless of where the camera is, and
--   • a field of 3D cricket / cicada emitters spread across the map on a loose grid, so
--     the bug chorus swells and fades naturally as the RTS camera pans — the 3D audio
--     environment. Each emitter's reach is smaller than the grid spacing, so crickets
--     read as localized pockets rather than a blanket heard everywhere. The emitters
--     live in workspace, so AudioDucker routes them through the Spatial3D SoundGroup and
--     they duck with every camera teleport for free.
--
-- Debug: `/debug sound` (see init.client) toggles a glowing neon marker at every emitter
-- so the spatial distribution of the ambience is visible in-world.
--!strict

local SoundService = game:GetService("SoundService")

local AmbientAudio = {}

local WIND_ID    = "rbxassetid://5799870105"
local CRICKET_ID = "rbxassetid://9112762614"

local WIND_VOLUME    = 0.7    -- constant 2D wind bed
local CRICKET_VOLUME = 0.2    -- per-emitter 3D chorus

-- Emitters scattered at random across the play area (the boundary walls sit at ±432).
-- Reach is kept small so they read as localized pockets, not a blanket heard everywhere.
local HALF     = 400   -- half-extent of the emitter field (studs)
local COUNT    = 12    -- randomly-placed emitters (about half the old 5×5 grid)
local EMIT_Y   = 6     -- height above the world floor
local ROLL_MIN = 25    -- studs of full volume around each emitter
local ROLL_MAX = 140   -- studs to silence → audible pockets

-- Debug markers: a dark-blue neon ball at each cricket emitter, hidden until /debug sound.
local DEBUG_COLOR    = Color3.fromRGB(20, 40, 150)   -- dark blue
local DEBUG_BALL     = 16                             -- marker diameter (studs)
local DEBUG_SHOWN_T  = 0.15                           -- transparency when shown

local WIND_NAME    = "AmbientWind"
local FOLDER_NAME  = "_AmbientEmitters"

local debugBalls: { BasePart } = {}
local debugOn = false

function AmbientAudio.start()
	-- Clear a previous match's ambience first, so replays in the same session don't
	-- stack duplicate loops.
	local oldWind = SoundService:FindFirstChild(WIND_NAME)
	if oldWind then oldWind:Destroy() end
	local oldFolder = workspace:FindFirstChild(FOLDER_NAME)
	if oldFolder then oldFolder:Destroy() end
	table.clear(debugBalls)

	-- 2D wind bed.
	local wind    = Instance.new("Sound")
	wind.Name     = WIND_NAME
	wind.SoundId  = WIND_ID
	wind.Looped   = true
	wind.Volume   = WIND_VOLUME
	wind.Parent   = SoundService
	wind:Play()

	-- 3D cricket / cicada field.
	local folder  = Instance.new("Folder")
	folder.Name   = FOLDER_NAME
	folder.Parent = workspace

	for _ = 1, COUNT do
		local x = (math.random() * 2 - 1) * HALF
		local z = (math.random() * 2 - 1) * HALF

		local part        = Instance.new("Part")
		part.Name         = "CricketEmitter"
		part.Anchored     = true
		part.CanCollide   = false
		part.CanQuery     = false
		part.CanTouch     = false
		part.CastShadow   = false
		part.Transparency = 1
		part.Size         = Vector3.one
		part.Position     = Vector3.new(x, EMIT_Y, z)
		part.Parent       = folder

		local s              = Instance.new("Sound")
		s.SoundId            = CRICKET_ID
		s.Looped             = true
		s.Volume             = CRICKET_VOLUME
		s.RollOffMode        = Enum.RollOffMode.Linear
		s.RollOffMinDistance = ROLL_MIN
		s.RollOffMaxDistance = ROLL_MAX
		s.PlaybackSpeed      = 0.92 + math.random() * 0.16   -- slight per-emitter detune
		s.Parent             = part
		s:Play()
		s.TimePosition       = math.random() * 12            -- desync loops so they don't phase

		-- Debug marker (hidden unless /debug sound is on).
		local ball         = Instance.new("Part")
		ball.Name          = "CricketDebugMarker"
		ball.Shape         = Enum.PartType.Ball
		ball.Material      = Enum.Material.Neon
		ball.Color         = DEBUG_COLOR
		ball.Size          = Vector3.new(DEBUG_BALL, DEBUG_BALL, DEBUG_BALL)
		ball.Anchored      = true
		ball.CanCollide    = false
		ball.CanQuery      = false
		ball.CanTouch      = false
		ball.CastShadow    = false
		ball.Transparency  = debugOn and DEBUG_SHOWN_T or 1
		ball.Position      = Vector3.new(x, EMIT_Y, z)
		ball.Parent        = part
		debugBalls[#debugBalls + 1] = ball
	end
end

-- Toggle the neon emitter markers (driven by the /debug sound chat command).
function AmbientAudio.setDebugVisible(on: boolean)
	debugOn = on
	for _, b in debugBalls do
		if b.Parent then b.Transparency = on and DEBUG_SHOWN_T or 1 end
	end
end

return AmbientAudio
