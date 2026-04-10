--!strict
--[[
    BarracksPanel — Radial bubble node-graph for training units.

    Root node "BARRACKS" auto-expands to three children when show() is called:
      Soldier (-135°)  ·  Tank (-90°)  ·  Elite (-45°)

    Training state is shown inline on the root node label.
    All network calls and logic are preserved unchanged.
]]

local Players      = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UILib             = require(script.Parent:WaitForChild("UILib"))

local BarracksPanel  = {}
local localPlayer    = Players.LocalPlayer
local C              = UILib.C

-- ── State ─────────────────────────────────────────────────────────────────────
local activeBarracksId: string? = nil
local networkRef:       any
local hasResearchFn:    ((string) -> boolean)?

local lastTrainingState: { [string]: { queue: {string}, progress: number } } = {}

-- Root node label ref (shows training state inline)
local rootLbl: TextLabel?

-- Overlay instances
local overlay:  Frame?
local rootNode: TextButton?

-- ── Unit definitions ──────────────────────────────────────────────────────────
local PURPLE     = Color3.fromRGB(160, 80, 230)
local MEDIC_TEAL = Color3.fromRGB(50, 200, 160)

type UnitDef = {
	key:   string,
	label: string,
	icon:  string,
	color: Color3,
	cost:  number,
	angle: number,
}

local UNIT_DEFS: { UnitDef } = {
	{ key = "Soldier", label = "Soldier\n◆ 25",  icon = "⚔", color = C.GREEN,    cost = 25,  angle = -135 },
	{ key = "Tank",    label = "Tank\n◆ 60",      icon = "⬡", color = C.BARRACKS, cost = 60,  angle = -90  },
	{ key = "Elite",   label = "Elite\n◆ 100",    icon = "★", color = PURPLE,     cost = 100, angle = -45  },
	{ key = "Medic",   label = "Medic\n◆ 60",     icon = "✚", color = MEDIC_TEAL, cost = 60,  angle = 0    },
}

local RADIUS   = 155  -- px from root centre to child centre
local ROOT_POS = UDim2.new(0.5, 0, 0.68, 0)

-- ── Radial node refs ──────────────────────────────────────────────────────────
type ChildNode = {
	wrapper:  Frame,
	btn:      TextButton,
	line:     Frame,
	stroke:   UIStroke,
	label:    TextLabel,
	key:      string,
	finalPos: UDim2,
	startPos: UDim2,
}
local childNodes: { ChildNode } = {}

-- ── Expand / collapse ─────────────────────────────────────────────────────────
local EXPAND_TI   = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local COLLAPSE_TI = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local function expandNodes()
	for _, c in childNodes do
		c.wrapper.Visible             = true
		c.wrapper.Position            = c.startPos
		c.btn.BackgroundTransparency  = 1
		c.line.BackgroundTransparency = 1
		TweenService:Create(c.wrapper, EXPAND_TI, { Position = c.finalPos }):Play()
		TweenService:Create(c.btn,     EXPAND_TI, { BackgroundTransparency = 0.35 }):Play()
		TweenService:Create(c.line,    EXPAND_TI, { BackgroundTransparency = 0.65 }):Play()
	end
end

local function collapseNodes(then_: (() -> ())?)
	for _, c in childNodes do
		TweenService:Create(c.wrapper, COLLAPSE_TI, { Position = c.startPos }):Play()
		TweenService:Create(c.btn,     COLLAPSE_TI, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(c.line,    COLLAPSE_TI, { BackgroundTransparency = 1 }):Play()
	end
	task.delay(COLLAPSE_TI.Time, function()
		for _, c in childNodes do c.wrapper.Visible = false end
		if then_ then then_() end
	end)
end

-- ── Research-gated node refresh ───────────────────────────────────────────────
-- Refreshes the locked/unlocked appearance of Elite and Medic nodes.
local function refreshResearchNodes()
	for _, c in childNodes do
		if c.key == "Elite" then
			local unlocked = hasResearchFn and hasResearchFn("EliteUnits") or false
			if unlocked then
				c.btn.BackgroundColor3       = PURPLE
				c.btn.BackgroundTransparency = 0.35
				c.stroke.Color               = PURPLE
				c.stroke.Thickness           = 2
				c.label.TextColor3           = C.TEXT
			else
				c.btn.BackgroundColor3       = C.BG_LOCKED
				c.btn.BackgroundTransparency = 0.3
				c.stroke.Color               = C.BORDER_LO
				c.stroke.Thickness           = 1.5
				c.label.Text                 = "Elite\nLocked"
				c.label.TextColor3           = C.DIM
			end
		elseif c.key == "Medic" then
			local unlocked = hasResearchFn and hasResearchFn("MedicUnit") or false
			if unlocked then
				c.btn.BackgroundColor3       = MEDIC_TEAL
				c.btn.BackgroundTransparency = 0.35
				c.stroke.Color               = MEDIC_TEAL
				c.stroke.Thickness           = 2
				c.label.TextColor3           = C.TEXT
			else
				c.btn.BackgroundColor3       = C.BG_LOCKED
				c.btn.BackgroundTransparency = 0.3
				c.stroke.Color               = C.BORDER_LO
				c.stroke.Thickness           = 1.5
				c.label.Text                 = "Medic\nLocked"
				c.label.TextColor3           = C.DIM
			end
		end
	end
end

-- ── Root label update ─────────────────────────────────────────────────────────
local function updateRootLabel(queue: {string}, progress: number)
	if not rootLbl then return end
	if #queue > 0 then
		rootLbl.Text = "BARRACKS\n" .. queue[1] .. " " .. math.floor(progress * 100) .. "%"
	else
		rootLbl.Text = "BARRACKS"
	end
end

-- ── World-space training bar (above barracks in 3D) ───────────────────────────
local function updateWorldTrainBar(barrackId: string, queue: {string}, progress: number)
	local bf = workspace:FindFirstChild("Buildings")
	if not bf then return end
	local model = bf:FindFirstChild(barrackId)
	if not model then return end
	local base = model:FindFirstChild("Base") :: BasePart?
	if not base then return end

	local bb = base:FindFirstChild("TrainBar") :: BillboardGui?

	if #queue == 0 then
		if bb then bb:Destroy() end
		return
	end

	if not bb then
		bb             = Instance.new("BillboardGui")
		bb.Name        = "TrainBar"
		bb.Size        = UDim2.fromOffset(70, 6)
		bb.StudsOffset = Vector3.new(0, base.Size.Y / 2 + 4.5, 0)
		bb.AlwaysOnTop = false
		bb.Parent      = base

		local track                = Instance.new("Frame")
		track.Size                 = UDim2.new(1, 0, 1, 0)
		track.BackgroundColor3     = Color3.fromRGB(10, 12, 22)
		track.BorderSizePixel      = 0
		track.Parent               = bb
		UILib.corner(track, 2)

		local fill                 = Instance.new("Frame")
		fill.Name                  = "Fill"
		fill.Size                  = UDim2.new(0, 0, 1, 0)
		fill.BackgroundColor3      = C.ACCENT
		fill.BorderSizePixel       = 0
		fill.Parent                = track
		UILib.corner(fill, 2)
	end

	local track = bb:FindFirstChildWhichIsA("Frame") :: Frame?
	if track then
		local fill = track:FindFirstChild("Fill") :: Frame?
		if fill then fill.Size = UDim2.new(math.clamp(progress, 0, 1), 0, 1, 0) end
	end
end

-- ── Init ──────────────────────────────────────────────────────────────────────
function BarracksPanel.init(network, hasResearch)
	networkRef    = network
	hasResearchFn = hasResearch

	local sg = localPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui

	-- Full-screen transparent overlay
	local ov                         = Instance.new("Frame")
	ov.Name                          = "BarracksOverlay"
	ov.Size                          = UDim2.new(1, 0, 1, 0)
	ov.BackgroundTransparency        = 1
	ov.BorderSizePixel               = 0
	ov.ZIndex                        = 10
	ov.Visible                       = false
	ov.Parent                        = sg
	overlay = ov

	-- Root "BARRACKS" node — centre of screen, slightly lower
	local rootWrapper, rBtn = UILib.radialNode(ov, "BARRACKS", "⚔", C.BARRACKS, ROOT_POS, 70, 11)
	rootNode = rBtn
	rootLbl  = rootWrapper:FindFirstChild("NodeLabel") :: TextLabel?

	-- Close on root click
	rBtn.MouseButton1Click:Connect(function()
		BarracksPanel.hide()
	end)

	-- Child nodes
	for _, def in UNIT_DEFS do
		local rad = math.rad(def.angle)
		local dx  = math.cos(rad) * RADIUS
		local dy  = math.sin(rad) * RADIUS
		local finalPos = UDim2.new(ROOT_POS.X.Scale, ROOT_POS.X.Offset + dx, ROOT_POS.Y.Scale, ROOT_POS.Y.Offset + dy)

		local line         = UILib.connectorLine(ov, ROOT_POS, def.angle, RADIUS, 10)
		local wrapper, btn = UILib.radialNode(ov, def.label, def.icon, def.color, ROOT_POS, 70, 11)
		wrapper.Visible    = false

		local stroke = btn:FindFirstChildWhichIsA("UIStroke") :: UIStroke
		local label  = wrapper:FindFirstChild("NodeLabel")    :: TextLabel

		local key = def.key
		btn.MouseButton1Click:Connect(function()
			if not activeBarracksId then return end
			if key == "Elite" and not (hasResearchFn and hasResearchFn("EliteUnits")) then return end
			if key == "Medic" and not (hasResearchFn and hasResearchFn("MedicUnit"))  then return end
			networkRef.trainUnit(activeBarracksId, key)
		end)

		table.insert(childNodes, {
			wrapper  = wrapper,
			btn      = btn,
			line     = line,
			stroke   = stroke,
			label    = label,
			key      = key,
			finalPos = finalPos,
			startPos = ROOT_POS,
		})
	end

	-- ── Training update listener ───────────────────────────────────────────────
	network.onTrainingUpdate(function(barrackId: string, queue: {string}, progress: number)
		lastTrainingState[barrackId] = { queue = queue, progress = progress }
		updateWorldTrainBar(barrackId, queue, progress)
		if barrackId == activeBarracksId then
			updateRootLabel(queue, progress)
		end
	end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function BarracksPanel.show(barrackId: string)
	activeBarracksId = barrackId
	if overlay then overlay.Visible = true end
	refreshResearchNodes()
	expandNodes()

	local state = lastTrainingState[barrackId]
	if state then
		updateRootLabel(state.queue, state.progress)
	else
		updateRootLabel({}, 0)
	end
end

function BarracksPanel.hide()
	activeBarracksId = nil
	if rootLbl then rootLbl.Text = "BARRACKS" end
	collapseNodes(function()
		if overlay then overlay.Visible = false end
	end)
end

function BarracksPanel.refreshIfVisible()
	if overlay and (overlay :: Frame).Visible then refreshResearchNodes() end
end

function BarracksPanel.isVisible(): boolean
	return overlay ~= nil and (overlay :: Frame).Visible
end

return BarracksPanel
