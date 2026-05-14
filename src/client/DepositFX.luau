--!strict
-- DepositFX — client-side periodic glimmer effects for mushroom deposit clusters.
-- Uses TweenService only (no ParticleEmitters) for cross-device performance.
-- Optimizations: 10 Hz scan, camera distance cull, reduced rate on mobile.

local RunService       = game:GetService("RunService")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local DepositFX = {}

local isMobile    = UserInputService.TouchEnabled
local CULL_DIST   = isMobile and 100  or 140   -- studs; skip deposits beyond this
local BASE_CHANCE = isMobile and 0.015 or 0.028 -- probability per deposit per 0.1 s tick
local TICK_RATE   = 0.10                         -- seconds between scans (10 Hz)

local FLASH_COLOR = Color3.fromRGB(240, 185, 255) -- near-white lavender spike
local FLASH_TI    = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FADE_TI     = TweenInfo.new(0.60, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Per-cap cache populated on first flash; guards against mid-tween reads
local origColors: { [BasePart]: Color3  } = {}
local origSizes:  { [BasePart]: Vector3 } = {}

local conn:    RBXScriptConnection?
local started  = false
local accum    = 0

-- Collect the neon cap parts from a deposit model
local function getCaps(model: Model): { BasePart }
	local out = {}
	for _, p in model:GetChildren() do
		if p:IsA("BasePart") and p.Material == Enum.Material.Neon and p.Transparency < 0.5 then
			table.insert(out, p)
		end
	end
	return out
end

-- Find the PointLight carried by the cluster's invisible glow part
local function getLight(model: Model): PointLight?
	for _, p in model:GetChildren() do
		if p:IsA("BasePart") and p.Transparency >= 0.99 then
			local l = p:FindFirstChildWhichIsA("PointLight")
			if l then return l :: PointLight end
		end
	end
	return nil
end

local function flashCap(cap: BasePart, light: PointLight?)
	-- Populate cache before any tween mutates these values
	if not origColors[cap] then origColors[cap] = cap.Color end
	if not origSizes[cap]  then origSizes[cap]  = cap.Size  end

	local oColor = origColors[cap]
	local oSize  = origSizes[cap]

	-- Snap to bright white-lavender, then ease back to original purple
	TweenService:Create(cap, FLASH_TI, { Color = FLASH_COLOR, Size = oSize * 1.10 }):Play()
	task.delay(FLASH_TI.Time, function()
		if not cap.Parent then return end
		TweenService:Create(cap, FADE_TI, { Color = oColor, Size = oSize }):Play()
	end)

	-- Pulse the cluster's ambient point light in sync
	if light then
		TweenService:Create(light, FLASH_TI, { Brightness = 9, Range = 30 }):Play()
		task.delay(FLASH_TI.Time, function()
			if not light.Parent then return end
			TweenService:Create(light, FADE_TI, { Brightness = 3, Range = 20 }):Play()
		end)
	end
end

function DepositFX.start()
	if started then return end
	started = true

	task.spawn(function()
		local folder = workspace:WaitForChild("Deposits", 60)
		if not folder then return end

		conn = RunService.Heartbeat:Connect(function(dt: number)
			accum += dt
			if accum < TICK_RATE then return end
			accum -= TICK_RATE

			local cam = workspace.CurrentCamera
			if not cam then return end
			local camPos = cam.CFrame.Position

			for _, model in (folder :: Folder):GetChildren() do
				if not model:IsA("Model") then continue end
				local primary = model.PrimaryPart
				if not primary then continue end
				-- Distance cull — skip clusters the camera can't see closely
				if (primary.Position - camPos).Magnitude > CULL_DIST then continue end
				-- Stochastic gate — each cluster glimmers independently
				if math.random() > BASE_CHANCE then continue end

				local caps = getCaps(model :: Model)
				if #caps == 0 then continue end
				flashCap(caps[math.random(1, #caps)], getLight(model :: Model))
			end
		end)
	end)
end

function DepositFX.stop()
	if conn then conn:Disconnect(); conn = nil end
	origColors = {}
	origSizes  = {}
	accum      = 0
	started    = false
end

return DepositFX
