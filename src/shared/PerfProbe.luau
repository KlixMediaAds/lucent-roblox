-- PerfProbe.luau
-- Where the frame actually goes. Shared by both sides.
--
-- Guessing at performance is how you end up optimising the wrong thing three times in a
-- row. This is the instrument that ends the guessing: every per-frame system in the game
-- opens a probe around its work, and the probe adds up how many milliseconds of each
-- frame that system really spends. PerfHUD then shows the list, biggest first, next to
-- the frame time itself -- so the gap between "what Lua spent" and "what the frame cost"
-- is visible too, and that gap is the answer whenever the answer is not a script at all
-- (rendering, physics, or replication).
--
--   PerfProbe.open("LampreyBody")
--   ... the work ...
--   PerfProbe.shut()
--
-- Probes may nest; each one is charged only its own time, with any nested probe's time
-- subtracted, so the numbers add up to the total instead of double-counting.
--
-- Every call also emits a MicroProfiler label (debug.profilebegin/profileend), so the
-- same instrumentation shows up in a Ctrl+F6 capture with no extra work.
--
-- OFF by default and free when off: an open/shut pair with sampling disabled is two
-- branches and the profiler label, no clock reads and no table writes. PerfHUD turns
-- sampling on only while the overlay is up.
--!strict

local RunService = game:GetService("RunService")

local PerfProbe = {}

local sampling = false

-- Names in the order they were first seen, so the readout does not reshuffle itself.
local order: { string } = {}
local seen:  { [string]: boolean } = {}

local accum:  { [string]: number } = {}   -- seconds charged this window
local report: { [string]: number } = {}   -- ms per frame over the last closed window

-- Open probes: name, wall-clock start, and time already charged to children.
local stackName:  { string } = {}
local stackStart: { number } = {}
local stackChild: { number } = {}
local depth = 0

-- Window bookkeeping. A window is a fixed slice of wall time; dividing by the frames in
-- it gives "ms per frame", which is the only unit that can be compared with the budget.
local WINDOW      = 0.5
local windowStart = 0
local windowFrames = 0
local reportFrames = 0
local reportSpan   = 0

-- Frame timing, measured from the roll itself so it includes everything, script or not.
local lastRoll  = 0
local frameAccum = 0

function PerfProbe.setSampling(on: boolean)
	if sampling == on then return end
	sampling = on
	depth    = 0
	table.clear(accum)
	if on then
		windowStart  = os.clock()
		lastRoll     = windowStart
		windowFrames = 0
		frameAccum   = 0
	end
end

function PerfProbe.isSampling(): boolean
	return sampling
end

function PerfProbe.open(name: string)
	debug.profilebegin(name)
	if not sampling then return end
	depth += 1
	stackName[depth]  = name
	stackStart[depth] = os.clock()
	stackChild[depth] = 0
end

function PerfProbe.shut()
	debug.profileend()
	if not sampling or depth == 0 then return end
	local spent = os.clock() - stackStart[depth]
	local name  = stackName[depth]
	local own   = spent - stackChild[depth]
	depth -= 1
	if depth > 0 then
		-- Charged to the parent as a child, so the parent reports only its own work.
		stackChild[depth] += spent
	end
	if not seen[name] then
		seen[name] = true
		order[#order + 1] = name
	end
	accum[name] = (accum[name] or 0) + own
end

-- Called once per frame by whoever owns the sampler (PerfHUD on the client, the reporter
-- on the server). Closes the window when it is up and publishes the averages.
function PerfProbe.roll()
	if not sampling then return end
	local now = os.clock()
	frameAccum += now - lastRoll
	lastRoll = now
	windowFrames += 1

	-- Self-heal: a callback that errors out never reaches its shut(), which would leave
	-- the stack open and mis-charge everything after it. Probes never span a frame, so
	-- the roll is always allowed to assume nothing is open.
	depth = 0

	local span = now - windowStart
	if span < WINDOW then return end

	local frames = math.max(windowFrames, 1)
	table.clear(report)
	for _, name in order do
		local s = accum[name]
		if s and s > 0 then report[name] = (s / frames) * 1000 end
	end
	reportFrames = frames
	reportSpan   = span

	table.clear(accum)
	windowStart  = now
	windowFrames = 0
	frameAccum   = 0
end

export type Row = { name: string, ms: number }

-- The last closed window: every probe's ms per frame (biggest first), the measured frame
-- time, and the frames per second that implies.
function PerfProbe.snapshot(): ({ Row }, number, number)
	local rows: { Row } = {}
	for _, name in order do
		local ms = report[name]
		if ms and ms > 0.005 then rows[#rows + 1] = { name = name, ms = ms } end
	end
	table.sort(rows, function(a, b) return a.ms > b.ms end)
	local frameMs = if reportFrames > 0 then (reportSpan / reportFrames) * 1000 else 0
	local fps     = if frameMs > 0 then 1000 / frameMs else 0
	return rows, frameMs, fps
end

-- Everything the probes account for, in ms per frame. What is left of the frame time
-- after this is the engine's: rendering, physics, replication, and the scheduler.
function PerfProbe.accounted(): number
	local total = 0
	for _, ms in report do total += ms end
	return total
end

function PerfProbe.reset()
	table.clear(accum)
	table.clear(report)
	table.clear(seen)
	table.clear(order)
	depth = 0
end

-- ── Connecting through the probe ────────────────────────────────────────────
-- Every per-frame system in the game connects with one of these instead of connecting to
-- RunService directly, which is what makes the readout exhaustive rather than a sample of
-- whatever anyone remembered to instrument. The connection is returned unchanged, so a
-- caller that keeps it around to disconnect later is unaffected.
function PerfProbe.onRender(name: string, fn: (number) -> ()): RBXScriptConnection
	return RunService.RenderStepped:Connect(function(dt: number)
		PerfProbe.open(name)
		fn(dt)
		PerfProbe.shut()
	end)
end

function PerfProbe.onHeartbeat(name: string, fn: (number) -> ()): RBXScriptConnection
	return RunService.Heartbeat:Connect(function(dt: number)
		PerfProbe.open(name)
		fn(dt)
		PerfProbe.shut()
	end)
end

-- BindToRenderStep has its own name and priority, so it gets its own wrapper rather
-- than being bent into onRender.
function PerfProbe.bindRender(bindName: string, priority: number, label: string, fn: (number) -> ())
	RunService:BindToRenderStep(bindName, priority, function(dt: number)
		PerfProbe.open(label)
		fn(dt)
		PerfProbe.shut()
	end)
end

-- Convenience for the server, which has no overlay: run the sampler forever and roll it
-- on Heartbeat. Connect this FIRST, so the roll closes a window over the frame that has
-- just finished rather than the one starting.
function PerfProbe.autoRollHeartbeat()
	PerfProbe.setSampling(true)
	RunService.Heartbeat:Connect(function()
		PerfProbe.roll()
	end)
end

return PerfProbe
