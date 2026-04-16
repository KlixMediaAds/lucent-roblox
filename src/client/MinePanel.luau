--!strict
--[[
    MinePanel — Info card shown when the player clicks a mine.
    Displays the root "MINE" node; click it (or click away) to close.
    Upgrade nodes removed — mines no longer have buildable upgrades.
]]

local Players      = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UILib             = require(script.Parent:WaitForChild("UILib"))

local MinePanel   = {}
local localPlayer = Players.LocalPlayer
local C           = UILib.C

-- ── State ─────────────────────────────────────────────────────────────────────
local activeMineId: string? = nil
local networkRef:   any
local overlay:      Frame?
local rootLbl:      TextLabel?

local ROOT_POS = UDim2.new(0.5, 0, 0.68, 0)

local EXPAND_TI   = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local COLLAPSE_TI = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

-- ── Init ──────────────────────────────────────────────────────────────────────
function MinePanel.init(network, _getResourcesFn, _hasResearchFn)
	networkRef = network

	local sg = localPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui

	local ov                         = Instance.new("Frame")
	ov.Name                          = "MineOverlay"
	ov.Size                          = UDim2.new(1, 0, 1, 0)
	ov.BackgroundTransparency        = 1
	ov.BorderSizePixel               = 0
	ov.ZIndex                        = 10
	ov.Visible                       = false
	ov.Parent                        = sg
	overlay = ov

	local rootWrapper, rBtn = UILib.radialNode(ov, "MINE", "⛏", C.MINE, ROOT_POS, 70, 11)
	rootLbl = rootWrapper:FindFirstChild("NodeLabel") :: TextLabel?

	rBtn.MouseButton1Click:Connect(function()
		MinePanel.hide()
	end)

	-- Pop-in scale tween on the wrapper
	local scale = Instance.new("UIScale")
	scale.Scale = 0.7
	scale.Parent = rootWrapper
	ov:GetPropertyChangedSignal("Visible"):Connect(function()
		if ov.Visible then
			TweenService:Create(scale, EXPAND_TI, { Scale = 1 }):Play()
		else
			scale.Scale = 0.7
		end
	end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function MinePanel.show(mineId: string)
	activeMineId = mineId
	if rootLbl then rootLbl.Text = "MINE" end
	if overlay then overlay.Visible = true end
end

function MinePanel.hide()
	activeMineId = nil
	if overlay then
		TweenService:Create(overlay, COLLAPSE_TI, { BackgroundTransparency = 1 }):Play()
		task.delay(COLLAPSE_TI.Time, function()
			if overlay then overlay.Visible = false end
		end)
	end
end

function MinePanel.refreshIfVisible()
	-- No dynamic content to refresh in the simplified panel
end

return MinePanel
