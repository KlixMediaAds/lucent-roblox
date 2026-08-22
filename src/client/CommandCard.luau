--!strict
--[[
	CommandCard — StarCraft-2-style command card (bottom-right).

	A single, logic-free grid surface. Panels push a "page" of slots into it;
	whichever owner last called show() owns the grid.

	Visual style: flat, dark, utilitarian — beveled square buttons with full-bleed
	icons, a small gold hotkey glyph, and a quiet border-highlight on hover. No
	decorative brackets / diamonds / glow.

	Layout:
	  • A square 3×3 grid panel sized to match the minimap. Pages may ask for fewer
	    columns (cols = 2 / 1) to get bigger tiles out of the same frame.
	  • A slim header bar above it with the selected structure's name.
	  • A floating info panel above the stack with the hovered slot's name/cost/desc.

	show()        — render a page of action slots.
	showMessage() — render a centered message (e.g. "Upgrades coming soon!").
]]

local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local UILib = require(script.Parent:WaitForChild("UILib"))
local PerfProbe = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("PerfProbe"))
local C     = UILib.C

local CommandCard = {}

-- ── Palette (flat SC2-style steel/blue-grey) ─────────────────────────────────────
local PANEL_BG   = Color3.fromRGB(13, 16, 23)
local TILE_BG    = Color3.fromRGB(24, 30, 40)
local TILE_BG_HI = Color3.fromRGB(48, 62, 84)    -- hover: a distinct, brighter steel
local BORDER     = Color3.fromRGB(56, 70, 92)
local BORDER_HI  = Color3.fromRGB(150, 184, 220)

-- Hover feel + success-press flash.
local HOVER_ICON  = 1.10                          -- icon zoom while hovered
local FLASH_FILL  = Color3.fromRGB(196, 231, 255) -- bright wash on a successful press
local FLASH_EDGE  = Color3.fromRGB(224, 242, 255) -- edge pulse on that press
local BORDER_RED = Color3.fromRGB(150, 72, 72)
local BEVEL_HI   = Color3.fromRGB(70, 86, 110)   -- top edge highlight
local BEVEL_LO   = Color3.fromRGB(8, 11, 16)      -- bottom edge shadow
local TXT        = Color3.fromRGB(214, 224, 238)
local TXT_DIM    = Color3.fromRGB(120, 134, 158)
local HOTKEY_COL = Color3.fromRGB(228, 198, 120)
-- Pool-paid abilities (the Mother's energy) price in her purple, so a pool cost is never
-- read as a resource cost.
local ENERGY_COL = Color3.fromRGB(196,  90, 255)

-- Cooldown palette: the shade's leading edge, the printed seconds, and the ring that
-- fires when the ability comes back up.
local CD_EDGE  = Color3.fromRGB(150, 196, 255)
local CD_TEXT  = Color3.fromRGB(226, 238, 255)
local CD_READY = Color3.fromRGB(190, 226, 255)

-- Monochrome palette for locked / unavailable options.
local MONO_BG   = Color3.fromRGB(18, 18, 20)
local MONO_LINE = Color3.fromRGB(64, 64, 70)
local MONO_TXT  = Color3.fromRGB(96, 96, 102)
local MONO_TINT = Color3.fromRGB(120, 122, 130)

-- ── Types ──────────────────────────────────────────────────────────────────────
export type Slot = {
	index:           number,
	name:            string,
	cost:            number?,
	-- Abilities paid for out of a pool rather than the wallet (the Mother's energy).
	-- Printed on the tooltip's price line beside any resource cost, in its own colour so
	-- the two are never mistaken for each other.
	energyCost:      number?,
	color:           Color3,
	enabled:         boolean?,
	locked:          boolean?,
	icon:            string?,
	-- Text printed across the face of the tile, under the icon. Only worth using on
	-- big tiles (cols = 1 or 2); a 40px tile has no room for words.
	label:           string?,
	viewportKey:     string?,
	viewportFactory: (() -> ViewportFrame)?,
	badge:           string?,
	progress:        number?,
	-- Ability cooldown. `cooldownUntil` is a workspace:GetServerTimeNow() timestamp (so it
	-- needs no per-frame pushing from the panel) and `cooldownTotal` its full length, which
	-- is what the sweep divides by. Set both, or neither. The card animates it from there
	-- and fires a ready-pulse on the tile the moment it lapses.
	cooldownUntil:   number?,
	cooldownTotal:   number?,
	desc:            string?,
	hotkey:          string?,
	onClick:         () -> (),
}

export type Page = {
	header: string?,
	slots:  { Slot },
	-- Number of columns to lay the tiles out in. Defaults to 3 (the classic small
	-- 3×3 grid). Pass 2 for the Hollowed race's larger 2×2 tiles — same grid frame,
	-- fewer/bigger tiles.
	cols:   number?,
}

-- ── Layout (square grid, sized to match the minimap) ─────────────────────────────
local COLS, ROWS = 3, 3
local SLOTS      = COLS * ROWS
local TILE       = 40
local GAP        = 6
local PAD        = 8

local GRID_W = COLS * TILE + (COLS - 1) * GAP   -- 132
local GRID_H = ROWS * TILE + (ROWS - 1) * GAP   -- 132

CommandCard.FRAME_W = GRID_W + PAD * 2          -- 148 (square, == minimap border)
CommandCard.FRAME_H = GRID_H + PAD * 2          -- 148
CommandCard.RIGHT_OFFSET  = 10
CommandCard.BOTTOM_OFFSET = 10

local HEADER_H = 26
local TIP_W    = 240

-- Tile geometry for a given column count. The grid frame is fixed (GRID_W×GRID_H);
-- the tile size is derived so `cols` columns exactly fill it with the standard GAP.
-- cols = 3 → 40px tiles (classic). cols = 2 → 63px tiles (Hollowed 2×2).
local function tilePxFor(cols: number): number
	return (GRID_W - (cols - 1) * GAP) / cols
end
local function tileGeom(index: number, cols: number): (number, number, number)
	local tilePx = tilePxFor(cols)
	local row = math.floor((index - 1) / cols)
	local col = (index - 1) % cols
	local x   = PAD + col * (tilePx + GAP)
	local y   = PAD + row * (tilePx + GAP)
	return tilePx, x, y
end

-- ── State ──────────────────────────────────────────────────────────────────────
local frame:      Frame?
local headerBar:  Frame?
local headerLbl:  TextLabel?
local msgLbl:     TextLabel?
local hint:       TextLabel?   -- camera/menu prompt shown when nothing selected
local vpStash:    Frame?
local currentOwner: string? = nil

-- Page shown when the grid falls empty (see CommandCard.setFallback).
local fallbackFn:     (() -> ())? = nil
local fallbackQueued              = false

local function queueFallback()
	if not fallbackFn or fallbackQueued then return end
	fallbackQueued = true
	task.defer(function()
		fallbackQueued = false
		if currentOwner == nil and fallbackFn then fallbackFn() end
	end)
end

-- The empty-grid prompt first teaches camera movement, then swaps to the menu hint once
-- the player has actually panned with WASD (a one-time, cross-faded transition).
local HINT_WASD  = "[WASD] to move camera"
local HINT_SPACE = "[Space] for menu"
local wasdUsed   = false

local vpCache: { [string]: ViewportFrame } = {}

type TipData = { name: string, cost: number?, energyCost: number?, desc: string,
	enabled: boolean, locked: boolean }

type Tile = {
	wrapper:  Frame,
	btn:      TextButton,
	stroke:   UIStroke,
	holder:   Frame,
	iconScale: UIScale,
	flash:    Frame,
	hotkey:   TextLabel,
	badge:    TextLabel,
	label:    TextLabel,
	track:    Frame,
	fill:     Frame,
	cdScrim:  Frame,
	cdEdge:   Frame,
	cdText:   TextLabel,
	cdRing:   Frame,
	cdRingStroke: UIStroke,
	cdUntil:  number?,
	cdTotal:  number?,
	cdActive: boolean,
	onClick:  (() -> ())?,
	tip:      TipData?,
	restColor: Color3,
	restBg:    Color3,
	locked:    boolean,
	enabled:   boolean,
}
local tiles: { Tile } = {}

-- ── Floating info tooltip refs ──────────────────────────────────────────────────
local tip:        Frame?
local tipName:    TextLabel?
local tipCostLbl: TextLabel?
local tipDesc:    TextLabel?
local hoveredIndex: number? = nil   -- slot currently under the cursor (live tooltip)

-- ── Tooltip ──────────────────────────────────────────────────────────────────────
local function showTip(data: TipData)
	if not (tip and tipName and tipCostLbl and tipDesc) then return end
	tipName.Text       = data.name
	tipName.TextColor3 = data.locked and TXT_DIM or TXT
	local price = {}
	if data.cost ~= nil then
		price[#price + 1] = "◆  " .. data.cost
	end
	if data.energyCost ~= nil then
		-- Coloured inline rather than given its own label: the price line is one row and
		-- an ability can carry both a wallet cost and a pool cost.
		local c = data.locked and TXT_DIM or ENERGY_COL
		price[#price + 1] = string.format('<font color="rgb(%d,%d,%d)">%d ENERGY</font>',
			math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5),
			data.energyCost)
	end
	if #price > 0 then
		tipCostLbl.Visible    = true
		tipCostLbl.Text       = table.concat(price, "   ")
		tipCostLbl.TextColor3 = data.locked and TXT_DIM or (data.enabled and HOTKEY_COL or C.RED)
	else
		tipCostLbl.Visible = false
	end
	tipDesc.Text = data.locked and "Requirement not met." or data.desc
	tip.Visible  = true
end

local function hideTip()
	if tip then tip.Visible = false end
end

-- ── Tile factory ────────────────────────────────────────────────────────────────
local TI = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Success-press flash timings.
local FLASH_BLOOM = TweenInfo.new(0.4,  Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FLASH_POP   = TweenInfo.new(0.34, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- Celebrate a successful press: a bright wash blooms over the tile and fades out, the
-- edge pulses, and the icon punches up. Because the cursor is still on the tile after a
-- click, the edge + icon settle back to the HOVER pose (not rest) so nothing flickers.
-- The bloom + icon-pop live outside applySlot's reset, so they survive a re-render the
-- purchase may trigger (e.g. resources dropping).
local function flashTile(tile: Tile)
	local ov = tile.flash
	ov.BackgroundTransparency = 0.1
	ov.Visible                = true
	local bloom = TweenService:Create(ov, FLASH_BLOOM, { BackgroundTransparency = 1 })
	bloom.Completed:Once(function() ov.Visible = false end)
	bloom:Play()

	tile.stroke.Color     = FLASH_EDGE
	tile.stroke.Thickness = 3
	TweenService:Create(tile.stroke, FLASH_BLOOM, { Color = BORDER_HI, Thickness = 2 }):Play()

	tile.iconScale.Scale = 1.28
	TweenService:Create(tile.iconScale, FLASH_POP, { Scale = HOVER_ICON }):Play()
end

-- The ability came back up. A wash over the tile, an edge snap, an icon punch and a ring
-- thrown outward: the same vocabulary as a successful press, so "ready again" reads as a
-- small reward rather than the mere absence of a shade.
local CD_RING_OUT = TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function readyPulse(tile: Tile)
	flashTile(tile)

	local ring   = tile.cdRing
	local stroke = tile.cdRingStroke
	ring.Size          = UDim2.fromScale(1, 1)
	ring.Visible       = true
	stroke.Color       = CD_READY
	stroke.Thickness   = 2
	stroke.Transparency = 0.05

	TweenService:Create(ring,   CD_RING_OUT, { Size = UDim2.fromScale(1.42, 1.42) }):Play()
	local fade = TweenService:Create(stroke, CD_RING_OUT, { Transparency = 1, Thickness = 0.5 })
	fade.Completed:Once(function() ring.Visible = false end)
	fade:Play()
end

-- Drives every tile carrying a live cooldown. Runs off the shared server clock, so the
-- panel sets the window once and never has to re-render for the countdown.
local function stepCooldowns()
	local now = workspace:GetServerTimeNow()
	for _, tile in tiles do
		local untilT = tile.cdUntil
		if untilT == nil then continue end

		local left = untilT - now
		if left <= 0 then
			tile.cdUntil        = nil
			tile.cdScrim.Visible = false
			tile.cdText.Visible  = false
			if tile.cdActive then
				tile.cdActive = false
				readyPulse(tile)
			end
		else
			tile.cdActive        = true
			local total          = tile.cdTotal or left
			tile.cdScrim.Size    = UDim2.fromScale(1, math.clamp(left / math.max(total, 0.001), 0, 1))
			tile.cdScrim.Visible = true
			tile.cdText.Visible  = true
			-- Whole seconds while there is time to read them, tenths in the last second so
			-- the number is visibly moving as it lands.
			tile.cdText.Text = left >= 1 and tostring(math.ceil(left)) or string.format("%.1f", left)
		end
	end
end

PerfProbe.onRender("CommandCard", stepCooldowns)

local function makeTile(parent: Instance, index: number): Tile
	local row = math.floor((index - 1) / COLS)
	local col = (index - 1) % COLS
	local x   = PAD + col * (TILE + GAP)
	local y   = PAD + row * (TILE + GAP)

	local wrapper                  = Instance.new("Frame")
	wrapper.Name                   = "Slot" .. index
	wrapper.Size                   = UDim2.fromOffset(TILE, TILE)
	wrapper.Position               = UDim2.fromOffset(x, y)
	wrapper.BackgroundTransparency = 1
	wrapper.ZIndex                 = 12
	wrapper.Visible                = false
	wrapper.Parent                 = parent

	local btn                      = Instance.new("TextButton")
	btn.Name                       = "Btn"
	btn.Size                       = UDim2.fromScale(1, 1)
	btn.BackgroundColor3           = TILE_BG
	btn.BackgroundTransparency     = 0.04
	btn.Text                       = ""
	btn.TextSize                   = 20
	btn.Font                       = Enum.Font.GothamBold
	btn.TextColor3                 = TXT
	btn.AutoButtonColor            = false
	btn.BorderSizePixel            = 0
	btn.ClipsDescendants           = true
	btn.ZIndex                     = 13
	btn.Parent                     = wrapper
	UILib.corner(btn, 3)
	local stroke = UILib.stroke(btn, BORDER, 1)

	-- Subtle bevel: faint lighter top edge + darker bottom edge.
	local bevelTop                 = Instance.new("Frame")
	bevelTop.Size                  = UDim2.new(1, 0, 0, 1)
	bevelTop.BackgroundColor3      = BEVEL_HI
	bevelTop.BackgroundTransparency = 0.4
	bevelTop.BorderSizePixel       = 0
	bevelTop.ZIndex                = 16
	bevelTop.Parent                = btn
	local bevelBot                 = Instance.new("Frame")
	bevelBot.Size                  = UDim2.new(1, 0, 0, 1)
	bevelBot.Position              = UDim2.new(0, 0, 1, -1)
	bevelBot.BackgroundColor3      = BEVEL_LO
	bevelBot.BackgroundTransparency = 0.2
	bevelBot.BorderSizePixel       = 0
	bevelBot.ZIndex                = 16
	bevelBot.Parent                = btn

	-- Icon holder (near full-bleed, small inset). Centre-anchored so its UIScale zooms
	-- the icon from the middle of the tile (btn clips the overflow).
	local holder                   = Instance.new("Frame")
	holder.Name                    = "IconHolder"
	holder.Size                    = UDim2.fromScale(1, 1)
	holder.Position                = UDim2.fromScale(0.5, 0.5)
	holder.AnchorPoint             = Vector2.new(0.5, 0.5)
	holder.BackgroundTransparency  = 1
	holder.ZIndex                  = 14
	holder.Parent                  = btn
	local iconScale                = Instance.new("UIScale")
	iconScale.Scale                = 1
	iconScale.Parent               = holder

	local hotkey                   = Instance.new("TextLabel")
	hotkey.Name                    = "Hotkey"
	hotkey.Size                    = UDim2.fromOffset(14, 12)
	hotkey.Position                = UDim2.fromOffset(3, 2)
	hotkey.BackgroundTransparency  = 1
	hotkey.Font                    = Enum.Font.GothamBold
	hotkey.TextSize                = 11
	hotkey.TextColor3              = HOTKEY_COL
	hotkey.TextXAlignment          = Enum.TextXAlignment.Left
	hotkey.TextStrokeTransparency  = 0.5
	hotkey.TextStrokeColor3        = Color3.new(0, 0, 0)
	hotkey.Text                    = ""
	hotkey.ZIndex                  = 18
	hotkey.Parent                  = btn

	local badge                    = Instance.new("TextLabel")
	badge.Name                     = "Badge"
	badge.Size                     = UDim2.fromOffset(28, 12)
	badge.Position                 = UDim2.new(1, -30, 0, 2)
	badge.BackgroundTransparency   = 1
	badge.Font                     = Enum.Font.GothamBold
	badge.TextSize                 = 11
	badge.TextColor3               = TXT
	badge.TextXAlignment           = Enum.TextXAlignment.Right
	badge.TextStrokeTransparency   = 0.5
	badge.TextStrokeColor3         = Color3.new(0, 0, 0)
	badge.Text                     = ""
	badge.ZIndex                   = 18
	badge.Parent                   = btn

	-- Face text for big tiles (e.g. the Mother's single full-grid INJECT button).
	local label                    = Instance.new("TextLabel")
	label.Name                     = "Label"
	label.Size                     = UDim2.new(1, -8, 0.22, 0)
	label.Position                 = UDim2.new(0, 4, 0.68, 0)
	label.BackgroundTransparency   = 1
	label.Font                     = Enum.Font.GothamBold
	label.TextSize                 = 16
	label.TextColor3               = TXT
	label.TextStrokeTransparency   = 0.6
	label.TextStrokeColor3         = Color3.new(0, 0, 0)
	label.Text                     = ""
	label.Visible                  = false
	label.ZIndex                   = 18
	label.Parent                   = btn

	local track                    = Instance.new("Frame")
	track.Name                     = "ProgTrack"
	track.Size                     = UDim2.new(1, -6, 0, 2)
	track.Position                 = UDim2.new(0.5, 0, 1, -3)
	track.AnchorPoint              = Vector2.new(0.5, 0)
	track.BackgroundColor3         = Color3.fromRGB(6, 8, 14)
	track.BackgroundTransparency   = 0.2
	track.BorderSizePixel          = 0
	track.Visible                  = false
	track.ZIndex                   = 17
	track.Parent                   = btn
	UILib.corner(track, 1)

	local fill                     = Instance.new("Frame")
	fill.Name                      = "Fill"
	fill.Size                      = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3          = Color3.fromRGB(70, 190, 90)
	fill.BorderSizePixel           = 0
	fill.ZIndex                    = 18
	fill.Parent                    = track
	UILib.corner(fill, 1)

	-- ── Cooldown layers ───────────────────────────────────────────────────────
	-- A dark shade covering the tile, whose height shrinks to nothing as the ability
	-- recharges: the art fills back in from the bottom, which is the read every RTS/MOBA
	-- player already has. A bright line rides the shade's lower edge so the wipe is
	-- legible even in the last second, and the seconds left are printed over the middle.
	local cdScrim                  = Instance.new("Frame")
	cdScrim.Name                   = "CDScrim"
	cdScrim.AnchorPoint            = Vector2.new(0, 0)
	cdScrim.Position               = UDim2.fromScale(0, 0)
	cdScrim.Size                   = UDim2.fromScale(1, 1)
	cdScrim.BackgroundColor3       = Color3.fromRGB(4, 6, 11)
	cdScrim.BackgroundTransparency = 0.32
	cdScrim.BorderSizePixel        = 0
	cdScrim.Visible                = false
	cdScrim.ZIndex                 = 20
	cdScrim.Parent                 = btn

	local cdEdge                   = Instance.new("Frame")
	cdEdge.Name                    = "CDEdge"
	cdEdge.AnchorPoint             = Vector2.new(0, 1)
	cdEdge.Position                = UDim2.fromScale(0, 1)
	cdEdge.Size                    = UDim2.new(1, 0, 0, 2)
	cdEdge.BackgroundColor3        = CD_EDGE
	cdEdge.BackgroundTransparency  = 0.15
	cdEdge.BorderSizePixel         = 0
	cdEdge.ZIndex                  = 21
	cdEdge.Parent                  = cdScrim

	local cdText                   = Instance.new("TextLabel")
	cdText.Name                    = "CDText"
	cdText.Size                    = UDim2.fromScale(1, 1)
	cdText.BackgroundTransparency  = 1
	cdText.Font                    = Enum.Font.GothamBlack
	cdText.TextColor3              = CD_TEXT
	cdText.TextStrokeTransparency  = 0.35
	cdText.TextStrokeColor3        = Color3.new(0, 0, 0)
	cdText.Text                    = ""
	cdText.Visible                 = false
	cdText.ZIndex                  = 22
	cdText.Parent                  = btn

	-- Ready-pulse ring: snaps to the tile's edge and expands outward as it fades, so the
	-- ability coming back up is caught in peripheral vision.
	local cdRing                   = Instance.new("Frame")
	cdRing.Name                    = "CDRing"
	cdRing.AnchorPoint             = Vector2.new(0.5, 0.5)
	cdRing.Position                = UDim2.fromScale(0.5, 0.5)
	cdRing.Size                    = UDim2.fromScale(1, 1)
	cdRing.BackgroundTransparency  = 1
	cdRing.BorderSizePixel         = 0
	cdRing.Visible                 = false
	cdRing.ZIndex                  = 22
	cdRing.Parent                  = wrapper   -- on the wrapper: it grows past the tile edge
	UILib.corner(cdRing, 4)
	local cdRingStroke             = UILib.stroke(cdRing, CD_READY, 2)

	-- Success-press bloom: a bright full-tile wash on top that fades out. Hidden at rest
	-- and non-interactive (plain Frame — doesn't steal the button's clicks).
	local flash                    = Instance.new("Frame")
	flash.Name                     = "Flash"
	flash.Size                     = UDim2.fromScale(1, 1)
	flash.BackgroundColor3         = FLASH_FILL
	flash.BackgroundTransparency   = 1
	flash.BorderSizePixel          = 0
	flash.Visible                  = false
	flash.ZIndex                   = 23   -- above the cooldown shade, so a pulse washes over it
	flash.Parent                   = btn
	UILib.corner(flash, 3)

	local tile: Tile = {
		wrapper = wrapper, btn = btn, stroke = stroke, holder = holder,
		iconScale = iconScale, flash = flash,
		hotkey = hotkey, badge = badge, label = label, track = track, fill = fill,
		cdScrim = cdScrim, cdEdge = cdEdge, cdText = cdText,
		cdRing = cdRing, cdRingStroke = cdRingStroke, cdActive = false,
		onClick = nil, tip = nil, restColor = BORDER, restBg = TILE_BG,
		locked = false, enabled = true,
	}

	btn.MouseButton1Click:Connect(function()
		if tile.onClick then tile.onClick() end
		-- A "successful" press = an affordable, unlocked option (the disabled/red state
		-- means unaffordable → the click just plays the error cue, no celebratory flash).
		if tile.enabled and not tile.locked then flashTile(tile) end
	end)
	btn.MouseEnter:Connect(function()
		hoveredIndex = index
		if not tile.locked then
			TweenService:Create(btn,    TI, { BackgroundColor3 = TILE_BG_HI, BackgroundTransparency = 0 }):Play()
			TweenService:Create(stroke, TI, { Color = BORDER_HI, Thickness = 2 }):Play()
			TweenService:Create(iconScale, TI, { Scale = HOVER_ICON }):Play()
		end
		if tile.tip then showTip(tile.tip) end
	end)
	btn.MouseLeave:Connect(function()
		if hoveredIndex == index then hoveredIndex = nil end
		TweenService:Create(btn,    TI, { BackgroundColor3 = tile.restBg, BackgroundTransparency = tile.locked and 0.3 or 0.04 }):Play()
		TweenService:Create(stroke, TI, { Color = tile.restColor, Thickness = 1 }):Play()
		TweenService:Create(iconScale, TI, { Scale = 1 }):Play()
		hideTip()
	end)

	return tile
end

-- ── Rendering ─────────────────────────────────────────────────────────────────
local function setHolderViewport(tile: Tile, wantVp: ViewportFrame?)
	for _, ch in tile.holder:GetChildren() do
		if ch ~= wantVp and ch:IsA("ViewportFrame") then ch.Parent = vpStash end
	end
	if wantVp and wantVp.Parent ~= tile.holder then
		wantVp.Parent = tile.holder
	end
end

local function applySlot(tile: Tile, slot: Slot, cols: number)
	local locked  = slot.locked == true
	local enabled = slot.enabled ~= false

	-- Position + size this tile for the active column count (2 = big Hollowed tiles).
	local tilePx, x, y = tileGeom(slot.index, cols)
	tile.wrapper.Size     = UDim2.fromOffset(tilePx, tilePx)
	tile.wrapper.Position = UDim2.fromOffset(x, y)
	tile.wrapper.Visible  = true
	tile.locked  = locked
	tile.enabled = enabled

	local wantVp: ViewportFrame? = nil
	if slot.viewportKey and slot.viewportFactory then
		local vp = vpCache[slot.viewportKey]
		if not vp then
			vp = (slot.viewportFactory :: () -> ViewportFrame)()
			-- Scale-based so one cached viewport fits tiles of any column count.
			vp.Size                   = UDim2.fromScale(0.82, 0.82)
			vp.Position               = UDim2.fromScale(0.5, 0.5)
			vp.AnchorPoint            = Vector2.new(0.5, 0.5)
			vp.BackgroundTransparency = 1
			vpCache[slot.viewportKey] = vp
		end
		wantVp = vp
	end
	setHolderViewport(tile, wantVp)
	if wantVp then
		tile.btn.Text = ""
	else
		tile.btn.Text       = slot.icon or ""
		tile.btn.TextColor3 = locked and MONO_TXT or TXT
		-- Bigger glyphs on bigger tiles; a labelled tile leaves room for its words.
		tile.btn.TextSize   = math.floor(tilePx * (slot.label and 0.30 or 0.5))
	end

	tile.label.Visible    = slot.label ~= nil
	tile.label.Text       = slot.label or ""
	tile.label.TextSize   = math.clamp(math.floor(tilePx * 0.15), 11, 20)
	tile.label.TextColor3 = locked and MONO_TXT or TXT

	-- Border colour conveys state: locked = grey, unaffordable = red, else steel.
	local restColor = locked and MONO_LINE or (enabled and BORDER or BORDER_RED)
	local restBg    = locked and MONO_BG or TILE_BG
	tile.restColor        = restColor
	tile.restBg           = restBg
	-- If this tile is under the cursor, keep the hover pose across the re-render (a
	-- resource tick can re-render mid-hover) instead of snapping back to rest.
	local hovering = hoveredIndex == slot.index and not locked
	tile.stroke.Color     = hovering and BORDER_HI or restColor
	tile.stroke.Thickness = hovering and 2 or 1
	tile.btn.BackgroundColor3       = hovering and TILE_BG_HI or restBg
	tile.btn.BackgroundTransparency = hovering and 0 or (locked and 0.3 or 0.04)
	tile.iconScale.Scale            = hovering and HOVER_ICON or 1
	for _, ch in tile.holder:GetChildren() do
		if ch:IsA("ViewportFrame") then
			ch.ImageColor3       = locked and MONO_TINT or Color3.fromRGB(255, 255, 255)
			ch.ImageTransparency = locked and 0.1 or 0
		end
	end

	tile.badge.Text       = slot.badge or ""
	tile.badge.TextColor3  = locked and MONO_TXT or TXT
	tile.hotkey.Text      = slot.hotkey or ""
	tile.hotkey.TextColor3 = locked and MONO_TXT or HOTKEY_COL

	-- Cooldown window. Adopting it here (rather than each frame) keeps the countdown off
	-- the re-render path: the panel names the window once and stepCooldowns runs it out.
	-- cdActive is only ever cleared by stepCooldowns, so the ready-pulse still fires on a
	-- tile that was re-rendered mid-cooldown.
	tile.cdUntil = slot.cooldownUntil
	tile.cdTotal = slot.cooldownTotal
	if slot.cooldownUntil == nil then
		tile.cdActive        = false
		tile.cdScrim.Visible = false
		tile.cdText.Visible  = false
	else
		tile.cdText.TextSize = math.floor(tilePx * 0.34)
	end

	if slot.progress ~= nil then
		tile.track.Visible = true
		tile.fill.Size     = UDim2.new(math.clamp(slot.progress, 0, 1), 0, 1, 0)
	else
		tile.track.Visible = false
	end

	tile.onClick = function()
		if locked then return end
		slot.onClick()
	end
	tile.tip = {
		name = slot.name, cost = slot.cost, energyCost = slot.energyCost,
		desc = slot.desc or "",
		enabled = enabled, locked = locked,
	}
end

-- Drop a tile's cooldown outright. Tiles are pooled and reused by whatever page opens
-- next, so a hidden one must not keep counting down someone else's ability -- or fire a
-- ready-pulse on a page nobody is looking at.
local function clearTileCooldown(t: Tile)
	t.cdUntil            = nil
	t.cdTotal            = nil
	t.cdActive           = false
	t.cdScrim.Visible    = false
	t.cdText.Visible     = false
	t.cdRing.Visible     = false
end

local function hideAllTiles()
	for i = 1, SLOTS do
		local t = tiles[i]
		t.wrapper.Visible = false
		t.onClick = nil
		t.tip = nil
		clearTileCooldown(t)
		setHolderViewport(t, nil)
	end
end

local function setHeader(text: string)
	if headerLbl then headerLbl.Text = text end
	if headerBar then headerBar.Visible = text ~= "" end
end

-- ── Public API ────────────────────────────────────────────────────────────────
function CommandCard.init(sg: ScreenGui)
	if frame then return end

	-- Own inset-ignoring ScreenGui carrying the SAME shared HUD scale as the minimap,
	-- so the command grid stays the same size as the minimap at every resolution and
	-- the whole bottom cluster scales together.
	local own               = Instance.new("ScreenGui")
	own.Name                = "RTSCommandCard"
	own.ResetOnSpawn        = false
	own.IgnoreGuiInset      = true
	own.DisplayOrder        = 3
	own.ZIndexBehavior      = Enum.ZIndexBehavior.Sibling
	own.Parent              = sg.Parent
	UILib.applyHudScale(own)

	local stash             = Instance.new("Frame")
	stash.Name              = "VpStash"
	stash.Size              = UDim2.fromOffset(1, 1)
	stash.Visible           = false
	stash.Parent            = own
	vpStash = stash

	-- ── Square grid panel ─────────────────────────────────────────────────────
	local f                        = Instance.new("Frame")
	f.Name                         = "CommandCard"
	f.Size                         = UDim2.fromOffset(CommandCard.FRAME_W, CommandCard.FRAME_H)
	f.AnchorPoint                  = Vector2.new(1, 1)
	f.Position                     = UDim2.new(1, -CommandCard.RIGHT_OFFSET, 1, -CommandCard.BOTTOM_OFFSET)
	f.BackgroundColor3             = PANEL_BG
	f.BackgroundTransparency       = 0.04
	f.BorderSizePixel              = 0
	f.Visible                      = false
	f.ZIndex                       = 10
	f.Parent                       = own
	UILib.corner(f, 4)
	local fStroke                  = UILib.stroke(f, BORDER, 1)
	fStroke.Transparency           = 0.2
	frame = f

	-- Camera / menu prompt — occupies the grid spot whenever nothing is selected. Starts
	-- as the WASD camera hint, then cross-fades to the [Space] menu hint on first WASD use.
	local hl                       = Instance.new("TextLabel")
	hl.Name                        = "SpaceHint"
	hl.Size                        = UDim2.fromOffset(CommandCard.FRAME_W, CommandCard.FRAME_H)
	hl.AnchorPoint                 = Vector2.new(1, 1)
	hl.Position                    = UDim2.new(1, -CommandCard.RIGHT_OFFSET, 1, -CommandCard.BOTTOM_OFFSET)
	hl.BackgroundColor3            = PANEL_BG
	hl.BackgroundTransparency      = 0.55
	hl.BorderSizePixel             = 0
	hl.Font                        = Enum.Font.GothamBold
	hl.TextSize                    = 13
	hl.TextColor3                  = Color3.new(1, 1, 1)
	hl.TextStrokeTransparency      = 0.5
	hl.TextStrokeColor3            = Color3.new(0, 0, 0)
	hl.TextWrapped                 = true
	hl.Text                        = wasdUsed and HINT_SPACE or HINT_WASD
	hl.Visible                     = true
	hl.ZIndex                      = 9
	hl.Parent                      = own
	UILib.corner(hl, 4)
	local hlStroke                 = UILib.stroke(hl, BORDER, 1)
	hlStroke.Transparency          = 0.45
	hint = hl

	-- First WASD press: cross-fade the hint from the camera prompt to the menu prompt.
	local wasdConn: RBXScriptConnection? = nil
	wasdConn = UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe then return end
		local k = input.KeyCode
		if k ~= Enum.KeyCode.W and k ~= Enum.KeyCode.A
			and k ~= Enum.KeyCode.S and k ~= Enum.KeyCode.D then return end
		wasdUsed = true
		if wasdConn then wasdConn:Disconnect(); wasdConn = nil end
		if not hint then return end
		local fadeOut = TweenService:Create(hint,
			TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ TextTransparency = 1, TextStrokeTransparency = 1 })
		fadeOut.Completed:Connect(function()
			if not hint then return end
			hint.Text = HINT_SPACE
			TweenService:Create(hint,
				TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ TextTransparency = 0, TextStrokeTransparency = 0.5 }):Play()
		end)
		fadeOut:Play()
	end)

	-- Centered "coming soon" message (hidden unless showMessage is used)
	local mg                       = Instance.new("TextLabel")
	mg.Name                        = "Message"
	mg.Size                        = UDim2.new(1, -24, 1, -24)
	mg.Position                    = UDim2.fromScale(0.5, 0.5)
	mg.AnchorPoint                 = Vector2.new(0.5, 0.5)
	mg.BackgroundTransparency      = 1
	mg.Font                        = Enum.Font.GothamMedium
	mg.TextSize                    = 15
	mg.TextColor3                  = TXT_DIM
	mg.TextWrapped                 = true
	mg.Text                        = ""
	mg.Visible                     = false
	mg.ZIndex                      = 13
	mg.Parent                      = f
	msgLbl = mg

	for i = 1, SLOTS do
		tiles[i] = makeTile(f, i)
	end

	-- ── Slim header bar (above the grid) — structure name ─────────────────────
	local hb                       = Instance.new("Frame")
	hb.Name                        = "CommandHeader"
	hb.Size                        = UDim2.fromOffset(CommandCard.FRAME_W, HEADER_H)
	hb.AnchorPoint                 = Vector2.new(1, 1)
	hb.Position                    = UDim2.new(
		1, -CommandCard.RIGHT_OFFSET,
		1, -(CommandCard.BOTTOM_OFFSET + CommandCard.FRAME_H + 5))
	hb.BackgroundColor3            = PANEL_BG
	hb.BackgroundTransparency      = 0.04
	hb.BorderSizePixel             = 0
	hb.Visible                     = false
	hb.ZIndex                      = 10
	hb.Parent                      = own
	UILib.corner(hb, 4)
	local hbStroke                 = UILib.stroke(hb, BORDER, 1)
	hbStroke.Transparency          = 0.2
	headerBar = hb

	-- Thin left accent stripe (the only flash of colour — steel-blue)
	local hAcc                     = Instance.new("Frame")
	hAcc.Size                      = UDim2.fromOffset(3, HEADER_H - 10)
	hAcc.Position                  = UDim2.fromOffset(8, 5)
	hAcc.BackgroundColor3          = Color3.fromRGB(90, 140, 190)
	hAcc.BorderSizePixel           = 0
	hAcc.ZIndex                    = 12
	hAcc.Parent                    = hb
	UILib.corner(hAcc, 1)

	local hLbl                     = Instance.new("TextLabel")
	hLbl.Name                      = "Header"
	hLbl.Size                      = UDim2.new(1, -24, 1, 0)
	hLbl.Position                  = UDim2.fromOffset(18, 0)
	hLbl.BackgroundTransparency    = 1
	hLbl.Font                      = Enum.Font.GothamBold
	-- Rich text so a page can colour part of its header. The Mother's page uses it to
	-- print her energy pool in her own purple beside her name; every other header is a
	-- plain uppercase word and is unaffected.
	hLbl.RichText                  = true
	hLbl.TextScaled                = true
	hLbl.TextColor3                = TXT
	hLbl.TextXAlignment            = Enum.TextXAlignment.Left
	hLbl.TextYAlignment            = Enum.TextYAlignment.Center
	hLbl.Text                      = ""
	hLbl.ZIndex                    = 12
	hLbl.Parent                    = hb
	local hCon                     = Instance.new("UITextSizeConstraint")
	hCon.MaxTextSize               = 15
	hCon.MinTextSize               = 10
	hCon.Parent                    = hLbl
	headerLbl = hLbl

	-- ── Floating info tooltip (above the stack) ───────────────────────────────
	local tp                       = Instance.new("Frame")
	tp.Name                        = "CommandTip"
	tp.Size                        = UDim2.fromOffset(TIP_W, 100)
	tp.AnchorPoint                 = Vector2.new(1, 1)
	tp.Position                    = UDim2.new(
		1, -CommandCard.RIGHT_OFFSET,
		1, -(CommandCard.BOTTOM_OFFSET + CommandCard.FRAME_H + 5 + HEADER_H + 6))
	tp.BackgroundColor3            = PANEL_BG
	tp.BackgroundTransparency      = 0.03
	tp.BorderSizePixel             = 0
	tp.Visible                     = false
	tp.ZIndex                      = 14
	tp.Parent                      = own
	UILib.corner(tp, 4)
	local tpStroke                 = UILib.stroke(tp, BORDER, 1)
	tpStroke.Transparency          = 0.15

	local tName                    = Instance.new("TextLabel")
	tName.Size                     = UDim2.new(1, -24, 0, 22)
	tName.Position                 = UDim2.fromOffset(12, 11)
	tName.BackgroundTransparency   = 1
	tName.Font                     = Enum.Font.GothamBold
	tName.TextSize                 = 17
	tName.TextColor3               = TXT
	tName.TextXAlignment           = Enum.TextXAlignment.Left
	tName.Text                     = ""
	tName.ZIndex                   = 15
	tName.Parent                   = tp
	tipName = tName

	local tCost                    = Instance.new("TextLabel")
	tCost.Size                     = UDim2.new(1, -24, 0, 16)
	tCost.Position                 = UDim2.fromOffset(12, 34)
	tCost.BackgroundTransparency   = 1
	tCost.Font                     = Enum.Font.GothamBold
	tCost.TextSize                 = 14
	tCost.TextColor3               = HOTKEY_COL
	tCost.TextXAlignment           = Enum.TextXAlignment.Left
	tCost.Text                     = ""
	tCost.RichText                 = true   -- an energy price is coloured inline
	tCost.ZIndex                   = 15
	tCost.Parent                   = tp
	tipCostLbl = tCost

	local tSep                     = Instance.new("Frame")
	tSep.Size                      = UDim2.new(1, -24, 0, 1)
	tSep.Position                  = UDim2.fromOffset(12, 56)
	tSep.BackgroundColor3          = BORDER
	tSep.BackgroundTransparency    = 0.3
	tSep.BorderSizePixel           = 0
	tSep.ZIndex                    = 15
	tSep.Parent                    = tp

	local tDesc                    = Instance.new("TextLabel")
	tDesc.Size                     = UDim2.new(1, -24, 1, -68)
	tDesc.Position                 = UDim2.fromOffset(12, 64)
	tDesc.BackgroundTransparency   = 1
	tDesc.Font                     = Enum.Font.Gotham
	tDesc.TextSize                 = 12
	tDesc.TextColor3               = TXT_DIM
	tDesc.TextXAlignment           = Enum.TextXAlignment.Left
	tDesc.TextYAlignment           = Enum.TextYAlignment.Top
	tDesc.TextWrapped              = true
	tDesc.Text                     = ""
	tDesc.ZIndex                   = 15
	tDesc.Parent                   = tp
	tipDesc = tDesc

	tip = tp
end

local function renderPage(page: Page)
	if msgLbl then msgLbl.Visible = false end
	if hint then hint.Visible = false end
	setHeader(page.header or "")
	local cols = page.cols or COLS
	local used: { [number]: boolean } = {}
	for _, slot in page.slots do
		local i = slot.index
		if i >= 1 and i <= SLOTS then
			used[i] = true
			applySlot(tiles[i], slot, cols)
		end
	end
	for i = 1, SLOTS do
		if not used[i] then
			local t = tiles[i]
			t.wrapper.Visible = false
			t.onClick = nil
			t.tip = nil
			clearTileCooldown(t)
			setHolderViewport(t, nil)
		end
	end
	-- If a slot is currently hovered, refresh its (already-open) tooltip so its
	-- cost colour tracks the new affordability state live.
	local hv = hoveredIndex
	if hv and tiles[hv].wrapper.Visible and tiles[hv].tip then
		showTip(tiles[hv].tip :: TipData)
	end
	if frame then frame.Visible = true end
end

function CommandCard.show(ownerKey: string, page: Page)
	currentOwner = ownerKey
	renderPage(page)
end

function CommandCard.update(ownerKey: string, page: Page)
	if currentOwner ~= ownerKey then return end
	renderPage(page)
end

function CommandCard.showMessage(ownerKey: string, header: string, message: string)
	currentOwner = ownerKey
	hideAllTiles()
	hideTip()
	if hint then hint.Visible = false end
	setHeader(header)
	if msgLbl then
		msgLbl.Text    = message
		msgLbl.Visible = true
	end
	if frame then frame.Visible = true end
end

function CommandCard.hide(ownerKey: string)
	if currentOwner ~= ownerKey then return end
	currentOwner = nil
	hideTip()
	hideAllTiles()
	if msgLbl then msgLbl.Visible = false end
	if hint then hint.Visible = true end
	setHeader("")
	if frame then frame.Visible = false end
	queueFallback()
end

function CommandCard.isOwner(ownerKey: string): boolean
	return currentOwner == ownerKey
end

-- Fallback page. Panels release the grid all the time (a selection is dropped, another
-- panel takes over), and most of those releases are immediately followed by someone else
-- claiming it. The fallback runs one frame later, only if the grid is still unowned:
-- that's what keeps the Hollowed Mother's card up whenever nothing is selected.
function CommandCard.setFallback(fn: (() -> ())?)
	fallbackFn = fn
	queueFallback()
end

return CommandCard
