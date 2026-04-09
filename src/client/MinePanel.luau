--!strict
--[[
    MinePanel — Radial bubble node-graph for mine upgrades.

    Root node "MINE" auto-expands to two children when show() is called:
      Efficiency (-135°)  ·  Capacity (-45°)

    Miner count is shown inline on the root node label.
    Upgrade state is shown directly on child nodes.
    All network calls and logic are preserved unchanged.
]]

local Players      = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UILib             = require(script.Parent:WaitForChild("UILib"))

local MinePanel   = {}
local localPlayer = Players.LocalPlayer
local C           = UILib.C

-- ── State ─────────────────────────────────────────────────────────────────────
local activeMineId:  string? = nil
local networkRef:    any
local getResources:  (() -> number)?
local getMinerCount: ((string) -> number)?
local hasResearchFn: ((string) -> boolean)?

-- Root node label ref (shows miner count inline)
local rootLbl: TextLabel?

-- Overlay instances
local overlay: Frame?

local RADIUS   = 155
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

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function getUpgradeState(mineId: string): string?
	local bf = workspace:FindFirstChild("Buildings")
	if not bf then return nil end
	local model = bf:FindFirstChild(mineId)
	if not model then return nil end
	local uv = model:FindFirstChild("Upgrade") :: StringValue?
	return uv and uv.Value or nil
end

-- ── Refresh node & root label states ─────────────────────────────────────────
local function refresh()
	if not activeMineId then return end
	local mineId     = activeMineId
	local upgrade    = getUpgradeState(mineId)
	local res        = getResources and getResources() or 0
	local hasRes     = hasResearchFn and hasResearchFn("BetterMines") or false
	local miners     = getMinerCount and getMinerCount(mineId) or 0
	local cap        = if upgrade == "Capacity"   then 10 else 6
	local mult       = if upgrade == "Efficiency" then 2.0 else 1.0
	local incMin     = miners * 5 * (60 / 10) * mult

	-- Root label: miner count + income
	if rootLbl then
		rootLbl.Text = string.format("MINE\n%d/%d  ·  %.0f/min", miners, cap, incMin)
	end

	-- Node visual states
	for _, c in childNodes do
		if upgrade == c.key then
			c.btn.BackgroundColor3       = C.GREEN
			c.btn.BackgroundTransparency = 0.15
			c.stroke.Color               = C.GREEN
			c.stroke.Thickness           = 2.5
			c.label.Text                 = c.key .. "\n✓ ACTIVE"
			c.label.TextColor3           = C.GREEN
			c.btn.Active                 = false

		elseif upgrade ~= nil then
			c.btn.BackgroundColor3       = C.BG_LOCKED
			c.btn.BackgroundTransparency = 0.35
			c.stroke.Color               = C.BORDER_LO
			c.stroke.Thickness           = 1.5
			c.label.Text                 = c.key .. "\nLOCKED"
			c.label.TextColor3           = C.DIM
			c.btn.Active                 = false

		elseif not hasRes then
			c.btn.BackgroundColor3       = C.BG_LOCKED
			c.btn.BackgroundTransparency = 0.35
			c.stroke.Color               = C.BORDER_LO
			c.stroke.Thickness           = 1.5
			c.label.Text                 = c.key .. "\nNeeds Research"
			c.label.TextColor3           = C.DIM
			c.btn.Active                 = false

		else
			local cost = c.key == "Efficiency" and 150 or 125
			local ok   = res >= cost
			c.btn.BackgroundColor3       = ok and (c.key == "Efficiency" and C.MINE or C.TURRET) or C.BG_LOCKED
			c.btn.BackgroundTransparency = ok and 0.35 or 0.45
			c.stroke.Color               = ok and c.btn.BackgroundColor3 or C.BORDER_LO
			c.stroke.Thickness           = 2
			c.label.Text                 = c.key .. "\n◆ " .. cost
			c.label.TextColor3           = ok and C.TEXT or C.DIM
			c.btn.Active                 = ok
		end
	end
end

-- ── Init ──────────────────────────────────────────────────────────────────────
function MinePanel.init(network, getResourcesFn, getMinerCountFn, hasResearchFn_)
	networkRef    = network
	getResources  = getResourcesFn
	getMinerCount = getMinerCountFn
	hasResearchFn = hasResearchFn_

	local sg = localPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui

	-- Full-screen transparent overlay
	local ov                         = Instance.new("Frame")
	ov.Name                          = "MineOverlay"
	ov.Size                          = UDim2.new(1, 0, 1, 0)
	ov.BackgroundTransparency        = 1
	ov.BorderSizePixel               = 0
	ov.ZIndex                        = 10
	ov.Visible                       = false
	ov.Parent                        = sg
	overlay = ov

	-- Root "MINE" node
	local rootWrapper, rBtn = UILib.radialNode(ov, "MINE", "⛏", C.MINE, ROOT_POS, 70, 11)
	rootLbl = rootWrapper:FindFirstChild("NodeLabel") :: TextLabel?
	rBtn.MouseButton1Click:Connect(function()
		MinePanel.hide()
	end)

	-- Child nodes: Efficiency (-135°) and Capacity (-45°)
	local UPGRADES = {
		{ key = "Efficiency", icon = "⛏", color = C.MINE,   angle = -135 },
		{ key = "Capacity",   icon = "◆",  color = C.TURRET, angle = -45  },
	}

	for _, def in UPGRADES do
		local rad = math.rad(def.angle)
		local dx  = math.cos(rad) * RADIUS
		local dy  = math.sin(rad) * RADIUS
		local finalPos = UDim2.new(ROOT_POS.X.Scale, ROOT_POS.X.Offset + dx, ROOT_POS.Y.Scale, ROOT_POS.Y.Offset + dy)

		local line         = UILib.connectorLine(ov, ROOT_POS, def.angle, RADIUS, 10)
		local wrapper, btn = UILib.radialNode(ov, def.key, def.icon, def.color, ROOT_POS, 70, 11)
		wrapper.Visible    = false

		local stroke = btn:FindFirstChildWhichIsA("UIStroke") :: UIStroke
		local label  = wrapper:FindFirstChild("NodeLabel")    :: TextLabel

		local key = def.key
		btn.MouseButton1Click:Connect(function()
			if not activeMineId or not btn.Active then return end
			networkRef.upgradeMine(activeMineId, key)
			task.delay(0.35, refresh)
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
end

-- ── Public API ────────────────────────────────────────────────────────────────

function MinePanel.show(mineId: string)
	activeMineId = mineId
	if overlay then overlay.Visible = true end
	refresh()
	expandNodes()

	task.spawn(function()
		local bf = workspace:WaitForChild("Buildings", 10) :: Folder?
		if not bf then return end
		local model = bf:WaitForChild(mineId, 10)
		if not model then return end
		model.ChildAdded:Connect(function(child)
			if child.Name == "Upgrade" and activeMineId == mineId then refresh() end
		end)
	end)
end

function MinePanel.hide()
	activeMineId = nil
	if rootLbl then rootLbl.Text = "MINE" end
	collapseNodes(function()
		if overlay then overlay.Visible = false end
	end)
end

function MinePanel.refreshIfVisible()
	if overlay and (overlay :: Frame).Visible then refresh() end
end

return MinePanel
