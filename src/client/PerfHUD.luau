-- PerfHUD.luau
-- The readout that settles where the frame is going. Press F3.
--
-- Three numbers decide everything, and they are the first three lines:
--
--   FRAME    what a frame actually costs, and the fps that implies.
--   SCRIPTS  what every instrumented per-frame system spends, added up.
--   ENGINE   frame minus scripts. Rendering, physics, replication, scheduler.
--
-- If SCRIPTS is the big one, the list underneath names the culprit outright: it is sorted
-- by cost and every per-frame system in the game is in it. If ENGINE is the big one then
-- no amount of Lua tuning will help, and the counters below it say which part of the
-- engine to look at -- PARTS and MOVING for the renderer and the physics broadphase, NET
-- for replication, SERVER for a server that is falling behind and dragging the client
-- with it.
--
-- Take the reading twice: once with a handful of units, once with the army that hurts.
-- The system whose ms grew with the unit count is the one that scales, and that is the
-- one worth fixing. F4 prints the same table to the developer console (F9), which is the
-- thing to copy out and hand over.
--!strict

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local Stats             = game:GetService("Stats")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared     = ReplicatedStorage:WaitForChild("Shared")
local PerfProbe  = require(Shared:WaitForChild("PerfProbe"))

local PerfHUD = {}

local gui:   ScreenGui?  = nil
local label: TextLabel?  = nil
local shown  = false
local started = false

-- Whatever the server last told us about its own frame, if anything is reporting.
local serverMs    = 0
local serverRows: { PerfProbe.Row } = {}
local serverStamp = 0

-- ── Engine counters ─────────────────────────────────────────────────────────
-- Read through pcall: these are long-lived but deprecated-adjacent properties, and a
-- diagnostic overlay must never be the thing that breaks the game.
local function stat(name: string): number?
	local ok, v = pcall(function() return (Stats :: any)[name] end)
	if ok and type(v) == "number" then return v end
	return nil
end

local function num(v: number?, fmt: string): string
	return if v then string.format(fmt, v) else "--"
end

local function countUnits(): (number, number)
	local mine, all = 0, 0
	local folder = workspace:FindFirstChild("Units")
	local myStr  = tostring(Players.LocalPlayer.UserId)
	if folder then
		for _, c in folder:GetChildren() do
			if not c:IsA("BasePart") then continue end
			all += 1
			local ov = c:FindFirstChild("OwnerId") :: StringValue?
			if ov and ov.Value == myStr then mine += 1 end
		end
	end
	return mine, all
end

-- ── The readout ─────────────────────────────────────────────────────────────
local function compose(): string
	local rows, frameMs, fps = PerfProbe.snapshot()
	local lua    = PerfProbe.accounted()
	local engine = math.max(frameMs - lua, 0)
	local mine, all = countUnits()

	local out = {}
	out[#out + 1] = string.format("FRAME    %6.2f ms   %5.1f fps", frameMs, fps)
	out[#out + 1] = string.format("SCRIPTS  %6.2f ms   %4.0f%% of frame",
		lua, if frameMs > 0 then lua / frameMs * 100 else 0)
	out[#out + 1] = string.format("ENGINE   %6.2f ms   %4.0f%% of frame",
		engine, if frameMs > 0 then engine / frameMs * 100 else 0)
	out[#out + 1] = ""
	out[#out + 1] = string.format("UNITS    %d mine / %d total", mine, all)
	out[#out + 1] = string.format("PARTS    %s   moving %s",
		num(stat("PrimitivesCount"), "%d"), num(stat("MovingPrimitivesCount"), "%d"))
	out[#out + 1] = string.format("NET      in %s kbps   out %s kbps   phys in %s",
		num(stat("DataReceiveKbps"), "%.0f"), num(stat("DataSendKbps"), "%.0f"),
		num(stat("PhysicsReceiveKbps"), "%.0f"))
	if serverStamp > 0 and (os.clock() - serverStamp) < 3 then
		out[#out + 1] = string.format("SERVER   %6.2f ms per heartbeat", serverMs)
	else
		out[#out + 1] = "SERVER   (not reporting)"
	end
	out[#out + 1] = ""
	out[#out + 1] = "PER-SYSTEM, ms per frame"

	if #rows == 0 then
		out[#out + 1] = "  (sampling...)"
	end
	for i, r in rows do
		if i > 16 then break end
		local share = if frameMs > 0 then r.ms / frameMs * 100 else 0
		out[#out + 1] = string.format("  %-18s %6.2f  %3.0f%%", r.name, r.ms, share)
	end

	if #serverRows > 0 then
		out[#out + 1] = ""
		out[#out + 1] = "SERVER SYSTEMS, ms per heartbeat"
		for i, r in serverRows do
			if i > 8 then break end
			out[#out + 1] = string.format("  %-18s %6.2f", r.name, r.ms)
		end
	end

	return table.concat(out, "\n")
end

local function build()
	local sg          = Instance.new("ScreenGui")
	sg.Name           = "PerfHUD"
	sg.ResetOnSpawn   = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder   = 10000
	sg.Enabled        = false
	sg.Parent         = Players.LocalPlayer:WaitForChild("PlayerGui")

	local frame               = Instance.new("Frame")
	frame.Size                = UDim2.new(0, 380, 0, 470)
	frame.Position            = UDim2.new(0, 12, 0, 12)
	frame.BackgroundColor3    = Color3.fromRGB(8, 8, 12)
	frame.BackgroundTransparency = 0.15
	frame.BorderSizePixel     = 0
	frame.Parent              = sg

	local pad          = Instance.new("UIPadding")
	pad.PaddingTop     = UDim.new(0, 8)
	pad.PaddingLeft    = UDim.new(0, 10)
	pad.PaddingRight   = UDim.new(0, 10)
	pad.PaddingBottom  = UDim.new(0, 8)
	pad.Parent         = frame

	local txt                  = Instance.new("TextLabel")
	txt.Size                   = UDim2.new(1, 0, 1, 0)
	txt.BackgroundTransparency = 1
	txt.Font                   = Enum.Font.Code
	txt.TextSize               = 14
	txt.TextColor3             = Color3.fromRGB(180, 255, 200)
	txt.TextXAlignment         = Enum.TextXAlignment.Left
	txt.TextYAlignment         = Enum.TextYAlignment.Top
	txt.Text                   = ""
	txt.Parent                 = frame

	gui   = sg
	label = txt
end

-- ── Public ──────────────────────────────────────────────────────────────────
function PerfHUD.setShown(on: boolean)
	shown = on
	if gui then gui.Enabled = on end
	-- Sampling only runs while the overlay is up, so the instrumentation costs nothing
	-- in a normal session.
	PerfProbe.setSampling(on)
	if on then PerfProbe.reset() end
end

function PerfHUD.toggle()
	PerfHUD.setShown(not shown)
end

-- What F4 prints, and what to paste when someone asks where the frame went.
function PerfHUD.dump()
	local wasShown = shown
	if not wasShown then PerfHUD.setShown(true) end
	print("──── PerfHUD ────────────────────────────────")
	print(compose())
	print("─────────────────────────────────────────────")
	if not wasShown then
		-- Leave it running for a moment so a cold dump has a window to average over.
		task.delay(1.0, function()
			if not shown then return end
			print("──── PerfHUD (settled) ──────────────────────")
			print(compose())
			print("─────────────────────────────────────────────")
			PerfHUD.setShown(false)
		end)
	end
end

-- Called by the client bootstrap when the server reports its own frame.
function PerfHUD.setServerReport(ms: number, rows: { PerfProbe.Row }?)
	serverMs    = ms
	serverRows  = rows or {}
	serverStamp = os.clock()
end

function PerfHUD.init()
	if started then return end
	started = true
	build()

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		if input.KeyCode == Enum.KeyCode.F3 then
			PerfHUD.toggle()
		elseif input.KeyCode == Enum.KeyCode.F4 then
			PerfHUD.dump()
		end
	end)

	-- Heartbeat runs after every RenderStepped connection in the same frame, so rolling
	-- here closes a window over work that has actually finished.
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		PerfProbe.roll()
		if not shown then return end
		acc += dt
		if acc < 0.25 then return end
		acc = 0
		if label then label.Text = compose() end
	end)
end

return PerfHUD
