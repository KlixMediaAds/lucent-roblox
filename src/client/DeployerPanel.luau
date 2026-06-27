--!strict
--[[
    DeployerPanel — Radial identity selector for Deployer buildings.

    Clicking a Deployer opens a radial menu identical in style to BarracksPanel.
    Selecting a unit type sends SetDeployerType to the server; the deployer will
    free-spawn that unit every DEPLOYER_SPAWN_INTERVAL seconds.

    World display (matches Signal Flare method):
      • BillboardGui on the deployer base  — slim progress bar (spawn countdown).
      • ScreenGui overlay entry per deployer — ViewportFrame unit preview icon,
        repositioned each frame via WorldToViewportPoint (same as FlareIconOverlay).
]]

local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local UILib             = require(script.Parent:WaitForChild("UILib"))
local ViewportPreview   = require(script.Parent:WaitForChild("ViewportPreview"))
local CommandCard       = require(script.Parent:WaitForChild("CommandCard"))

local DeployerPanel = {}
local localPlayer   = Players.LocalPlayer
local C             = UILib.C
local OWNER         = "deployer"

-- ── State ─────────────────────────────────────────────────────────────────────
local activeDeployerId: string? = nil
local networkRef:       any
local hasResearchFn:    ((string) -> boolean)?

-- ── Unit definitions ──────────────────────────────────────────────────────────
local PURPLE       = Color3.fromRGB(160,  80, 230)
local MEDIC_TEAL   = Color3.fromRGB( 50, 200, 160)
local HOWITZER_OLV = Color3.fromRGB(138, 168,  52)
local FOAM_BLUE    = Color3.fromRGB(160, 220, 255)

type UnitDef = { key: string, label: string, icon: string, color: Color3, angle: number }

local UNIT_DEFS: { UnitDef } = {
	{ key = "Soldier",  label = "Soldier",  icon = "⚔",  color = C.GREEN,      angle = -135 },
	{ key = "Tank",     label = "Tank",      icon = "⬡",  color = C.BARRACKS,   angle = -90  },
	{ key = "Howitzer", label = "Howitzer",  icon = "💣", color = HOWITZER_OLV, angle = -45  },
	{ key = "Elite",    label = "Elite",     icon = "★",  color = PURPLE,       angle = 0    },
	{ key = "Medic",    label = "Medic",     icon = "✚",  color = MEDIC_TEAL,   angle = 45   },
	{ key = "Foamer",   label = "Foamer",    icon = "🫧", color = FOAM_BLUE,    angle = 90   },
}

local UNIT_COLOR: { [string]: Color3 } = {
	Soldier  = C.GREEN,
	Tank     = C.BARRACKS,
	Howitzer = HOWITZER_OLV,
	Elite    = PURPLE,
	Medic    = MEDIC_TEAL,
	Foamer   = FOAM_BLUE,
}

-- ── Research gate per unit key ──────────────────────────────────────────────────
local RESEARCH_GATE: { [string]: string } = { Elite = "EliteUnits", Medic = "MedicUnit" }

-- ── World display (Signal Flare method) ───────────────────────────────────────
-- Each deployer gets:
--   • A BillboardGui on its base: slim progress bar (spawn timer 0→1).
--   • A ScreenGui overlay entry: ViewportFrame unit preview, repositioned each
--     frame to sit directly above the progress bar.

local overlaySg: ScreenGui

type DeployerEntry = { anchor: BasePart, frame: Frame }
local deployerEntries:      { [string]: DeployerEntry } = {}
local deployerBillboards:   { [string]: BillboardGui  } = {}
local deployerCurrentTypes: { [string]: string        } = {}

local function getDeployerBase(deployerId: string): BasePart?
	local bf    = workspace:FindFirstChild("Buildings") :: Folder?
	local model = bf and bf:FindFirstChild(deployerId)
	return model and model:FindFirstChild("Base") :: BasePart?
end

local function destroyDeployerDisplay(deployerId: string)
	local bb = deployerBillboards[deployerId]
	if bb and bb.Parent then bb:Destroy() end
	deployerBillboards[deployerId] = nil

	local entry = deployerEntries[deployerId]
	if entry then
		if entry.frame and entry.frame.Parent then entry.frame:Destroy() end
		deployerEntries[deployerId] = nil
	end
	deployerCurrentTypes[deployerId] = nil
end

local function ensureDisplay(deployerId: string, unitType: string)
	local base = getDeployerBase(deployerId)
	if not base then destroyDeployerDisplay(deployerId); return end

	-- BillboardGui: matches signal-flare layout (44 wide × 52 tall, unit icon slot + progress bar)
	local bb = deployerBillboards[deployerId]
	if not bb or not bb.Parent then
		bb              = Instance.new("BillboardGui")
		bb.Name         = "DeployerDisplay"
		bb.Size         = UDim2.fromOffset(44, 52)
		bb.StudsOffset  = Vector3.new(0, base.Size.Y / 2 + 5, 0)
		bb.AlwaysOnTop  = false
		bb.MaxDistance  = 350
		bb.LightInfluence = 0
		bb.Parent       = base
		deployerBillboards[deployerId] = bb

		-- Slim progress bar at the bottom (y = 46, matching signal flare position)
		local track                    = Instance.new("Frame")
		track.Name                     = "ProgTrack"
		track.Size                     = UDim2.new(1, 0, 0, 3)
		track.Position                 = UDim2.fromOffset(0, 46)
		track.BackgroundColor3         = Color3.fromRGB(20, 22, 28)
		track.BackgroundTransparency   = 0.3
		track.BorderSizePixel          = 0
		track.Parent                   = bb
		local ptc = Instance.new("UICorner"); ptc.CornerRadius = UDim.new(1, 0); ptc.Parent = track
		local pts = Instance.new("UIStroke"); pts.Color = Color3.fromRGB(0, 0, 0); pts.Thickness = 1; pts.Transparency = 0.35; pts.Parent = track

		local fill                 = Instance.new("Frame")
		fill.Name                  = "Fill"
		fill.Size                  = UDim2.new(0, 0, 1, 0)
		fill.BackgroundColor3      = C.DEPLOYER
		fill.BorderSizePixel       = 0
		fill.Parent                = track
		local pfc = Instance.new("UICorner"); pfc.CornerRadius = UDim.new(1, 0); pfc.Parent = fill

		base.Destroying:Connect(function() destroyDeployerDisplay(deployerId) end)
	end

	-- ScreenGui overlay entry: rebuild when unit type changes
	if deployerCurrentTypes[deployerId] ~= unitType then
		local old = deployerEntries[deployerId]
		if old then
			if old.frame and old.frame.Parent then old.frame:Destroy() end
			deployerEntries[deployerId] = nil
		end
		deployerCurrentTypes[deployerId] = unitType

		local frame                  = Instance.new("Frame")
		frame.Size                   = UDim2.fromOffset(44, 44)
		frame.AnchorPoint            = Vector2.new(0.5, 1)
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel        = 0
		frame.ZIndex                 = 15
		frame.Visible                = false
		frame.Parent                 = overlaySg

		local vp = ViewportPreview.forUnit(unitType, Vector2.new(38, 38))
		vp.Position = UDim2.fromOffset(3, 3)
		vp.Parent   = frame

		deployerEntries[deployerId] = { anchor = base, frame = frame }
	end
end

local function updateWorldDisplay(deployerId: string, unitType: string, progress: number)
	ensureDisplay(deployerId, unitType)

	local bb = deployerBillboards[deployerId]
	if bb then
		local track = bb:FindFirstChild("ProgTrack") :: Frame?
		if track then
			local fill = track:FindFirstChild("Fill") :: Frame?
			if fill then
				fill.Size             = UDim2.new(math.clamp(progress, 0, 1), 0, 1, 0)
				fill.BackgroundColor3 = UNIT_COLOR[unitType] or C.DEPLOYER
			end
		end
	end
end

-- ── Command-card page ───────────────────────────────────────────────────────────
local function buildPage(): CommandCard.Page
	local current = activeDeployerId and deployerCurrentTypes[activeDeployerId] or "Soldier"
	local slots: { CommandCard.Slot } = {}
	for i, def in UNIT_DEFS do
		local key    = def.key
		local gate   = RESEARCH_GATE[key]
		local locked = gate ~= nil and not (hasResearchFn and hasResearchFn(gate))
		table.insert(slots, {
			index           = i,
			name            = key:upper(),
			color           = def.color,
			locked          = locked,
			icon            = def.icon,
			viewportKey     = "unit:" .. key,
			viewportFactory = function() return ViewportPreview.forUnit(key, Vector2.new(64, 64)) end,
			badge           = (key == current) and "✓" or nil,
			desc            = locked and "Locked — research required" or ("Free-spawn " .. key),
			onClick         = function()
				if not activeDeployerId or locked then return end
				networkRef.setDeployerType(activeDeployerId, key)
				if CommandCard.isOwner(OWNER) then CommandCard.update(OWNER, buildPage()) end
			end,
		})
	end
	return { header = "DEPLOYER", slots = slots }
end

local function renderIfActive()
	if activeDeployerId and CommandCard.isOwner(OWNER) then
		CommandCard.update(OWNER, buildPage())
	end
end

-- ── Init ──────────────────────────────────────────────────────────────────────
function DeployerPanel.init(network, hasResearch)
	networkRef    = network
	hasResearchFn = hasResearch

	-- ScreenGui overlay for per-deployer unit viewport icons
	overlaySg                  = Instance.new("ScreenGui")
	overlaySg.Name             = "DeployerIconOverlay"
	overlaySg.IgnoreGuiInset   = true
	overlaySg.ResetOnSpawn     = false
	overlaySg.ZIndexBehavior   = Enum.ZIndexBehavior.Sibling
	overlaySg.Parent           = localPlayer.PlayerGui

	-- Reposition icons every frame (same technique as FlareIconOverlay in init.client)
	RunService:BindToRenderStep("DeployerIconPositions", Enum.RenderPriority.Camera.Value + 1, function()
		local cam = workspace.CurrentCamera
		for _, entry in deployerEntries do
			if not entry.anchor.Parent then
				entry.frame.Visible = false
				continue
			end
			-- Billboard StudsOffset is (0, base.SizeY/2 + 5, 0); project that world point
			local worldPt = entry.anchor.Position
				+ Vector3.new(0, entry.anchor.Size.Y / 2 + 5, 0)
			local sv, onScreen = cam:WorldToViewportPoint(worldPt)
			if onScreen and sv.Z > 0 then
				entry.frame.Visible  = true
				-- AnchorPoint (0.5, 1): bottom-center of the 44px icon sits at +8px below billboard center,
				-- matching the FlareIconOverlay positioning.
				entry.frame.Position = UDim2.fromOffset(math.floor(sv.X), math.floor(sv.Y + 8))
			else
				entry.frame.Visible = false
			end
		end
	end)

	-- Listen for server updates → drive world display
	network.onDeployerUpdate(function(deployerId: string, unitType: string, progress: number)
		updateWorldDisplay(deployerId, unitType, progress)
		if deployerId == activeDeployerId then
			renderIfActive()
		end
	end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function DeployerPanel.show(deployerId: string)
	activeDeployerId = deployerId
	CommandCard.show(OWNER, buildPage())
end

function DeployerPanel.hide()
	activeDeployerId = nil
	CommandCard.hide(OWNER)
end

function DeployerPanel.refreshIfVisible()
	renderIfActive()
end

function DeployerPanel.isVisible(): boolean
	return activeDeployerId ~= nil and CommandCard.isOwner(OWNER)
end

return DeployerPanel
