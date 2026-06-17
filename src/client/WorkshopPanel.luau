--!strict
--[[
    WorkshopPanel — research / upgrade browser (opens on R).

    Layout:
      • Top-left: two category tabs — Infra and Army.
      • Below the tabs: a scrollable, grocery-style list of that category's upgrades.
        Each row = [3D thumbnail of the unit/structure] + [upgrade name].
        In-progress researches jump to the top with a progress bar; completed
        ("Upgraded") ones sit just below them.
      • Right: a tooltip pane for the selected upgrade —
          name → large rotating 3D viewport (drag to spin) → UPGRADE button →
          one-line description → colour-coded requirement list.

    Research is manual: requirements only gate the UPGRADE button (no cost). Clicking
    it starts a Config.UPGRADE_TIME research; max Config.MAX_CONCURRENT_RESEARCH per
    category run at once. The server grants the tech when the timer finishes.
]]

local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))
local ViewportPreview   = require(script.Parent:WaitForChild("ViewportPreview"))

local WorkshopPanel = {}
local C             = UILib.C

-- ── Palette ───────────────────────────────────────────────────────────────────
local COL_PANEL_BG   = Color3.fromRGB( 7,   9,  18)
local COL_HEADER     = Color3.fromRGB(10,  12,  24)
local COL_LIST_BG    = Color3.fromRGB( 9,  11,  22)
local COL_ROW        = Color3.fromRGB(15,  19,  36)
local COL_ROW_SEL    = Color3.fromRGB(26,  34,  62)
local COL_TAB_ON     = Color3.fromRGB(30,  42,  78)
local COL_TAB_OFF    = Color3.fromRGB(13,  16,  30)
local COL_RED        = Color3.fromRGB(208,  62,  58)
local COL_YELLOW     = Color3.fromRGB(225, 180,  45)
local COL_GREEN      = Color3.fromRGB( 52, 200,  92)

-- ── Geometry ──────────────────────────────────────────────────────────────────
local PANEL_W   = 880
local PANEL_H   = 600
local TITLE_H   = 40
local CONTENT_Y = TITLE_H + 8
local CONTENT_H = PANEL_H - CONTENT_Y - 12

local LEFT_X    = 12
local LEFT_W    = 360
local TAB_H     = 32
local LIST_Y    = CONTENT_Y + TAB_H + 8

local RIGHT_X   = LEFT_X + LEFT_W + 14
local RIGHT_W   = PANEL_W - RIGHT_X - 12

local ROW_H     = 58
local VP_BOX    = 290   -- large tooltip viewport square

-- ── External hooks ──────────────────────────────────────────────────────────────
local networkRef:        any
local hasResearchFn:     ((string) -> boolean)?
local resourcesFn:       (() -> number)?
-- getCondInfo(techName) -> { current:number, needed:number, label:string }
local getCondInfoFn:     ((string) -> { current: number, needed: number, label: string })?
local localMonumentTime: number?

-- ── Module state ──────────────────────────────────────────────────────────────
local overlay:     Frame?
local listScroll:  ScrollingFrame?
local tabButtons:  { [string]: TextButton } = {}
local autoBtn:     TextButton?

local currentTab:    string  = "Infra"
local selectedTech:  string? = nil
local autoUpgrade:   boolean = true   -- auto-research whenever an upgrade is available

-- techName → server-clock end time of its in-progress research
local upgradingEnd: { [string]: number } = {}

-- Per-tech row widgets in the list
type RowRef = {
    frame:    TextButton,
    nameLbl:  TextLabel,
    tagLbl:   TextLabel,
    barBg:    Frame,
    barFill:  Frame,
    stroke:   UIStroke,
}
local rowRefs:    { [string]: RowRef } = {}
local alphaIndex: { [string]: number } = {}

-- Tooltip widgets
local ttName:     TextLabel?
local vpHolder:   Frame?
local ttBtn:      TextButton?
local ttBtnFill:  Frame?
local ttBtnLbl:   TextLabel?
local ttDesc:     TextLabel?
local ttReqHolder: Frame?

-- Rotating viewport state
local currentOrbit: ViewportPreview.Orbit? = nil
local currentYaw:   number  = math.rad(35)
local dragging:     boolean = false
local dragLastX:    number  = 0

-- ── Helpers ─────────────────────────────────────────────────────────────────────

local function techTitle(techName: string): string
    local u = (Config.UNLOCKS :: any)[techName]
    return (u and (u.title :: string?)) or techName
end

type TechState = "done" | "upgrading" | "available" | "locked" | "excluded"

local function groupSiblingDone(techName: string): boolean
    local u     = (Config.UNLOCKS :: any)[techName]
    local group = u and (u.group :: string?)
    if not group then return false end
    local hr = hasResearchFn
    if not hr then return false end
    for other, otherU in (Config.UNLOCKS :: any) do
        if other ~= techName and (otherU.group :: string?) == group and hr(other) then
            return true
        end
    end
    return false
end

-- Returns the requirement list for a tech: { {label, met, inProgress, detail}, ... }
local function requirementsFor(techName: string): { { label: string, met: boolean, inProgress: boolean, detail: string } }
    local u    = (Config.UNLOCKS :: any)[techName]
    local hr   = hasResearchFn
    local reqs = {}

    local requires = u and (u.requires :: string?)
    if requires then
        local done = hr and hr(requires) or false
        local prog = upgradingEnd[requires] ~= nil and not done
        table.insert(reqs, {
            label      = "Research " .. techTitle(requires),
            met        = done,
            inProgress = prog,
            detail     = done and "Researched" or (prog and "Researching…" or "Not yet researched"),
        })
    end

    local info = getCondInfoFn and getCondInfoFn(techName)
    if info then
        local met = info.current >= info.needed
        table.insert(reqs, {
            label      = info.label,
            met        = met,
            inProgress = (not met) and info.current > 0,
            detail     = string.format("%d / %d", math.min(info.current, info.needed), info.needed),
        })
    end

    return reqs
end

local function requirementsMet(techName: string): boolean
    for _, r in requirementsFor(techName) do
        if not r.met then return false end
    end
    return true
end

local function techStateOf(techName: string): TechState
    local hr = hasResearchFn
    if hr and hr(techName)        then return "done" end
    if upgradingEnd[techName]     then return "upgrading" end
    if groupSiblingDone(techName) then return "excluded" end
    if requirementsMet(techName)  then return "available" end
    return "locked"
end

-- How many researches are currently running in a category (excludes finished ones).
local function activeInCategory(cat: string): number
    local n  = 0
    local hr = hasResearchFn
    for tech in upgradingEnd do
        local u = (Config.UNLOCKS :: any)[tech]
        if u and (u.category :: string?) == cat and not (hr and hr(tech)) then
            n += 1
        end
    end
    return n
end

-- When auto-upgrade is on, start any available research that has a free slot in
-- its category. Runs regardless of whether the panel is open. Server re-validates
-- every request, so duplicate/over-cap requests are harmless.
local function runAutoUpgrade()
    if not autoUpgrade or not networkRef or not hasResearchFn then return end
    for _, cat in { "Infra", "Army" } do
        local slots = Config.MAX_CONCURRENT_RESEARCH - activeInCategory(cat)
        if slots <= 0 then continue end
        for tech in (Config.UNLOCKS :: any) do
            if slots <= 0 then break end
            local u = (Config.UNLOCKS :: any)[tech]
            if (u.category :: string) == cat and techStateOf(tech) == "available" then
                networkRef.requestUpgrade(tech)
                slots -= 1
            end
        end
    end
end

-- ── List ─────────────────────────────────────────────────────────────────────

local function selectTech(techName: string)
    selectedTech = techName
    WorkshopPanel.refreshIfVisible()
    -- Rebuild the rotating viewport for the new selection.
    local holder = vpHolder
    if holder then
        if currentOrbit then currentOrbit.vpf:Destroy() end
        local u = (Config.UNLOCKS :: any)[techName]
        local vp = u and (u.vp :: any)
        if vp then
            local teamColor = Players.LocalPlayer.TeamColor
            local size      = Vector2.new(VP_BOX, VP_BOX)
            local orbit: ViewportPreview.Orbit
            if vp.kind == "building" then
                orbit = ViewportPreview.forBuildingOrbit(vp.name, size, teamColor)
            else
                orbit = ViewportPreview.forUnitOrbit(vp.name, size, teamColor)
            end
            orbit.vpf.Position = UDim2.fromScale(0.5, 0.5)
            orbit.vpf.AnchorPoint = Vector2.new(0.5, 0.5)
            orbit.vpf.ZIndex   = 54
            orbit.vpf.Parent   = holder
            currentOrbit = orbit
            orbit.setYaw(currentYaw)
        end
    end
end

local function buildRow(techName: string)
    local scroll = listScroll
    if not scroll then return end
    local u = (Config.UNLOCKS :: any)[techName]

    local row                     = Instance.new("TextButton")
    row.Name                      = "Row_" .. techName
    row.Size                      = UDim2.new(1, -8, 0, ROW_H)
    row.BackgroundColor3          = COL_ROW
    row.BackgroundTransparency    = 0.05
    row.BorderSizePixel           = 0
    row.AutoButtonColor           = false
    row.Text                      = ""
    row.ZIndex                    = 52
    row.Parent                    = scroll
    UILib.corner(row, 8)
    local stroke = UILib.stroke(row, Color3.fromRGB(28, 36, 64), 1)

    -- 3D thumbnail
    local vp = u and (u.vp :: any)
    if vp then
        local thumbSize = Vector2.new(ROW_H - 12, ROW_H - 12)
        local thumb: ViewportFrame
        local teamColor = Players.LocalPlayer.TeamColor
        if vp.kind == "building" then
            thumb = ViewportPreview.forBuilding(vp.name, thumbSize, teamColor)
        else
            thumb = ViewportPreview.forUnit(vp.name, thumbSize, teamColor)
        end
        thumb.Position = UDim2.fromOffset(6, 6)
        thumb.ZIndex   = 53
        thumb.Parent   = row
    end

    local nameLbl                 = Instance.new("TextLabel")
    nameLbl.Size                  = UDim2.new(1, -(ROW_H + 86), 1, 0)
    nameLbl.Position              = UDim2.fromOffset(ROW_H + 2, 0)
    nameLbl.BackgroundTransparency = 1
    nameLbl.Font                  = Enum.Font.GothamBold
    nameLbl.TextSize              = 14
    nameLbl.TextColor3            = C.TEXT
    nameLbl.TextXAlignment        = Enum.TextXAlignment.Left
    nameLbl.TextYAlignment        = Enum.TextYAlignment.Center
    nameLbl.TextTruncate          = Enum.TextTruncate.AtEnd
    nameLbl.Text                  = techTitle(techName)
    nameLbl.ZIndex                = 53
    nameLbl.Parent                = row

    local tagLbl                  = Instance.new("TextLabel")
    tagLbl.Size                   = UDim2.fromOffset(78, ROW_H)
    tagLbl.AnchorPoint            = Vector2.new(1, 0)
    tagLbl.Position               = UDim2.new(1, -8, 0, 0)
    tagLbl.BackgroundTransparency = 1
    tagLbl.Font                   = Enum.Font.GothamBold
    tagLbl.TextSize               = 10
    tagLbl.TextXAlignment         = Enum.TextXAlignment.Right
    tagLbl.TextYAlignment         = Enum.TextYAlignment.Center
    tagLbl.Text                   = ""
    tagLbl.ZIndex                 = 53
    tagLbl.Parent                 = row

    -- Progress bar (visible only while upgrading)
    local barBg                   = Instance.new("Frame")
    barBg.Size                    = UDim2.new(1, -(ROW_H + 16), 0, 4)
    barBg.AnchorPoint             = Vector2.new(0, 1)
    barBg.Position                = UDim2.new(0, ROW_H + 2, 1, -7)
    barBg.BackgroundColor3        = Color3.fromRGB(12, 14, 26)
    barBg.BorderSizePixel         = 0
    barBg.ClipsDescendants        = true
    barBg.Visible                 = false
    barBg.ZIndex                  = 53
    barBg.Parent                  = row
    UILib.corner(barBg, 2)

    local barFill                 = Instance.new("Frame")
    barFill.Size                  = UDim2.new(0, 0, 1, 0)
    barFill.BackgroundColor3      = COL_YELLOW
    barFill.BorderSizePixel       = 0
    barFill.ZIndex                = 54
    barFill.Parent                = barBg
    UILib.corner(barFill, 2)

    row.MouseButton1Click:Connect(function() selectTech(techName) end)

    rowRefs[techName] = {
        frame = row, nameLbl = nameLbl, tagLbl = tagLbl,
        barBg = barBg, barFill = barFill, stroke = stroke,
    }
end

-- ── Tooltip refresh ─────────────────────────────────────────────────────────────

local function clearChildren(holder: Frame)
    for _, ch in holder:GetChildren() do
        if ch:IsA("GuiObject") then ch:Destroy() end
    end
end

local function refreshTooltip()
    local tech = selectedTech
    if not (ttName and ttBtn and ttBtnLbl and ttDesc and ttReqHolder) then return end
    local nameL   = ttName :: TextLabel
    local btn     = ttBtn :: TextButton
    local btnLbl  = ttBtnLbl :: TextLabel
    local btnFill = ttBtnFill :: Frame
    local descL   = ttDesc :: TextLabel
    local reqH    = ttReqHolder :: Frame

    if not tech then
        nameL.Text = "Select an upgrade"
        descL.Text = ""
        btn.Visible = false
        if vpHolder then (vpHolder :: Frame).Visible = false end
        clearChildren(reqH)
        return
    end
    if vpHolder then (vpHolder :: Frame).Visible = true end

    local u  = (Config.UNLOCKS :: any)[tech]
    local st = techStateOf(tech)

    nameL.Text = techTitle(tech)
    descL.Text = (u.desc :: string?) or ""

    -- Upgrade button
    btn.Visible = true
    btnFill.Size = UDim2.new(0, 0, 1, 0)
    if st == "done" then
        btn.AutoButtonColor   = false
        btn.BackgroundColor3   = Color3.fromRGB(14, 46, 24)
        btnLbl.Text            = "✓  UPGRADED"
        btnLbl.TextColor3      = COL_GREEN
    elseif st == "upgrading" then
        btn.AutoButtonColor   = false
        btn.BackgroundColor3   = Color3.fromRGB(40, 38, 12)
        btnLbl.Text            = "UPGRADING…"
        btnLbl.TextColor3      = COL_YELLOW
    elseif st == "excluded" then
        btn.AutoButtonColor   = false
        btn.BackgroundColor3   = Color3.fromRGB(20, 20, 28)
        btnLbl.Text            = "UNAVAILABLE"
        btnLbl.TextColor3      = C.DIM
    elseif st == "available" then
        local atLimit = activeInCategory(u.category :: string) >= Config.MAX_CONCURRENT_RESEARCH
        if atLimit then
            btn.AutoButtonColor = false
            btn.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
            btnLbl.Text          = "UPGRADE — slots full"
            btnLbl.TextColor3    = C.DIM
        else
            btn.AutoButtonColor  = true
            btn.BackgroundColor3 = Color3.fromRGB(58, 44, 0)
            btnLbl.Text          = "▲  UPGRADE"
            btnLbl.TextColor3    = C.GOLD
        end
    else -- locked
        btn.AutoButtonColor   = false
        btn.BackgroundColor3   = Color3.fromRGB(20, 20, 28)
        btnLbl.Text            = "UPGRADE"
        btnLbl.TextColor3      = C.DIM
    end

    -- Requirements list
    clearChildren(reqH)
    local y = 0
    for _, r in requirementsFor(tech) do
        local col = r.met and COL_GREEN or (r.inProgress and COL_YELLOW or COL_RED)
        local mark = r.met and "●" or (r.inProgress and "◐" or "○")

        local rl                     = Instance.new("TextLabel")
        rl.Size                      = UDim2.new(1, 0, 0, 18)
        rl.Position                  = UDim2.fromOffset(0, y)
        rl.BackgroundTransparency    = 1
        rl.Font                      = Enum.Font.GothamMedium
        rl.TextSize                  = 12
        rl.TextColor3                = col
        rl.TextXAlignment            = Enum.TextXAlignment.Left
        rl.TextYAlignment            = Enum.TextYAlignment.Center
        rl.Text                      = mark .. "  " .. r.label
        rl.ZIndex                    = 53
        rl.Parent                    = reqH

        -- Hover reveals the progress detail in place of the label.
        local baseText = rl.Text
        local detail   = r.detail
        rl.MouseEnter:Connect(function() rl.Text = mark .. "  " .. detail end)
        rl.MouseLeave:Connect(function() rl.Text = baseText end)

        y += 20
    end
end

-- ── Full refresh ─────────────────────────────────────────────────────────────

local function rankOf(st: TechState): number
    if st == "upgrading"  then return 0 end
    if st == "done"       then return 1 end
    if st == "available"  then return 2 end
    if st == "locked"     then return 3 end
    return 4  -- excluded
end

local function refreshList()
    local hr = hasResearchFn
    for tech, ref in rowRefs do
        local u   = (Config.UNLOCKS :: any)[tech]
        local cat = u.category :: string
        if cat ~= currentTab then
            ref.frame.Visible = false
            continue
        end
        ref.frame.Visible = true

        -- Drop finished researches from the in-progress set.
        if upgradingEnd[tech] and hr and hr(tech) then upgradingEnd[tech] = nil end

        local st = techStateOf(tech)
        ref.frame.LayoutOrder = rankOf(st) * 1000 + (alphaIndex[tech] or 0)

        -- Tag + colours
        if st == "upgrading" then
            ref.tagLbl.Text       = "UPGRADING"
            ref.tagLbl.TextColor3 = COL_YELLOW
            ref.barBg.Visible     = true
        elseif st == "done" then
            ref.tagLbl.Text       = "✓ UPGRADED"
            ref.tagLbl.TextColor3 = COL_GREEN
            ref.barBg.Visible     = false
        elseif st == "available" then
            ref.tagLbl.Text       = "READY"
            ref.tagLbl.TextColor3 = C.GOLD
            ref.barBg.Visible     = false
        elseif st == "excluded" then
            ref.tagLbl.Text       = "LOCKED"
            ref.tagLbl.TextColor3 = C.DIM
            ref.barBg.Visible     = false
        else
            ref.tagLbl.Text       = ""
            ref.barBg.Visible     = false
        end

        local isSel = selectedTech == tech
        ref.frame.BackgroundColor3 = isSel and COL_ROW_SEL or COL_ROW
        ref.stroke.Color           = isSel and C.GOLD or Color3.fromRGB(28, 36, 64)
        ref.stroke.Thickness       = isSel and 1.5 or 1
        ref.nameLbl.TextColor3     = (st == "locked" or st == "excluded") and C.SUBTEXT or C.TEXT
    end
end

local function refreshAutoBtn()
    local b = autoBtn
    if not b then return end
    if autoUpgrade then
        b.BackgroundColor3 = Color3.fromRGB(14, 46, 24)
        b.TextColor3       = COL_GREEN
        b.Text             = "AUTO-UPGRADE: ON"
    else
        b.BackgroundColor3 = Color3.fromRGB(26, 26, 34)
        b.TextColor3       = C.DIM
        b.Text             = "AUTO-UPGRADE: OFF"
    end
end

local function setTab(tab: string)
    currentTab = tab
    for name, btn in tabButtons do
        local on = name == tab
        btn.BackgroundColor3 = on and COL_TAB_ON or COL_TAB_OFF
        btn.TextColor3       = on and C.TEXT or C.SUBTEXT
    end
    -- Auto-select the first visible tech in this tab if nothing selected here.
    local sel = selectedTech
    local selCat = sel and (((Config.UNLOCKS :: any)[sel] or {}).category)
    if selCat ~= tab then
        local best: string? = nil
        local bestRank = math.huge
        for tech in rowRefs do
            local u = (Config.UNLOCKS :: any)[tech]
            if (u.category :: string) == tab then
                local r = rankOf(techStateOf(tech)) * 1000 + (alphaIndex[tech] or 0)
                if r < bestRank then bestRank = r; best = tech end
            end
        end
        if best then selectTech(best) end
    end
    refreshList()
    refreshTooltip()
end

-- ── Public API ────────────────────────────────────────────────────────────────

function WorkshopPanel.show(_ccId: string?)
    local ov = overlay
    if not ov then return end
    setTab(currentTab)   -- refreshes list/tooltip and auto-selects if needed
    ov.Visible = true
end

function WorkshopPanel.hide()
    if overlay then overlay.Visible = false end
end

function WorkshopPanel.refreshIfVisible()
    if overlay and overlay.Visible then
        refreshList()
        refreshTooltip()
    end
end

-- Called by init.client on cond-progress / unlock events so auto-upgrade works
-- even when the panel is closed.
function WorkshopPanel.runAutoUpgrade()
    runAutoUpgrade()
end

function WorkshopPanel.onUpgradeStarted(techName: string, endTime: number)
    upgradingEnd[techName] = endTime
    WorkshopPanel.refreshIfVisible()
end

-- Monument was removed from this panel; kept as no-ops for existing callers.
function WorkshopPanel.resetMonument()
    localMonumentTime = nil
end

function WorkshopPanel.onMonumentProgress(timeRemaining: number?)
    localMonumentTime = timeRemaining
end

function WorkshopPanel.resetPlayer()
    upgradingEnd = {}
    selectedTech = nil
    autoUpgrade  = true   -- defaults back on each new game
    refreshAutoBtn()
end

-- ── Init ──────────────────────────────────────────────────────────────────────

function WorkshopPanel.init(
    network:     any,
    hasResearch: (string) -> boolean,
    resourcesGet: () -> number,
    getCondInfo: ((string) -> { current: number, needed: number, label: string })?
)
    networkRef      = network
    hasResearchFn   = hasResearch
    resourcesFn     = resourcesGet
    getCondInfoFn   = getCondInfo

    local sg = Players.LocalPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui

    local ov                     = Instance.new("Frame")
    ov.Name                      = "TechGallery"
    ov.Size                      = UDim2.new(1, 0, 1, 0)
    ov.BackgroundColor3          = Color3.fromRGB(0, 0, 0)
    ov.BackgroundTransparency    = 0.45
    ov.BorderSizePixel           = 0
    ov.ZIndex                    = 48
    ov.Visible                   = false
    ov.Parent                    = sg
    overlay = ov

    local dimBlocker                  = Instance.new("TextButton")
    dimBlocker.Size                   = UDim2.new(1, 0, 1, 0)
    dimBlocker.BackgroundTransparency = 1
    dimBlocker.Text                   = ""
    dimBlocker.ZIndex                 = 49
    dimBlocker.Parent                 = ov
    dimBlocker.MouseButton1Click:Connect(WorkshopPanel.hide)

    local panel                  = Instance.new("Frame")
    panel.Name                   = "Panel"
    panel.Size                   = UDim2.fromOffset(PANEL_W, PANEL_H)
    panel.AnchorPoint            = Vector2.new(0.5, 0.5)
    panel.Position               = UDim2.new(0.5, 0, 0.5, 0)
    panel.BackgroundColor3       = COL_PANEL_BG
    panel.BorderSizePixel        = 0
    panel.ZIndex                 = 50
    panel.ClipsDescendants       = true
    panel.Parent                 = ov
    UILib.corner(panel, 14)
    UILib.stroke(panel, Color3.fromRGB(38, 48, 90), 1.5)

    -- Title bar
    local titleBar               = Instance.new("Frame")
    titleBar.Size                = UDim2.new(1, 0, 0, TITLE_H)
    titleBar.BackgroundColor3    = COL_HEADER
    titleBar.BorderSizePixel     = 0
    titleBar.ZIndex              = 51
    titleBar.Parent              = panel
    UILib.lbl(titleBar, "⚗  RESEARCH",
        UDim2.new(1, -50, 1, 0), UDim2.fromOffset(14, 0),
        { bold = true, size = 16, color = C.TEXT, zIndex = 52 })

    local closeBtn               = Instance.new("TextButton")
    closeBtn.Size                = UDim2.fromOffset(28, 28)
    closeBtn.Position            = UDim2.new(1, -36, 0.5, -14)
    closeBtn.BackgroundColor3    = Color3.fromRGB(130, 30, 30)
    closeBtn.BorderSizePixel     = 0
    closeBtn.Font                = Enum.Font.GothamBold
    closeBtn.TextSize            = 13
    closeBtn.TextColor3          = C.TEXT
    closeBtn.Text                = "✕"
    closeBtn.ZIndex              = 53
    closeBtn.Parent              = titleBar
    UILib.corner(closeBtn, 6)
    closeBtn.MouseButton1Click:Connect(WorkshopPanel.hide)

    -- Auto-upgrade toggle (on by default)
    local ab                     = Instance.new("TextButton")
    ab.Size                      = UDim2.fromOffset(168, 26)
    ab.Position                  = UDim2.new(1, -214, 0.5, -13)
    ab.BackgroundColor3          = Color3.fromRGB(14, 46, 24)
    ab.BorderSizePixel           = 0
    ab.AutoButtonColor           = false
    ab.Font                      = Enum.Font.GothamBold
    ab.TextSize                  = 12
    ab.TextColor3                = COL_GREEN
    ab.Text                      = "AUTO-UPGRADE: ON"
    ab.ZIndex                    = 53
    ab.Parent                    = titleBar
    UILib.corner(ab, 6)
    UILib.stroke(ab, Color3.fromRGB(40, 70, 50), 1)
    autoBtn = ab
    ab.MouseButton1Click:Connect(function()
        autoUpgrade = not autoUpgrade
        refreshAutoBtn()
        if autoUpgrade then runAutoUpgrade() end
        WorkshopPanel.refreshIfVisible()
    end)

    -- Category tabs
    local TAB_W = (LEFT_W - 8) / 2
    local function makeTab(name: string, label: string, xi: number)
        local b                  = Instance.new("TextButton")
        b.Size                   = UDim2.fromOffset(TAB_W, TAB_H)
        b.Position               = UDim2.fromOffset(LEFT_X + xi * (TAB_W + 8), CONTENT_Y)
        b.BackgroundColor3       = COL_TAB_OFF
        b.BorderSizePixel        = 0
        b.AutoButtonColor        = false
        b.Font                   = Enum.Font.GothamBold
        b.TextSize               = 14
        b.TextColor3             = C.SUBTEXT
        b.Text                   = label
        b.ZIndex                 = 52
        b.Parent                 = panel
        UILib.corner(b, 8)
        b.MouseButton1Click:Connect(function() setTab(name) end)
        tabButtons[name] = b
    end
    makeTab("Infra", "🏭  INFRA", 0)
    makeTab("Army",  "⚔  ARMY",  1)

    -- Scrollable list
    local scroll                  = Instance.new("ScrollingFrame")
    scroll.Name                   = "List"
    scroll.Size                   = UDim2.fromOffset(LEFT_W, CONTENT_Y + CONTENT_H - LIST_Y)
    scroll.Position               = UDim2.fromOffset(LEFT_X, LIST_Y)
    scroll.BackgroundColor3       = COL_LIST_BG
    scroll.BackgroundTransparency = 0.25
    scroll.BorderSizePixel        = 0
    scroll.ScrollBarThickness     = 6
    scroll.ScrollBarImageColor3   = Color3.fromRGB(50, 62, 100)
    scroll.CanvasSize             = UDim2.new()
    scroll.AutomaticCanvasSize    = Enum.AutomaticSize.Y
    scroll.ZIndex                 = 51
    scroll.Parent                 = panel
    UILib.corner(scroll, 8)
    listScroll = scroll

    local listLayout              = Instance.new("UIListLayout")
    listLayout.FillDirection      = Enum.FillDirection.Vertical
    listLayout.SortOrder          = Enum.SortOrder.LayoutOrder
    listLayout.Padding            = UDim.new(0, 6)
    listLayout.Parent             = scroll
    local listPad                 = Instance.new("UIPadding")
    listPad.PaddingTop            = UDim.new(0, 6)
    listPad.PaddingBottom         = UDim.new(0, 6)
    listPad.PaddingLeft           = UDim.new(0, 4)
    listPad.Parent                = scroll

    -- ── Tooltip pane ──────────────────────────────────────────────────────────
    local nameL                   = Instance.new("TextLabel")
    nameL.Size                    = UDim2.fromOffset(RIGHT_W, 30)
    nameL.Position                = UDim2.fromOffset(RIGHT_X, CONTENT_Y)
    nameL.BackgroundTransparency  = 1
    nameL.Font                    = Enum.Font.GothamBold
    nameL.TextSize                = 20
    nameL.TextColor3              = C.TEXT
    nameL.TextXAlignment          = Enum.TextXAlignment.Center
    nameL.TextTruncate            = Enum.TextTruncate.AtEnd
    nameL.Text                    = "Select an upgrade"
    nameL.ZIndex                  = 52
    nameL.Parent                  = panel
    ttName = nameL

    -- Viewport holder (square, centred in the right column)
    local holder                  = Instance.new("Frame")
    holder.Size                   = UDim2.fromOffset(VP_BOX, VP_BOX)
    holder.Position               = UDim2.fromOffset(RIGHT_X + (RIGHT_W - VP_BOX) / 2, CONTENT_Y + 36)
    holder.BackgroundColor3       = Color3.fromRGB(6, 8, 16)
    holder.BackgroundTransparency = 0.2
    holder.BorderSizePixel        = 0
    holder.ClipsDescendants       = true
    holder.ZIndex                 = 52
    holder.Parent                 = panel
    UILib.corner(holder, 10)
    UILib.stroke(holder, Color3.fromRGB(34, 44, 80), 1)
    vpHolder = holder

    -- drag-to-spin
    holder.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging  = true
            dragLastX = input.Position.X
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
            currentYaw -= (input.Position.X - dragLastX) * 0.01
            dragLastX   = input.Position.X
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)

    -- Upgrade button
    local UPG_Y = CONTENT_Y + 36 + VP_BOX + 12
    local btn                     = Instance.new("TextButton")
    btn.Size                      = UDim2.fromOffset(RIGHT_W, 40)
    btn.Position                  = UDim2.fromOffset(RIGHT_X, UPG_Y)
    btn.BackgroundColor3          = Color3.fromRGB(58, 44, 0)
    btn.BorderSizePixel           = 0
    btn.AutoButtonColor           = false
    btn.Text                      = ""
    btn.ZIndex                    = 52
    btn.Visible                   = false
    btn.Parent                    = panel
    UILib.corner(btn, 8)
    UILib.stroke(btn, Color3.fromRGB(60, 60, 30), 1)
    ttBtn = btn

    local btnFill                 = Instance.new("Frame")
    btnFill.Size                  = UDim2.new(0, 0, 1, 0)
    btnFill.BackgroundColor3      = Color3.fromRGB(120, 95, 0)
    btnFill.BackgroundTransparency = 0.4
    btnFill.BorderSizePixel       = 0
    btnFill.ZIndex                = 52
    btnFill.Parent                = btn
    UILib.corner(btnFill, 8)
    ttBtnFill = btnFill

    local btnLbl                  = Instance.new("TextLabel")
    btnLbl.Size                   = UDim2.new(1, 0, 1, 0)
    btnLbl.BackgroundTransparency = 1
    btnLbl.Font                   = Enum.Font.GothamBold
    btnLbl.TextSize               = 15
    btnLbl.TextColor3             = C.GOLD
    btnLbl.Text                   = "UPGRADE"
    btnLbl.ZIndex                 = 53
    btnLbl.Parent                 = btn
    ttBtnLbl = btnLbl

    btn.MouseButton1Click:Connect(function()
        local tech = selectedTech
        if not tech then return end
        if techStateOf(tech) ~= "available" then return end
        local u = (Config.UNLOCKS :: any)[tech]
        if activeInCategory(u.category :: string) >= Config.MAX_CONCURRENT_RESEARCH then return end
        networkRef.requestUpgrade(tech)
    end)

    -- Description
    local descL                   = Instance.new("TextLabel")
    descL.Size                    = UDim2.fromOffset(RIGHT_W, 38)
    descL.Position                = UDim2.fromOffset(RIGHT_X, UPG_Y + 48)
    descL.BackgroundTransparency  = 1
    descL.Font                    = Enum.Font.Gotham
    descL.TextSize                = 13
    descL.TextColor3              = C.SUBTEXT
    descL.TextXAlignment          = Enum.TextXAlignment.Left
    descL.TextYAlignment          = Enum.TextYAlignment.Top
    descL.TextWrapped             = true
    descL.Text                    = ""
    descL.ZIndex                  = 52
    descL.Parent                  = panel
    ttDesc = descL

    -- Requirements header + list
    local reqTitle                = Instance.new("TextLabel")
    reqTitle.Size                 = UDim2.fromOffset(RIGHT_W, 16)
    reqTitle.Position             = UDim2.fromOffset(RIGHT_X, UPG_Y + 90)
    reqTitle.BackgroundTransparency = 1
    reqTitle.Font                 = Enum.Font.GothamBold
    reqTitle.TextSize             = 11
    reqTitle.TextColor3           = C.DIM
    reqTitle.TextXAlignment       = Enum.TextXAlignment.Left
    reqTitle.Text                 = "REQUIREMENTS"
    reqTitle.ZIndex               = 52
    reqTitle.Parent               = panel

    local reqHolder               = Instance.new("Frame")
    reqHolder.Size                = UDim2.fromOffset(RIGHT_W, CONTENT_Y + CONTENT_H - (UPG_Y + 110))
    reqHolder.Position            = UDim2.fromOffset(RIGHT_X, UPG_Y + 110)
    reqHolder.BackgroundTransparency = 1
    reqHolder.ZIndex              = 52
    reqHolder.Parent              = panel
    ttReqHolder = reqHolder

    -- Build rows once for every tech, alpha-indexed within category.
    do
        local names: { string } = {}
        for tech in (Config.UNLOCKS :: any) do table.insert(names, tech) end
        table.sort(names, function(a, b) return techTitle(a) < techTitle(b) end)
        for i, tech in ipairs(names) do
            alphaIndex[tech] = i
            buildRow(tech)
        end
    end

    setTab("Infra")

    -- Per-frame: auto-spin the viewport and advance progress bars while open.
    RunService.Heartbeat:Connect(function(dt)
        if not (overlay and overlay.Visible) then return end

        -- Rotating viewport
        if currentOrbit then
            if not dragging then currentYaw += dt * 0.6 end
            currentOrbit.setYaw(currentYaw)
        end

        -- Progress bars
        local now = workspace:GetServerTimeNow()
        for tech, endT in upgradingEnd do
            local frac = math.clamp(1 - (endT - now) / Config.UPGRADE_TIME, 0, 1)
            local ref  = rowRefs[tech]
            if ref and ref.barBg.Visible then
                ref.barFill.Size = UDim2.new(frac, 0, 1, 0)
            end
            if selectedTech == tech and ttBtnFill then
                (ttBtnFill :: Frame).Size = UDim2.new(frac, 0, 1, 0)
            end
        end
    end)
end

return WorkshopPanel
