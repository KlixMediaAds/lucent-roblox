local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))

local Camera    = {}
local cam       = workspace.CurrentCamera
local mouse     = Players.LocalPlayer:GetMouse()

local focus     = Vector3.new(0, 0, 0)
local zoom      = 80
local yaw       = 0   -- degrees

local midDrag   = false
local lastMouse = Vector2.zero

local function apply()
	local yr = math.rad(yaw)
	local pr = math.rad(Config.CAMERA_PITCH)
	local offset = Vector3.new(
		math.sin(yr) * math.cos(pr) * zoom,
		math.sin(pr) * zoom,
		math.cos(yr) * math.cos(pr) * zoom
	)
	cam.CFrame = CFrame.new(focus + offset, focus)
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
			zoom = math.clamp(
				zoom - input.Position.Z * Config.CAMERA_ZOOM_STEP,
				Config.CAMERA_ZOOM_MIN,
				Config.CAMERA_ZOOM_MAX
			)
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
		local yr  = math.rad(yaw)
		local fwd = Vector3.new(-math.sin(yr), 0, -math.cos(yr))
		local rgt = Vector3.new( math.cos(yr), 0, -math.sin(yr))
		local spd = Config.CAMERA_MOVE_SPEED * dt
		local vp  = cam.ViewportSize
		local mp  = UserInputService:GetMouseLocation()
		local thr = Config.CAMERA_EDGE_THRESHOLD
		local move = Vector3.zero

		if UserInputService:IsKeyDown(Enum.KeyCode.W) or mp.Y < thr            then move += fwd end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) or mp.Y > vp.Y - thr     then move -= fwd end
		if UserInputService:IsKeyDown(Enum.KeyCode.A) or mp.X < thr            then move -= rgt end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) or mp.X > vp.X - thr     then move += rgt end
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

-- Returns the world position on the y=0 ground plane under the cursor.
-- Uses Mouse.UnitRay which Roblox resolves internally, avoiding the
-- coordinate-space mismatch between GetMouseLocation and ScreenPointToRay.
function Camera.getGroundPosition(): Vector3?
	local ray = mouse.UnitRay
	if math.abs(ray.Direction.Y) < 1e-6 then return nil end
	local t = -ray.Origin.Y / ray.Direction.Y
	if t <= 0 then return nil end
	return ray.Origin + ray.Direction * t
end

-- Intersect the cursor ray with an arbitrary horizontal plane at height h.
-- Used by BuildingPlacer so the ghost center (not its base) tracks the cursor.
function Camera.getPositionAtHeight(h: number): Vector3?
	local ray = mouse.UnitRay
	if math.abs(ray.Direction.Y) < 1e-6 then return nil end
	local t = (h - ray.Origin.Y) / ray.Direction.Y
	if t <= 0 then return nil end
	return ray.Origin + ray.Direction * t
end

return Camera
