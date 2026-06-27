--!strict
--[[
    BarracksPanel — Radial bubble node-graph for training units.

    Root node "BARRACKS" auto-expands to three children when show() is called:
      Soldier (-135°)  ·  Tank (-90°)  ·  Elite (-45°)

    Training state is shown inline on the root node label.
    All network calls and logic are preserved unchanged.
]]

local Players      = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local UILib             = require(script.Parent:WaitForChild("UILib"))
local ViewportPreview   = require(script.Parent:WaitForChild("ViewportPreview"))
local CommandCard       = require(script.Parent:WaitForChild("CommandCard"))
local UnitVisuals       = require(Shared:WaitForChild("UnitVisuals"))

local OWNER = "barracks"

local BarracksPanel  = {}
local localPlayer    = Players.LocalPlayer
local C              = UILib.C

-- ── State ─────────────────────────────────────────────────────────────────────
local activeBarracksId: string? = nil
local networkRef:       any
local hasResearchFn:    ((string) -> boolean)?
local getMultiIdsFn:    (() -> {string})?

local lastTrainingState: { [string]: { queue: {string}, progress: number } } = {}
local lastQueueKeys:     { [string]: string  } = {}   -- barrackId -> "Soldier,Tank,..." for diff-check

-- ── 3D training model state ───────────────────────────────────────────────────
-- One Model per barracks showing the unit being assembled on the training pad.
-- PAD_Y_ABOVE_BOTTOM: world-Y offset from the building's ground level to the top of
-- the training pad neon surface (matches the 0.2-tall pad sitting on the 0.7 floor).
local TRAIN_PAD_Y = 0.9

local trainingModels:     { [string]: Model  } = {}
local trainingModelTypes: { [string]: string } = {}

local function destroyTrainingModel(barrackId: string)
	local m = trainingModels[barrackId]
	if m and m.Parent then m:Destroy() end
	trainingModels[barrackId]     = nil
	trainingModelTypes[barrackId] = nil
end

function BarracksPanel.cleanupAllTrainingModels()
	for id in trainingModels do destroyTrainingModel(id) end
end

local function updateTrainingVisual3D(barrackId: string, queue: {string}, progress: number)
	if #queue == 0 then
		destroyTrainingModel(barrackId)
		return
	end

	local unitType = queue[1]

	-- Locate the barracks base part
	local bf    = workspace:FindFirstChild("Buildings") :: Folder?
	local bldg  = bf and bf:FindFirstChild(barrackId)
	local base  = bldg and bldg:FindFirstChild("Base") :: BasePart?
	if not base then destroyTrainingModel(barrackId); return end

	-- Rebuild model when unit type changes
	if trainingModelTypes[barrackId] ~= unitType then
		destroyTrainingModel(barrackId)
	end

	-- Create model on first appearance
	if not trainingModels[barrackId] then
		local m = Instance.new("Model")
		m.Name  = "_BarracksTrain_" .. barrackId
		UnitVisuals.buildUnitPreview(m, unitType)

		-- PrimaryPart: the body (named after the unit type) or any BasePart
		local primary: BasePart?
		for _, child in m:GetChildren() do
			if child:IsA("BasePart") and child.Name == unitType then
				primary = child :: BasePart; break
			end
		end
		if not primary then
			for _, child in m:GetChildren() do
				if child:IsA("BasePart") then primary = child :: BasePart; break end
			end
		end
		if not primary then m:Destroy(); return end

		m.PrimaryPart = primary
		m.Parent      = workspace
		trainingModels[barrackId]     = m
		trainingModelTypes[barrackId] = unitType

		-- Auto-clean when the barracks is destroyed mid-training
		local conn: RBXScriptConnection
		conn = base.Destroying:Connect(function()
			conn:Disconnect()
			destroyTrainingModel(barrackId)
		end)
	end

	local model = trainingModels[barrackId]
	if not model or not model.Parent then return end

	-- Smoothstep for a gradual ease-in from underground
	local eased = progress * progress * (3 - 2 * progress)

	local buildingBottom = base.Position.Y - base.Size.Y / 2
	local padTop         = buildingBottom + TRAIN_PAD_Y
	local bottomOffset   = UnitVisuals.getUnitPreviewBottomOffset(unitType)

	-- Rise: starts 3 studs underground, reaches resting position at progress=1
	local centreY = padTop + bottomOffset + (eased - 1) * 3

	model:PivotTo(CFrame.new(base.Position.X, centreY, base.Position.Z))

	-- Ghost transparency: nearly invisible at start, solid at end
	local trans = 0.78 * (1 - eased)
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			(part :: BasePart).Transparency = trans
		end
	end
end

local UNIT_ICON: { [string]: string } = {
	Soldier       = "⚔",
	Tank          = "⬡",
	Howitzer      = "💣",
	Elite         = "★",
	Medic         = "✚",
	Foamer        = "🫧",
	Lamprey       = "🪱",
	CreepySoldier = "🪲",
}
local UNIT_COLOR: { [string]: Color3 } = {
	Soldier       = C.GREEN,
	Tank          = C.BARRACKS,
	Howitzer      = Color3.fromRGB(138, 168,  52),
	Elite         = Color3.fromRGB(160,  80, 230),
	Medic         = Color3.fromRGB( 50, 200, 160),
	Foamer        = Color3.fromRGB(160, 220, 255),
	Lamprey       = Color3.fromRGB(120, 190,  60),
	CreepySoldier = Color3.fromRGB( 50, 170,  80),
}

-- ── Unit definitions ──────────────────────────────────────────────────────────
local PURPLE       = Color3.fromRGB(160,  80, 230)
local MEDIC_TEAL   = Color3.fromRGB( 50, 200, 160)
local HOWITZER_OLV = Color3.fromRGB(138, 168,  52)
local FOAM_BLUE    = Color3.fromRGB(160, 220, 255)
local LAMPREY_GRN  = Color3.fromRGB(120, 190,  60)

type UnitDef = {
	key:   string,
	label: string,
	icon:  string,
	color: Color3,
	cost:  number,
	angle: number,
}

local UNIT_DEFS: { UnitDef } = {
	{ key = "Soldier",  label = "Soldier\n◆ 25",   icon = "⚔",  color = C.GREEN,      cost = 25,  angle = -135 },
	{ key = "Tank",     label = "Tank\n◆ 60",       icon = "⬡",  color = C.BARRACKS,   cost = 60,  angle = -90  },
	{ key = "Howitzer", label = "Howitzer\n◆ 90",   icon = "💣", color = HOWITZER_OLV, cost = 90,  angle = -45  },
	{ key = "Elite",    label = "Elite\n◆ 100",     icon = "★",  color = PURPLE,       cost = 100, angle = 0    },
	{ key = "Medic",    label = "Medic\n◆ 60",      icon = "✚",  color = MEDIC_TEAL,   cost = 60,  angle = 45   },
	{ key = "Foamer",   label = "Foamer\n◆ 80",     icon = "🫧", color = FOAM_BLUE,    cost = 80,  angle = 90   },
	-- Lamprey is now born at the Lamprey Nest, not trained here.
}

-- Research gate per unit key (nil = always available).
local RESEARCH_GATE: { [string]: string } = {
	Elite = "EliteUnits",
	Medic = "MedicUnit",
}

-- ── Command-card page builder ───────────────────────────────────────────────────
local function buildPage(): CommandCard.Page
	local state    = activeBarracksId and lastTrainingState[activeBarracksId]
	local queue    = state and state.queue or {}
	local progress = state and state.progress or 0
	local active   = queue[1]

	-- Count how many of each type are queued (for a slot badge).
	local counts: { [string]: number } = {}
	for _, ut in queue do counts[ut] = (counts[ut] or 0) + 1 end

	local slots: { CommandCard.Slot } = {}
	for i, def in UNIT_DEFS do
		local key    = def.key
		local gate   = RESEARCH_GATE[key]
		local locked = gate ~= nil and not (hasResearchFn and hasResearchFn(gate))
		local n      = counts[key] or 0
		table.insert(slots, {
			index           = i,
			name            = key:upper(),
			cost            = def.cost,
			color           = def.color,
			locked          = locked,
			icon            = def.icon,
			viewportKey     = "unit:" .. key,
			viewportFactory = function() return ViewportPreview.forUnit(key, Vector2.new(64, 64)) end,
			desc            = locked and "Locked — research required" or ("Train " .. key),
			progress        = (key == active) and progress or nil,
			badge           = n > 0 and tostring(n) or nil,
			onClick         = function()
				if not activeBarracksId then return end
				if locked then return end
				local ids = getMultiIdsFn and getMultiIdsFn() or { activeBarracksId }
				networkRef.trainUnit(ids, key)
			end,
		})
	end
	return { header = "BARRACKS", slots = slots }
end

local function renderIfActive()
	if activeBarracksId and CommandCard.isOwner(OWNER) then
		CommandCard.update(OWNER, buildPage())
	end
end

-- ── World-space queue display (icons + progress bar above barracks) ──────────
local ICON_W = 26
local ICON_H = 26
local ICON_P = 3   -- padding between icons
local BAR_H  = 2

local function updateWorldQueueDisplay(barrackId: string, queue: {string}, progress: number)
	local bf = workspace:FindFirstChild("Buildings")
	if not bf then return end
	local model = bf:FindFirstChild(barrackId)
	if not model then return end
	local base = model:FindFirstChild("Base") :: BasePart?
	if not base then return end

	-- Remove legacy TrainBar if present
	local old = base:FindFirstChild("TrainBar")
	if old then old:Destroy() end

	local bb = base:FindFirstChild("QueueDisplay") :: BillboardGui?

	if #queue == 0 then
		if bb then bb:Destroy() end
		lastQueueKeys[barrackId] = nil
		return
	end

	local newKey     = table.concat(queue, ",")
	local needRebuild = (bb == nil) or (lastQueueKeys[barrackId] ~= newKey)
	lastQueueKeys[barrackId] = newKey

	if needRebuild then
		if bb then bb:Destroy() end

		local n      = #queue
		local rowW   = n * ICON_W + (n - 1) * ICON_P
		local totalW = math.max(rowW, 70)
		local totalH = ICON_H + 4 + BAR_H

		bb                 = Instance.new("BillboardGui")
		bb.Name            = "QueueDisplay"
		bb.Size            = UDim2.fromOffset(totalW, totalH)
		bb.StudsOffset     = Vector3.new(0, base.Size.Y / 2 + 6, 0)
		bb.AlwaysOnTop     = false
		bb.LightInfluence  = 0
		bb.Parent          = base

		-- Icon row (centered horizontally in the billboard)
		local row                    = Instance.new("Frame")
		row.Name                     = "IconRow"
		row.Size                     = UDim2.fromOffset(rowW, ICON_H)
		row.Position                 = UDim2.fromOffset((totalW - rowW) / 2, 0)
		row.BackgroundTransparency   = 1
		row.BorderSizePixel          = 0
		row.Parent                   = bb

		local layout             = Instance.new("UIListLayout")
		layout.FillDirection     = Enum.FillDirection.Horizontal
		layout.Padding           = UDim.new(0, ICON_P)
		layout.SortOrder         = Enum.SortOrder.LayoutOrder
		layout.Parent            = row

		for i, unitType in queue do
			local color    = UNIT_COLOR[unitType] or Color3.fromRGB(120, 120, 120)
			local icon     = UNIT_ICON[unitType]  or "?"
			local isActive = (i == 1)

			local badge                    = Instance.new("Frame")
			badge.Size                     = UDim2.fromOffset(ICON_W, ICON_H)
			badge.BackgroundColor3         = color
			badge.BackgroundTransparency   = isActive and 0.15 or 0.60
			badge.BorderSizePixel          = 0
			badge.LayoutOrder              = i
			badge.Parent                   = row
			UILib.corner(badge, 7)

			if isActive then
				UILib.stroke(badge, color, 1.5)
			end

			local lbl                  = Instance.new("TextLabel")
			lbl.Size                   = UDim2.new(1, 0, 1, 0)
			lbl.BackgroundTransparency = 1
			lbl.Text                   = icon
			lbl.TextScaled             = true
			lbl.Font                   = Enum.Font.GothamBold
			lbl.TextColor3             = Color3.new(1, 1, 1)
			lbl.TextTransparency       = isActive and 0 or 0.35
			lbl.Parent                 = badge
		end

		-- Progress bar
		local track                    = Instance.new("Frame")
		track.Name                     = "ProgTrack"
		track.Size                     = UDim2.fromOffset(totalW, BAR_H)
		track.Position                 = UDim2.fromOffset(0, ICON_H + 4)
		track.BackgroundColor3         = Color3.fromRGB(10, 12, 22)
		track.BackgroundTransparency   = 0.25
		track.BorderSizePixel          = 0
		track.Parent                   = bb
		UILib.corner(track, 1)
		local tStroke                  = UILib.stroke(track, Color3.fromRGB(0, 0, 0), 1)
		tStroke.Transparency           = 0.35

		local fill                 = Instance.new("Frame")
		fill.Name                  = "Fill"
		fill.Size                  = UDim2.new(math.clamp(progress, 0, 1), 0, 1, 0)
		fill.BackgroundColor3      = UNIT_COLOR[queue[1]] or C.ACCENT
		fill.BorderSizePixel       = 0
		fill.Parent                = track
		UILib.corner(fill, 1)
	else
		-- Queue unchanged — only update progress fill
		local track = bb:FindFirstChild("ProgTrack") :: Frame?
		if track then
			local fill = track:FindFirstChild("Fill") :: Frame?
			if fill then fill.Size = UDim2.new(math.clamp(progress, 0, 1), 0, 1, 0) end
		end
	end
end

-- ── Init ──────────────────────────────────────────────────────────────────────
function BarracksPanel.init(network, hasResearch, getMultiIds)
	networkRef    = network
	hasResearchFn = hasResearch
	getMultiIdsFn = getMultiIds

	-- ── Training update listener ───────────────────────────────────────────────
	network.onTrainingUpdate(function(barrackId: string, queue: {string}, progress: number)
		lastTrainingState[barrackId] = { queue = queue, progress = progress }
		updateWorldQueueDisplay(barrackId, queue, progress)
		updateTrainingVisual3D(barrackId, queue, progress)
		if barrackId == activeBarracksId then
			renderIfActive()
		end
	end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function BarracksPanel.show(barrackId: string)
	activeBarracksId = barrackId
	CommandCard.show(OWNER, buildPage())
end

function BarracksPanel.hide()
	activeBarracksId = nil
	CommandCard.hide(OWNER)
end

function BarracksPanel.refreshIfVisible()
	renderIfActive()
end

function BarracksPanel.isVisible(): boolean
	return activeBarracksId ~= nil and CommandCard.isOwner(OWNER)
end

return BarracksPanel
