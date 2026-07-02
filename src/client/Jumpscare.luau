--!strict
--[[
	Jumpscare — press F and a lamprey erupts out of the dark, lunges at the screen
	with its maw flaring open, and swallows the camera (cut to black), then fades
	back to the game.

	Fully self-contained: a full-screen ViewportFrame with a bespoke lamprey head
	(matching LampreyBody's palette) that we drive frame-by-frame — the head hurtles
	toward the viewport camera while its mouth opens. No game state is touched; the
	real camera is never moved.
]]

local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris       = game:GetService("Debris")

local Jumpscare = {}

-- Lamprey palette (matches LampreyBody so it reads as the same creature).
local C_BODY   = Color3.fromRGB( 40,  44,  52)
local C_TOOTH  = Color3.fromRGB(228, 226, 210)
local C_MAW    = Color3.fromRGB(150,  24,  28)
local C_GULLET = Color3.fromRGB( 46,   6,   8)
local C_EYE    = Color3.fromRGB(255, 230,  40)

-- Loud sting on impact (lamprey death shriek).
local SCREAM_ID = "rbxassetid://135417409504018"

local N_TEETH  = 11
local MAW_SIZE = Vector3.new(3.4, 3.4, 3.4)

-- ── State ──────────────────────────────────────────────────────────────────────
local overlay:  ScreenGui?  = nil
local vpf:      ViewportFrame
local blackout: Frame
local head:     BasePart
local maw:      BasePart
local snout:    BasePart
local eyes:     { BasePart } = {}
local teeth:    { BasePart } = {}
local SNOUT_OFF: CFrame
local EYE_OFF:   { CFrame } = {}
local active = false

-- ── Helpers ──────────────────────────────────────────────────────────────────
local function mk(size: Vector3, color: Color3, material: Enum.Material, shape: Enum.PartType?): BasePart
	local p = Instance.new("Part")
	if shape then (p :: any).Shape = shape end
	p.Size        = size
	p.Color       = color
	p.Material    = material
	p.Anchored    = true
	p.CanCollide  = false
	p.CanQuery    = false
	p.CastShadow  = false
	p.Parent      = vpf
	return p
end

-- Orient a box so its local Y axis runs from world point a → b (length along Y).
local function orientYBetween(part: BasePart, a: Vector3, b: Vector3, thick: number)
	local delta = b - a
	local len   = delta.Magnitude
	if len < 0.04 then return end
	local dir   = delta / len
	local right = dir:Cross(Vector3.yAxis)
	if right.Magnitude < 0.01 then right = dir:Cross(Vector3.xAxis) end
	right = right.Unit
	local back = right:Cross(dir)
	part.CFrame = CFrame.fromMatrix((a + b) * 0.5, right, dir, -back)
	part.Size   = Vector3.new(thick, len, thick)
end

-- Positions every part for the given lunge depth (lz, negative = deeper) and mouth
-- openness (0..1). Local +Z faces the viewport camera (the mouth points at you).
local function layout(lz: number, mouthOpen: number, shakeRot: CFrame)
	local headCF = CFrame.new(0, 0, lz) * shakeRot
	head.CFrame  = headCF
	snout.CFrame = headCF * SNOUT_OFF
	eyes[1].CFrame = headCF * EYE_OFF[1]
	eyes[2].CFrame = headCF * EYE_OFF[2]

	-- Gullet bulges forward and swells as the maw gapes.
	maw.Size   = MAW_SIZE * (1 + mouthOpen * 0.75)
	maw.CFrame = headCF * CFrame.new(0, -0.2, 1.4 + mouthOpen * 1.3)

	-- Fang ring: teeth hinge off a fixed mouth rim and splay out + forward as it opens.
	local RIM_R, RIM_FWD = 1.75, 2.0
	local tipR = RIM_R * (1 + mouthOpen * 1.15)
	local tipF = RIM_FWD + 0.5 + mouthOpen * 1.7
	for k, tooth in teeth do
		local a  = ((k - 0.5) / N_TEETH) * math.pi * 2
		local c, s = math.cos(a), math.sin(a)
		local baseP = (headCF * CFrame.new(c * RIM_R, s * RIM_R, RIM_FWD)).Position
		local tipP  = (headCF * CFrame.new(c * tipR,  s * tipR,  tipF)).Position
		orientYBetween(tooth, baseP, tipP, 0.34)
	end
end

-- ── Public API ──────────────────────────────────────────────────────────────
function Jumpscare.init(playerGui: Instance)
	if overlay then return end

	local sg               = Instance.new("ScreenGui")
	sg.Name                = "LampreyJumpscare"
	sg.ResetOnSpawn        = false
	sg.IgnoreGuiInset      = true
	sg.DisplayOrder        = 5000        -- above everything
	sg.Enabled             = false
	sg.Parent              = playerGui
	overlay = sg

	local frame            = Instance.new("ViewportFrame")
	frame.Size             = UDim2.fromScale(1, 1)
	frame.BackgroundColor3  = Color3.fromRGB(4, 3, 6)   -- emerges out of near-black
	frame.BackgroundTransparency = 0
	frame.BorderSizePixel  = 0
	frame.Ambient          = Color3.fromRGB(70, 66, 74)
	frame.LightColor       = Color3.fromRGB(180, 170, 175)
	frame.LightDirection   = Vector3.new(0, -0.3, 1)    -- lit from the camera side
	frame.Parent           = sg
	vpf = frame

	local cam              = Instance.new("Camera")
	cam.FieldOfView        = 72
	cam.CFrame             = CFrame.new()               -- at origin, looking down -Z
	cam.Parent             = frame
	frame.CurrentCamera    = cam

	-- Head (elongated eel skull), snout ridge, glowing eyes.
	head  = mk(Vector3.new(5.6, 4.7, 6.6), C_BODY, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	snout = mk(Vector3.new(2.6, 1.3, 3.4), C_BODY, Enum.Material.SmoothPlastic)
	SNOUT_OFF = CFrame.new(0, 1.15, 1.7)
	for i = 1, 2 do
		eyes[i]   = mk(Vector3.new(1.15, 1.15, 1.15), C_EYE, Enum.Material.Neon, Enum.PartType.Ball)
		EYE_OFF[i] = CFrame.new((i == 1 and -1.75 or 1.75), 0.95, 1.2)
	end

	-- Gullet + fang ring (driven each frame in layout).
	maw = mk(MAW_SIZE, C_GULLET, Enum.Material.Neon, Enum.PartType.Ball)
	for _ = 1, N_TEETH do
		table.insert(teeth, mk(Vector3.new(0.34, 1, 0.34), C_TOOTH, Enum.Material.SmoothPlastic))
	end

	-- Full-screen black used for the "camera eaten" cut and the fade back.
	local bo               = Instance.new("Frame")
	bo.Size                = UDim2.fromScale(1, 1)
	bo.BackgroundColor3    = Color3.new(0, 0, 0)
	bo.BackgroundTransparency = 1
	bo.BorderSizePixel     = 0
	bo.ZIndex              = 10
	bo.Parent              = sg
	blackout = bo

	layout(-22, 0, CFrame.identity)   -- pose it lurking far back, mouth shut
end

-- Play the jumpscare (ignored if one is already running).
function Jumpscare.trigger()
	if active or not overlay then return end
	active = true

	local sg = overlay :: ScreenGui
	blackout.BackgroundTransparency = 1
	vpf.Visible = true
	sg.Enabled  = true

	local scream        = Instance.new("Sound")
	scream.SoundId      = SCREAM_ID
	scream.Volume       = 4
	scream.PlaybackSpeed = 0.9
	scream.Parent       = sg
	scream:Play()
	Debris:AddItem(scream, 5)

	local DUR     = 0.55
	local START_Z = -22
	local END_Z   = -2.4
	local elapsed = 0
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		local t = math.clamp(elapsed / DUR, 0, 1)

		-- Accelerating lunge (t² eases in) + mouth gaping open + growing shake.
		local lz        = START_Z + (END_Z - START_Z) * (t * t)
		local mouthOpen = math.clamp(t * 1.35, 0, 1)
		local sh        = 0.14 * t
		local shakeRot  = CFrame.Angles(
			(math.random() - 0.5) * sh * 2,
			(math.random() - 0.5) * sh * 2,
			(math.random() - 0.5) * sh)
		layout(lz, mouthOpen, shakeRot)

		-- Last stretch: the maw swallows the lens → black.
		if t > 0.85 then
			blackout.BackgroundTransparency = 1 - (t - 0.85) / 0.15
		end

		if t >= 1 then
			conn:Disconnect()
			blackout.BackgroundTransparency = 0
			vpf.Visible = false                 -- hide the model behind the black
			-- Hold in the dark, then fade back to the game.
			task.delay(0.35, function()
				local tw = TweenService:Create(blackout,
					TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ BackgroundTransparency = 1 })
				tw:Play()
				tw.Completed:Once(function()
					sg.Enabled = false
					layout(START_Z, 0, CFrame.identity)   -- reset for next time
					active = false
				end)
			end)
		end
	end)
end

return Jumpscare
