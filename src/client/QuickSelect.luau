--!strict
--[[
	QuickSelect: the row of group buttons standing on top of the command bar, in the
	column right of the minimap where the scout toggle and its command row live.

	Four slots, left to right:

	  MOTHER   your Command Center (the Hollowed Mother, or the Humans' Fabricator Core)
	  EGGS     every egg in your clutch, with the hatch panel open on them
	  LEECHES  every Leech you own
	  ARMY     everything else you own that fights

	One tap TAKES the group -- the same selection, rings and command card you would get by
	clicking the thing itself. A second tap inside DOUBLE_TAP flies the camera to where
	that group is standing. The Mother slot replaces the old [1] button on the minimap,
	which only ever did the camera half of that.

	A slot is hidden until the player actually has one of its group, and shows a count
	once they have more than one. Slots keep FIXED positions rather than packing left, so
	a button never moves out from under the cursor as an army grows or a clutch hatches.

	Hovering one names it: a small label rises into place above the button as it fades in.
	There is one label, moved to whichever slot the cursor is on, since only one slot can
	be hovered at a time.

	The 3D faces come from ViewportPreview, the same builders the command cards use, so a
	button shows the actual creature rather than a glyph standing in for it.
]]

local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PerfProbe = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PerfProbe"))
local UILib           = require(script.Parent:WaitForChild("UILib"))
local ViewportPreview = require(script.Parent:WaitForChild("ViewportPreview"))

local QuickSelect = {}

local localPlayer = Players.LocalPlayer

-- ── Layout ────────────────────────────────────────────────────────────────────
-- This shares the bottom cluster's coordinate space (bottom-left origin, inset ignored,
-- same HUD scale). The constants mirror the ones MiniMap and ScoutManager keep: the row
-- stands ON the command bar's top edge, starting in the same column as the scout toggle
-- (right of the minimap), so the buttons read as part of the bar rather than as one more
-- thing stacked over the map.
local MAP_PAD   = 10
local MAP_SPAN  = 148                        -- minimap border footprint (144 + 4)
local BAND_H    = (MAP_PAD + MAP_SPAN) / 2   -- command bar height (ScoutManager owns it)
local BTN       = 28
local GAP       = 6
local ROW_LEFT  = MAP_PAD + MAP_SPAN + 8     -- right of the minimap, level with the scout toggle
-- Clearance above the bar's top edge. It also has to clear the scout menu, whose wrapper
-- reserves headroom for the eye that pops up out of it and reaches ~4px past the bar.
local ROW_LIFT  = 7
local ROW_Y     = -(BAND_H + ROW_LIFT)       -- bottom edge of the row

local DOUBLE_TAP = 0.4   -- seconds; matches the [1] key's own double-tap window
local POLL       = 0.25  -- seconds between "what do I own" passes

-- ── Hover label ───────────────────────────────────────────────────────────────
-- The rise is what makes a fast fade read as a pop rather than a flicker: the label
-- climbs the last few pixels into place as it comes up. Back easing on the SLIDE gives it
-- the small overshoot that sells it; the fade itself stays plain Quad, since an
-- overshooting transparency would just clamp and do nothing.
local TIP_H    = 19
local TIP_GAP  = 6    -- air between the button's top edge and the label
local TIP_RISE = 6    -- pixels the label climbs on the way in
local TIP_SLIDE_IN  = TweenInfo.new(0.17, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local TIP_FADE_IN   = TweenInfo.new(0.10, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TIP_FADE_OUT  = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TIP_BG        = Color3.fromRGB(7, 9, 14)
local TIP_TXT       = Color3.fromRGB(232, 240, 252)

-- ── Palette ───────────────────────────────────────────────────────────────────
local BG        = Color3.fromRGB(7, 9, 14)
local BG_HOVER  = Color3.fromRGB(20, 26, 38)
local EDGE      = Color3.fromRGB(150, 210, 255)
local EDGE_EGG  = Color3.fromRGB(255, 180, 90)
local EDGE_LEECH= Color3.fromRGB(190, 120, 255)
local EDGE_ARMY = Color3.fromRGB(120, 235, 190)
local COUNT_COL = Color3.fromRGB(226, 238, 255)

-- ── State ─────────────────────────────────────────────────────────────────────
type Slot = {
	kind:   string,
	btn:    TextButton,
	stroke: UIStroke,
	count:  TextLabel,
	shown:  boolean,
}

local slots: { [string]: Slot } = {}
local unitControllerRef: any = nil
local cameraRef: any         = nil
local lastKind: string?      = nil
local lastTapAt              = 0
local built                  = false

local function isHollowed(): boolean
	return localPlayer:GetAttribute("Faction") == "Hollowed"
end

-- ── Faces ─────────────────────────────────────────────────────────────────────
-- Built once per slot, on the faction the player actually is: a Hollowed player's first
-- button is the Mother's face, a Human's is their Core.
local function faceFor(kind: string): ViewportFrame?
	local px   = Vector2.new(BTN - 8, BTN - 8)
	local team = localPlayer.TeamColor
	if kind == "mother" then
		if isHollowed() then return ViewportPreview.forMotherHead(px, team) end
		return ViewportPreview.forBuilding("CommandCenter", px, team)
	elseif kind == "eggs" then
		return ViewportPreview.forEggSacNest(px, team)
	elseif kind == "leeches" then
		return ViewportPreview.forLeech(false, px, team)
	elseif kind == "army" then
		-- One face has to stand for a mixed army, so it is the rank-and-file body of
		-- whichever side the player is on.
		local rankAndFile = if isHollowed() then "Lamprey" else "Survivor"
		return ViewportPreview.forUnit(rankAndFile, px, team)
	end
	return nil
end

-- ── Presses ───────────────────────────────────────────────────────────────────
-- Take the group. Returns false when there was nothing to take, which also means a
-- double tap on it does nothing rather than flying the camera at empty ground.
local function take(kind: string): boolean
	local uc = unitControllerRef
	if not uc then return false end
	if     kind == "mother"  then return uc.selectCommandCenter()
	elseif kind == "eggs"    then return uc.selectAllEggs()    > 0
	elseif kind == "leeches" then return uc.selectLeeches()    > 0
	elseif kind == "army"    then return uc.selectArmy()       > 0
	end
	return false
end

local function press(kind: string)
	local now      = os.clock()
	local isDouble = (kind == lastKind) and (now - lastTapAt <= DOUBLE_TAP)
	lastKind   = kind
	-- A consumed double tap resets the clock, so a third tap opens a fresh pair rather
	-- than flying the camera again on every tap after the second.
	lastTapAt  = if isDouble then 0 else now

	if not take(kind) then return end
	if not isDouble then return end

	local uc  = unitControllerRef
	local pos = uc and uc.selectionCentroid()
	if pos and cameraRef then cameraRef.returnToBase(pos) end
end

-- ── Hover label ───────────────────────────────────────────────────────────────
local tipFrame:  Frame?     = nil
local tipLabel:  TextLabel? = nil
local tipStroke: UIStroke?  = nil
local tipOwner:  string?    = nil   -- which slot the label is currently naming
local tipGen                = 0     -- bumped on every show/hide, so a stale fade-out
                                    -- never hides a label that has since come back

-- What the label says. The first slot is whatever that faction's Command Center IS, so
-- a Human player reads CORE where a Hollowed player reads MOTHER.
local function tipTextFor(kind: string): string
	if kind == "eggs"    then return "EGGS"    end
	if kind == "leeches" then return "LEECHES" end
	if kind == "army"    then return "ARMY"    end
	return if isHollowed() then "MOTHER" else "CORE"
end

local function buildTip(parent: Instance)
	local f                    = Instance.new("Frame")
	f.Name                     = "QS_Tip"
	f.AnchorPoint              = Vector2.new(0.5, 1)
	f.Size                     = UDim2.fromOffset(0, TIP_H)
	f.AutomaticSize            = Enum.AutomaticSize.X   -- hugs whatever word it holds
	f.BackgroundColor3         = TIP_BG
	f.BackgroundTransparency   = 1
	f.BorderSizePixel          = 0
	f.Visible                  = false
	f.ZIndex                   = 20
	f.Parent                   = parent
	UILib.corner(f, 4)

	local pad          = Instance.new("UIPadding")
	pad.PaddingLeft    = UDim.new(0, 7)
	pad.PaddingRight   = UDim.new(0, 7)
	pad.Parent         = f

	local st           = Instance.new("UIStroke")
	st.Color           = EDGE
	st.Thickness       = 1
	st.Transparency    = 1
	st.Parent          = f

	local t                    = Instance.new("TextLabel")
	t.Name                     = "Text"
	t.Size                     = UDim2.new(0, 0, 1, 0)
	t.AutomaticSize            = Enum.AutomaticSize.X
	t.BackgroundTransparency   = 1
	t.Font                     = Enum.Font.GothamBold
	t.TextSize                 = 11
	t.TextColor3               = TIP_TXT
	t.TextTransparency         = 1
	t.TextXAlignment           = Enum.TextXAlignment.Center
	t.Text                     = ""
	t.ZIndex                   = 21
	t.Parent                   = f

	tipFrame, tipLabel, tipStroke = f, t, st
end

-- Bring the label up over `slot`, naming it. Called on hover; re-entering another slot
-- while one is up just moves it and re-runs the rise, which reads as the label hopping
-- along the row rather than blinking out and back.
local function showTip(slot: Slot, edge: Color3)
	local f, t, st = tipFrame, tipLabel, tipStroke
	if not (f and t and st) then return end

	tipGen  += 1
	tipOwner = slot.kind
	t.Text   = tipTextFor(slot.kind)
	st.Color = edge

	local centreX = slot.btn.Position.X.Offset + BTN // 2
	local restY   = ROW_Y - BTN - TIP_GAP

	f.Position = UDim2.new(0, centreX, 1, restY + TIP_RISE)
	f.Visible  = true
	TweenService:Create(f,  TIP_SLIDE_IN, { Position = UDim2.new(0, centreX, 1, restY) }):Play()
	TweenService:Create(f,  TIP_FADE_IN,  { BackgroundTransparency = 0.08 }):Play()
	TweenService:Create(st, TIP_FADE_IN,  { Transparency = 0.35 }):Play()
	TweenService:Create(t,  TIP_FADE_IN,  { TextTransparency = 0 }):Play()
end

-- Take the label away. `kind` guards against the cursor having already moved on to
-- another slot: only the slot that still owns the label may dismiss it.
local function hideTip(kind: string?)
	local f, t, st = tipFrame, tipLabel, tipStroke
	if not (f and t and st) then return end
	if kind and tipOwner ~= kind then return end

	tipGen  += 1
	tipOwner = nil
	local gen = tipGen

	TweenService:Create(f,  TIP_FADE_OUT, { BackgroundTransparency = 1 }):Play()
	TweenService:Create(st, TIP_FADE_OUT, { Transparency = 1 }):Play()
	local fade = TweenService:Create(t, TIP_FADE_OUT, { TextTransparency = 1 })
	fade.Completed:Connect(function()
		-- Only the fade that is still the newest may pull it off screen.
		if tipGen == gen and f.Parent then f.Visible = false end
	end)
	fade:Play()
end

-- ── Build ─────────────────────────────────────────────────────────────────────
local function makeSlot(parent: Instance, kind: string, index: number, edge: Color3)
	local btn                   = Instance.new("TextButton")
	btn.Name                    = "QS_" .. kind
	btn.Size                    = UDim2.fromOffset(BTN, BTN)
	btn.AnchorPoint             = Vector2.new(0, 1)
	btn.Position                = UDim2.new(0, ROW_LEFT + (index - 1) * (BTN + GAP), 1, ROW_Y)
	btn.BackgroundColor3        = BG
	btn.BackgroundTransparency  = 0.06
	btn.AutoButtonColor         = false
	btn.Text                    = ""
	btn.BorderSizePixel         = 0
	btn.Visible                 = false
	btn.ZIndex                  = 6
	btn.Parent                  = parent
	UILib.corner(btn, 6)

	local stroke          = Instance.new("UIStroke")
	stroke.Color          = edge
	stroke.Thickness      = 1
	stroke.Transparency   = 0.3
	stroke.Parent         = btn

	local face = faceFor(kind)
	if face then
		face.ZIndex = 7
		UILib.setNodeViewport(btn, face, 4)
	end

	-- How many are in the group, tucked into the corner. The Mother is always one of
	-- her, so hers stays empty.
	local count                     = Instance.new("TextLabel")
	count.Name                      = "Count"
	count.Size                      = UDim2.fromOffset(BTN - 4, 10)
	count.AnchorPoint               = Vector2.new(1, 1)
	count.Position                  = UDim2.new(1, -3, 1, -1)
	count.BackgroundTransparency    = 1
	count.Font                      = Enum.Font.GothamBold
	count.TextSize                  = 10
	count.TextColor3                = COUNT_COL
	count.TextStrokeColor3          = Color3.new(0, 0, 0)
	count.TextStrokeTransparency    = 0.3
	count.TextXAlignment            = Enum.TextXAlignment.Right
	count.Text                      = ""
	count.ZIndex                    = 9
	count.Parent                    = btn

	local slot: Slot = { kind = kind, btn = btn, stroke = stroke, count = count, shown = false }

	btn.MouseEnter:Connect(function()
		TweenService:Create(btn,    TweenInfo.new(0.12), { BackgroundColor3 = BG_HOVER }):Play()
		TweenService:Create(stroke, TweenInfo.new(0.12), { Transparency = 0, Thickness = 1.8 }):Play()
		showTip(slot, edge)
	end)
	btn.MouseLeave:Connect(function()
		TweenService:Create(btn,    TweenInfo.new(0.12), { BackgroundColor3 = BG }):Play()
		TweenService:Create(stroke, TweenInfo.new(0.12), { Transparency = 0.3, Thickness = 1 }):Play()
		hideTip(kind)
	end)
	btn.MouseButton1Click:Connect(function() press(kind) end)

	slots[kind] = slot
end

local function setShown(slot: Slot, shown: boolean, n: number)
	if slot.shown ~= shown then
		slot.shown       = shown
		slot.btn.Visible = shown
		-- A button can go away under the cursor (the last Leech dies while you are
		-- pointing at it), and MouseLeave does not fire for a button that was simply
		-- hidden. Take its label with it.
		if not shown then hideTip(slot.kind) end
	end
	if not shown then return end
	-- A count of one says nothing the picture doesn't; it only earns its space once
	-- there is a group rather than a single thing.
	slot.count.Text = if n > 1 then tostring(n) else ""
end

-- ── Public ────────────────────────────────────────────────────────────────────
function QuickSelect.init(unitController: any, cameraModule: any)
	if built then return end
	built              = true
	unitControllerRef  = unitController
	cameraRef          = cameraModule

	local sg           = Instance.new("ScreenGui")
	sg.Name            = "QuickSelectGui"
	sg.ResetOnSpawn    = false
	sg.IgnoreGuiInset  = true   -- same coordinate space as the minimap and the command bar
	sg.DisplayOrder    = 3
	sg.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
	sg.Parent          = localPlayer.PlayerGui
	UILib.applyHudScale(sg)

	-- Built before the slots so their hover handlers always have a label to raise.
	buildTip(sg)

	makeSlot(sg, "mother",  1, EDGE)
	makeSlot(sg, "eggs",    2, EDGE_EGG)
	makeSlot(sg, "leeches", 3, EDGE_LEECH)
	makeSlot(sg, "army",    4, EDGE_ARMY)

	-- A button appears the moment the player owns one of its group and goes away with
	-- the last of them. Polled rather than event-driven: units and eggs arrive and die
	-- through half a dozen different paths, and a quarter-second lag on a HUD button is
	-- invisible next to the cost of hooking all of them.
	local acc = POLL
	PerfProbe.onHeartbeat("QuickSelect", function(dt: number)
		acc += dt
		if acc < POLL then return end
		acc = 0
		local t = unitControllerRef and unitControllerRef.ownedTally()
		if not t then return end
		setShown(slots.mother,  t.cc,           1)
		setShown(slots.eggs,    t.eggs    > 0,  t.eggs)
		setShown(slots.leeches, t.leeches > 0,  t.leeches)
		setShown(slots.army,    t.army    > 0,  t.army)
	end)
end

return QuickSelect
