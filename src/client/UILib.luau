--[[
	UILib — Shared UI component library.
	Require this in any client panel to get consistent styling.
	Add new colour tokens or helpers here; every panel that requires UILib
	automatically picks up the changes.
]]

local UILib = {}

-- ── Palette ───────────────────────────────────────────────────────────────────
-- All colours used across every UI element live here.
-- Change a value once and every panel updates.

UILib.C = {
	-- Surfaces
	BG_PANEL  = Color3.fromRGB(10,  15,  28),   -- standard panel
	BG_HEADER = Color3.fromRGB(14,  22,  44),   -- title bar
	BG_CARD   = Color3.fromRGB(16,  22,  40),   -- card / button bg
	BG_LOCKED = Color3.fromRGB( 9,  10,  16),   -- locked / unavailable

	-- Borders & separators
	BORDER    = Color3.fromRGB(35,  75, 140),
	BORDER_LO = Color3.fromRGB(20,  30,  55),   -- dimmed border
	SEP       = Color3.fromRGB(22,  40,  75),   -- divider line

	-- Accent
	ACCENT    = Color3.fromRGB( 0, 210, 255),   -- primary cyan

	-- Building-type colours (used for accent bars & button tints)
	MINE     = Color3.fromRGB(200, 150,  20),
	BARRACKS = Color3.fromRGB( 50, 115, 225),
	TURRET   = Color3.fromRGB(215,  95,  20),
	WORKSHOP = Color3.fromRGB(135,  55, 230),
	TEAL     = Color3.fromRGB(  0, 190, 160),
	RED      = Color3.fromRGB(210,  50,  50),
	GREEN    = Color3.fromRGB( 40, 200,  80),
	GOLD     = Color3.fromRGB(255, 195,  45),

	-- Text
	TEXT    = Color3.fromRGB(220, 235, 255),
	SUBTEXT = Color3.fromRGB(115, 150, 195),
	DIM     = Color3.fromRGB( 55,  65,  90),

	-- Misc
	FILL_BG = Color3.fromRGB( 8,  12,  26),
	WHITE   = Color3.new(1, 1, 1),
}

-- ── Low-level helpers ─────────────────────────────────────────────────────────

function UILib.corner(parent: Instance, r: number?): UICorner
	local c       = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 8)
	c.Parent       = parent
	return c
end

function UILib.stroke(parent: Instance, color: Color3?, thick: number?): UIStroke
	local s              = Instance.new("UIStroke")
	s.Color              = color or UILib.C.BORDER
	s.Thickness          = thick or 1
	s.ApplyStrokeMode    = Enum.ApplyStrokeMode.Border
	s.Parent             = parent
	return s
end

function UILib.pad(parent: Instance, t: number, b: number?, l: number?, r: number?): UIPadding
	local p          = Instance.new("UIPadding")
	p.PaddingTop     = UDim.new(0, t)
	p.PaddingBottom  = UDim.new(0, b  or t)
	p.PaddingLeft    = UDim.new(0, l  or t)
	p.PaddingRight   = UDim.new(0, r  or l or t)
	p.Parent         = parent
	return p
end

-- ── Panel ─────────────────────────────────────────────────────────────────────

-- Creates a dark-glass panel frame with rounded corners and a border.
function UILib.panel(parent: Instance, size: UDim2, pos: UDim2, zIndex: number?): Frame
	local f                  = Instance.new("Frame")
	f.Name                   = "Panel"
	f.Size                   = size
	f.Position               = pos
	f.BackgroundColor3       = UILib.C.BG_PANEL
	f.BackgroundTransparency = 0.06
	f.BorderSizePixel        = 0
	f.ZIndex                 = zIndex or 10
	f.Parent                 = parent
	UILib.corner(f, 12)
	UILib.stroke(f, UILib.C.BORDER, 1.5)
	return f
end

-- ── Title bar ─────────────────────────────────────────────────────────────────

--[[
	Creates a 34px-tall header bar anchored to the top of `parent`.
	  • Shows `title` left-aligned.
	  • Draws a thin accent underline (coloured by `accentColor`).
	  • If `closeFn` is provided, adds a ✕ close button wired to it.
	Returns the bar Frame.
]]
function UILib.titleBar(
	parent:      Instance,
	title:       string,
	closeFn:     (() -> ())?,
	accentColor: Color3?
): Frame
	local C   = UILib.C
	local zi  = (parent :: Frame).ZIndex + 1

	local bar                  = Instance.new("Frame")
	bar.Name                   = "TitleBar"
	bar.Size                   = UDim2.new(1, 0, 0, 34)
	bar.BackgroundColor3       = C.BG_HEADER
	bar.BackgroundTransparency = 0
	bar.BorderSizePixel        = 0
	bar.ZIndex                 = zi
	bar.Parent                 = parent
	UILib.corner(bar, 10)

	-- Square-off the bottom corners of the title bar
	local sq            = Instance.new("Frame")
	sq.Size             = UDim2.new(1, 0, 0, 10)
	sq.Position         = UDim2.new(0, 0, 1, -10)
	sq.BackgroundColor3 = C.BG_HEADER
	sq.BorderSizePixel  = 0
	sq.ZIndex           = zi
	sq.Parent           = bar

	-- Accent underline
	local line                  = Instance.new("Frame")
	line.Name                   = "AccentLine"
	line.Size                   = UDim2.new(1, -16, 0, 2)
	line.Position               = UDim2.new(0, 8, 1, -2)
	line.BackgroundColor3       = accentColor or C.ACCENT
	line.BackgroundTransparency = 0.35
	line.BorderSizePixel        = 0
	line.ZIndex                 = zi + 1
	line.Parent                 = bar

	-- Title label
	local lbl                  = Instance.new("TextLabel")
	lbl.Name                   = "Title"
	lbl.Size                   = UDim2.new(1, closeFn and -44 or -16, 1, -2)
	lbl.Position               = UDim2.fromOffset(12, 0)
	lbl.BackgroundTransparency = 1
	lbl.TextColor3             = C.TEXT
	lbl.Font                   = Enum.Font.GothamBold
	lbl.TextSize               = 14
	lbl.TextXAlignment         = Enum.TextXAlignment.Left
	lbl.Text                   = title
	lbl.ZIndex                 = zi + 1
	lbl.Parent                 = bar

	-- Close button
	if closeFn then
		local x                  = Instance.new("TextButton")
		x.Name                   = "CloseBtn"
		x.Size                   = UDim2.fromOffset(26, 22)
		x.Position               = UDim2.new(1, -32, 0.5, -11)
		x.BackgroundColor3       = Color3.fromRGB(150, 28, 28)
		x.BackgroundTransparency = 0.15
		x.TextColor3             = C.TEXT
		x.Font                   = Enum.Font.GothamBold
		x.TextSize               = 12
		x.Text                   = "✕"
		x.AutoButtonColor        = true
		x.BorderSizePixel        = 0
		x.ZIndex                 = zi + 2
		x.Parent                 = bar
		UILib.corner(x, 5)
		x.MouseButton1Click:Connect(closeFn)
	end

	return bar
end

-- ── Action button ─────────────────────────────────────────────────────────────

--[[
	A styled TextButton intended for clickable actions (train, research, upgrade).
	Pass `multiLine = true` and set Text = "" to add your own child labels.
	Otherwise the button displays `text` with the standard font.
]]
function UILib.btn(
	parent:  Instance,
	text:    string,
	size:    UDim2,
	pos:     UDim2,
	color:   Color3?,
	zIndex:  number?
): TextButton
	local C                  = UILib.C
	local b                  = Instance.new("TextButton")
	b.Name                   = "Btn"
	b.Text                   = text
	b.Size                   = size
	b.Position               = pos
	b.BackgroundColor3       = color or C.BG_CARD
	b.BackgroundTransparency = 0
	b.TextColor3             = C.TEXT
	b.Font                   = Enum.Font.GothamBold
	b.TextSize               = 13
	b.AutoButtonColor        = true
	b.BorderSizePixel        = 0
	b.ZIndex                 = zIndex or 10
	b.Parent                 = parent
	UILib.corner(b, 8)
	UILib.stroke(b, C.BORDER, 1)
	return b
end

-- ── Text label ────────────────────────────────────────────────────────────────

type LabelOpts = {
	color:  Color3?,
	font:   Enum.Font?,
	size:   number?,
	align:  Enum.TextXAlignment?,
	wrap:   boolean?,
	bold:   boolean?,
	zIndex: number?,
}

function UILib.lbl(
	parent: Instance,
	text:   string,
	lsize:  UDim2,
	pos:    UDim2,
	opts:   LabelOpts?
): TextLabel
	local C   = UILib.C
	local o   = opts or {}
	local l   = Instance.new("TextLabel")
	l.Text              = text
	l.Size              = lsize
	l.Position          = pos
	l.BackgroundTransparency = 1
	l.TextColor3        = o.color  or C.TEXT
	l.Font              = o.font   or (o.bold and Enum.Font.GothamBold or Enum.Font.Gotham)
	l.TextSize          = o.size   or 12
	l.TextXAlignment    = o.align  or Enum.TextXAlignment.Left
	l.TextWrapped       = o.wrap   or false
	l.ZIndex            = o.zIndex or 10
	l.Parent            = parent
	return l
end

-- ── Progress bar ─────────────────────────────────────────────────────────────

--[[
	Returns { fill = Frame, track = Frame }.
	Update progress: `fill.Size = UDim2.new(t, 0, 1, 0)` where t ∈ [0, 1].
]]
function UILib.progressBar(
	parent:    Instance,
	size:      UDim2,
	pos:       UDim2,
	fillColor: Color3?,
	zIndex:    number?
): { fill: Frame, track: Frame }
	local C                  = UILib.C
	local zi                 = zIndex or 10

	local track                  = Instance.new("Frame")
	track.Name                   = "ProgressTrack"
	track.Size                   = size
	track.Position               = pos
	track.BackgroundColor3       = C.FILL_BG
	track.BackgroundTransparency = 0.15
	track.BorderSizePixel        = 0
	track.ZIndex                 = zi
	track.Parent                 = parent
	UILib.corner(track, 4)
	UILib.stroke(track, C.BORDER_LO, 1)

	local fill                   = Instance.new("Frame")
	fill.Name                    = "Fill"
	fill.Size                    = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3        = fillColor or C.ACCENT
	fill.BorderSizePixel         = 0
	fill.ZIndex                  = zi + 1
	fill.Parent                  = track
	UILib.corner(fill, 3)

	return { fill = fill, track = track }
end

-- ── Divider ───────────────────────────────────────────────────────────────────

function UILib.divider(parent: Instance, yOff: number, xPad: number?, zIndex: number?): Frame
	local xp                 = xPad or 10
	local d                  = Instance.new("Frame")
	d.Name                   = "Divider"
	d.Size                   = UDim2.new(1, -(xp * 2), 0, 1)
	d.Position               = UDim2.fromOffset(xp, yOff)
	d.BackgroundColor3       = UILib.C.SEP
	d.BackgroundTransparency = 0.25
	d.BorderSizePixel        = 0
	d.ZIndex                 = zIndex or 10
	d.Parent                 = parent
	return d
end

-- ── Radial node & connector line (shared by all radial menus) ─────────────────

UILib.NODE_D = 80  -- default node circle diameter

--[[
    Build a circular bubble node.
    Returns (wrapper: Frame, btn: TextButton).
    Wrapper AnchorPoint = (0.5, 0.5) — Position is the node centre.
    btn has a UIStroke as its first UIStroke child.
]]
function UILib.radialNode(
	parent:   Instance,
	label:    string,
	icon:     string,
	color:    Color3,
	position: UDim2,
	diameter: number?,
	zIndex:   number?
): (Frame, TextButton)
	local d     = diameter or UILib.NODE_D
	local zi    = zIndex   or 12
	local halfD = math.floor(d / 2)

	local wrapper                    = Instance.new("Frame")
	wrapper.Name                     = "RadialNode"
	wrapper.Size                     = UDim2.fromOffset(d, d + 40)
	wrapper.Position                 = position
	wrapper.AnchorPoint              = Vector2.new(0.5, 0.5)
	wrapper.BackgroundTransparency   = 1
	wrapper.BorderSizePixel          = 0
	wrapper.ZIndex                   = zi
	wrapper.Parent                   = parent

	local btn                        = Instance.new("TextButton")
	btn.Name                         = "NodeBtn"
	btn.Size                         = UDim2.fromOffset(d, d)
	btn.BackgroundColor3             = color
	btn.BackgroundTransparency       = 0.35
	btn.Text                         = icon
	btn.TextSize                     = math.max(20, math.floor(d * 0.40))
	btn.TextColor3                   = UILib.C.TEXT
	btn.TextStrokeTransparency       = 0.65
	btn.TextStrokeColor3             = Color3.new(0, 0, 0)
	btn.Font                         = Enum.Font.GothamBold
	btn.AutoButtonColor              = false
	btn.BorderSizePixel              = 0
	btn.ZIndex                       = zi + 1
	btn.Parent                       = wrapper
	UILib.corner(btn, halfD)
	UILib.stroke(btn, color, 2)

	local lbl                        = Instance.new("TextLabel")
	lbl.Name                         = "NodeLabel"
	lbl.Size                         = UDim2.fromOffset(d + 36, 38)
	lbl.Position                     = UDim2.fromOffset(-18, d + 2)
	lbl.BackgroundTransparency       = 1
	lbl.Text                         = label
	lbl.Font                         = Enum.Font.GothamBold
	lbl.TextSize                     = 13
	lbl.TextColor3                   = UILib.C.TEXT
	lbl.TextStrokeTransparency       = 0.6
	lbl.TextStrokeColor3             = Color3.new(0, 0, 0)
	lbl.TextXAlignment               = Enum.TextXAlignment.Center
	lbl.TextWrapped                  = true
	lbl.ZIndex                       = zi + 1
	lbl.Parent                       = wrapper

	return wrapper, btn
end

--[[
    Build a thin connector line from fromPos outward at angleDeg.
    Starts invisible (BackgroundTransparency = 1); fade in via TweenService.
    AnchorPoint = (0, 0.5) so the left edge is the origin.
]]
function UILib.connectorLine(
	parent:   Instance,
	fromPos:  UDim2,
	angleDeg: number,
	radius:   number?,
	zIndex:   number?
): Frame
	local r  = radius or 160
	local zi = zIndex or 11

	-- The wrapper that contains each node is (d + 40)px tall, centred at fromPos.
	-- The circle button occupies the top d px, so its centre sits 20px above the
	-- wrapper centre.  Shift the line origin up by 20 px so it starts from the
	-- circle centre rather than the mid-point of circle + label.
	local LABEL_HALF = 20

	local line                       = Instance.new("Frame")
	line.Name                        = "ConnectorLine"
	line.Size                        = UDim2.fromOffset(r, 2)
	line.Position                    = UDim2.new(
		fromPos.X.Scale,  fromPos.X.Offset,
		fromPos.Y.Scale,  fromPos.Y.Offset - LABEL_HALF
	)
	line.AnchorPoint                 = Vector2.new(0, 0.5)
	line.BackgroundColor3            = UILib.C.BORDER
	line.BackgroundTransparency      = 1
	line.BorderSizePixel             = 0
	line.Rotation                    = angleDeg
	line.ZIndex                      = zi
	line.Parent                      = parent

	return line
end

--[[
    Build a connector line between two node wrapper positions.

    fromPos / toPos are the UDim2 wrapper centres (AnchorPoint 0.5, 0.5).
    Each node's circle button sits 20 px above the wrapper centre, so both
    endpoints are shifted by -20 px on Y before computing the midpoint and angle.

    The line is placed at the midpoint with AnchorPoint (0.5, 0.5) and rotated
    with atan2 — this gives a pixel-perfect connection regardless of direction.
    Starts invisible (BackgroundTransparency = 1); caller fades it in.
]]
function UILib.connectorLineBetween(
	parent:  Instance,
	fromPos: UDim2,
	toPos:   UDim2,
	zIndex:  number?
): Frame
	local zi        = zIndex or 11
	local CIRC_OFF  = 20   -- circle centre is 20 px above the wrapper centre

	-- Circle-centre positions in offset-space.
	-- Both fromPos and toPos are assumed to share the same Scale (0.5, 0.5).
	local ax = fromPos.X.Offset
	local ay = fromPos.Y.Offset - CIRC_OFF
	local bx = toPos.X.Offset
	local by = toPos.Y.Offset - CIRC_OFF

	local dx     = bx - ax
	local dy     = by - ay
	local length = math.sqrt(dx * dx + dy * dy)
	local midX   = (ax + bx) * 0.5
	local midY   = (ay + by) * 0.5
	local angle  = math.deg(math.atan2(dy, dx))

	local line                  = Instance.new("Frame")
	line.Name                   = "ConnectorLine"
	line.Size                   = UDim2.fromOffset(length, 2)
	line.Position               = UDim2.new(fromPos.X.Scale, midX, fromPos.Y.Scale, midY)
	line.AnchorPoint            = Vector2.new(0.5, 0.5)
	line.BackgroundColor3       = UILib.C.BORDER
	line.BackgroundTransparency = 1
	line.BorderSizePixel        = 0
	line.Rotation               = angle
	line.ZIndex                 = zi
	line.Parent                 = parent

	return line
end

return UILib
