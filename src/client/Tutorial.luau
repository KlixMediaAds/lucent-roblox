--!strict
--[[
    Tutorial — minimal bottom-right pill toast.

    One step at a time, action-gated. No walls of text.
    Auto-hides after 8 s, re-pulses after 20 s if the step is still pending.
    Returning players will barely notice it; new players get enough to act on.

    Steps:
      1. camera_moved    — pan the camera
      2. cc_placed       — place Command Center
      3. mine_placed     — build a Mine
      4. barracks_placed — build a Barracks
      5. unit_trained    — train first unit
      6. move_issued     — right-click move
      7. cc_selected     — open Workshop
      8. (objective)     — auto-dismissed after 10 s, never repeats

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
    label:   string,   -- ≤ 4 words
    color:   Color3,
    trigger: string,   -- "" = auto-dismissed (last step only)
}

local STEPS: { Step } = {
    { icon = "✦", label = "Pan the camera",      color = C.ACCENT,   trigger = "camera_moved"    },
    { icon = "⌂", label = "Place Command Ctr",   color = C.TEAL,     trigger = "cc_placed"       },
    { icon = "⬡", label = "Place a Blob",        color = C.TEAL,     trigger = "blob_placed"     },
    { icon = "⛏", label = "Evolve to Mine",      color = C.MINE,     trigger = "mine_placed"     },
    { icon = "⚔", label = "Build Barracks",      color = C.BARRACKS, trigger = "barracks_placed" },
    { icon = "★", label = "Train a Soldier",     color = C.GREEN,    trigger = "unit_trained"    },
    { icon = "➤", label = "Right-click to move", color = C.TURRET,   trigger = "move_issued"     },
    { icon = "⚙", label = "Open Workshop",       color = C.WORKSHOP, trigger = "cc_selected"     },
    { icon = "◆", label = "Defend 5 minutes",    color = C.GOLD,     trigger = ""                },
}

-- ── State ─────────────────────────────────────────────────────────────────────

local currentStep: number              = 1
local completing:  boolean             = false
local dismissed:   boolean             = false
local pill:        Frame?              = nil
local iconLbl:     TextLabel?          = nil
local hintLbl:     TextLabel?          = nil
local camConn:     RBXScriptConnection? = nil
local hideTimer:   thread?             = nil

-- ── Positions ────────────────────────────────────────────────────────────────

-- AnchorPoint (1,1): bottom-right corner of the pill is the pivot.
local PILL_SHOWN  = UDim2.new(1, -14, 1, -68)
local PILL_HIDDEN = UDim2.new(1, -14, 1,  18)   -- just below screen edge
local EASE_IN     = TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local EASE_OUT    = TweenInfo.new(0.20, Enum.EasingStyle.Quint, Enum.EasingDirection.In)

local function slideIn()
    if not pill then return end
    pill.Position = PILL_HIDDEN
    pill.Visible  = true
    TweenService:Create(pill, EASE_IN, { Position = PILL_SHOWN }):Play()
end

local function slideOut(then_: (() -> ())?)
    if not pill then return end
    local t = TweenService:Create(pill, EASE_OUT, { Position = PILL_HIDDEN })
    t.Completed:Once(function()
        if pill then pill.Visible = false end
        if then_ then then_() end
    end)
    t:Play()
end

-- Brief brightness flash to re-draw attention without being annoying
local function pulse()
    if not pill or not pill.Visible then return end
    local t1 = TweenService:Create(pill, TweenInfo.new(0.12), { BackgroundTransparency = 0.0  })
    local t2 = TweenService:Create(pill, TweenInfo.new(0.30), { BackgroundTransparency = 0.14 })
    t1.Completed:Once(function() t2:Play() end)
    t1:Play()
end

-- Hide after 8 s; re-show with a pulse 20 s later if the step is still pending.
local function scheduleAutoHide()
    if hideTimer and coroutine.status(hideTimer) == "suspended" then task.cancel(hideTimer) end
    hideTimer = task.delay(8, function()
        if dismissed or completing then return end
        slideOut(function()
            hideTimer = task.delay(20, function()
                if dismissed or completing then return end
                if not pill then return end
                slideIn()
                pulse()
                scheduleAutoHide()
            end)
        end)
    end)
end

-- ── Apply step content ────────────────────────────────────────────────────────

local function applyStep(n: number)
    local step = STEPS[n]
    if not step then return end
    if iconLbl then
        iconLbl.Text       = step.icon
        iconLbl.TextColor3 = step.color
    end
    if hintLbl then
        hintLbl.Text       = step.label
        hintLbl.TextColor3 = C.TEXT
    end
end

-- ── Complete current step and slide to next ───────────────────────────────────

local function completeAndAdvance()
    if completing then return end
    completing = true
    if hideTimer then task.cancel(hideTimer); hideTimer = nil end

    if iconLbl then iconLbl.TextColor3 = C.GREEN end
    if hintLbl then
        hintLbl.Text       = "✓"
        hintLbl.TextColor3 = C.GREEN
    end

    task.delay(0.55, function()
        slideOut(function()
            completing    = false
            currentStep  += 1
            if currentStep > #STEPS then return end

            applyStep(currentStep)
            slideIn()

            local step = STEPS[currentStep]
            if step.trigger == "" then
                -- Objective card: show for 10 s then vanish forever
                task.delay(10, function()
                    if dismissed then return end
                    dismissed = true
                    slideOut(function()
                        if pill then pill:Destroy(); pill = nil end
                    end)
                end)
            else
                scheduleAutoHide()
            end
        end)
    end)
end

-- ── Camera pan detection ──────────────────────────────────────────────────────

local function startCameraWatch()
    local cam = workspace.CurrentCamera
    if not cam then return end
    task.delay(1.5, function()
        local origin = cam.CFrame.Position
        camConn = cam:GetPropertyChangedSignal("CFrame"):Connect(function()
            if currentStep ~= 1 then
                if camConn then camConn:Disconnect(); camConn = nil end
                return
            end
            local delta    = cam.CFrame.Position - origin
            local flatDist = Vector2.new(delta.X, delta.Z).Magnitude
            if flatDist > 14 then
                if camConn then camConn:Disconnect(); camConn = nil end
                Tutorial.notify("camera_moved")
            end
        end)
    end)
end

-- ── Build the pill UI ─────────────────────────────────────────────────────────

function Tutorial.init(sg: ScreenGui)
    local f                   = Instance.new("Frame")
    f.Name                    = "TutorialPill"
    f.Size                    = UDim2.fromOffset(188, 40)
    f.Position                = PILL_HIDDEN
    f.AnchorPoint             = Vector2.new(1, 1)
    f.BackgroundColor3        = Color3.fromRGB(7, 10, 20)
    f.BackgroundTransparency  = 0.14
    f.BorderSizePixel         = 0
    f.ZIndex                  = 50
    f.Visible                 = false
    f.Parent                  = sg
    UILib.corner(f, 8)
    UILib.stroke(f, C.BORDER, 1)
    pill = f

    -- Colored icon
    local ic                  = Instance.new("TextLabel")
    ic.Name                   = "Icon"
    ic.Size                   = UDim2.fromOffset(28, 28)
    ic.Position               = UDim2.fromOffset(8, 6)
    ic.BackgroundTransparency = 1
    ic.Text                   = "✦"
    ic.TextSize               = 20
    ic.TextColor3             = C.ACCENT
    ic.Font                   = Enum.Font.GothamBold
    ic.TextXAlignment         = Enum.TextXAlignment.Center
    ic.TextYAlignment         = Enum.TextYAlignment.Center
    ic.ZIndex                 = 51
    ic.Parent                 = f
    iconLbl = ic

    -- Short hint (≤ 4 words, no body text)
    local ht                  = Instance.new("TextLabel")
    ht.Name                   = "Hint"
    ht.Size                   = UDim2.new(1, -56, 1, 0)
    ht.Position               = UDim2.fromOffset(40, 0)
    ht.BackgroundTransparency = 1
    ht.Text                   = ""
    ht.TextSize               = 13
    ht.TextColor3             = C.TEXT
    ht.Font                   = Enum.Font.GothamMedium
    ht.TextXAlignment         = Enum.TextXAlignment.Left
    ht.TextYAlignment         = Enum.TextYAlignment.Center
    ht.ZIndex                 = 51
    ht.Parent                 = f
    hintLbl = ht

    -- ✕ skip — lets returning players dismiss permanently
    local xb                  = Instance.new("TextButton")
    xb.Name                   = "SkipBtn"
    xb.Size                   = UDim2.fromOffset(18, 18)
    xb.Position               = UDim2.new(1, -22, 0.5, -9)
    xb.BackgroundColor3       = Color3.fromRGB(80, 18, 18)
    xb.BackgroundTransparency = 0.25
    xb.Text                   = "✕"
    xb.TextSize               = 9
    xb.TextColor3             = Color3.fromRGB(190, 140, 140)
    xb.Font                   = Enum.Font.GothamBold
    xb.AutoButtonColor        = true
    xb.BorderSizePixel        = 0
    xb.ZIndex                 = 52
    xb.Parent                 = f
    UILib.corner(xb, 4)

    xb.MouseButton1Click:Connect(function()
        dismissed = true
        if camConn   then camConn:Disconnect();  camConn   = nil end
        if hideTimer then task.cancel(hideTimer); hideTimer = nil end
        slideOut(function()
            if pill then pill:Destroy(); pill = nil end
        end)
    end)

    applyStep(1)
    slideIn()
    scheduleAutoHide()
    startCameraWatch()
end

-- ── Public notify ─────────────────────────────────────────────────────────────

function Tutorial.notify(action: string)
    if dismissed or completing then return end
    local step = STEPS[currentStep]
    if not step or step.trigger == "" then return end
    if action == step.trigger then
        completeAndAdvance()
    end
end

return Tutorial
