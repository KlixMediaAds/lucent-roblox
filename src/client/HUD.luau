--!strict
--[[
    HUD — Resource bar, selection label, drag-select rect, CC button,
    single BLOB placement button, UPGRADES button, and notification toasts.
]]

local Players       = game:GetService("Players")
local TweenService  = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))

-- ── UI scaling ────────────────────────────────────────────────────────────────
local BASE_W = 1920
local BASE_H = 1080

local function setupScaling(sg: ScreenGui)
	local uiScale        = Instance.new("UIScale")
	uiScale.Scale        = 1
	uiScale.Parent       = sg

	local function applyScale()
		local cam = workspace.CurrentCamera
		if not cam then return end
		local vp  = cam.ViewportSize
		if vp.X == 0 or vp.Y == 0 then return end
		uiScale.Scale = math.max(
			math.min(vp.X / BASE_W, vp.Y / BASE_H),
			0.35
		)
	end

	applyScale()

	local function hookCamera(cam: Camera)
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(applyScale)
		applyScale()
	end

	if workspace.CurrentCamera then
		hookCamera(workspace.CurrentCamera)
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		if workspace.CurrentCamera then hookCamera(workspace.CurrentCamera) end
	end)
end

local HUD         = {}
local localPlayer = Players.LocalPlayer
local C           = UILib.C

-- ── State ─────────────────────────────────────────────────────────────────────
local resLabel:  TextLabel?
local incLabel:  TextLabel?
local selLabel:  TextLabel?

local currentResources = 0
local currentIncome    = 0

local blobBtnRef:       TextButton?
local buildOverlay:     Frame?
local cancelBtnRef:     TextButton?
local ccBtnInternal:    TextButton?
local ccGlowRef:        UIStroke?
local ccScaleRef:       UIScale?
local upgradesBtnRef:   TextButton?
local upgradesWrapper:  Frame?
local upgradesStroke:   UIStroke?
local upgradesScaleRef: UIScale?
local UPGRADES_COLOR = Color3.fromRGB(190, 140, 255)
local UPGRADES_SEGS  = 24

-- ── Resource display ──────────────────────────────────────────────────────────
local function refreshResDisplay()
	if resLabel then resLabel.Text = tostring(currentResources) end
	if incLabel then
		if currentIncome > 0 then
			incLabel.Text       = string.format("+%.0f/min", currentIncome)
			incLabel.TextColor3 = C.GREEN
		else
			incLabel.Text = ""
		end
	end
end

-- ── HUD.create ────────────────────────────────────────────────────────────────
function HUD.create(): (Frame, TextButton)
	local sg                    = Instance.new("ScreenGui")
	sg.Name                     = "RTSHUD"
	sg.ResetOnSpawn             = false
	sg.ZIndexBehavior           = Enum.ZIndexBehavior.Sibling
	sg.Parent                   = localPlayer.PlayerGui
	setupScaling(sg)

	-- ── Resource bar (top-left) ───────────────────────────────────────────────
	local resBar                    = Instance.new("Frame")
	resBar.Name                     = "ResourceBar"
	resBar.Size                     = UDim2.fromOffset(272, 40)
	resBar.Position                 = UDim2.fromOffset(12, 12)
	resBar.BackgroundColor3         = C.BG_PANEL
	resBar.BackgroundTransparency   = 0.08
	resBar.BorderSizePixel          = 0
	resBar.ZIndex                   = 4
	resBar.Parent                   = sg
	UILib.corner(resBar, 8)
	UILib.stroke(resBar, C.BORDER, 1)

	UILib.lbl(resBar, "◆",
		UDim2.fromOffset(22, 40), UDim2.fromOffset(8, 0),
		{ bold = true, size = 18, color = C.GOLD, align = Enum.TextXAlignment.Center, zIndex = 5 })

	local rLbl = UILib.lbl(resBar, "400",
		UDim2.fromOffset(100, 40), UDim2.fromOffset(30, 0),
		{ bold = true, size = 16, color = C.GOLD, align = Enum.TextXAlignment.Left, zIndex = 5 })
	rLbl.Name = "ResLabel"
	resLabel   = rLbl

	UILib.lbl(resBar, "·",
		UDim2.fromOffset(14, 40), UDim2.fromOffset(132, 0),
		{ size = 16, color = C.SUBTEXT, align = Enum.TextXAlignment.Center, zIndex = 5 })

	local iLbl = UILib.lbl(resBar, "",
		UDim2.fromOffset(112, 40), UDim2.fromOffset(148, 0),
		{ size = 13, color = C.GREEN, align = Enum.TextXAlignment.Left, zIndex = 5 })
	iLbl.Name = "IncLabel"
	incLabel   = iLbl

	-- ── Selection label (top-centre) ──────────────────────────────────────────
	local sLbl                      = Instance.new("TextLabel")
	sLbl.Name                       = "SelLabel"
	sLbl.Size                       = UDim2.fromOffset(280, 38)
	sLbl.Position                   = UDim2.new(0.5, -140, 0, 12)
	sLbl.BackgroundTransparency     = 1
	sLbl.TextColor3                 = C.TEXT
	sLbl.Font                       = Enum.Font.GothamBold
	sLbl.TextSize                   = 15
	sLbl.TextXAlignment             = Enum.TextXAlignment.Center
	sLbl.Text                       = ""
	sLbl.ZIndex                     = 4
	sLbl.Parent                     = sg
	selLabel = sLbl

	-- ── Drag-select rectangle ─────────────────────────────────────────────────
	local dragFrame                     = Instance.new("Frame")
	dragFrame.Name                      = "DragSelect"
	dragFrame.BackgroundColor3          = C.ACCENT
	dragFrame.BackgroundTransparency    = 0.76
	dragFrame.BorderSizePixel           = 1
	dragFrame.BorderColor3              = C.ACCENT
	dragFrame.Visible                   = false
	dragFrame.ZIndex                    = 20
	dragFrame.Parent                    = sg

	-- ── CC placement button (shown in CC mode only) ───────────────────────────
	local ccBtn                         = UILib.btn(sg,
		"⌂  PLACE COMMAND CENTER",
		UDim2.fromOffset(320, 58),
		UDim2.new(0.5, -160, 1, -68),
		C.TEAL, 4)
	ccBtn.Name                          = "CCButton"
	ccBtn.TextSize                      = 17
	ccBtn.Visible                       = false
	ccBtnInternal                       = ccBtn

	local ccGrad                        = Instance.new("UIGradient")
	ccGrad.Color                        = ColorSequence.new({
		ColorSequenceKeypoint.new(0,   Color3.fromRGB( 30, 220, 210)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(  0, 180, 200)),
		ColorSequenceKeypoint.new(1,   Color3.fromRGB(  0, 130, 160)),
	})
	ccGrad.Rotation                     = 90
	ccGrad.Parent                       = ccBtn

	local ccGlowStroke                  = Instance.new("UIStroke")
	ccGlowStroke.Color                  = Color3.fromRGB(0, 220, 255)
	ccGlowStroke.Thickness              = 2.5
	ccGlowStroke.Transparency           = 0
	ccGlowStroke.Parent                 = ccBtn
	ccGlowRef                           = ccGlowStroke

	local ccScaleInst                   = Instance.new("UIScale")
	ccScaleInst.Scale                   = 1
	ccScaleInst.Parent                  = ccBtn
	ccScaleRef                          = ccScaleInst

	-- ── Cancel button (shown during placement, bottom-right) ──────────────────
	local cancelBtn                     = UILib.btn(sg,
		"X  CANCEL",
		UDim2.fromOffset(145, 50),
		UDim2.new(1, -160, 1, -60),
		C.RED, 6)
	cancelBtn.Name                      = "CancelBtn"
	cancelBtn.TextSize                  = 14
	cancelBtn.Visible                   = false
	cancelBtnRef                        = cancelBtn

	-- ── Build overlay (full-screen transparent, holds BLOB + UPGRADES buttons) ─
	local ov                            = Instance.new("Frame")
	ov.Name                             = "BuildOverlay"
	ov.Size                             = UDim2.new(1, 0, 1, 0)
	ov.BackgroundTransparency           = 1
	ov.BorderSizePixel                  = 0
	ov.ZIndex                           = 3
	ov.Visible                          = false
	ov.Parent                           = sg
	buildOverlay = ov

	-- ── Single BLOB placement button (bottom-left) ────────────────────────────
	local blobPos                       = UDim2.new(0, 80, 1, -110)
	local _, bBtn                       = UILib.radialNode(ov, "BLOB", "●", C.TEAL, blobPos, 80, 4)
	blobBtnRef                          = bBtn

	-- ── UPGRADES button (above BLOB) ──────────────────────────────────────────
	do
		local upgPos = UDim2.new(0, 80, 1, -212)
		local w, btn = UILib.radialNode(ov, "UPGRADES", "⚗", UPGRADES_COLOR, upgPos, 80, 4)
		;(w:FindFirstChild("NodeLabel") :: TextLabel).TextSize = 15

		local stroke     = btn:FindFirstChildWhichIsA("UIStroke") :: UIStroke
		stroke.Color     = UPGRADES_COLOR
		stroke.Thickness = 1.5

		local scl  = Instance.new("UIScale")
		scl.Scale  = 1
		scl.Parent = btn

		local SEG_R = 47
		for i = 0, UPGRADES_SEGS - 1 do
			local rad               = math.rad((i / UPGRADES_SEGS) * 360 - 90)
			local seg               = Instance.new("Frame")
			seg.Name                = "ProgSeg" .. i
			seg.Size                = UDim2.fromOffset(6, 6)
			seg.AnchorPoint         = Vector2.new(0.5, 0.5)
			seg.Position            = UDim2.fromOffset(
				40 + math.cos(rad) * SEG_R,
				40 + math.sin(rad) * SEG_R
			)
			seg.BackgroundColor3       = UPGRADES_COLOR
			seg.BackgroundTransparency = 0.82
			seg.BorderSizePixel        = 0
			seg.ZIndex                 = 6
			seg.Parent                 = w
			UILib.corner(seg, 3)
		end

		btn.MouseEnter:Connect(function()
			TweenService:Create(btn,    TweenInfo.new(0.12), { BackgroundTransparency = 0.15 }):Play()
			TweenService:Create(stroke, TweenInfo.new(0.12), { Thickness = 2.5 }):Play()
		end)
		btn.MouseLeave:Connect(function()
			TweenService:Create(btn,    TweenInfo.new(0.12), { BackgroundTransparency = 0.35 }):Play()
			TweenService:Create(stroke, TweenInfo.new(0.12), { Thickness = 1.5 }):Play()
		end)

		upgradesBtnRef   = btn
		upgradesWrapper  = w
		upgradesStroke   = stroke
		upgradesScaleRef = scl
	end

	return dragFrame, ccBtn
end

-- ── Notification toast ────────────────────────────────────────────────────────
local toastQueue: { Frame } = {}
local TOAST_BASE_Y = 64

local function shiftToasts()
	for i, t in toastQueue do
		TweenService:Create(t, TweenInfo.new(0.18), {
			Position = UDim2.new(1, -12, 0, TOAST_BASE_Y + (i - 1) * 52)
		}):Play()
	end
end

function HUD.showNotification(msg: string, color: Color3?)
	local sg = localPlayer.PlayerGui:FindFirstChild("RTSHUD") :: ScreenGui?
	if not sg then return end

	local col = color or C.TEXT

	local toast                         = Instance.new("Frame")
	toast.Size                          = UDim2.fromOffset(290, 42)
	toast.Position                      = UDim2.new(1, 290, 0, TOAST_BASE_Y)
	toast.AnchorPoint                   = Vector2.new(1, 0)
	toast.BackgroundColor3              = Color3.fromRGB(8, 12, 24)
	toast.BackgroundTransparency        = 0.06
	toast.BorderSizePixel               = 0
	toast.ZIndex                        = 60
	toast.Parent                        = sg
	UILib.corner(toast, 8)
	UILib.stroke(toast, col, 1.5)

	local bar                           = Instance.new("Frame")
	bar.Size                            = UDim2.new(0, 4, 1, -12)
	bar.Position                        = UDim2.fromOffset(6, 6)
	bar.BackgroundColor3                = col
	bar.BorderSizePixel                 = 0
	bar.ZIndex                          = 61
	bar.Parent                          = toast
	UILib.corner(bar, 2)

	local lbl                           = Instance.new("TextLabel")
	lbl.Size                            = UDim2.new(1, -20, 1, 0)
	lbl.Position                        = UDim2.fromOffset(16, 0)
	lbl.BackgroundTransparency          = 1
	lbl.Text                            = msg
	lbl.TextSize                        = 13
	lbl.TextColor3                      = col
	lbl.Font                            = Enum.Font.GothamBold
	lbl.TextXAlignment                  = Enum.TextXAlignment.Left
	lbl.TextWrapped                     = true
	lbl.ZIndex                          = 61
	lbl.Parent                          = toast

	table.insert(toastQueue, toast)
	local targetY = TOAST_BASE_Y + (#toastQueue - 1) * 52

	shiftToasts()
	TweenService:Create(toast, TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
		Position = UDim2.new(1, -12, 0, targetY)
	}):Play()

	task.delay(4, function()
		local t2 = TweenService:Create(toast, TweenInfo.new(0.18), { Position = UDim2.new(1, 290, 0, targetY) })
		t2.Completed:Once(function()
			for i, t in toastQueue do
				if t == toast then table.remove(toastQueue, i); break end
			end
			toast:Destroy()
			shiftToasts()
		end)
		t2:Play()
	end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function HUD.setResources(n: number)
	currentResources = n
	refreshResDisplay()
end

function HUD.setIncome(perMin: number)
	currentIncome = perMin
	refreshResDisplay()
end

function HUD.setCommandCenterMode(isCC: boolean)
	if buildOverlay  then buildOverlay.Visible  = not isCC end
	if ccBtnInternal then ccBtnInternal.Visible = isCC     end

	if isCC then
		if ccScaleRef then
			ccScaleRef.Scale = 0.82
			TweenService:Create(ccScaleRef,
				TweenInfo.new(0.30, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Scale = 1 }
			):Play()
		end
		if ccGlowRef then
			local pulseOut = TweenService:Create(ccGlowRef,
				TweenInfo.new(0.50, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
				{ Thickness = 6, Transparency = 0.3 }
			)
			pulseOut:Play()
			pulseOut.Completed:Once(function()
				TweenService:Create(ccGlowRef,
					TweenInfo.new(0.50, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
					{ Thickness = 2.5, Transparency = 0 }
				):Play()
			end)
		end
	end
end

-- No-ops kept for call-site compatibility
function HUD.refreshTrayState(_counts: { [string]: number }) end
function HUD.setHasResearch(_fn: (string) -> boolean) end

-- ── HUD.wire ──────────────────────────────────────────────────────────────────
function HUD.wire(
	network,
	unitController,
	buildingPlacer,
	hidePanelsFn: () -> (),
	upgradesFn:  (() -> ())?
)
	network.onResourceSync(function(n: number)
		HUD.setResources(n)
	end)

	unitController.onSelectionChanged(function(n: number)
		if selLabel then
			selLabel.Text = n > 0
				and (n .. " unit" .. (n == 1 and "" or "s") .. " selected")
				or  ""
		end
	end)

	-- BLOB button: enter blob placement mode
	if blobBtnRef then
		blobBtnRef.MouseButton1Click:Connect(function()
			hidePanelsFn()
			buildingPlacer.enterPlacementMode("Blob")
		end)
	end

	if cancelBtnRef then
		cancelBtnRef.MouseButton1Click:Connect(function()
			buildingPlacer.exitPlacementMode()
		end)
	end

	if upgradesBtnRef and upgradesFn then
		upgradesBtnRef.MouseButton1Click:Connect(upgradesFn)
	end

	buildingPlacer.onModeChanged(function(active: boolean, buildingType: string?)
		if cancelBtnRef then
			cancelBtnRef.Visible = active and buildingType ~= "CommandCenter"
		end
		-- Highlight blob button while in blob placement mode
		if blobBtnRef then
			local inBlobMode = active and buildingType == "Blob"
			local stroke = blobBtnRef:FindFirstChildWhichIsA("UIStroke") :: UIStroke?
			if stroke then
				TweenService:Create(stroke, TweenInfo.new(0.12), {
					Thickness = inBlobMode and 4 or 2
				}):Play()
			end
			TweenService:Create(blobBtnRef, TweenInfo.new(0.12), {
				BackgroundTransparency = inBlobMode and 0.1 or 0.35
			}):Play()
		end
	end)
end

-- ── Research ring (UPGRADES button) ──────────────────────────────────────────

function HUD.setResearchProgress(progress: number?)
	local w = upgradesWrapper
	if not w then return end
	local active = if progress then math.floor(progress * UPGRADES_SEGS) else 0
	for i = 0, UPGRADES_SEGS - 1 do
		local seg = w:FindFirstChild("ProgSeg" .. i) :: Frame?
		if seg then
			seg.BackgroundTransparency = if i < active then 0 else 0.82
		end
	end
	if upgradesStroke then
		upgradesStroke.Thickness = if progress then 2.5 else 1.5
	end
end

function HUD.flashResearchComplete()
	local w = upgradesWrapper
	if not w then return end
	for i = 0, UPGRADES_SEGS - 1 do
		local seg = w:FindFirstChild("ProgSeg" .. i) :: Frame?
		if seg then
			TweenService:Create(seg, TweenInfo.new(0.1), {
				BackgroundColor3 = C.GOLD, BackgroundTransparency = 0,
			}):Play()
		end
	end
	if upgradesStroke then
		TweenService:Create(upgradesStroke,
			TweenInfo.new(0.12), { Color = C.GOLD, Thickness = 4 }):Play()
	end
	if upgradesScaleRef then
		upgradesScaleRef.Scale = 1.22
		TweenService:Create(upgradesScaleRef,
			TweenInfo.new(0.5, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out),
			{ Scale = 1 }):Play()
	end
	task.delay(0.9, function()
		local w2 = upgradesWrapper
		if not w2 then return end
		for i = 0, UPGRADES_SEGS - 1 do
			local seg = w2:FindFirstChild("ProgSeg" .. i) :: Frame?
			if seg then
				TweenService:Create(seg, TweenInfo.new(0.5), {
					BackgroundColor3 = UPGRADES_COLOR, BackgroundTransparency = 0.82,
				}):Play()
			end
		end
		if upgradesStroke then
			TweenService:Create(upgradesStroke,
				TweenInfo.new(0.5), { Color = UPGRADES_COLOR, Thickness = 1.5 }):Play()
		end
	end)
end

return HUD
