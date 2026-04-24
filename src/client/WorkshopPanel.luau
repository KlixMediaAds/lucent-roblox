--!strict
--[[
    WorkshopPanel — progressive reveal tech tree with dynamic ring layout.

    Progressive reveal:
      • Below REVEAL_SHOW (10%): node hidden, ring closes the gap
      • 10% → 30%: very faint (trans ~0.90 → ~0.75)
      • 30% → 50%: semi-transparent (trans ~0.75 → ~0.50)
      • 50% → REVEAL_FULL (70%): fading in (trans ~0.50 → 0)
      • 70%+: fully opaque
    Sub-nodes always visible once their parent is unlocked (at minimum faint).
    Press Y while open to preview all upgrades as gray ghosts.
]]

local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))
local Fusion            = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Fusion"))

local WorkshopPanel = {}
local C             = UILib.C

-- ── Palette ───────────────────────────────────────────────────────────────────
local COL_PANEL_BG      = Color3.fromRGB( 7,   9,  18)
local COL_NODE_LOCKED   = Color3.fromRGB(14,  16,  30)
local COL_NODE_AVAIL    = Color3.fromRGB(32,  24,   6)
local COL_NODE_UNLOCKED = Color3.fromRGB( 6,  28,  12)
local COL_NODE_EXCL     = Color3.fromRGB(12,  12,  18)
local COL_NODE_GHOST    = Color3.fromRGB(18,  18,  28)
local COL_BDR_LOCKED    = Color3.fromRGB(40,  50,  85)
local COL_BDR_AVAIL     = Color3.fromRGB(210,160,  30)
local COL_BDR_UNLOCKED  = Color3.fromRGB(45, 200,  80)
local COL_BDR_EXCL      = Color3.fromRGB(25,  25,  35)
local COL_BDR_GHOST     = Color3.fromRGB(38,  38,  55)
local COL_CONN_DARK     = Color3.fromRGB(30,  36,  58)
local COL_CONN_LIT      = Color3.fromRGB(40, 170,  65)

-- ── Layout constants ──────────────────────────────────────────────────────────
local NODE_R     = 34
local ROOT_DIST  = 148
local CHILD_DIST = 135
local SPREAD_1   = 0.0
local SPREAD_2   = math.rad(30)
local SPREAD_N   = math.rad(38)

-- ── Progressive reveal thresholds ────────────────────────────────────────────
local REVEAL_SHOW = 0.10
local REVEAL_FULL = 0.70

-- ── Panel geometry ────────────────────────────────────────────────────────────
local PANEL_W   = 820
local PANEL_H   = 620
local TITLE_H   = 44
local MON_H     = 34
local MON_PAD_B = 10

-- ── Module state ──────────────────────────────────────────────────────────────
local overlay:        Frame?
local monBtn:         TextButton?
local monLabel:       TextLabel?
local tooltipFrame:   Frame?
local tooltipName:    TextLabel?
local tooltipDesc:    TextLabel?
local tooltipCond:    TextLabel?
local tooltipBarBg:   Frame?
local tooltipBarFill: Frame?
local nodeCanvas:     Frame?

local hasResearchFn:     ((string) -> boolean)?
local resourcesFn:       (() -> number)?
local getCondProgressFn: ((string) -> number)?
local networkRef:        any
local localMonumentTime: number?
local previewMode:       boolean = false

local scope = Fusion.scoped(Fusion) :: any

type NodeState = string  -- "locked" | "available" | "unlocked" | "excluded"
local techStateVals: { [string]: any } = {}

type NodeRef = {
    circle:  Frame,
    stroke:  UIStroke,
    icon:    TextLabel,
    nameLbl: TextLabel,
    condLbl: TextLabel,
}
local nodeRefs: { [string]: NodeRef } = {}

type ConnRef = { line: Frame }
local connRefs: { [string]: ConnRef } = {}

local lastLayoutPositions: { [string]: { x: number, y: number } } = {}

type NodeData = {
    name:     string,
    parent:   string?,
    group:    string?,
    children: { string },
}
local fullGraph: { [string]: NodeData } = {}

-- ── Graph construction ────────────────────────────────────────────────────────

local function buildGraph(): { [string]: NodeData }
    local nodes: { [string]: NodeData } = {}
    for name, unlock in (Config.UNLOCKS :: any) do
        nodes[name] = {
            name     = name,
            parent   = (unlock.requires :: string?),
            group    = (unlock.group    :: string?),
            children = {},
        }
    end
    for name, node in nodes do
        if node.parent then
            local p = nodes[node.parent]
            if p then table.insert(p.children, name) end
        end
    end
    for _, node in nodes do table.sort(node.children) end
    return nodes
end

local function buildFilteredGraph(
    nodes:   { [string]: NodeData },
    visible: { [string]: boolean }
): { [string]: NodeData }
    local filtered: { [string]: NodeData } = {}
    for name, node in nodes do
        if not visible[name] then continue end
        local filteredParent: string? = nil
        if node.parent ~= nil and visible[node.parent] == true then
            filteredParent = node.parent
        end
        filtered[name] = {
            name     = name,
            parent   = filteredParent,
            group    = node.group,
            children = {},
        }
    end
    for name, fnode in filtered do
        local p = fnode.parent
        if p and filtered[p] then
            table.insert(filtered[p].children, name)
        end
    end
    for _, fnode in filtered do table.sort(fnode.children) end
    return filtered
end

-- ── Layout engine ─────────────────────────────────────────────────────────────

type Vec2 = { x: number, y: number }

local function computeLayout(nodes: { [string]: NodeData }): { [string]: Vec2 }
    local pos: { [string]: Vec2 } = {}

    local roots: { string } = {}
    for name, node in nodes do
        if not node.parent then table.insert(roots, name) end
    end
    table.sort(roots)

    local n = #roots
    for i, name in ipairs(roots) do
        local angle = math.rad(-90) + (i - 1) * (2 * math.pi / n)
        pos[name] = { x = math.cos(angle) * ROOT_DIST, y = math.sin(angle) * ROOT_DIST }
    end

    local queue: { string } = {}
    for _, name in ipairs(roots) do table.insert(queue, name) end
    local visited: { [string]: boolean } = {}
    local head = 1

    while head <= #queue do
        local name = queue[head]; head += 1
        if visited[name] then continue end
        visited[name] = true

        local node  = nodes[name]
        local pPos  = pos[name]
        if not pPos then continue end

        local kids  = node.children
        local count = #kids
        if count == 0 then continue end

        local parentAngle = math.atan2(pPos.y, pPos.x)
        local halfSpread  = count == 1 and SPREAD_1 or count == 2 and SPREAD_2 or SPREAD_N

        for j, childName in ipairs(kids) do
            local t     = count == 1 and 0.0 or (j - 1) / (count - 1) - 0.5
            local angle = parentAngle + t * 2 * halfSpread
            pos[childName] = {
                x = pPos.x + math.cos(angle) * CHILD_DIST,
                y = pPos.y + math.sin(angle) * CHILD_DIST,
            }
            table.insert(queue, childName)
        end
    end

    return pos
end

-- ── Progress helpers ──────────────────────────────────────────────────────────

local function computeNodeProgress(techName: string): number
    local hr = hasResearchFn
    if not hr then return 1.0 end
    if hr(techName) then return 1.0 end

    local unlock = (Config.UNLOCKS :: any)[techName]

    -- Excluded: a sibling in the same group was chosen
    local group = (unlock.group :: string?)
    if group then
        for otherName, otherU in (Config.UNLOCKS :: any) do
            if otherName ~= techName and (otherU.group :: string?) == group and hr(otherName) then
                return 0
            end
        end
    end

    -- Child node: hidden until parent is done, then always at least barely visible
    local parent = (unlock.requires :: string?)
    if parent then
        if not hr(parent) then return 0 end
        local fn = getCondProgressFn
        local p  = fn and fn(techName) or 1.0
        -- Ensure sub-nodes are always visible once the parent is unlocked
        return math.max(p, REVEAL_SHOW + 0.01)
    end

    -- Root node: condition progress drives reveal
    local fn = getCondProgressFn
    return fn and fn(techName) or 1.0
end

-- Piecewise: [REVEAL_SHOW, REVEAL_FULL] → transparency [0.90, 0]
local function progressToTransparency(p: number): number
    if p >= REVEAL_FULL then return 0 end
    if p >= 0.50 then
        return 0.50 * (1 - (p - 0.50) / (REVEAL_FULL - 0.50))
    elseif p >= 0.30 then
        return 0.75 + (0.50 - 0.75) * (p - 0.30) / (0.50 - 0.30)
    else
        return 0.90 + (0.75 - 0.90) * (p - REVEAL_SHOW) / (0.30 - REVEAL_SHOW)
    end
end

-- ── State computation ─────────────────────────────────────────────────────────

local function computeNodeState(techName: string): NodeState
    local hr = hasResearchFn
    if not hr then return "locked" end
    if hr(techName) then return "unlocked" end

    local unlock = (Config.UNLOCKS :: any)[techName]
    local group  = (unlock.group    :: string?)
    if group then
        for other, otherU in (Config.UNLOCKS :: any) do
            if other ~= techName and (otherU.group :: string?) == group and hr(other) then
                return "excluded"
            end
        end
    end

    local req = (unlock.requires :: string?)
    if req and not hr(req) then return "locked" end

    return "available"
end

-- ── Visual helpers ────────────────────────────────────────────────────────────

local function colorsForState(st: NodeState): (Color3, Color3)
    if st == "unlocked" then      return COL_NODE_UNLOCKED, COL_BDR_UNLOCKED
    elseif st == "available" then return COL_NODE_AVAIL,    COL_BDR_AVAIL
    elseif st == "excluded"  then return COL_NODE_EXCL,     COL_BDR_EXCL
    else                          return COL_NODE_LOCKED,   COL_BDR_LOCKED
    end
end

local function applyRef(techName: string, st: NodeState)
    local ref = nodeRefs[techName]
    if not ref then return end
    local bg, bdr = colorsForState(st)
    TweenService:Create(ref.circle, TweenInfo.new(0.22), { BackgroundColor3 = bg  }):Play()
    TweenService:Create(ref.stroke, TweenInfo.new(0.22), { Color             = bdr }):Play()
    ref.icon.TextColor3 = bdr
end

local function applyTransparency(ref: NodeRef, trans: number)
    local t = TweenInfo.new(0.35)
    TweenService:Create(ref.circle,  t, { BackgroundTransparency = trans }):Play()
    TweenService:Create(ref.stroke,  t, { Transparency           = trans }):Play()
    TweenService:Create(ref.icon,    t, { TextTransparency       = trans }):Play()
    TweenService:Create(ref.nameLbl, t, { TextTransparency       = trans }):Play()
    TweenService:Create(ref.condLbl, t, { TextTransparency       = trans }):Play()
end

-- ── Refresh ───────────────────────────────────────────────────────────────────

local function refreshAllNodes()
    local progressMap: { [string]: number }  = {}
    local visibleSet:  { [string]: boolean } = {}
    for techName in fullGraph do
        local p = computeNodeProgress(techName)
        progressMap[techName] = p
        if p >= REVEAL_SHOW then
            visibleSet[techName] = true
        end
    end

    -- In preview mode use the full graph so ghost nodes get proper ring positions
    local layoutGraph = previewMode and fullGraph or buildFilteredGraph(fullGraph, visibleSet)
    local positions   = computeLayout(layoutGraph)

    local TI_POS = TweenInfo.new(0.4)

    for techName, ref in nodeRefs do
        local p       = progressMap[techName] or 0
        local isReal  = p >= REVEAL_SHOW
        local isGhost = previewMode and not isReal

        if not isReal and not isGhost then
            ref.circle.Visible = false
            continue
        end

        ref.circle.Visible = true

        local newPos = positions[techName]
        if newPos then
            local nx = math.floor(newPos.x)
            local ny = math.floor(newPos.y)
            if isGhost then
                -- Ghosts snap instantly; don't dirty the position cache
                ref.circle.Position = UDim2.new(0.5, nx, 0.5, ny)
            else
                local last = lastLayoutPositions[techName]
                if not last then
                    ref.circle.Position = UDim2.new(0.5, nx, 0.5, ny)
                elseif last.x ~= nx or last.y ~= ny then
                    TweenService:Create(ref.circle, TI_POS,
                        { Position = UDim2.new(0.5, nx, 0.5, ny) }):Play()
                end
                lastLayoutPositions[techName] = { x = nx, y = ny }
            end
        end

        if isGhost then
            ref.circle.BackgroundColor3      = COL_NODE_GHOST
            ref.circle.BackgroundTransparency = 0.55
            ref.stroke.Color                 = COL_BDR_GHOST
            ref.stroke.Transparency          = 0.55
            ref.icon.TextColor3              = COL_BDR_GHOST
            ref.icon.TextTransparency        = 0.6
            ref.nameLbl.TextTransparency     = 0.6
            ref.condLbl.TextTransparency     = 0.75
        else
            local stateVal = techStateVals[techName]
            if stateVal then
                local newState = computeNodeState(techName)
                if Fusion.peek(stateVal) ~= newState then
                    stateVal:set(newState)
                end
            end
            applyTransparency(ref, progressToTransparency(p))
        end
    end

    -- Connectors
    for key, connRef in connRefs do
        local sep = string.find(key, "|", 1, true)
        if not sep then continue end
        local parentName = string.sub(key, 1, sep - 1)
        local childName  = string.sub(key, sep + 1)

        local pPos = positions[parentName]
        local cPos = positions[childName]

        if not pPos or not cPos then
            connRef.line.Visible = false
            continue
        end

        connRef.line.Visible = true

        local dx   = cPos.x - pPos.x
        local dy   = cPos.y - pPos.y
        local dist = math.sqrt(dx * dx + dy * dy)
        local len  = math.max(1, dist - NODE_R * 2)
        local mx   = (pPos.x + cPos.x) * 0.5
        local my   = (pPos.y + cPos.y) * 0.5

        connRef.line.Size     = UDim2.fromOffset(math.floor(len), 2)
        connRef.line.Position = UDim2.new(0.5, math.floor(mx), 0.5, math.floor(my))
        connRef.line.Rotation = math.deg(math.atan2(dy, dx))

        local pIsGhost = previewMode and (progressMap[parentName] or 0) < REVEAL_SHOW
        local cIsGhost = previewMode and (progressMap[childName]  or 0) < REVEAL_SHOW

        if pIsGhost or cIsGhost then
            connRef.line.BackgroundColor3       = COL_BDR_GHOST
            connRef.line.BackgroundTransparency = 0.65
        else
            local hr  = hasResearchFn
            local lit = hr and hr(parentName) and (hr(childName) or computeNodeState(childName) == "available")
            TweenService:Create(connRef.line, TweenInfo.new(0.22),
                { BackgroundColor3 = lit and COL_CONN_LIT or COL_CONN_DARK }):Play()
            local pTrans = progressToTransparency(progressMap[parentName] or 0)
            local cTrans = progressToTransparency(progressMap[childName]  or 0)
            connRef.line.BackgroundTransparency = math.max(pTrans, cTrans)
        end
    end
end

-- ── Connector placeholder builder ────────────────────────────────────────────

local function createConnectorPlaceholder(canvas: Frame, key: string)
    local line                      = Instance.new("Frame")
    line.Name                       = "Conn_" .. key
    line.AnchorPoint                = Vector2.new(0.5, 0.5)
    line.Size                       = UDim2.fromOffset(0, 2)
    line.Position                   = UDim2.new(0.5, 0, 0.5, 0)
    line.BackgroundColor3           = COL_CONN_DARK
    line.BackgroundTransparency     = 0
    line.BorderSizePixel            = 0
    line.ZIndex                     = 50
    line.Visible                    = false
    line.Parent                     = canvas
    connRefs[key] = { line = line }
end

-- ── Node builder ──────────────────────────────────────────────────────────────

local function buildNode(canvas: Frame, techName: string)
    local unlock   = (Config.UNLOCKS :: any)[techName]
    local icon     = (unlock.icon     :: string?) or "◆"
    local condText = (unlock.condText :: string?) or ""
    local D        = NODE_R * 2

    local circle                     = Instance.new("Frame")
    circle.Name                      = "Node_" .. techName
    circle.AnchorPoint               = Vector2.new(0.5, 0.5)
    circle.Size                      = UDim2.fromOffset(D, D)
    circle.Position                  = UDim2.new(0.5, 0, 0.5, 0)
    circle.BackgroundColor3          = COL_NODE_LOCKED
    circle.BackgroundTransparency    = 1
    circle.BorderSizePixel           = 0
    circle.ZIndex                    = 52
    circle.Visible                   = false
    circle.Parent                    = canvas
    UILib.corner(circle, NODE_R)

    local stroke          = Instance.new("UIStroke")
    stroke.Color          = COL_BDR_LOCKED
    stroke.Thickness      = 2
    stroke.Transparency   = 1
    stroke.Parent         = circle

    local iconLbl                    = Instance.new("TextLabel")
    iconLbl.Size                     = UDim2.new(1, 0, 0.6, 0)
    iconLbl.Position                 = UDim2.fromOffset(0, 4)
    iconLbl.BackgroundTransparency   = 1
    iconLbl.Font                     = Enum.Font.GothamBold
    iconLbl.TextSize                 = 22
    iconLbl.TextColor3               = COL_BDR_LOCKED
    iconLbl.TextTransparency         = 1
    iconLbl.TextXAlignment           = Enum.TextXAlignment.Center
    iconLbl.TextYAlignment           = Enum.TextYAlignment.Center
    iconLbl.Text                     = icon
    iconLbl.ZIndex                   = 53
    iconLbl.Parent                   = circle

    local nameLbl                    = Instance.new("TextLabel")
    nameLbl.Size                     = UDim2.fromOffset(D + 24, 16)
    nameLbl.AnchorPoint              = Vector2.new(0.5, 0)
    nameLbl.Position                 = UDim2.new(0.5, 0, 1, 4)
    nameLbl.BackgroundTransparency   = 1
    nameLbl.Font                     = Enum.Font.GothamBold
    nameLbl.TextSize                 = 11
    nameLbl.TextColor3               = C.TEXT
    nameLbl.TextTransparency         = 1
    nameLbl.TextXAlignment           = Enum.TextXAlignment.Center
    nameLbl.TextTruncate             = Enum.TextTruncate.AtEnd
    nameLbl.Text                     = techName
    nameLbl.ZIndex                   = 53
    nameLbl.Parent                   = circle

    local condLbl                    = Instance.new("TextLabel")
    condLbl.Size                     = UDim2.fromOffset(D + 32, 13)
    condLbl.AnchorPoint              = Vector2.new(0.5, 0)
    condLbl.Position                 = UDim2.new(0.5, 0, 1, 22)
    condLbl.BackgroundTransparency   = 1
    condLbl.Font                     = Enum.Font.Gotham
    condLbl.TextSize                 = 9
    condLbl.TextColor3               = C.DIM
    condLbl.TextTransparency         = 1
    condLbl.TextXAlignment           = Enum.TextXAlignment.Center
    condLbl.Text                     = condText
    condLbl.ZIndex                   = 53
    condLbl.Parent                   = circle

    nodeRefs[techName] = {
        circle  = circle,
        stroke  = stroke,
        icon    = iconLbl,
        nameLbl = nameLbl,
        condLbl = condLbl,
    }

    local stateVal = scope:Value("locked" :: NodeState)
    techStateVals[techName] = stateVal
    scope:Observer(stateVal):onChange(function()
        applyRef(techName, Fusion.peek(stateVal) :: NodeState)
    end)

    circle.MouseEnter:Connect(function()
        local tf  = tooltipFrame
        local tn  = tooltipName
        local td  = tooltipDesc
        local tc  = tooltipCond
        local tbg = tooltipBarBg
        local tfl = tooltipBarFill
        local c   = nodeCanvas
        if not tf or not tn or not td or not tc or not c then return end

        tn.Text = techName
        td.Text = (unlock.desc :: string?) or ""

        local st = Fusion.peek(stateVal) :: NodeState
        if st == "unlocked" then
            tc.Text       = "✓  " .. condText
            tc.TextColor3 = COL_BDR_UNLOCKED
        elseif st == "available" then
            tc.Text       = "◎  " .. condText
            tc.TextColor3 = COL_BDR_AVAIL
        elseif st == "excluded" then
            tc.Text       = "✗  Excluded (chose another)"
            tc.TextColor3 = C.DIM
        else
            local req = (unlock.requires :: string?)
            tc.Text = req and ("⚠ Requires " .. req .. " • " .. condText) or ("◎  " .. condText)
            tc.TextColor3 = C.SUBTEXT
        end

        -- Progress bar
        if tbg and tfl then
            local hr = hasResearchFn
            local fraction: number
            if st == "excluded" then
                tbg.Visible = false
                fraction = 0
            else
                tbg.Visible = true
                if hr and hr(techName) then
                    fraction = 1.0
                else
                    local fn = getCondProgressFn
                    fraction = fn and fn(techName) or 0
                end
                local fillColor =
                    st == "unlocked"  and COL_BDR_UNLOCKED or
                    st == "available" and COL_BDR_AVAIL     or
                    COL_BDR_LOCKED
                tfl.BackgroundColor3 = fillColor
                tfl.Size = UDim2.new(math.clamp(fraction, 0, 1), 0, 1, 0)
            end
        end

        -- Live tooltip position based on where the circle actually is after tweens
        local canvasAbs  = c.AbsolutePosition
        local canvasSize = c.AbsoluteSize
        local circleAbs  = circle.AbsolutePosition
        local cx  = circleAbs.X - canvasAbs.X + NODE_R
        local cy  = circleAbs.Y - canvasAbs.Y + NODE_R
        local tw  = tf.AbsoluteSize.X
        local xOff = cx + NODE_R + 4
        if xOff + tw > canvasSize.X then xOff = cx - NODE_R - 4 - tw end
        tf.Position = UDim2.fromOffset(
            math.clamp(math.floor(xOff), 0, canvasSize.X - tw),
            math.clamp(math.floor(cy - 30), 0, canvasSize.Y - 100)
        )
        tf.Visible = true
    end)
    circle.MouseLeave:Connect(function()
        if tooltipFrame then tooltipFrame.Visible = false end
    end)
end

-- ── Monument button helpers ───────────────────────────────────────────────────

local function refreshMonumentBtn()
    if not monBtn or not monLabel then return end
    local t   = localMonumentTime
    local res = resourcesFn and resourcesFn() or 0

    if t == nil then
        local canAfford = res >= Config.MONUMENT_COST
        monBtn.BackgroundColor3 = canAfford and Color3.fromRGB(60, 44, 0) or Color3.fromRGB(22, 22, 22)
        monLabel.Text       = "★  BUILD MONUMENT  —  ◆ " .. Config.MONUMENT_COST
        monLabel.TextColor3 = canAfford and C.GOLD or C.DIM
    elseif t == -1 then
        monBtn.BackgroundColor3 = Color3.fromRGB(30, 30, 10)
        monLabel.Text           = "★  MONUMENT  —  Rising…"
        monLabel.TextColor3     = C.GOLD
    else
        local mins = math.floor(t / 60)
        local secs = t % 60
        monBtn.BackgroundColor3 = Color3.fromRGB(8, 36, 8)
        monLabel.Text           = string.format("★  MONUMENT  —  %d:%02d remaining", mins, secs)
        monLabel.TextColor3     = C.GREEN
    end
end

-- ── Public API ────────────────────────────────────────────────────────────────

function WorkshopPanel.show(_ccId: string?)
    local ov = overlay
    if not ov then return end
    previewMode = false
    refreshAllNodes()
    refreshMonumentBtn()
    ov.Visible = true
end

function WorkshopPanel.hide()
    if overlay then overlay.Visible = false end
    if tooltipFrame then tooltipFrame.Visible = false end
    previewMode = false
end

function WorkshopPanel.refreshIfVisible()
    if overlay and overlay.Visible then
        refreshAllNodes()
        refreshMonumentBtn()
    end
end

function WorkshopPanel.resetMonument()
    localMonumentTime = nil
    refreshMonumentBtn()
end

function WorkshopPanel.onMonumentProgress(timeRemaining: number?)
    localMonumentTime = timeRemaining
    if overlay and overlay.Visible then refreshMonumentBtn() end
end

function WorkshopPanel.resetPlayer()
    lastLayoutPositions = {}
    previewMode = false
end

-- ── Init ──────────────────────────────────────────────────────────────────────

function WorkshopPanel.init(
    network:         any,
    hasResearch:     (string) -> boolean,
    resourcesGet:    () -> number,
    getCondProgress: ((string) -> number)?
)
    networkRef          = network
    hasResearchFn       = hasResearch
    resourcesFn         = resourcesGet
    getCondProgressFn   = getCondProgress

    local sg = Players.LocalPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui

    local ov                          = Instance.new("Frame")
    ov.Name                           = "TechGallery"
    ov.Size                           = UDim2.new(1, 0, 1, 0)
    ov.BackgroundColor3               = Color3.fromRGB(0, 0, 0)
    ov.BackgroundTransparency         = 0.45
    ov.BorderSizePixel                = 0
    ov.ZIndex                         = 48
    ov.Visible                        = false
    ov.Parent                         = sg
    overlay = ov

    local dimBlocker                  = Instance.new("TextButton")
    dimBlocker.Size                   = UDim2.new(1, 0, 1, 0)
    dimBlocker.BackgroundTransparency = 1
    dimBlocker.Text                   = ""
    dimBlocker.ZIndex                 = 49
    dimBlocker.Parent                 = ov
    dimBlocker.MouseButton1Click:Connect(WorkshopPanel.hide)

    local panel                       = Instance.new("Frame")
    panel.Name                        = "Panel"
    panel.Size                        = UDim2.fromOffset(PANEL_W, PANEL_H)
    panel.AnchorPoint                 = Vector2.new(0.5, 0.5)
    panel.Position                    = UDim2.new(0.5, 0, 0.5, 0)
    panel.BackgroundColor3            = COL_PANEL_BG
    panel.BackgroundTransparency      = 0
    panel.BorderSizePixel             = 0
    panel.ZIndex                      = 50
    panel.ClipsDescendants            = true
    panel.Parent                      = ov
    UILib.corner(panel, 14)
    UILib.stroke(panel, Color3.fromRGB(38, 48, 90), 1.5)

    local titleBar                    = Instance.new("Frame")
    titleBar.Size                     = UDim2.new(1, 0, 0, TITLE_H)
    titleBar.BackgroundColor3         = Color3.fromRGB(10, 12, 24)
    titleBar.BackgroundTransparency   = 0
    titleBar.BorderSizePixel          = 0
    titleBar.ZIndex                   = 51
    titleBar.Parent                   = panel
    UILib.corner(titleBar, 14)

    local sq             = Instance.new("Frame")
    sq.Size              = UDim2.new(1, 0, 0, 14)
    sq.Position          = UDim2.new(0, 0, 1, -14)
    sq.BackgroundColor3  = Color3.fromRGB(10, 12, 24)
    sq.BorderSizePixel   = 0
    sq.ZIndex            = 51
    sq.Parent            = titleBar

    UILib.lbl(titleBar, "⚗  TECH TREE",
        UDim2.new(1, -50, 1, 0), UDim2.fromOffset(14, 0),
        { bold = true, size = 16, color = C.TEXT, zIndex = 52 })


    local closeBtn                    = Instance.new("TextButton")
    closeBtn.Size                     = UDim2.fromOffset(28, 28)
    closeBtn.Position                 = UDim2.new(1, -36, 0.5, -14)
    closeBtn.BackgroundColor3         = Color3.fromRGB(130, 30, 30)
    closeBtn.BackgroundTransparency   = 0.1
    closeBtn.BorderSizePixel          = 0
    closeBtn.Font                     = Enum.Font.GothamBold
    closeBtn.TextSize                 = 13
    closeBtn.TextColor3               = C.TEXT
    closeBtn.Text                     = "✕"
    closeBtn.ZIndex                   = 53
    closeBtn.Parent                   = titleBar
    UILib.corner(closeBtn, 6)
    closeBtn.MouseButton1Click:Connect(WorkshopPanel.hide)

    local mb                          = Instance.new("TextButton")
    mb.Size                           = UDim2.fromOffset(PANEL_W - 20, MON_H)
    mb.AnchorPoint                    = Vector2.new(0, 1)
    mb.Position                       = UDim2.new(0, 10, 1, -MON_PAD_B)
    mb.BackgroundColor3               = Color3.fromRGB(60, 44, 0)
    mb.BackgroundTransparency         = 0
    mb.BorderSizePixel                = 0
    mb.Text                           = ""
    mb.AutoButtonColor                = false
    mb.ZIndex                         = 51
    mb.Parent                         = panel
    UILib.corner(mb, 6)
    UILib.stroke(mb, C.GOLD, 1)
    monBtn = mb

    local mLbl                        = Instance.new("TextLabel")
    mLbl.Size                         = UDim2.new(1, 0, 1, 0)
    mLbl.BackgroundTransparency       = 1
    mLbl.Font                         = Enum.Font.GothamBold
    mLbl.TextSize                     = 13
    mLbl.TextColor3                   = C.GOLD
    mLbl.TextXAlignment               = Enum.TextXAlignment.Center
    mLbl.Text                         = "★  BUILD MONUMENT  —  ◆ " .. Config.MONUMENT_COST
    mLbl.ZIndex                       = 52
    mLbl.Parent                       = mb
    monLabel = mLbl

    mb.MouseEnter:Connect(function()
        if localMonumentTime ~= nil then return end
        TweenService:Create(mb, TweenInfo.new(0.1), { BackgroundColor3 = Color3.fromRGB(80, 60, 0) }):Play()
    end)
    mb.MouseLeave:Connect(function()
        if localMonumentTime ~= nil then return end
        TweenService:Create(mb, TweenInfo.new(0.1), { BackgroundColor3 = Color3.fromRGB(60, 44, 0) }):Play()
    end)
    mb.MouseButton1Click:Connect(function()
        if localMonumentTime ~= nil then return end
        if (resourcesFn and resourcesFn() or 0) < Config.MONUMENT_COST then return end
        networkRef.buildMonument()
    end)

    local CANVAS_H = PANEL_H - TITLE_H - (MON_PAD_B + MON_H + MON_PAD_B)
    local canvas                      = Instance.new("Frame")
    canvas.Name                       = "NodeCanvas"
    canvas.Size                       = UDim2.fromOffset(PANEL_W, CANVAS_H)
    canvas.Position                   = UDim2.fromOffset(0, TITLE_H)
    canvas.BackgroundTransparency     = 1
    canvas.BorderSizePixel            = 0
    canvas.ZIndex                     = 50
    canvas.ClipsDescendants           = false
    canvas.Parent                     = panel
    nodeCanvas = canvas

    -- "Press Y to reveal all paths" hint pill at the bottom of the canvas
    do
        local tipPill                       = Instance.new("Frame")
        tipPill.Size                        = UDim2.fromOffset(248, 22)
        tipPill.AnchorPoint                 = Vector2.new(0.5, 1)
        tipPill.Position                    = UDim2.new(0.5, 0, 1, -8)
        tipPill.BackgroundColor3            = Color3.fromRGB(12, 13, 26)
        tipPill.BackgroundTransparency      = 0.15
        tipPill.BorderSizePixel             = 0
        tipPill.ZIndex                      = 51
        tipPill.Parent                      = canvas
        UILib.corner(tipPill, 8)
        UILib.stroke(tipPill, Color3.fromRGB(38, 44, 80), 1)

        local tipLbl                        = Instance.new("TextLabel")
        tipLbl.Size                         = UDim2.new(1, 0, 1, 0)
        tipLbl.BackgroundTransparency       = 1
        tipLbl.Font                         = Enum.Font.Gotham
        tipLbl.TextSize                     = 10
        tipLbl.TextColor3                   = Color3.fromRGB(130, 138, 180)
        tipLbl.TextXAlignment               = Enum.TextXAlignment.Center
        tipLbl.Text                         = "⌨  Press Y to reveal all upgrade paths"
        tipLbl.ZIndex                       = 52
        tipLbl.Parent                       = tipPill
    end

    -- Tooltip (height 100px to fit the progress bar)
    local tf                          = Instance.new("Frame")
    tf.Name                           = "Tooltip"
    tf.Size                           = UDim2.fromOffset(196, 100)
    tf.BackgroundColor3               = Color3.fromRGB(10, 12, 26)
    tf.BackgroundTransparency         = 0.05
    tf.BorderSizePixel                = 0
    tf.ZIndex                         = 60
    tf.Visible                        = false
    tf.Parent                         = canvas
    UILib.corner(tf, 6)
    UILib.stroke(tf, Color3.fromRGB(50, 60, 100), 1)
    tooltipFrame = tf

    local ttName                      = Instance.new("TextLabel")
    ttName.Size                       = UDim2.new(1, -8, 0, 18)
    ttName.Position                   = UDim2.fromOffset(6, 5)
    ttName.BackgroundTransparency     = 1
    ttName.Font                       = Enum.Font.GothamBold
    ttName.TextSize                   = 13
    ttName.TextColor3                 = C.TEXT
    ttName.TextXAlignment             = Enum.TextXAlignment.Left
    ttName.Text                       = ""
    ttName.ZIndex                     = 61
    ttName.Parent                     = tf
    tooltipName = ttName

    local ttDesc                      = Instance.new("TextLabel")
    ttDesc.Size                       = UDim2.new(1, -8, 0, 30)
    ttDesc.Position                   = UDim2.fromOffset(6, 24)
    ttDesc.BackgroundTransparency     = 1
    ttDesc.Font                       = Enum.Font.Gotham
    ttDesc.TextSize                   = 10
    ttDesc.TextColor3                 = C.SUBTEXT
    ttDesc.TextXAlignment             = Enum.TextXAlignment.Left
    ttDesc.TextWrapped                = true
    ttDesc.Text                       = ""
    ttDesc.ZIndex                     = 61
    ttDesc.Parent                     = tf
    tooltipDesc = ttDesc

    local ttCond                      = Instance.new("TextLabel")
    ttCond.Size                       = UDim2.new(1, -8, 0, 14)
    ttCond.Position                   = UDim2.fromOffset(6, 56)
    ttCond.BackgroundTransparency     = 1
    ttCond.Font                       = Enum.Font.GothamBold
    ttCond.TextSize                   = 10
    ttCond.TextColor3                 = C.DIM
    ttCond.TextXAlignment             = Enum.TextXAlignment.Left
    ttCond.Text                       = ""
    ttCond.ZIndex                     = 61
    ttCond.Parent                     = tf
    tooltipCond = ttCond

    -- Progress bar background
    local barBg                       = Instance.new("Frame")
    barBg.Name                        = "BarBg"
    barBg.Size                        = UDim2.new(1, -12, 0, 10)
    barBg.Position                    = UDim2.fromOffset(6, 76)
    barBg.BackgroundColor3            = Color3.fromRGB(14, 14, 24)
    barBg.BackgroundTransparency      = 0
    barBg.BorderSizePixel             = 0
    barBg.ZIndex                      = 61
    barBg.ClipsDescendants            = true
    barBg.Parent                      = tf
    UILib.corner(barBg, 4)
    UILib.stroke(barBg, Color3.fromRGB(30, 30, 50), 1)
    tooltipBarBg = barBg

    -- Progress bar fill
    local barFill                     = Instance.new("Frame")
    barFill.Name                      = "BarFill"
    barFill.Size                      = UDim2.new(0, 0, 1, 0)
    barFill.BackgroundColor3          = COL_BDR_LOCKED
    barFill.BackgroundTransparency    = 0
    barFill.BorderSizePixel           = 0
    barFill.ZIndex                    = 62
    barFill.Parent                    = barBg
    UILib.corner(barFill, 4)
    tooltipBarFill = barFill

    -- Build graph, create connector placeholders, then node instances
    fullGraph = buildGraph()

    for techName, node in fullGraph do
        local parentName = node.parent
        if parentName then
            createConnectorPlaceholder(canvas, parentName .. "|" .. techName)
        end
    end

    for techName in fullGraph do
        buildNode(canvas, techName)
    end

    -- Y key: toggle preview mode while panel is open
    UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
        if processed then return end
        if input.KeyCode ~= Enum.KeyCode.Y then return end
        if not (overlay and overlay.Visible) then return end
        previewMode = not previewMode
        refreshAllNodes()
    end)

    refreshMonumentBtn()
end

return WorkshopPanel
