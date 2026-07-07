--[[
	MainMenu — the first screen the player sees.

	Deliberately sparse: a black screen with a mild colour glow rising from the
	bottom edge that slowly drifts through the hue wheel, and two "nodes" that
	float lazily around the middle, each forever easing toward a fresh nearby spot.

	  • BATTLE   → tears the menu down and hands off to onBattle() (the Map/AI lobby).
	  • TUTORIAL → not wired up yet; clicking it just flashes a "coming soon" hint.

	Everything is client-side and self-contained. A UIScale keeps the node sizes
	proportional across resolutions; node positions use scale coordinates so they
	stay centred on any screen.
]]

local Players      = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService   = game:GetService("RunService")

local MainMenu    = {}
local localPlayer = Players.LocalPlayer

-- Reference resolution for the UIScale (node sizes scale off this).
local DESIGN_W, DESIGN_H = 1280, 720

-- Float homes (scale coords) and how far each node wanders from home.
local WANDER_X = 0.06   -- ± fraction of screen width
local WANDER_Y = 0.07   -- ± fraction of screen height

-- Battle-lunge maw
local N_FANGS  = 16
local STING_ID = "rbxassetid://135417409504018"   -- shared with the F-key jumpscare

-- ── Small helpers ───────────────────────────────────────────────────────────
local function circle(inst: GuiObject)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(1, 0)
	c.Parent = inst
end

local function stroke(inst: GuiObject, color: Color3, thick: number): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thick
	s.Parent = inst
	return s
end

-- ── A floating node (Tutorial / Battle) ──────────────────────────────────────
local function makeNode(
	parent: Instance, text: string, accent: Color3, homeX: number, homeY: number
): (TextButton, Frame, UIScale)
	-- Soft outer glow (a larger, faint accent disc that breathes).
	local glow = Instance.new("Frame")
	glow.Name = text .. "Glow"
	glow.Size = UDim2.fromOffset(196, 196)
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = UDim2.new(0.5, 0, 0.5, 0)
	glow.BackgroundColor3 = accent
	glow.BackgroundTransparency = 0.82
	glow.BorderSizePixel = 0
	glow.ZIndex = 4
	circle(glow)

	local btn = Instance.new("TextButton")
	btn.Name = text .. "Node"
	btn.Size = UDim2.fromOffset(150, 150)
	btn.AnchorPoint = Vector2.new(0.5, 0.5)
	btn.Position = UDim2.new(homeX, 0, homeY, 0)
	btn.BackgroundColor3 = Color3.fromRGB(9, 11, 16)
	btn.BackgroundTransparency = 0.15
	btn.AutoButtonColor = false
	btn.Text = ""
	btn.ZIndex = 5
	btn.Parent = parent
	circle(btn)
	local ring = stroke(btn, accent, 2)
	ring.Transparency = 0.1

	-- Per-node UIScale keeps the orb proportional across resolutions. It lives INSIDE
	-- the button so it only scales the node (+ its glow/label), never the full-screen
	-- backdrop, and the button's own scale-based position stays screen-relative.
	local nodeScale = Instance.new("UIScale")
	nodeScale.Parent = btn

	-- Inner vertical sheen so the disc reads as a 3D orb, not a flat circle.
	local sheen = Instance.new("UIGradient")
	sheen.Rotation = 90
	sheen.Color = ColorSequence.new(Color3.fromRGB(40, 46, 60), Color3.fromRGB(6, 8, 12))
	sheen.Parent = btn

	-- The glow rides the button, so parent it to the button and centre it.
	glow.Parent = btn

	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(1, 0, 1, 0)
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.GothamBold
	lbl.TextSize = 20
	lbl.TextColor3 = accent
	lbl.Text = text
	lbl.TextYAlignment = Enum.TextYAlignment.Center
	lbl.ZIndex = 6
	lbl.Parent = btn

	-- Hover: swell slightly and brighten the ring.
	btn.MouseEnter:Connect(function()
		TweenService:Create(btn, TweenInfo.new(0.16), { Size = UDim2.fromOffset(166, 166) }):Play()
		TweenService:Create(ring, TweenInfo.new(0.16), { Transparency = 0, Thickness = 3 }):Play()
	end)
	btn.MouseLeave:Connect(function()
		TweenService:Create(btn, TweenInfo.new(0.16), { Size = UDim2.fromOffset(150, 150) }):Play()
		TweenService:Create(ring, TweenInfo.new(0.16), { Transparency = 0.1, Thickness = 2 }):Play()
	end)

	return btn, glow, nodeScale
end

-- Forever ease the node from its current spot to a fresh one near its home.
local function driftNode(btn: TextButton, homeX: number, homeY: number)
	local function step()
		if not btn.Parent then return end
		local ox = (math.random() - 0.5) * 2 * WANDER_X
		local oy = (math.random() - 0.5) * 2 * WANDER_Y
		local dur = 4.5 + math.random() * 3
		local tw = TweenService:Create(btn,
			TweenInfo.new(dur, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
			{ Position = UDim2.new(homeX + ox, 0, homeY + oy, 0) })
		tw.Completed:Connect(step)   -- each tween is fresh → one connection apiece
		tw:Play()
	end
	step()
end

-- Gentle breathing pulse on a node's outer glow (independent of hover/drift).
local function breathe(glow: Frame)
	TweenService:Create(glow,
		TweenInfo.new(2.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ BackgroundTransparency = 0.6, Size = UDim2.fromOffset(214, 214) }
	):Play()
end

-- A lamprey-style maw for the Battle lunge: a near-black throat with a blood-red
-- gullet, ringed by white fangs, centred at `atPos`. Its UIScale (returned) is
-- driven up to hurl the mouth at the screen. `fangs` is returned so the ring can
-- be popped into existence a beat before the lunge. Inspired by the F-key jumpscare.
local function spawnMaw(parent: Instance, atPos: UDim2, sizePx: number): (Frame, UIScale, Frame)
	local maw = Instance.new("Frame")
	maw.Name = "BattleMaw"
	maw.AnchorPoint = Vector2.new(0.5, 0.5)
	maw.Position = atPos
	maw.Size = UDim2.fromOffset(sizePx, sizePx)
	maw.BackgroundTransparency = 1
	maw.ZIndex = 8
	maw.Parent = parent
	local scale = Instance.new("UIScale")
	scale.Parent = maw

	-- Throat: near-black disc that swallows the view as it grows.
	local throat = Instance.new("Frame")
	throat.AnchorPoint = Vector2.new(0.5, 0.5)
	throat.Position = UDim2.fromScale(0.5, 0.5)
	throat.Size = UDim2.fromScale(1, 1)
	throat.BackgroundColor3 = Color3.fromRGB(6, 3, 5)
	throat.BorderSizePixel = 0
	throat.ZIndex = 8
	throat.Parent = maw
	circle(throat)

	-- Gullet: a blood-red core glowing at the centre of the throat.
	local gullet = Instance.new("Frame")
	gullet.AnchorPoint = Vector2.new(0.5, 0.5)
	gullet.Position = UDim2.fromScale(0.5, 0.5)
	gullet.Size = UDim2.fromScale(0.55, 0.55)
	gullet.BackgroundColor3 = Color3.fromRGB(122, 16, 20)
	gullet.BorderSizePixel = 0
	gullet.ZIndex = 9
	gullet.Parent = throat
	circle(gullet)
	local gg = Instance.new("UIGradient")
	gg.Rotation = 90
	gg.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(1, 0.85),
	})
	gg.Parent = gullet

	-- Fang ring: white teeth bristling around the rim (radially, tapered to a tip).
	local fangs = Instance.new("Frame")
	fangs.Name = "Fangs"
	fangs.AnchorPoint = Vector2.new(0.5, 0.5)
	fangs.Position = UDim2.fromScale(0.5, 0.5)
	fangs.Size = UDim2.fromScale(1, 1)
	fangs.BackgroundTransparency = 1
	fangs.ZIndex = 10
	fangs.Parent = maw
	local half = sizePx / 2
	local R = half * 0.92
	for k = 1, N_FANGS do
		local a = (k - 0.5) / N_FANGS * math.pi * 2
		local tooth = Instance.new("Frame")
		tooth.AnchorPoint = Vector2.new(0.5, 0)                    -- pivot at the rim base
		tooth.Position = UDim2.fromOffset(half + math.cos(a) * R, half + math.sin(a) * R)
		tooth.Size = UDim2.fromOffset(sizePx * 0.1, sizePx * 0.24)
		tooth.Rotation = math.deg(a) + 90                          -- run radially off the rim
		tooth.BackgroundColor3 = Color3.fromRGB(232, 230, 214)
		tooth.BorderSizePixel = 0
		tooth.ZIndex = 10
		tooth.Parent = fangs
		local tc = Instance.new("UICorner")
		tc.CornerRadius = UDim.new(0.5, 0)                          -- rounded fang tip
		tc.Parent = tooth
		local tg = Instance.new("UIGradient")
		tg.Rotation = 90
		tg.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(1, 0.3),                    -- fade toward the point
		})
		tg.Parent = tooth
	end

	return maw, scale, fangs
end

-- ── Public init ───────────────────────────────────────────────────────────────
function MainMenu.init(onBattle: () -> ())
	local sg = Instance.new("ScreenGui")
	sg.Name = "MainMenu"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 120   -- above the lobby (100) so it sits in front until dismissed
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = localPlayer:WaitForChild("PlayerGui")

	-- Black backdrop.
	local bg = Instance.new("Frame")
	bg.Name = "Backdrop"
	bg.Size = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	bg.BorderSizePixel = 0
	bg.ZIndex = 1
	bg.Parent = sg

	-- Mild colour glow rising from the bottom edge. Its colour cycles slowly; the
	-- gradient fades it out toward the top so it reads as a soft ground haze.
	local glow = Instance.new("Frame")
	glow.Name = "BottomGlow"
	glow.AnchorPoint = Vector2.new(0.5, 1)
	glow.Position = UDim2.new(0.5, 0, 1, 0)
	glow.Size = UDim2.new(1, 0, 0.62, 0)
	glow.BackgroundColor3 = Color3.fromHSV(0.58, 0.5, 0.5)
	glow.BorderSizePixel = 0
	glow.ZIndex = 2
	glow.Parent = bg
	local glowGrad = Instance.new("UIGradient")
	glowGrad.Rotation = 90   -- runs top → bottom
	glowGrad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.0),    -- fully faded at the top
		NumberSequenceKeypoint.new(0.7, 0.78),
		NumberSequenceKeypoint.new(1, 0.42),   -- mild at the very bottom
	})
	glowGrad.Parent = glow

	-- Faint wordmark up top so the empty screen still feels like "somewhere".
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.new(0.5, 0, 0.16, 0)
	title.Size = UDim2.fromOffset(600, 70)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBlack
	title.TextSize = 56
	title.TextColor3 = Color3.fromRGB(228, 232, 240)
	title.TextTransparency = 0.35
	title.Text = "LUCENT"
	title.ZIndex = 3
	title.Parent = bg
	local titleStroke = stroke(title, Color3.fromRGB(120, 224, 255), 1)
	titleStroke.Transparency = 0.8

	-- Two floating nodes near the middle: Tutorial (left) and Battle (right).
	local C_TUT   = Color3.fromRGB(150, 165, 190)   -- muted (not wired up yet)
	local C_BATTLE = Color3.fromRGB(232, 196, 120)  -- inviting gold
	local tutBtn,    tutGlow,    tutScale    = makeNode(bg, "TUTORIAL", C_TUT,    0.37, 0.54)
	local battleBtn, battleGlow, battleScale = makeNode(bg, "BATTLE",   C_BATTLE, 0.63, 0.54)

	-- Keep the nodes proportional to the viewport (the backdrop stays full-screen).
	local function rescale()
		local cam = workspace.CurrentCamera
		if not cam then return end
		local vp = cam.ViewportSize
		if vp.X == 0 or vp.Y == 0 then return end
		local s = math.min(vp.X / DESIGN_W, vp.Y / DESIGN_H)
		tutScale.Scale = s
		battleScale.Scale = s
	end
	rescale()
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)

	driftNode(tutBtn, 0.37, 0.54)
	driftNode(battleBtn, 0.63, 0.54)
	breathe(tutGlow)
	breathe(battleGlow)

	-- "coming soon" hint that flashes when Tutorial is clicked.
	local hint = Instance.new("TextLabel")
	hint.Name = "TutorialHint"
	hint.AnchorPoint = Vector2.new(0.5, 0)
	hint.Position = UDim2.new(0.37, 0, 0.7, 0)
	hint.Size = UDim2.fromOffset(240, 24)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.GothamMedium
	hint.TextSize = 15
	hint.TextColor3 = C_TUT
	hint.TextTransparency = 1
	hint.Text = "Coming soon"
	hint.ZIndex = 6
	hint.Parent = bg

	-- Slow hue cycle on the bottom glow.
	local hue = 0.58
	local cycleConn: RBXScriptConnection
	cycleConn = RunService.RenderStepped:Connect(function(dt)
		hue = (hue + dt * 0.02) % 1   -- ~50s per full loop
		glow.BackgroundColor3 = Color3.fromHSV(hue, 0.5, 0.5)
	end)

	-- Present the menu behind a fresh scriptable camera so nothing from the
	-- default view bleeds through before the player picks a node.
	task.spawn(function()
		local cam = workspace.CurrentCamera
		if cam then
			cam.CameraType = Enum.CameraType.Scriptable
			cam.CFrame = CFrame.lookAt(Vector3.new(0, 60, 40), Vector3.new(0, 0, 0))
		end
	end)

	-- ── Wiring ──────────────────────────────────────────────────────────────
	local dismissed = false

	-- Dissolve the whole menu away, revealing the map lobby that sits behind it.
	local function fadeMenu(dur: number)
		local fade = TweenInfo.new(dur, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		pcall(function() TweenService:Create(bg, fade, { BackgroundTransparency = 1 }):Play() end)
		for _, d in bg:GetDescendants() do
			if d:IsA("Frame") then
				pcall(function() TweenService:Create(d, fade, { BackgroundTransparency = 1 }):Play() end)
			elseif d:IsA("TextLabel") or d:IsA("TextButton") then
				pcall(function() TweenService:Create(d, fade, { BackgroundTransparency = 1, TextTransparency = 1 }):Play() end)
			end
			if d:IsA("UIStroke") then
				pcall(function() TweenService:Create(d, fade, { Transparency = 1 }):Play() end)
			end
		end
	end

	local function teardown()
		if cycleConn then cycleConn:Disconnect() end
		sg:Destroy()
	end

	tutBtn.MouseButton1Click:Connect(function()
		if dismissed then return end
		-- Not implemented yet: flash the hint and give the node a tiny nudge.
		hint.TextTransparency = 1
		TweenService:Create(hint, TweenInfo.new(0.2), { TextTransparency = 0 }):Play()
		task.delay(1.1, function()
			TweenService:Create(hint, TweenInfo.new(0.5), { TextTransparency = 1 }):Play()
		end)
	end)

	battleBtn.MouseButton1Click:Connect(function()
		if dismissed then return end
		dismissed = true

		-- Build the lobby now so it's sitting ready behind the overlay to be revealed.
		onBattle()

		local nodePos = battleBtn.Position
		battleBtn.Visible = false
		tutBtn.Visible    = false

		-- 1-in-10: the node erupts into a lamprey maw that lunges at the screen.
		-- The other 9 times it's just a clean dissolve into the map lobby.
		if math.random(1, 10) ~= 1 then
			fadeMenu(0.45)
			task.delay(0.5, teardown)
			return
		end

		-- The maw takes the Battle node's place: sprout a fang ring where Battle was,
		-- then hurl it into the screen and dissolve to the lobby.
		local maw, mawScale, fangs = spawnMaw(bg, nodePos, 150)

		-- Fangs snap into being around the node with a little overshoot.
		local fangsScale = Instance.new("UIScale")
		fangsScale.Scale = 0
		fangsScale.Parent = fangs
		TweenService:Create(fangsScale,
			TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = 1 }):Play()

		local sting = Instance.new("Sound")
		sting.SoundId = STING_ID
		sting.Volume  = 0.75
		sting.Parent  = sg

		-- After the teeth form, hurl the maw at the lens (accelerating scale + drift to
		-- centre + shake). Past the peak, the whole menu fades out over the reveal.
		task.delay(0.2, function()
			sting:Play()
			local LUNGE = 0.5
			local el, faded = 0.0, false
			local sx, sy = nodePos.X.Scale, nodePos.Y.Scale
			local conn: RBXScriptConnection
			conn = RunService.RenderStepped:Connect(function(dt)
				el += dt
				local t = math.clamp(el / LUNGE, 0, 1)
				mawScale.Scale = 1 + 27 * (t * t)                  -- accelerating swallow
				local jit = 0.008 * t
				maw.Position = UDim2.new(
					sx + (0.5 - sx) * t + (math.random() - 0.5) * jit, 0,
					sy + (0.5 - sy) * t + (math.random() - 0.5) * jit, 0)

				-- Cross-fade the menu away past the peak → the map lobby shows through.
				if t > 0.62 and not faded then
					faded = true
					fadeMenu(0.32)
				end

				if t >= 1 then
					conn:Disconnect()
					task.delay(0.34, teardown)   -- teardown also stops the sting
				end
			end)
		end)
	end)
end

return MainMenu
