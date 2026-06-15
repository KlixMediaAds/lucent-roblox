--!strict
--[[
    LampreyNestPanel — Radial panel for the Lamprey Nest building.

    A single product node: "Lamprey". Each click pays LAMPREY_EGG_COST and asks the
    server to birth one egg (the server caps concurrent eggs at LAMPREY_NEST_MAX_EGGS).
    The eggs ARE the queue — they're real parts parented to the nest model, so this
    panel counts them directly off the replicated model. The root label shows the
    live egg count, and the node greys out when the nest is full or unaffordable.
]]

local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))
local ViewportPreview   = require(script.Parent:WaitForChild("ViewportPreview"))

local LampreyNestPanel = {}
local localPlayer      = Players.LocalPlayer
local C                = UILib.C

-- ── State ─────────────────────────────────────────────────────────────────────
local activeNestId:  string? = nil
local networkRef:    any
local getResources:  (() -> number)?
local getMultiIdsFn: (() -> {string})?

local rootLbl: TextLabel?
local overlay: Frame?

local NEST_COL    = Color3.fromRGB(90, 130, 50)
local LAMPREY_GRN = Color3.fromRGB(120, 190, 60)

local RADIUS   = 155
local ROOT_POS = UDim2.new(0.5, 0, 0.68, 0)

-- Single product node
local node: {
	wrapper: Frame,
	btn:     TextButton,
	line:    Frame,
	stroke:  UIStroke,
	label:   TextLabel,
	finalPos: UDim2,
}? = nil

-- ── Egg counting (off the replicated nest model) ───────────────────────────────
local function eggCount(nestId: string): number
	local bf    = workspace:FindFirstChild("Buildings") :: Folder?
	local model = bf and bf:FindFirstChild(nestId)
	if not model then return 0 end
	local n = 0
	for _, child in model:GetChildren() do
		if child:IsA("BasePart") and child.Name:match("^Egg_") then n += 1 end
	end
	return n
end

-- ── Expand / collapse ─────────────────────────────────────────────────────────
local EXPAND_TI   = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local COLLAPSE_TI = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local function expandNodes()
	if not node then return end
	node.wrapper.Visible             = true
	node.wrapper.Position            = ROOT_POS
	node.btn.BackgroundTransparency  = 1
	node.line.BackgroundTransparency = 1
	TweenService:Create(node.wrapper, EXPAND_TI, { Position = node.finalPos }):Play()
	TweenService:Create(node.btn,     EXPAND_TI, { BackgroundTransparency = 0.35 }):Play()
	TweenService:Create(node.line,    EXPAND_TI, { BackgroundTransparency = 0.65 }):Play()
end

local function collapseNodes(then_: (() -> ())?)
	if node then
		TweenService:Create(node.wrapper, COLLAPSE_TI, { Position = ROOT_POS }):Play()
		TweenService:Create(node.btn,     COLLAPSE_TI, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(node.line,    COLLAPSE_TI, { BackgroundTransparency = 1 }):Play()
	end
	task.delay(COLLAPSE_TI.Time, function()
		if node then node.wrapper.Visible = false end
		if then_ then then_() end
	end)
end

-- ── Refresh ─────────────────────────────────────────────────────────────────--
local function updateRootLabel()
	if not rootLbl then return end
	local count = activeNestId and eggCount(activeNestId) or 0
	rootLbl.Text = "NEST\nEggs " .. count .. "/" .. Config.LAMPREY_NEST_MAX_EGGS
end

local function refresh()
	if not node then return end
	local res   = getResources and getResources() or 0
	local count = activeNestId and eggCount(activeNestId) or 0
	local full  = count >= Config.LAMPREY_NEST_MAX_EGGS
	local broke = res < Config.LAMPREY_EGG_COST

	if full then
		node.btn.BackgroundColor3       = C.BG_LOCKED
		node.btn.BackgroundTransparency = 0.4
		node.stroke.Color               = C.BORDER_LO
		node.stroke.Thickness           = 1.5
		node.label.Text                 = "Lamprey\nFull"
		node.label.TextColor3           = C.DIM
		node.btn.Active                 = false
	elseif broke then
		node.btn.BackgroundColor3       = C.BG_LOCKED
		node.btn.BackgroundTransparency = 0.4
		node.stroke.Color               = C.BORDER_LO
		node.stroke.Thickness           = 1.5
		node.label.Text                 = "Lamprey\n◆ " .. Config.LAMPREY_EGG_COST
		node.label.TextColor3           = C.DIM
		node.btn.Active                 = false
	else
		node.btn.BackgroundColor3       = LAMPREY_GRN
		node.btn.BackgroundTransparency = 0.35
		node.stroke.Color               = LAMPREY_GRN
		node.stroke.Thickness           = 2
		node.label.Text                 = "Lamprey\n◆ " .. Config.LAMPREY_EGG_COST
		node.label.TextColor3           = C.TEXT
		node.btn.Active                 = true
	end
	updateRootLabel()
end

-- Heartbeat refresh while open (egg counts change as eggs are laid / hatch)
local refreshConn: RBXScriptConnection?
local function startRefreshLoop()
	if refreshConn then refreshConn:Disconnect() end
	refreshConn = RunService.Heartbeat:Connect(function()
		if not (overlay and (overlay :: Frame).Visible) then
			if refreshConn then refreshConn:Disconnect(); refreshConn = nil end
			return
		end
		refresh()
	end)
end

-- ── Init ──────────────────────────────────────────────────────────────────────
function LampreyNestPanel.init(network: any, getResourcesFn: () -> number, getMultiIds: (() -> {string})?)
	networkRef    = network
	getResources  = getResourcesFn
	getMultiIdsFn = getMultiIds

	local sg = localPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui

	local ov                  = Instance.new("Frame")
	ov.Name                   = "LampreyNestOverlay"
	ov.Size                   = UDim2.new(1, 0, 1, 0)
	ov.BackgroundTransparency = 1
	ov.BorderSizePixel        = 0
	ov.ZIndex                 = 10
	ov.Visible                = false
	ov.Parent                 = sg
	overlay = ov

	local rootWrapper, rBtn = UILib.radialNode(ov, "NEST", "🥚", NEST_COL, ROOT_POS, 70, 11)
	rootLbl = rootWrapper:FindFirstChild("NodeLabel") :: TextLabel?
	rBtn.MouseButton1Click:Connect(function()
		LampreyNestPanel.hide()
	end)

	-- Single "Lamprey" product node (straight up from the root)
	local angle    = -90
	local rad      = math.rad(angle)
	local dx       = math.cos(rad) * RADIUS
	local dy       = math.sin(rad) * RADIUS
	local finalPos = UDim2.new(ROOT_POS.X.Scale, ROOT_POS.X.Offset + dx, ROOT_POS.Y.Scale, ROOT_POS.Y.Offset + dy)

	local line          = UILib.connectorLine(ov, ROOT_POS, angle, RADIUS, 10)
	local wrapper, btn  = UILib.radialNode(ov, "Lamprey\n◆ " .. Config.LAMPREY_EGG_COST, "🪱", LAMPREY_GRN, ROOT_POS, 70, 11)
	wrapper.Visible     = false
	UILib.setNodeViewport(btn, ViewportPreview.forUnit("Lamprey", Vector2.new(70, 70)))

	local stroke = btn:FindFirstChildWhichIsA("UIStroke") :: UIStroke
	local label  = wrapper:FindFirstChild("NodeLabel") :: TextLabel

	btn.MouseButton1Click:Connect(function()
		if not activeNestId or not btn.Active then return end
		local ids = getMultiIdsFn and getMultiIdsFn() or {activeNestId}
		networkRef.lampreyEgg(ids)
		refresh()
	end)

	node = {
		wrapper  = wrapper,
		btn      = btn,
		line     = line,
		stroke   = stroke,
		label    = label,
		finalPos = finalPos,
	}
end

-- ── Public API ────────────────────────────────────────────────────────────────
function LampreyNestPanel.show(nestId: string)
	activeNestId = nestId
	if overlay then overlay.Visible = true end
	refresh()
	expandNodes()
	startRefreshLoop()

	-- Auto-close if the nest is destroyed
	task.spawn(function()
		local bf = workspace:WaitForChild("Buildings", 10) :: Folder?
		if not bf then return end
		local model = bf:WaitForChild(nestId, 10)
		if not model then return end
		local base = model:FindFirstChild("Base") :: BasePart?
		if not base then return end
		local conn: RBXScriptConnection
		conn = base.Destroying:Connect(function()
			conn:Disconnect()
			if activeNestId == nestId then
				LampreyNestPanel.hide()
			end
		end)
	end)
end

function LampreyNestPanel.hide()
	activeNestId = nil
	collapseNodes(function()
		if overlay then overlay.Visible = false end
	end)
end

function LampreyNestPanel.refreshIfVisible()
	if overlay and (overlay :: Frame).Visible then refresh() end
end

return LampreyNestPanel
