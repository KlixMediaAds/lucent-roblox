local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))

local Camera    = {}
local cam       = workspace.CurrentCamera
local mouse     = Players.LocalPlayer:GetMouse()

local DEFAULT_ZOOM = 80
local DEFAULT_YAW  = 0

local focus     = Vector3.new(0, 0, 0)
local zoom      = DEFAULT_ZOOM
local yaw       = DEFAULT_YAW   -- degrees

-- While true, the camera is animating back to base; WASD/edge panning is paused
-- and the animation coroutine drives focus/zoom/yaw each frame.
local returning = false

local midDrag   = false
local lastMouse = Vector2.zero

-- When true, screen-edge panning is suppressed (e.g. while the cursor is over the
-- minimap, whose top-right corner sits inside the edge-pan threshold and would
-- otherwise drag the camera away from a click-to-pan target). WASD still works.
local edgePanSuppressed = false

-- When set, the camera locks its focus onto this part each frame (used to follow
-- the incoming Core drop pod). WASD panning is suspended while following.
local followTarget: BasePart? = nil

-- Screen shake: a single decaying amplitude jittered into the camera position each
-- frame. Camera.shake(amp) tops it up (strongest concurrent shake wins); it bleeds
-- off on its own. Used for nearby heavy impacts (e.g. a Broodmother's death).
local shakeAmp        = 0
local lastShakeClock  = os.clock()

local function apply()
	local yr = math.rad(yaw)
	local pr = math.rad(Config.CAMERA_PITCH)
	local offset = Vector3.new(
		math.sin(yr) * math.cos(pr) * zoom,
		math.sin(pr) * zoom,
		math.cos(yr) * math.cos(pr) * zoom
	)
	local camPos = focus + offset
	if shakeAmp > 0.01 then
		local now = os.clock()
		local sdt = math.clamp(now - lastShakeClock, 0, 0.1)
		lastShakeClock = now
		shakeAmp = math.max(0, shakeAmp - shakeAmp * math.min(1, sdt * 7) - sdt * 0.4)
		camPos += Vector3.new(
			(math.random() - 0.5),
			(math.random() - 0.5),
			(math.random() - 0.5)
		) * (2 * shakeAmp)
	else
		lastShakeClock = os.clock()
	end
	cam.CFrame = CFrame.new(camPos, focus)
end

-- Add a screen shake of the given amplitude (in studs of camera jitter). Decays on
-- its own; repeated calls keep whichever is strongest.
function Camera.shake(amplitude: number)
	shakeAmp = math.max(shakeAmp, amplitude)
end

function Camera.init()
	cam.CameraType = Enum.CameraType.Scriptable

	UserInputService.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton3 then
			midDrag   = true
			lastMouse = UserInputService:GetMouseLocation()
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton3 then
			midDrag = false
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			-- Don't zoom when any modal panel is intercepting scroll
			local guiObjects = Players.LocalPlayer.PlayerGui
				:GetGuiObjectsAtPosition(UserInputService:GetMouseLocation().X, UserInputService:GetMouseLocation().Y)
			local overPanel = false
			for _, obj in guiObjects do
				if obj:IsA("ScrollingFrame") or obj.Name == "TechGallery" or obj.Name == "Panel" then
					overPanel = true; break
				end
			end
			if not overPanel then
				zoom = math.clamp(
					zoom - input.Position.Z * Config.CAMERA_ZOOM_STEP,
					Config.CAMERA_ZOOM_MIN,
					Config.CAMERA_ZOOM_MAX
				)
			end
		end
		if midDrag and input.UserInputType == Enum.UserInputType.MouseMovement then
			local cur = UserInputService:GetMouseLocation()
			yaw      -= (cur - lastMouse).X * 0.3
			lastMouse = cur
		end
	end)

	-- Priority > Camera (200) so this runs AFTER Roblox's built-in camera script
	-- and overwrites whatever it set, keeping full control of cam.CFrame.
	RunService:BindToRenderStep("RTSCamera", Enum.RenderPriority.Camera.Value + 1, function(dt)
		-- Follow mode: lock focus onto the tracked part and skip edge panning until the
		-- follow is released. It releases when the tracked part dies (Parent gone) or the
		-- player takes manual control (WASD/QE pan-rotate or a middle-mouse drag) — edge
		-- panning is intentionally NOT an override so a follow triggered from a bottom-
		-- corner UI click doesn't cancel itself instantly.
		if followTarget then
			local manualOverride = midDrag
				or UserInputService:IsKeyDown(Enum.KeyCode.W) or UserInputService:IsKeyDown(Enum.KeyCode.S)
				or UserInputService:IsKeyDown(Enum.KeyCode.A) or UserInputService:IsKeyDown(Enum.KeyCode.D)
				or UserInputService:IsKeyDown(Enum.KeyCode.Q) or UserInputService:IsKeyDown(Enum.KeyCode.E)
			if followTarget.Parent and not manualOverride then
				focus = Vector3.new(followTarget.Position.X, 0, followTarget.Position.Z)
				apply()
				return
			else
				followTarget = nil
			end
		end

		-- Return-to-base animation drives the camera; a manual pan/rotate cancels it.
		if returning then
			if midDrag
				or UserInputService:IsKeyDown(Enum.KeyCode.W) or UserInputService:IsKeyDown(Enum.KeyCode.S)
				or UserInputService:IsKeyDown(Enum.KeyCode.A) or UserInputService:IsKeyDown(Enum.KeyCode.D)
				or UserInputService:IsKeyDown(Enum.KeyCode.Q) or UserInputService:IsKeyDown(Enum.KeyCode.E) then
				returning = false
			else
				apply()
				return
			end
		end

		local yr  = math.rad(yaw)
		local fwd = Vector3.new(-math.sin(yr), 0, -math.cos(yr))
		local rgt = Vector3.new( math.cos(yr), 0, -math.sin(yr))
		local spd = Config.CAMERA_MOVE_SPEED * dt
		local vp  = cam.ViewportSize
		local mp  = UserInputService:GetMouseLocation()
		local thr = Config.CAMERA_EDGE_THRESHOLD
		local move = Vector3.zero

		local edge = not edgePanSuppressed
		if UserInputService:IsKeyDown(Enum.KeyCode.W) or (edge and mp.Y < thr)        then move += fwd end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) or (edge and mp.Y > vp.Y - thr) then move -= fwd end
		if UserInputService:IsKeyDown(Enum.KeyCode.A) or (edge and mp.X < thr)        then move -= rgt end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) or (edge and mp.X > vp.X - thr) then move += rgt end
		if UserInputService:IsKeyDown(Enum.KeyCode.Q) then yaw += Config.CAMERA_ROTATE_SPEED * dt end
		if UserInputService:IsKeyDown(Enum.KeyCode.E) then yaw -= Config.CAMERA_ROTATE_SPEED * dt end

		if move.Magnitude > 0 then
			focus = focus + move.Unit * spd
			focus = Vector3.new(focus.X, 0, focus.Z)
		end

		apply()
	end)

	apply()
end

function Camera.getFocus(): Vector3
	return focus
end

function Camera.getYaw(): number
	return yaw
end

function Camera.setFocus(pos: Vector3)
	followTarget = nil   -- an explicit jump is a manual override; drop any active follow
	focus = Vector3.new(pos.X, 0, pos.Z)
	apply()
end

-- Smoothly fly the camera back to `pos` (the Command Center), restoring the
-- default rotation and zoom. Cancels follow mode; a manual pan/rotate aborts it.
function Camera.returnToBase(pos: Vector3)
	followTarget = nil
	local targetFocus = Vector3.new(pos.X, 0, pos.Z)
	local startFocus, startZoom, startYaw = focus, zoom, yaw
	-- Rotate the short way to the default heading (nearest multiple of 360).
	local targetYaw = math.floor((startYaw - DEFAULT_YAW) / 360 + 0.5) * 360 + DEFAULT_YAW

	returning = true
	local DUR = 0.6
	local t0  = os.clock()
	task.spawn(function()
		while returning do
			local a = math.clamp((os.clock() - t0) / DUR, 0, 1)
			local e = 1 - (1 - a) * (1 - a) * (1 - a)  -- cubic ease-out
			focus = startFocus:Lerp(targetFocus, e)
			zoom  = startZoom + (DEFAULT_ZOOM - startZoom) * e
			yaw   = startYaw  + (targetYaw  - startYaw)  * e
			if a >= 1 then
				returning = false
				break
			end
			RunService.RenderStepped:Wait()
		end
	end)
end

-- Toggles screen-edge panning. The minimap suppresses it while hovered/dragged so
-- click-to-pan lands on the clicked point instead of drifting via edge-scroll.
function Camera.setEdgePanSuppressed(v: boolean)
	edgePanSuppressed = v
end

-- Lock the camera onto a moving part (the camera keeps it centred each frame and
-- ignores WASD until stopFollow is called).
function Camera.followPart(part: BasePart?)
	followTarget = part
end

function Camera.stopFollow()
	followTarget = nil
end

-- Cast the cursor ray against the real Terrain so the returned point follows
-- raised plateaus / ramps. Without this, intersecting a flat y=0 plane lands the
-- point *under* elevated terrain and offset from the cursor, which is why ghosts,
-- move pings and rally markers were invisible (buried) when standing on a plateau.
local terrainRayParams = RaycastParams.new()
terrainRayParams.FilterType = Enum.RaycastFilterType.Include
terrainRayParams.FilterDescendantsInstances = { workspace.Terrain }

local function raycastTerrain(): Vector3?
	local ray    = mouse.UnitRay
	local result = workspace:Raycast(ray.Origin, ray.Direction * 5000, terrainRayParams)
	return result and result.Position or nil
end

-- Terrain surface height at an XZ position (straight-down raycast). Lets ground
-- markers (rally points, pings) sit on raised tiers instead of at a fixed Y.
-- Returns 0 if no terrain is hit (shouldn't happen over the play area).
function Camera.terrainHeightAt(x: number, z: number): number
	local result = workspace:Raycast(Vector3.new(x, 250, z), Vector3.new(0, -500, 0), terrainRayParams)
	return result and result.Position.Y or 0
end

-- Returns the world position on the terrain surface under the cursor (true Y on
-- whichever tier the cursor is over). Falls back to the y=0 plane if the cursor
-- isn't over terrain (e.g. pointing at the skybox).
function Camera.getGroundPosition(): Vector3?
	local surf = raycastTerrain()
	if surf then return surf end
	local ray = mouse.UnitRay
	if math.abs(ray.Direction.Y) < 1e-6 then return nil end
	local t = -ray.Origin.Y / ray.Direction.Y
	if t <= 0 then return nil end
	return ray.Origin + ray.Direction * t
end

-- Returns a point h studs above the terrain surface under the cursor, so a ghost
-- whose centre is set to this point rests its base on the ground at any elevation.
-- Used by BuildingPlacer so the ghost (and the CC move ghost) track the cursor.
-- Falls back to a flat plane at height h if the cursor isn't over terrain.
function Camera.getPositionAtHeight(h: number): Vector3?
	local surf = raycastTerrain()
	if surf then return Vector3.new(surf.X, surf.Y + h, surf.Z) end
	local ray = mouse.UnitRay
	if math.abs(ray.Direction.Y) < 1e-6 then return nil end
	local t = (h - ray.Origin.Y) / ray.Direction.Y
	if t <= 0 then return nil end
	return ray.Origin + ray.Direction * t
end

return Camera
