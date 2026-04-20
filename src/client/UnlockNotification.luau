--!strict
--[[
    UnlockNotification — juicy unlock reveal cards with vertical stacking.

    Multiple unlocks that arrive simultaneously each get their own card, stacked
    bottom-to-top.  Each card runs its own animation independently; when one
    finishes the cards below shift down to fill the gap.

    Sequence for a standard unlock:
      1. Dark card slides up from bottom-centre (stacked above any existing cards).
      2. Condition text types out letter-by-letter.
      3. Brief pause → text flashes green + a strikethrough line sweeps across.
      4. Tech name pops in large with a glow burst.
      5. "UNLOCKED!" subtitle fades in.
      6. Card lingers 2 s then slides back down.

    For a choice unlock (mutually-exclusive group):
      Steps 1–3 play normally, then instead of step 4 the card expands and
      shows two glowing option buttons. Player clicks one; the card plays the
      reveal for that choice and closes. Until a choice is made the card stays.
]]

local TweenService  = game:GetService("TweenService")
local Players       = game:GetService("Players")
local SoundService  = game:GetService("SoundService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))

local UnlockNotification = {}

local C = UILib.C

-- ── Card stack (multiple cards visible simultaneously) ────────────────────────

type CardEntry = { frame: Frame, cardH: number }
local activeCards: { CardEntry } = {}
local CARD_GAP = 10

local function computeTargetY(idx: number): number
    local CARD_OFF_Y = 40
    local y = CARD_OFF_Y
    for i = 1, idx - 1 do
        y += activeCards[i].cardH + CARD_GAP
    end
    return -y
end

local function shiftCards()
    for i, entry in activeCards do
        TweenService:Create(entry.frame,
            TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
            { Position = UDim2.new(0.5, 0, 1, computeTargetY(i)) }
        ):Play()
    end
end

local function registerCard(frame: Frame, cardH: number): () -> ()
    local entry: CardEntry = { frame = frame, cardH = cardH }
    table.insert(activeCards, entry)
    return function()
        for i, e in activeCards do
            if e == entry then
                table.remove(activeCards, i)
                break
            end
        end
        shiftCards()
    end
end

-- ── Sound ─────────────────────────────────────────────────────────────────────

local function playUnlockSound()
    local snd       = Instance.new("Sound")
    snd.SoundId     = "rbxassetid://104003605923230"
    snd.Volume      = 0.8
    snd.Parent      = SoundService
    snd:Play()
    snd.Ended:Connect(function() snd:Destroy() end)
end

-- ── Card builder ──────────────────────────────────────────────────────────────

local CARD_W     = 480
local CARD_H_STD = 190
local CARD_H_CHO = 290

local function getScreenGui(): ScreenGui?
    local pg = Players.LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return nil end
    return pg:FindFirstChild("RTSHUD") :: ScreenGui?
end

-- Typewriter helper — returns a cancel function
local function typewrite(lbl: TextLabel, text: string, speed: number, done: () -> ())
    local cancelled = false
    task.spawn(function()
        for i = 1, #text do
            if cancelled then return end
            lbl.Text = string.sub(text, 1, i)
            task.wait(speed)
        end
        if not cancelled then done() end
    end)
    return function() cancelled = true end
end

-- Strikethrough: sweeps from left to right across the full parent width.
local function strikethrough(parent: Frame, color: Color3): Frame
    local line              = Instance.new("Frame")
    line.Name               = "Strike"
    line.Size               = UDim2.new(0, 0, 0, 3)
    line.AnchorPoint        = Vector2.new(0, 0.5)
    line.Position           = UDim2.new(0, 0, 0.5, 0)
    line.BackgroundColor3   = color
    line.BorderSizePixel    = 0
    line.ZIndex             = 105
    line.Parent             = parent
    TweenService:Create(line,
        TweenInfo.new(0.30, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { Size = UDim2.new(1, 0, 0, 3) }
    ):Play()
    return line
end

-- ── Standard unlock notification ─────────────────────────────────────────────

function UnlockNotification.showUnlock(techName: string)
    local unlock = (Config.UNLOCKS :: any)[techName]
    if not unlock then return end
    local condText = unlock.condText :: string

    task.spawn(function()
        local sg = getScreenGui()
        if not sg then return end

        -- ── Card frame ────────────────────────────────────────────────────────
        local card                      = Instance.new("Frame")
        card.Name                       = "UnlockCard"
        card.Size                       = UDim2.fromOffset(CARD_W, CARD_H_STD)
        card.AnchorPoint                = Vector2.new(0.5, 1)
        card.Position                   = UDim2.new(0.5, 0, 1, CARD_H_STD + 20)
        card.BackgroundColor3           = Color3.fromRGB(4, 5, 14)
        card.BackgroundTransparency     = 0
        card.BorderSizePixel            = 0
        card.ZIndex                     = 100
        card.Parent                     = sg
        UILib.corner(card, 14)

        local glow = UILib.stroke(card, C.ACCENT, 2)

        local iconLbl                   = Instance.new("TextLabel")
        iconLbl.Size                    = UDim2.fromOffset(38, 36)
        iconLbl.Position                = UDim2.fromOffset(16, 30)
        iconLbl.BackgroundTransparency  = 1
        iconLbl.Font                    = Enum.Font.GothamBold
        iconLbl.TextSize                = 24
        iconLbl.TextColor3              = C.SUBTEXT
        iconLbl.TextXAlignment          = Enum.TextXAlignment.Center
        iconLbl.TextYAlignment          = Enum.TextYAlignment.Center
        iconLbl.Text                    = unlock.icon :: string? or "◆"
        iconLbl.ZIndex                  = 103
        iconLbl.Parent                  = card

        local condFrame                 = Instance.new("Frame")
        condFrame.Size                  = UDim2.fromOffset(CARD_W - 72, 36)
        condFrame.Position              = UDim2.fromOffset(56, 30)
        condFrame.BackgroundTransparency= 1
        condFrame.BorderSizePixel       = 0
        condFrame.ZIndex                = 102
        condFrame.Parent                = card

        local condLbl                   = Instance.new("TextLabel")
        condLbl.Size                    = UDim2.new(1, 0, 1, 0)
        condLbl.BackgroundTransparency  = 1
        condLbl.Font                    = Enum.Font.GothamBold
        condLbl.TextSize                = 20
        condLbl.TextColor3              = Color3.fromRGB(160, 170, 200)
        condLbl.TextXAlignment          = Enum.TextXAlignment.Left
        condLbl.TextYAlignment          = Enum.TextYAlignment.Center
        condLbl.Text                    = ""
        condLbl.ZIndex                  = 103
        condLbl.Parent                  = condFrame

        local nameLbl                   = Instance.new("TextLabel")
        nameLbl.Size                    = UDim2.fromOffset(CARD_W - 32, 52)
        nameLbl.Position                = UDim2.fromOffset(16, 82)
        nameLbl.BackgroundTransparency  = 1
        nameLbl.Font                    = Enum.Font.GothamBold
        nameLbl.TextSize                = 36
        nameLbl.TextColor3              = Color3.fromRGB(80, 220, 120)
        nameLbl.TextXAlignment          = Enum.TextXAlignment.Center
        nameLbl.TextStrokeTransparency  = 0.15
        nameLbl.TextStrokeColor3        = Color3.new(0,0,0)
        nameLbl.Text                    = techName:upper()
        nameLbl.TextTransparency        = 1
        nameLbl.ZIndex                  = 103
        nameLbl.Parent                  = card

        local unlockedLbl               = Instance.new("TextLabel")
        unlockedLbl.Size                = UDim2.fromOffset(CARD_W - 32, 26)
        unlockedLbl.Position            = UDim2.fromOffset(16, 140)
        unlockedLbl.BackgroundTransparency = 1
        unlockedLbl.Font                = Enum.Font.GothamBold
        unlockedLbl.TextSize            = 16
        unlockedLbl.TextColor3          = Color3.fromRGB(60, 200, 90)
        unlockedLbl.TextXAlignment      = Enum.TextXAlignment.Center
        unlockedLbl.Text                = "✓  UNLOCKED"
        unlockedLbl.TextTransparency    = 1
        unlockedLbl.ZIndex              = 103
        unlockedLbl.Parent              = card

        -- Register in stack and slide to correct position
        local unregister = registerCard(card, CARD_H_STD)
        local targetY    = computeTargetY(#activeCards)

        TweenService:Create(card,
            TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
            { Position = UDim2.new(0.5, 0, 1, targetY) }
        ):Play()
        playUnlockSound()

        task.wait(0.45)

        -- Phase 1: typewriter
        local tw_done = false
        typewrite(condLbl, condText, 0.04, function() tw_done = true end)
        repeat task.wait(0.05) until tw_done

        task.wait(0.25)

        -- Phase 2: flash green + strikethrough
        TweenService:Create(condLbl, TweenInfo.new(0.12), { TextColor3 = C.GREEN }):Play()
        TweenService:Create(glow,    TweenInfo.new(0.12), { Color = C.GREEN, Thickness = 3 }):Play()
        strikethrough(condFrame, C.GREEN)

        task.wait(0.55)

        -- Phase 3: tech name pop-in
        local scl   = Instance.new("UIScale")
        scl.Scale   = 0.7
        scl.Parent  = nameLbl

        TweenService:Create(nameLbl, TweenInfo.new(0.05), { TextTransparency = 0 }):Play()
        TweenService:Create(scl,
            TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
            { Scale = 1 }
        ):Play()
        TweenService:Create(glow, TweenInfo.new(0.3), { Color = C.ACCENT, Thickness = 4 }):Play()
        TweenService:Create(unlockedLbl, TweenInfo.new(0.3), { TextTransparency = 0 }):Play()

        task.wait(2.2)

        -- Slide out
        TweenService:Create(card,
            TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
            { Position = UDim2.new(0.5, 0, 1, CARD_H_STD + 20) }
        ):Play()
        task.wait(0.35)
        unregister()
        card:Destroy()
    end)
end

-- ── Choice notification ───────────────────────────────────────────────────────

function UnlockNotification.showChoice(
    _group: string,
    options: { string },
    chooseFn: (string) -> ()
)
    task.spawn(function()
        local sg = getScreenGui()
        if not sg then return end

        local card                      = Instance.new("Frame")
        card.Name                       = "ChoiceCard"
        card.Size                       = UDim2.fromOffset(CARD_W, CARD_H_CHO)
        card.AnchorPoint                = Vector2.new(0.5, 1)
        card.Position                   = UDim2.new(0.5, 0, 1, CARD_H_CHO + 20)
        card.BackgroundColor3           = Color3.fromRGB(4, 5, 14)
        card.BackgroundTransparency     = 0
        card.BorderSizePixel            = 0
        card.ZIndex                     = 100
        card.Parent                     = sg
        UILib.corner(card, 14)

        local glow = UILib.stroke(card, C.GOLD, 2)

        local condLbl                   = Instance.new("TextLabel")
        condLbl.Size                    = UDim2.fromOffset(CARD_W - 48, 36)
        condLbl.Position                = UDim2.fromOffset(24, 38)
        condLbl.BackgroundTransparency  = 1
        condLbl.Font                    = Enum.Font.GothamBold
        condLbl.TextSize                = 18
        condLbl.TextColor3              = C.SUBTEXT
        condLbl.TextXAlignment          = Enum.TextXAlignment.Center
        condLbl.Text                    = ""
        condLbl.ZIndex                  = 102
        condLbl.Parent                  = card

        local headerLbl                 = Instance.new("TextLabel")
        headerLbl.Size                  = UDim2.fromOffset(CARD_W - 48, 32)
        headerLbl.Position              = UDim2.fromOffset(24, 78)
        headerLbl.BackgroundTransparency= 1
        headerLbl.Font                  = Enum.Font.GothamBold
        headerLbl.TextSize              = 21
        headerLbl.TextColor3            = C.GOLD
        headerLbl.TextXAlignment        = Enum.TextXAlignment.Center
        headerLbl.Text                  = "CHOOSE YOUR PATH:"
        headerLbl.TextTransparency      = 1
        headerLbl.ZIndex                = 102
        headerLbl.Parent                = card

        local BTN_W   = math.floor((CARD_W - 72) / #options)
        local chosenName: string? = nil
        local btns: { TextButton } = {}

        for i, techName in options do
            local ul = (Config.UNLOCKS :: any)[techName]
            local x  = 24 + (i - 1) * (BTN_W + 12)

            local btn                   = Instance.new("TextButton")
            btn.Size                    = UDim2.fromOffset(BTN_W, 110)
            btn.Position                = UDim2.fromOffset(x, 118)
            btn.BackgroundColor3        = Color3.fromRGB(14, 18, 36)
            btn.BackgroundTransparency  = 0.1
            btn.BorderSizePixel         = 0
            btn.Text                    = ""
            btn.AutoButtonColor         = false
            btn.ZIndex                  = 102
            btn.Parent                  = card
            UILib.corner(btn, 8)
            local s = UILib.stroke(btn, C.BORDER, 1.5)
            table.insert(btns, btn)

            local tLbl                  = Instance.new("TextLabel")
            tLbl.Size                   = UDim2.new(1, -8, 0, 28)
            tLbl.Position               = UDim2.fromOffset(4, 8)
            tLbl.BackgroundTransparency = 1
            tLbl.Font                   = Enum.Font.GothamBold
            tLbl.TextSize               = 15
            tLbl.TextColor3             = C.TEXT
            tLbl.TextXAlignment         = Enum.TextXAlignment.Center
            tLbl.TextWrapped            = true
            tLbl.Text                   = techName:upper()
            tLbl.ZIndex                 = 103
            tLbl.Parent                 = btn

            local dLbl                  = Instance.new("TextLabel")
            dLbl.Size                   = UDim2.new(1, -8, 0, 68)
            dLbl.Position               = UDim2.fromOffset(4, 38)
            dLbl.BackgroundTransparency = 1
            dLbl.Font                   = Enum.Font.Gotham
            dLbl.TextSize               = 11
            dLbl.TextColor3             = C.SUBTEXT
            dLbl.TextXAlignment         = Enum.TextXAlignment.Center
            dLbl.TextWrapped            = true
            dLbl.Text                   = ul and (ul.desc :: string) or ""
            dLbl.ZIndex                 = 103
            dLbl.Parent                 = btn

            btn.MouseEnter:Connect(function()
                if chosenName then return end
                TweenService:Create(btn, TweenInfo.new(0.1), { BackgroundColor3 = Color3.fromRGB(28, 36, 72) }):Play()
                TweenService:Create(s,   TweenInfo.new(0.1), { Color = C.GOLD, Thickness = 2 }):Play()
            end)
            btn.MouseLeave:Connect(function()
                if chosenName then return end
                TweenService:Create(btn, TweenInfo.new(0.1), { BackgroundColor3 = Color3.fromRGB(14, 18, 36) }):Play()
                TweenService:Create(s,   TweenInfo.new(0.1), { Color = C.BORDER, Thickness = 1.5 }):Play()
            end)

            local capturedName = techName
            btn.MouseButton1Click:Connect(function()
                if chosenName then return end
                chosenName = capturedName
                chooseFn(capturedName)

                for j, ob in btns do
                    if j == i then
                        TweenService:Create(s, TweenInfo.new(0.2), { Color = C.GREEN, Thickness = 3 }):Play()
                        TweenService:Create(btn, TweenInfo.new(0.2), { BackgroundColor3 = Color3.fromRGB(10, 40, 18) }):Play()
                    else
                        TweenService:Create(ob, TweenInfo.new(0.2), { BackgroundTransparency = 0.6 }):Play()
                    end
                end
                task.wait(1.2)
                TweenService:Create(card,
                    TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
                    { Position = UDim2.new(0.5, 0, 1, CARD_H_CHO + 20) }
                ):Play()
                task.wait(0.35)
                unregister()
                card:Destroy()
                UnlockNotification.showUnlock(capturedName)
            end)
        end

        -- Register in stack and slide in
        local unregister = registerCard(card, CARD_H_CHO)
        local targetY    = computeTargetY(#activeCards)

        TweenService:Create(card,
            TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
            { Position = UDim2.new(0.5, 0, 1, targetY) }
        ):Play()
        playUnlockSound()
        task.wait(0.45)

        local tw_done = false
        local hint    = "Unlock condition met!"
        for _, techName in options do
            local ul = (Config.UNLOCKS :: any)[techName]
            if ul then hint = ul.condText :: string; break end
        end
        typewrite(condLbl, hint, 0.04, function() tw_done = true end)
        repeat task.wait(0.05) until tw_done

        task.wait(0.2)
        TweenService:Create(condLbl, TweenInfo.new(0.12), { TextColor3 = C.GREEN }):Play()
        TweenService:Create(glow,    TweenInfo.new(0.12), { Thickness = 3 }):Play()

        task.wait(0.25)
        TweenService:Create(headerLbl, TweenInfo.new(0.2), { TextTransparency = 0 }):Play()

        -- Card stays until player clicks a button
    end)
end

return UnlockNotification
