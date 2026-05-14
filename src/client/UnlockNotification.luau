--!strict
--[[
    UnlockNotification — compact unlock toasts (top-right) with UPGRADES menu hint.

    Standard unlock:
      • Small pill slides in from the right edge (no typewriter, no strikethrough).
      • Shows icon, tech name, one-line description, and "⚗ View in UPGRADES menu".
      • A drain bar counts down the auto-dismiss timer.
      • Up to 4 toasts stack downward; the oldest waits if the stack is full.

    Choice unlock:
      • Compact card drops from top-center, gold pulsing border.
      • Two option buttons with icon + name + description.
      • After picking: selected button flashes green → card slides back up →
        standard toast fires for the chosen tech.
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

-- ── Toast stack (standard unlocks, top-right) ─────────────────────────────────

type CardEntry = { frame: Frame, h: number }
local activeCards: { CardEntry } = {}
local MAX_CARDS  = 4
local CARD_GAP   = 8
local CARD_W     = 290
local CARD_H     = 96
local TOP_MARGIN = 72  -- px from top (below resource bar)
local LINGER     = 3.8

local function computeTargetY(idx: number): number
	local y = TOP_MARGIN
	for i = 1, idx - 1 do
		y += activeCards[i].h + CARD_GAP
	end
	return y
end

local function shiftCards()
	for i, e in activeCards do
		TweenService:Create(e.frame,
			TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Position = UDim2.new(1, -12, 0, computeTargetY(i)) }
		):Play()
	end
end

local function registerCard(frame: Frame, h: number): () -> ()
	local entry: CardEntry = { frame = frame, h = h }
	table.insert(activeCards, entry)
	return function()
		for i, e in activeCards do
			if e == entry then table.remove(activeCards, i); break end
		end
		shiftCards()
	end
end

-- ── Shared helpers ────────────────────────────────────────────────────────────

local function getScreenGui(): ScreenGui?
	local pg = Players.LocalPlayer:FindFirstChild("PlayerGui")
	if not pg then return nil end
	return pg:FindFirstChild("RTSHUD") :: ScreenGui?
end

local function playUnlockSound()
	local snd   = Instance.new("Sound")
	snd.SoundId = "rbxassetid://104003605923230"
	snd.Volume  = 0.6
	snd.Parent  = SoundService
	snd:Play()
	snd.Ended:Connect(function() snd:Destroy() end)
end

local SLIDE_IN      = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local SLIDE_OUT     = TweenInfo.new(0.20, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local CHOICE_IN     = TweenInfo.new(0.30, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CHOICE_OUT    = TweenInfo.new(0.20, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

-- ── Standard unlock toast ────────────────────────────────────────────────────

function UnlockNotification.showUnlock(techName: string)
	local unlock = (Config.UNLOCKS :: any)[techName]
	if not unlock then return end

	task.spawn(function()
		while #activeCards >= MAX_CARDS do task.wait(0.25) end

		local sg = getScreenGui()
		if not sg then return end

		-- Card
		local card                     = Instance.new("Frame")
		card.Name                      = "UnlockToast"
		card.Size                      = UDim2.fromOffset(CARD_W, CARD_H)
		card.AnchorPoint               = Vector2.new(1, 0)
		card.Position                  = UDim2.new(1, CARD_W + 20, 0, TOP_MARGIN)
		card.BackgroundColor3          = Color3.fromRGB(7, 9, 22)
		card.BackgroundTransparency    = 0.04
		card.BorderSizePixel           = 0
		card.ZIndex                    = 100
		card.Parent                    = sg
		UILib.corner(card, 10)
		UILib.stroke(card, C.GREEN, 1.5)

		-- Left accent stripe
		local accent                   = Instance.new("Frame")
		accent.Size                    = UDim2.new(0, 3, 1, -16)
		accent.Position                = UDim2.fromOffset(7, 8)
		accent.BackgroundColor3        = C.GREEN
		accent.BorderSizePixel         = 0
		accent.ZIndex                  = 101
		accent.Parent                  = card
		UILib.corner(accent, 2)

		-- "✓ RESEARCH UNLOCKED" header
		local header                   = Instance.new("TextLabel")
		header.Size                    = UDim2.fromOffset(CARD_W - 48, 18)
		header.Position                = UDim2.fromOffset(18, 10)
		header.BackgroundTransparency  = 1
		header.Font                    = Enum.Font.GothamBold
		header.TextSize                = 10
		header.TextColor3              = C.GREEN
		header.TextXAlignment          = Enum.TextXAlignment.Left
		header.Text                    = "✓  RESEARCH UNLOCKED"
		header.ZIndex                  = 102
		header.Parent                  = card

		-- Icon (top-right)
		local iconLbl                  = Instance.new("TextLabel")
		iconLbl.Size                   = UDim2.fromOffset(28, 28)
		iconLbl.AnchorPoint            = Vector2.new(1, 0)
		iconLbl.Position               = UDim2.new(1, -9, 0, 8)
		iconLbl.BackgroundTransparency = 1
		iconLbl.Font                   = Enum.Font.GothamBold
		iconLbl.TextSize               = 18
		iconLbl.TextColor3             = C.TEXT
		iconLbl.TextXAlignment         = Enum.TextXAlignment.Center
		iconLbl.TextYAlignment         = Enum.TextYAlignment.Center
		iconLbl.Text                   = unlock.icon :: string? or "◆"
		iconLbl.ZIndex                 = 102
		iconLbl.Parent                 = card

		-- Tech name
		local nameLbl                  = Instance.new("TextLabel")
		nameLbl.Size                   = UDim2.fromOffset(CARD_W - 52, 22)
		nameLbl.Position               = UDim2.fromOffset(18, 26)
		nameLbl.BackgroundTransparency = 1
		nameLbl.Font                   = Enum.Font.GothamBold
		nameLbl.TextSize               = 16
		nameLbl.TextColor3             = C.TEXT
		nameLbl.TextXAlignment         = Enum.TextXAlignment.Left
		nameLbl.Text                   = techName
		nameLbl.ZIndex                 = 102
		nameLbl.Parent                 = card

		-- One-line description (truncated)
		local descStr = unlock.desc :: string? or ""
		if #descStr > 50 then descStr = string.sub(descStr, 1, 47) .. "…" end

		local descLbl                  = Instance.new("TextLabel")
		descLbl.Size                   = UDim2.fromOffset(CARD_W - 28, 18)
		descLbl.Position               = UDim2.fromOffset(18, 48)
		descLbl.BackgroundTransparency = 1
		descLbl.Font                   = Enum.Font.Gotham
		descLbl.TextSize               = 11
		descLbl.TextColor3             = C.SUBTEXT
		descLbl.TextXAlignment         = Enum.TextXAlignment.Left
		descLbl.Text                   = descStr
		descLbl.ZIndex                 = 102
		descLbl.Parent                 = card

		-- Upgrades menu callout
		local hintLbl                  = Instance.new("TextLabel")
		hintLbl.Size                   = UDim2.fromOffset(CARD_W - 28, 16)
		hintLbl.Position               = UDim2.fromOffset(18, 68)
		hintLbl.BackgroundTransparency = 1
		hintLbl.Font                   = Enum.Font.GothamBold
		hintLbl.TextSize               = 10
		hintLbl.TextColor3             = Color3.fromRGB(155, 120, 255)
		hintLbl.TextXAlignment         = Enum.TextXAlignment.Left
		hintLbl.Text                   = "⚗  View in UPGRADES menu"
		hintLbl.ZIndex                 = 102
		hintLbl.Parent                 = card

		-- Drain bar (auto-dismiss timer visual)
		local drainBg                  = Instance.new("Frame")
		drainBg.Size                   = UDim2.new(1, 0, 0, 2)
		drainBg.AnchorPoint            = Vector2.new(0, 1)
		drainBg.Position               = UDim2.new(0, 0, 1, 0)
		drainBg.BackgroundColor3       = Color3.fromRGB(18, 22, 48)
		drainBg.BorderSizePixel        = 0
		drainBg.ZIndex                 = 103
		drainBg.Parent                 = card
		UILib.corner(drainBg, 2)

		local drainFill                = Instance.new("Frame")
		drainFill.Size                 = UDim2.new(1, 0, 1, 0)
		drainFill.BackgroundColor3     = C.GREEN
		drainFill.BorderSizePixel      = 0
		drainFill.ZIndex               = 104
		drainFill.Parent               = drainBg
		UILib.corner(drainFill, 2)

		-- Register and slide in from right
		local unregister = registerCard(card, CARD_H)
		local targetY    = computeTargetY(#activeCards)

		TweenService:Create(card, SLIDE_IN, {
			Position = UDim2.new(1, -12, 0, targetY)
		}):Play()
		playUnlockSound()

		TweenService:Create(drainFill,
			TweenInfo.new(LINGER, Enum.EasingStyle.Linear),
			{ Size = UDim2.new(0, 0, 1, 0) }
		):Play()

		task.wait(LINGER)

		TweenService:Create(card, SLIDE_OUT, {
			Position = UDim2.new(1, CARD_W + 20, 0, targetY)
		}):Play()
		task.wait(SLIDE_OUT.Time + 0.05)
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
	local CHOICE_W = 370
	local CHOICE_H = 240

	task.spawn(function()
		local sg = getScreenGui()
		if not sg then return end

		local card                     = Instance.new("Frame")
		card.Name                      = "ChoiceCard"
		card.Size                      = UDim2.fromOffset(CHOICE_W, CHOICE_H)
		card.AnchorPoint               = Vector2.new(0.5, 0)
		card.Position                  = UDim2.new(0.5, 0, 0, -(CHOICE_H + 20))
		card.BackgroundColor3          = Color3.fromRGB(7, 9, 22)
		card.BackgroundTransparency    = 0.04
		card.BorderSizePixel           = 0
		card.ZIndex                    = 110
		card.Parent                    = sg
		UILib.corner(card, 12)
		local glow = UILib.stroke(card, C.GOLD, 2)

		-- Pulse the border while waiting for a choice
		task.spawn(function()
			while card.Parent do
				TweenService:Create(glow,
					TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
					{ Thickness = 3.5 }
				):Play()
				task.wait(0.95)
				if not card.Parent then break end
				TweenService:Create(glow,
					TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
					{ Thickness = 1.5 }
				):Play()
				task.wait(0.95)
			end
		end)

		-- Header
		local hdr                      = Instance.new("TextLabel")
		hdr.Size                       = UDim2.fromOffset(CHOICE_W - 24, 26)
		hdr.Position                   = UDim2.fromOffset(12, 12)
		hdr.BackgroundTransparency     = 1
		hdr.Font                       = Enum.Font.GothamBold
		hdr.TextSize                   = 13
		hdr.TextColor3                 = C.GOLD
		hdr.TextXAlignment             = Enum.TextXAlignment.Center
		hdr.Text                       = "⚗  CHOOSE YOUR UPGRADE PATH"
		hdr.ZIndex                     = 112
		hdr.Parent                     = card

		-- Condition text
		local hint = "Unlock condition met!"
		for _, t in options do
			local ul = (Config.UNLOCKS :: any)[t]
			if ul then hint = ul.condText :: string; break end
		end
		local condLbl                  = Instance.new("TextLabel")
		condLbl.Size                   = UDim2.fromOffset(CHOICE_W - 24, 18)
		condLbl.Position               = UDim2.fromOffset(12, 36)
		condLbl.BackgroundTransparency = 1
		condLbl.Font                   = Enum.Font.Gotham
		condLbl.TextSize               = 11
		condLbl.TextColor3             = C.SUBTEXT
		condLbl.TextXAlignment         = Enum.TextXAlignment.Center
		condLbl.Text                   = hint
		condLbl.ZIndex                 = 112
		condLbl.Parent                 = card

		-- Divider
		local div                      = Instance.new("Frame")
		div.Size                       = UDim2.new(1, -24, 0, 1)
		div.Position                   = UDim2.fromOffset(12, 60)
		div.BackgroundColor3           = Color3.fromRGB(30, 36, 72)
		div.BorderSizePixel            = 0
		div.ZIndex                     = 111
		div.Parent                     = card

		-- Option buttons
		local BTN_W      = math.floor((CHOICE_W - 36) / #options)
		local chosenName: string? = nil
		local btns:     { TextButton } = {}
		local strokes:  { UIStroke   } = {}

		for i, techName in options do
			local ul = (Config.UNLOCKS :: any)[techName]
			local x  = 12 + (i - 1) * (BTN_W + 12)

			local btn                  = Instance.new("TextButton")
			btn.Size                   = UDim2.fromOffset(BTN_W, 162)
			btn.Position               = UDim2.fromOffset(x, 68)
			btn.BackgroundColor3       = Color3.fromRGB(13, 16, 36)
			btn.BackgroundTransparency = 0.1
			btn.BorderSizePixel        = 0
			btn.Text                   = ""
			btn.AutoButtonColor        = false
			btn.ZIndex                 = 112
			btn.Parent                 = card
			UILib.corner(btn, 8)
			local s = UILib.stroke(btn, C.BORDER, 1.5)
			table.insert(btns,    btn)
			table.insert(strokes, s)

			local iLbl                 = Instance.new("TextLabel")
			iLbl.Size                  = UDim2.new(1, 0, 0, 28)
			iLbl.Position              = UDim2.fromOffset(0, 10)
			iLbl.BackgroundTransparency= 1
			iLbl.Font                  = Enum.Font.GothamBold
			iLbl.TextSize              = 22
			iLbl.TextColor3            = C.GOLD
			iLbl.TextXAlignment        = Enum.TextXAlignment.Center
			iLbl.Text                  = ul and (ul.icon :: string) or "◆"
			iLbl.ZIndex                = 113
			iLbl.Parent                = btn

			local tLbl                 = Instance.new("TextLabel")
			tLbl.Size                  = UDim2.new(1, -8, 0, 26)
			tLbl.Position              = UDim2.fromOffset(4, 42)
			tLbl.BackgroundTransparency= 1
			tLbl.Font                  = Enum.Font.GothamBold
			tLbl.TextSize              = 13
			tLbl.TextColor3            = C.TEXT
			tLbl.TextXAlignment        = Enum.TextXAlignment.Center
			tLbl.TextWrapped           = true
			tLbl.Text                  = techName
			tLbl.ZIndex                = 113
			tLbl.Parent                = btn

			local dLbl                 = Instance.new("TextLabel")
			dLbl.Size                  = UDim2.new(1, -8, 0, 72)
			dLbl.Position              = UDim2.fromOffset(4, 72)
			dLbl.BackgroundTransparency= 1
			dLbl.Font                  = Enum.Font.Gotham
			dLbl.TextSize              = 11
			dLbl.TextColor3            = C.SUBTEXT
			dLbl.TextXAlignment        = Enum.TextXAlignment.Center
			dLbl.TextWrapped           = true
			dLbl.Text                  = ul and (ul.desc :: string) or ""
			dLbl.ZIndex                = 113
			dLbl.Parent                = btn

			btn.MouseEnter:Connect(function()
				if chosenName then return end
				TweenService:Create(btn, TweenInfo.new(0.1), { BackgroundColor3 = Color3.fromRGB(22, 28, 60) }):Play()
				TweenService:Create(s,   TweenInfo.new(0.1), { Color = C.GOLD, Thickness = 2 }):Play()
			end)
			btn.MouseLeave:Connect(function()
				if chosenName then return end
				TweenService:Create(btn, TweenInfo.new(0.1), { BackgroundColor3 = Color3.fromRGB(13, 16, 36) }):Play()
				TweenService:Create(s,   TweenInfo.new(0.1), { Color = C.BORDER, Thickness = 1.5 }):Play()
			end)

			local capturedName = techName
			local capturedIdx  = i
			btn.MouseButton1Click:Connect(function()
				if chosenName then return end
				chosenName = capturedName
				chooseFn(capturedName)

				for j, ob in btns do
					if j == capturedIdx then
						TweenService:Create(strokes[j], TweenInfo.new(0.2), { Color = C.GREEN, Thickness = 2.5 }):Play()
						TweenService:Create(ob, TweenInfo.new(0.2), { BackgroundColor3 = Color3.fromRGB(8, 34, 14) }):Play()
					else
						TweenService:Create(ob, TweenInfo.new(0.2), { BackgroundTransparency = 0.65 }):Play()
					end
				end

				task.wait(0.85)
				TweenService:Create(card, CHOICE_OUT, {
					Position = UDim2.new(0.5, 0, 0, -(CHOICE_H + 20))
				}):Play()
				task.wait(CHOICE_OUT.Time + 0.05)
				card:Destroy()
				UnlockNotification.showUnlock(capturedName)
			end)
		end

		-- Slide down from top-center
		TweenService:Create(card, CHOICE_IN, {
			Position = UDim2.new(0.5, 0, 0, 16)
		}):Play()
		playUnlockSound()
	end)
end

return UnlockNotification
