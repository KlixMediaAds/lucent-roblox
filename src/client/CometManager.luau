--[[
	CometManager — client-side comet visual for ore wave spawns.

	Listens for CometWave remote events from the server. Each entry in the
	payload is { pos: Vector3, stagger: number }. For every comet:
	  1. Wait `stagger` seconds so the cluster doesn't land simultaneously.
	  2. Spawn a glowing sphere + outer glow that fall from ORE_COMET_HEIGHT
	     down to the ground with quadratic (accelerating) easing.
	  3. On impact, flash an expanding ring at ground level and destroy the comet.
]]

local TweenService      = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local RemoteHandler     = require(Shared:WaitForChild("RemoteHandler"))

local CometManager = {}

-- ── Comet part helpers ────────────────────────────────────────────────────────

local function makePart(size: number, color: BrickColor, trans: number): Part
	local p         = Instance.new("Part")
	p.Shape         = Enum.PartType.Ball
	p.Size          = Vector3.new(size, size, size)
	p.BrickColor    = color
	p.Material      = Enum.Material.Neon
	p.Transparency  = trans
	p.Anchored      = true
	p.CanCollide    = false
	p.CastShadow    = false
	p.CanQuery      = false
	p.Parent        = workspace
	return p
end

-- ── Single comet lifecycle ────────────────────────────────────────────────────

local function spawnComet(targetPos: Vector3, stagger: number)
	task.delay(stagger, function()
		local height     = Config.ORE_COMET_HEIGHT
		local speed      = Config.ORE_COMET_SPEED
		local travelTime = height / speed

		local startPos = Vector3.new(targetPos.X, height, targetPos.Z)
		local endPos   = Vector3.new(targetPos.X, 1,      targetPos.Z)

		-- Inner core (bright yellow)
		local core = makePart(3.5, BrickColor.new("Bright yellow"), 0)
		core.Position = startPos

		-- Outer glow halo (orange, semi-transparent)
		local glow = makePart(6, BrickColor.new("Bright orange"), 0.5)
		glow.Position = startPos

		-- Accelerating fall tween
		local info = TweenInfo.new(travelTime, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		local t1   = TweenService:Create(core, info, { Position = endPos })
		local t2   = TweenService:Create(glow, info, { Position = endPos })
		t1:Play()
		t2:Play()

		-- Also shrink the glow slightly as it falls (heat concentrates)
		TweenService:Create(glow, info, {
			Size = Vector3.new(4.5, 4.5, 4.5),
			Transparency = 0.3,
		}):Play()

		t1.Completed:Connect(function(state)
			if state ~= Enum.PlaybackState.Completed then return end
			core:Destroy()
			glow:Destroy()

			-- Impact: flat ring that expands and fades
			local ring         = Instance.new("Part")
			ring.Shape         = Enum.PartType.Cylinder
			ring.Size          = Vector3.new(0.4, 6, 6)
			ring.CFrame        = CFrame.new(endPos.X, 0.3, endPos.Z)
				* CFrame.Angles(0, 0, math.rad(90))  -- lay cylinder flat
			ring.BrickColor    = BrickColor.new("Bright yellow")
			ring.Material      = Enum.Material.Neon
			ring.Transparency  = 0
			ring.Anchored      = true
			ring.CanCollide    = false
			ring.CastShadow    = false
			ring.CanQuery      = false
			ring.Parent        = workspace

			local ringEnd = CFrame.new(endPos.X, 0.1, endPos.Z)
				* CFrame.Angles(0, 0, math.rad(90))
			TweenService:Create(ring,
				TweenInfo.new(0.75, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{
					CFrame       = ringEnd,
					Size         = Vector3.new(0.2, 32, 32),
					Transparency = 1,
				}
			):Play()

			task.delay(0.8, function() ring:Destroy() end)
		end)
	end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function CometManager.init()
	RemoteHandler.get(Config.REMOTES.CometWave).OnClientEvent:Connect(
		function(cometData: { { pos: Vector3, stagger: number } })
			for _, entry in cometData do
				spawnComet(entry.pos, entry.stagger)
			end
		end
	)
end

return CometManager
