--!strict
--[[
    WorkshopPanel — Radial bubble node-graph (Fusion 0.3.0).

    Root nodes: Units | Structures  (side-by-side at screen centre).
    Click a root  → children fan outward.
    Click a child → directly starts research / builds monument.
    Hover a child → tooltip with details.

    Child nodes update their own label and colour to reflect research state —
    no separate detail panel needed.
]]

local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))
local Fusion            = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Fusion"))

local WorkshopPanel = {}
local localPlayer   = Players.LocalPlayer
local C             = UILib.C
local peek          = Fusion.peek

-- ── Palette ───────────────────────────────────────────────────────────────────
local PURPLE = Color3.fromRGB(160, 80, 230)

-- ── Layout constants ──────────────────────────────────────────────────────────
local NODE_D = UILib.NODE_D  -- 80 — keep in sync with UILib
local RADIUS = 190
local ROOT_X = 125

-- ── State ─────────────────────────────────────────────────────────────────────
local activeCCId:      string?
local networkRef:      any
local getResearchedFn: ((string) -> boolean)?
local getProgressFn:   ((string) -> number?)?
local getResourcesFn:  (() -> number)?
local localMonumentTime: number?

local fScope: any = nil

-- ── Tech definitions ──────────────────────────────────────────────────────────
local TECHS = {
	{
		key   = "BetterMines",
		name  = "Better Mines",
		icon  = "⛏",
		color = C.TEAL,
		tip   = "Unlocks upgrade buttons on your mines.\n\nEfficiency — ×2 income per miner\nCapacity — +4 extra miner slots\n\nBoth upgrades are mutually exclusive per mine.\n\n⏱ 5 sec",
	},
	{
		key   = "EliteUnits",
		name  = "Elite Units",
		icon  = "⚔",
		color = PURPLE,
		tip   = "Trains Elite units at your Barracks.\n\nLong range, high damage, spider-leg movement.\nIdeal counter to turret-heavy bases.\n\nCost per unit: 100 res   ⏱ 15 sec",
	},
	{
		key   = "TurretUpgrades",
		name  = "Turret Upgrades",
		icon  = "⚙",
		color = C.TURRET,
		tip   = "Unlocks two upgrade paths for each turret.\n\nFlamethrower — short range (28), rapid fire\nRocket Launcher — long range (70), high damage\n\nMutually exclusive per turret.\n\n⏱ 20 sec",
	},
}

-- Quick lookup: tech key → TECHS entry
local techByKey: { [string]: typeof(TECHS[1]) } = {}
for _, t in TECHS do techByKey[t.key] = t end

-- ── Node tree definitions ─────────────────────────────────────────────────────
type ChildDef = {
	key:   string,
	icon:  string,
	color: Color3,
	angle: number,
	tip:   string,
}

local UNITS_CHILDREN: { ChildDef } = {
	{ key = "EliteUnits",     icon = "⚔", color = PURPLE,   angle = 180,
	  tip = (techByKey["EliteUnits"] or { tip = "" }).tip },
}

local STRUCTURES_CHILDREN: { ChildDef } = {
	{ key = "BetterMines",    icon = "⛏", color = C.TEAL,   angle = -45,
	  tip = (techByKey["BetterMines"] or { tip = "" }).tip },
	{ key = "TurretUpgrades", icon = "⚙", color = C.TURRET, angle = 0,
	  tip = (techByKey["TurretUpgrades"] or { tip = "" }).tip },
	{ key = "Monument",       icon = "★", color = C.GOLD,   angle = 45,
	  tip = "Rises from your Command Center.\nDefend it for 5 minutes to win.\n\nVisible to all players — 3 000 HP.\n\n💰 Costs 1 500 resources" },
}

-- ── Per-node live refs ────────────────────────────────────────────────────────
-- Populated during init; refresh() reads these to update node appearance.
type NodeRef = {
	btn:    TextButton,
	stroke: UIStroke,
	label:  TextLabel,
}
local nodeRefs: { [string]: NodeRef } = {}

-- ── Tooltip ───────────────────────────────────────────────────────────────────
local ttFrame: Frame?
local ttTitle: TextLabel?
local ttBody:  TextLabel?
local overlay: Frame?

local function buildTooltip(sg: ScreenGui)
	local f                      = Instance.new("Frame")
	f.Name                       = "WorkshopTooltip"
	f.Size                       = UDim2.fromOffset(255, 180)
	f.Position                   = UDim2.new(0.5, 24, 0.5, -90)
	f.BackgroundColor3           = Color3.fromRGB(8, 11, 22)
	f.BackgroundTransparency     = 0.06
	f.BorderSizePixel            = 0
	f.ZIndex                     = 30
	f.Visible                    = false
	f.Parent                     = sg
	UILib.corner(f, 10)
	UILib.stroke(f, C.BORDER, 1.5)

	local accent                 = Instance.new("Frame")
	accent.Size                  = UDim2.new(1, -2, 0, 3)
	accent.Position              = UDim2.fromOffset(1, 1)
	accent.BackgroundColor3      = C.ACCENT
	accent.BorderSizePixel       = 0
	accent.ZIndex                = 31
	accent.Parent                = f
	UILib.corner(accent, 8)

	local title                  = Instance.new("TextLabel")
	title.Size                   = UDim2.new(1, -16, 0, 24)
	title.Position               = UDim2.fromOffset(10, 10)
	title.BackgroundTransparency = 1
	title.Font                   = Enum.Font.GothamBold
	title.TextSize               = 15
	title.TextColor3             = C.TEXT
	title.TextXAlignment         = Enum.TextXAlignment.Left
	title.Text                   = ""
	title.ZIndex                 = 31
	title.Parent                 = f

	local sep                    = Instance.new("Frame")
	sep.Size                     = UDim2.new(1, -20, 0, 1)
	sep.Position                 = UDim2.fromOffset(10, 38)
	sep.BackgroundColor3         = C.SEP
	sep.BorderSizePixel          = 0
	sep.ZIndex                   = 31
	sep.Parent                   = f

	local body                   = Instance.new("TextLabel")
	body.Size                    = UDim2.new(1, -20, 1, -50)
	body.Position                = UDim2.fromOffset(10, 46)
	body.BackgroundTransparency  = 1
	body.Font                    = Enum.Font.Gotham
	body.TextSize                = 13
	body.TextColor3              = C.SUBTEXT
	body.TextXAlignment          = Enum.TextXAlignment.Left
	body.TextYAlignment          = Enum.TextYAlignment.Top
	body.TextWrapped             = true
	body.Text                    = ""
	body.ZIndex                  = 31
	body.Parent                  = f

	ttFrame = f
	ttTitle = title
	ttBody  = body
end

local function showTooltip(title: string, body: string)
	if not ttFrame or not ttTitle or not ttBody then return end
	ttTitle.Text    = title
	ttBody.Text     = body
	ttFrame.Visible = true
end

local function hideTooltip()
	if ttFrame then ttFrame.Visible = false end
end

-- ── Node state refresh ────────────────────────────────────────────────────────

local function refreshMonumentNode()
	local ref = nodeRefs["Monument"]
	if not ref then return end
	local t = localMonumentTime

	if t == nil then
		local canAfford                    = (getResourcesFn and getResourcesFn() or 0) >= Config.MONUMENT_COST
		ref.btn.BackgroundColor3           = C.GOLD
		ref.btn.BackgroundTransparency     = canAfford and 0.35 or 0.55
		ref.stroke.Color                   = C.GOLD
		ref.label.Text                     = "Monument\n◆ 1 500"
		ref.label.TextColor3               = canAfford and C.GOLD or C.DIM
		ref.btn.Active                     = canAfford
	elseif t == -1 then
		ref.btn.BackgroundColor3           = C.ACCENT
		ref.btn.BackgroundTransparency     = 0.2
		ref.stroke.Color                   = C.ACCENT
		ref.label.Text                     = "Monument\nRising…"
		ref.label.TextColor3               = C.ACCENT
		ref.btn.Active                     = false
	else
		ref.btn.BackgroundColor3           = C.GOLD
		ref.btn.BackgroundTransparency     = 0.2
		ref.stroke.Color                   = C.GOLD
		local mins = math.floor(t / 60)
		local secs = math.floor(t % 60)
		ref.label.Text                     = string.format("Monument\n%d:%02d", mins, secs)
		ref.label.TextColor3               = C.GOLD
		ref.btn.Active                     = false
	end
end

local function refreshTechNode(key: string)
	local ref  = nodeRefs[key]
	local tech = techByKey[key]
	if not ref or not tech then return end

	local done     = getResearchedFn and getResearchedFn(key) or false
	local progress = getProgressFn   and getProgressFn(key)   or nil
	local inProg   = progress ~= nil and not done

	if done then
		ref.btn.BackgroundColor3       = C.GREEN
		ref.btn.BackgroundTransparency = 0.2
		ref.stroke.Color               = C.GREEN
		ref.stroke.Thickness           = 2
		ref.label.Text                 = tech.name .. "\n✓ Done"
		ref.label.TextColor3           = C.GREEN
		ref.btn.Active                 = false
	elseif inProg then
		ref.btn.BackgroundColor3       = C.ACCENT
		ref.btn.BackgroundTransparency = 0.15
		ref.stroke.Color               = C.ACCENT
		ref.stroke.Thickness           = 2.5
		ref.label.Text                 = tech.name .. "\n" .. math.floor((progress :: number) * 100) .. "%"
		ref.label.TextColor3           = C.ACCENT
		ref.btn.Active                 = false
	else
		ref.btn.BackgroundColor3       = tech.color
		ref.btn.BackgroundTransparency = 0.35
		ref.stroke.Color               = tech.color
		ref.stroke.Thickness           = 2
		ref.label.Text                 = tech.name
		ref.label.TextColor3           = C.TEXT
		ref.btn.Active                 = true
	end
end

local function refresh()
	if not activeCCId then return end
	for _, tech in TECHS do refreshTechNode(tech.key) end
	refreshMonumentNode()
end

-- ── Expand / collapse ─────────────────────────────────────────────────────────
local EXPAND_TI   = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local COLLAPSE_TI = TweenInfo.new(0.2,  Enum.EasingStyle.Quad, Enum.EasingDirection.In)

type ChildNode = {
	wrapper:  Frame,
	btn:      TextButton,
	line:     Frame,
	key:      string,
	finalPos: UDim2,
	startPos: UDim2,
}

local function expandChildren(children: { ChildNode }, stroke: UIStroke)
	TweenService:Create(stroke, TweenInfo.new(0.15), { Thickness = 4 }):Play()
	for _, c in children do
		c.wrapper.Visible             = true
		c.wrapper.Position            = c.startPos
		c.btn.BackgroundTransparency  = 1
		c.line.BackgroundTransparency = 1
		TweenService:Create(c.wrapper, EXPAND_TI, { Position = c.finalPos }):Play()
		TweenService:Create(c.btn,     EXPAND_TI, { BackgroundTransparency = 0.35 }):Play()
		TweenService:Create(c.line,    EXPAND_TI, { BackgroundTransparency = 0.6  }):Play()
	end
end

local function collapseChildren(children: { ChildNode }, stroke: UIStroke)
	TweenService:Create(stroke, TweenInfo.new(0.15), { Thickness = 2 }):Play()
	for _, c in children do
		TweenService:Create(c.wrapper, COLLAPSE_TI, { Position = c.startPos }):Play()
		TweenService:Create(c.btn,     COLLAPSE_TI, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(c.line,    COLLAPSE_TI, { BackgroundTransparency = 1 }):Play()
	end
	task.delay(COLLAPSE_TI.Time, function()
		for _, c in children do c.wrapper.Visible = false end
	end)
end

-- ── Build child node group ────────────────────────────────────────────────────
local function buildChildNodes(
	parent:  Frame,
	defs:    { ChildDef },
	rootPos: UDim2
): { ChildNode }
	local nodes: { ChildNode } = {}
	for _, def in defs do
		local rad = math.rad(def.angle)
		local dx  = math.cos(rad) * RADIUS
		local dy  = math.sin(rad) * RADIUS
		local finalPos = UDim2.new(
			rootPos.X.Scale,  rootPos.X.Offset + dx,
			rootPos.Y.Scale,  rootPos.Y.Offset + dy
		)

		local line         = UILib.connectorLine(parent, rootPos, def.angle, RADIUS, 11)
		local wrapper, btn = UILib.radialNode(parent, def.key, def.icon, def.color, rootPos, nil, 13)
		wrapper.Visible    = false

		local stroke = btn:FindFirstChildWhichIsA("UIStroke") :: UIStroke
		local label  = wrapper:FindFirstChild("NodeLabel")    :: TextLabel

		-- Store ref for refresh()
		nodeRefs[def.key] = { btn = btn, stroke = stroke, label = label }

		-- Tooltip on hover
		local tipTitle = techByKey[def.key] and techByKey[def.key].name or "Monument"
		local tipBody  = def.tip
		btn.MouseEnter:Connect(function() showTooltip(tipTitle, tipBody) end)
		btn.MouseLeave:Connect(hideTooltip)

		-- Click: direct action
		local key = def.key
		btn.MouseButton1Click:Connect(function()
			if not activeCCId or not btn.Active then return end
			if key == "Monument" then
				networkRef.buildMonument()
			else
				networkRef.startResearch(activeCCId, key)
			end
		end)

		table.insert(nodes, {
			wrapper  = wrapper,
			btn      = btn,
			line     = line,
			key      = key,
			finalPos = finalPos,
			startPos = rootPos,
		})
	end
	return nodes
end

-- ── Init ─────────────────────────────────────────────────────────────────────
function WorkshopPanel.init(
	network,
	getResearched: (string) -> boolean,
	getProgress:   (string) -> number?,
	getResources:  (() -> number)?
)
	networkRef      = network
	getResearchedFn = getResearched
	getProgressFn   = getProgress
	getResourcesFn  = getResources

	local sg = localPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui

	fScope = Fusion.scoped(Fusion)
	local unitsOpen:      Fusion.Value<boolean> = fScope:Value(false)
	local structuresOpen: Fusion.Value<boolean> = fScope:Value(false)

	-- Full-screen overlay
	local ov                         = Instance.new("Frame")
	ov.Name                          = "WorkshopOverlay"
	ov.Size                          = UDim2.new(1, 0, 1, 0)
	ov.BackgroundTransparency        = 1
	ov.BorderSizePixel               = 0
	ov.ZIndex                        = 10
	ov.Visible                       = false
	ov.Parent                        = sg
	overlay = ov

	-- Root node positions
	local unitsPos   = UDim2.new(0.5, -ROOT_X, 0.5, 0)
	local structsPos = UDim2.new(0.5,  ROOT_X, 0.5, 0)

	local _uw, unitsBtn  = UILib.radialNode(ov, "Units",      "⚔", PURPLE,   unitsPos,  nil, 12)
	local _sw, structBtn = UILib.radialNode(ov, "Structures", "⚒", C.ACCENT, structsPos, nil, 12)
	local unitsStroke    = unitsBtn:FindFirstChildWhichIsA("UIStroke")  :: UIStroke
	local structStroke   = structBtn:FindFirstChildWhichIsA("UIStroke") :: UIStroke

	-- Child node groups
	local unitsChildren  = buildChildNodes(ov, UNITS_CHILDREN,      unitsPos)
	local structChildren = buildChildNodes(ov, STRUCTURES_CHILDREN, structsPos)

	-- Root clicks
	unitsBtn.MouseButton1Click:Connect(function()
		if peek(unitsOpen) then
			unitsOpen:set(false)
			collapseChildren(unitsChildren, unitsStroke)
		else
			unitsOpen:set(true)
			expandChildren(unitsChildren, unitsStroke)
		end
	end)

	structBtn.MouseButton1Click:Connect(function()
		if peek(structuresOpen) then
			structuresOpen:set(false)
			collapseChildren(structChildren, structStroke)
		else
			structuresOpen:set(true)
			expandChildren(structChildren, structStroke)
		end
	end)

	buildTooltip(sg)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function WorkshopPanel.show(ccId: string)
	activeCCId = ccId
	if overlay then overlay.Visible = true end
	refresh()
end

function WorkshopPanel.hide()
	activeCCId = nil
	if overlay then overlay.Visible = false end
	hideTooltip()
end

function WorkshopPanel.refreshIfVisible()
	if overlay and (overlay :: Frame).Visible then refresh() end
end

function WorkshopPanel.onMonumentProgress(timeRemaining: number?)
	localMonumentTime = timeRemaining
	if overlay and (overlay :: Frame).Visible then refreshMonumentNode() end
end

function WorkshopPanel.resetMonument()
	localMonumentTime = nil
	refreshMonumentNode()
end

return WorkshopPanel
