--!strict
--[[
    Tutorial — drip-feed onboarding state machine.

    One card is visible at a time.  Each step waits for the player to
    demonstrate the current mechanic before revealing the next hint.

    Steps unlock in order:
      1. camera        — pan the camera (WASD)
      2. place_cc      — place Command Center
      3. build_mine    — build a Mine
      4. build_barracks— build a Barracks
      5. train_unit    — train first unit
      6. move_units    — right-click move
      7. research      — click CC to open Workshop
      8. objective     — win condition  (persistent, manually dismissed)

    Wire Tutorial.notify(action) from init.client.luau at relevant events.
    The camera step is detected internally.
]]

local TweenService = game:GetService("TweenService")
local UILib        = require(script.Parent:WaitForChild("UILib"))

local Tutorial = {}
local C        = UILib.C

-- ── Step definitions ─────────────────────────────────────────────────────────

type Step = {
    icon:    string,
    title:   string,
    body:    string,
    color:   Color3,
    trigger: string,   -- action id that completes this step ("" = manual dismiss)
}

local STEPS: { Step } = {
    -- 1 -----------------------------------------------------------------------
    {
        icon    = "✦",
        title   = "Pan the Camera",
        body    = "Use  W A S D  to move the camera around the map.\n"
               .. "Scroll to zoom  ·  Q / E to rotate.",
        color   = C.ACCENT,
        trigger = "camera_moved",
    },
    -- 2 -----------------------------------------------------------------------
    {
        icon    = "⌂",
        title   = "Place Your Command Center",
        body    = "Click the  ⌂ PLACE COMMAND CENTER  button at the bottom,\n"
               .. "then click the map to place your base.",
        color   = C.TEAL,
        trigger = "cc_placed",
    },
    -- 3 -----------------------------------------------------------------------
    {
        icon    = "⛏",
        title   = "Build a Mine  —  ◆ 75",
        body    = "Open the  ⚒  build menu (bottom-left)  →  Mine.\n"
               .. "Place it on a yellow crystal deposit.\n"
               .. "Miners auto-spawn every 30 s and generate income.",
        color   = C.MINE,
        trigger = "mine_placed",
    },
    -- 4 -----------------------------------------------------------------------
    {
        icon    = "⚔",
        title   = "Build a Barracks  —  ◆ 50",
        body    = "You need soldiers to protect your base.\n"
               .. "Open  ⚒  →  Barracks  and place it near your Command Center.",
        color   = C.BARRACKS,
        trigger = "barracks_placed",
    },
    -- 5 -----------------------------------------------------------------------
    {
        icon    = "★",
        title   = "Train Your First Unit",
        body    = "Click your Barracks building to open its panel.\n"
               .. "Train a  Soldier  (◆ 25)  to start your army.",
        color   = C.GREEN,
        trigger = "unit_trained",
    },
    -- 6 -----------------------------------------------------------------------
    {
        icon    = "➤",
        title   = "Command Your Units",
        body    = "Left-click drag  to box-select units.\n"
               .. "Right-click  to move them to a position.\n"
               .. "A  +  click  to attack-move toward enemies.",
        color   = C.TURRET,
        trigger = "move_issued",
    },
    -- 7 -----------------------------------------------------------------------
    {
        icon    = "⚙",
        title   = "Research Upgrades",
        body    = "Click your Command Center to open the Workshop.\n"
               .. "Research  Better Mines,  Elite Units,  or  Turret Upgrades\n"
               .. "to strengthen your forces.",
        color   = C.WORKSHOP,
        trigger = "cc_selected",
    },
    -- 8 (objective — manual dismiss) -----------------------------------------
    {
        icon    = "◆",
        title   = "How to Win",
        body    = "Build a  Monument  from your Command Center  (◆ 1 500).\n"
               .. "Defend it for  5 minutes  to win the match.\n"
               .. "Good luck, Commander!",
        color   = C.GOLD,
        trigger = "",
    },
}

local TOTAL_STEPS = #STEPS - 1  -- last step is the objective, not counted

-- ── State ─────────────────────────────────────────────────────────────────────
local currentStep  = 1
local completing   = false
local dismissed    = false
local cardFrame:   Frame?
local accentBar:   Frame?
local iconLabel:   TextLabel?
local titleLabel:  TextLabel?
local bodyLabel:   TextLabel?
local stepLabel:   TextLabel?
local dismissBtn:  TextButton?
local skipBtn:     TextButton?
local camConn:     RBXScriptConnection?

-- ── Animation helpers ─────────────────────────────────────────────────────────
local CARD_SHOWN  = UDim2.new(0.5, 0, 1, -130)
local CARD_HIDDEN = UDim2.new(0.5, 0, 1,   70)
local EASE_IN     = TweenInfo.new(0.30, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local EASE_OUT    = TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.In)

local function slideIn()
    if not cardFrame then return end
    cardFrame.Position = CARD_HIDDEN
    cardFrame.Visible  = true
    TweenService:Create(cardFrame, EASE_IN, { Position = CARD_SHOWN }):Play()
end

local function slideOut(then_: (() -> ())?)
    if not cardFrame then return end
    local t = TweenService:Create(cardFrame, EASE_OUT, { Position = CARD_HIDDEN })
    t.Completed:Once(function()
        if cardFrame then cardFrame.Visible = false end
        if then_ then then_() end
    end)
    t:Play()
end

-- ── Apply a step's content to the card ───────────────────────────────────────
local function applyStep(n: number)
    local step = STEPS[n]
    if not step then return end
    if accentBar  then accentBar.BackgroundColor3 = step.color end
    if iconLabel  then
        iconLabel.Text       = step.icon
        iconLabel.TextColor3 = step.color
    end
    if titleLabel then
        titleLabel.Text       = step.title
        titleLabel.TextColor3 = C.TEXT
    end
    if bodyLabel  then bodyLabel.Text  = step.body  end

    -- Step counter: "1 / 7".  Hidden on the final objective card.
    if stepLabel then
        stepLabel.Text = (n <= TOTAL_STEPS) and (n .. " / " .. TOTAL_STEPS) or ""
    end

    -- Dismiss button only on the last step
    if dismissBtn then
        dismissBtn.Visible = (step.trigger == "")
    end
end

-- ── Complete current step and slide to next ───────────────────────────────────
local function completeAndAdvance()
    if completing then return end
    completing = true

    -- Flash title green with tick
    if titleLabel then
        titleLabel.TextColor3 = C.GREEN
        titleLabel.Text = "✓  " .. STEPS[currentStep].title
    end

    task.delay(0.8, function()
        slideOut(function()
            completing   = false
            currentStep += 1
            if currentStep <= #STEPS then
                applyStep(currentStep)
                slideIn()
            end
        end)
    end)
end

-- ── Camera pan detection ──────────────────────────────────────────────────────
local function startCameraWatch()
    local cam = workspace.CurrentCamera
    if not cam then return end

    -- Sample origin after a brief delay so loading drift doesn't count
    task.delay(1.5, function()
        local origin = cam.CFrame.Position
        camConn = cam:GetPropertyChangedSignal("CFrame"):Connect(function()
            if currentStep ~= 1 then
                if camConn then camConn:Disconnect(); camConn = nil end
                return
            end
            local delta = cam.CFrame.Position - origin
            -- Only count horizontal movement, ignore zoom
            local flatDist = Vector2.new(delta.X, delta.Z).Magnitude
            if flatDist > 14 then
                if camConn then camConn:Disconnect(); camConn = nil end
                Tutorial.notify("camera_moved")
            end
        end)
    end)
end

-- ── Build the card UI ─────────────────────────────────────────────────────────
function Tutorial.init(sg: ScreenGui)
    local f                      = Instance.new("Frame")
    f.Name                       = "TutorialCard"
    f.Size                       = UDim2.fromOffset(368, 118)
    f.Position                   = CARD_HIDDEN
    f.AnchorPoint                = Vector2.new(0.5, 1)
    f.BackgroundColor3           = Color3.fromRGB(7, 10, 20)
    f.BackgroundTransparency     = 0.04
    f.BorderSizePixel            = 0
    f.ZIndex                     = 50
    f.Visible                    = false
    f.Parent                     = sg
    UILib.corner(f, 10)
    UILib.stroke(f, C.BORDER, 1.5)
    cardFrame = f

    -- Left colour accent strip
    local ab                     = Instance.new("Frame")
    ab.Name                      = "AccentBar"
    ab.Size                      = UDim2.new(0, 4, 1, -20)
    ab.Position                  = UDim2.fromOffset(10, 10)
    ab.BackgroundColor3          = C.ACCENT
    ab.BorderSizePixel           = 0
    ab.ZIndex                    = 51
    ab.Parent                    = f
    UILib.corner(ab, 2)
    accentBar = ab

    -- Icon
    local ic                     = Instance.new("TextLabel")
    ic.Name                      = "Icon"
    ic.Size                      = UDim2.fromOffset(38, 38)
    ic.Position                  = UDim2.fromOffset(22, 18)
    ic.BackgroundTransparency    = 1
    ic.Text                      = "✦"
    ic.TextSize                  = 26
    ic.TextColor3                = C.ACCENT
    ic.Font                      = Enum.Font.GothamBold
    ic.TextXAlignment            = Enum.TextXAlignment.Center
    ic.TextYAlignment            = Enum.TextYAlignment.Center
    ic.ZIndex                    = 51
    ic.Parent                    = f
    iconLabel = ic

    -- Title
    local ti                     = Instance.new("TextLabel")
    ti.Name                      = "Title"
    ti.Size                      = UDim2.new(1, -104, 0, 24)
    ti.Position                  = UDim2.fromOffset(66, 10)
    ti.BackgroundTransparency    = 1
    ti.Text                      = ""
    ti.TextSize                  = 15
    ti.TextColor3                = C.TEXT
    ti.Font                      = Enum.Font.GothamBold
    ti.TextXAlignment            = Enum.TextXAlignment.Left
    ti.ZIndex                    = 51
    ti.Parent                    = f
    titleLabel = ti

    -- Divider
    local sep                    = Instance.new("Frame")
    sep.Size                     = UDim2.new(1, -76, 0, 1)
    sep.Position                 = UDim2.fromOffset(66, 36)
    sep.BackgroundColor3         = C.SEP
    sep.BorderSizePixel          = 0
    sep.ZIndex                   = 51
    sep.Parent                   = f

    -- Body text
    local bo                     = Instance.new("TextLabel")
    bo.Name                      = "Body"
    bo.Size                      = UDim2.new(1, -78, 1, -48)
    bo.Position                  = UDim2.fromOffset(66, 44)
    bo.BackgroundTransparency    = 1
    bo.Text                      = ""
    bo.TextSize                  = 13
    bo.TextColor3                = C.SUBTEXT
    bo.Font                      = Enum.Font.Gotham
    bo.TextXAlignment            = Enum.TextXAlignment.Left
    bo.TextYAlignment            = Enum.TextYAlignment.Top
    bo.TextWrapped               = true
    bo.ZIndex                    = 51
    bo.Parent                    = f
    bodyLabel = bo

    -- Step counter  "1 / 7"  (shifted left to make room for X button)
    local sc                     = Instance.new("TextLabel")
    sc.Name                      = "StepCount"
    sc.Size                      = UDim2.fromOffset(54, 20)
    sc.Position                  = UDim2.new(1, -90, 0, 8)
    sc.BackgroundTransparency    = 1
    sc.Text                      = ""
    sc.TextSize                  = 11
    sc.TextColor3                = C.DIM
    sc.Font                      = Enum.Font.Gotham
    sc.TextXAlignment            = Enum.TextXAlignment.Right
    sc.ZIndex                    = 51
    sc.Parent                    = f
    stepLabel = sc

    -- ✕ skip button — always visible, lets experienced players dismiss all tips
    local xb                     = Instance.new("TextButton")
    xb.Name                      = "SkipBtn"
    xb.Size                      = UDim2.fromOffset(22, 22)
    xb.Position                  = UDim2.new(1, -28, 0, 6)
    xb.BackgroundColor3          = Color3.fromRGB(110, 22, 22)
    xb.BackgroundTransparency    = 0.15
    xb.Text                      = "✕"
    xb.TextSize                  = 12
    xb.TextColor3                = Color3.fromRGB(220, 180, 180)
    xb.Font                      = Enum.Font.GothamBold
    xb.AutoButtonColor           = true
    xb.BorderSizePixel           = 0
    xb.ZIndex                    = 52
    xb.Parent                    = f
    UILib.corner(xb, 5)
    skipBtn = xb

    xb.MouseButton1Click:Connect(function()
        dismissed = true
        if camConn then camConn:Disconnect(); camConn = nil end
        slideOut(function()
            if cardFrame then cardFrame:Destroy(); cardFrame = nil end
        end)
    end)

    -- "Got it" dismiss button (only on last step)
    local db                     = Instance.new("TextButton")
    db.Name                      = "DismissBtn"
    db.Size                      = UDim2.fromOffset(90, 24)
    db.Position                  = UDim2.new(1, -100, 1, -30)
    db.BackgroundColor3          = C.GOLD
    db.BackgroundTransparency    = 0.2
    db.Text                      = "Got it  ✓"
    db.TextSize                  = 12
    db.TextColor3                = Color3.fromRGB(10, 8, 0)
    db.Font                      = Enum.Font.GothamBold
    db.AutoButtonColor           = true
    db.BorderSizePixel           = 0
    db.Visible                   = false
    db.ZIndex                    = 52
    db.Parent                    = f
    UILib.corner(db, 6)
    dismissBtn = db

    db.MouseButton1Click:Connect(function()
        dismissed = true
        slideOut(function()
            if cardFrame then cardFrame:Destroy(); cardFrame = nil end
        end)
    end)

    -- Show step 1 and begin watching the camera
    applyStep(1)
    slideIn()
    startCameraWatch()
end

-- ── Public: fire from init.client.luau at key game events ────────────────────
function Tutorial.notify(action: string)
    if dismissed or completing then return end
    local step = STEPS[currentStep]
    if not step or step.trigger == "" then return end
    if action == step.trigger then
        completeAndAdvance()
    end
end

return Tutorial
