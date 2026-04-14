local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local RemoteHandler     = require(Shared:WaitForChild("RemoteHandler"))

-- ── Research orbit effect ─────────────────────────────────────────────────────
-- Orbs are parented to the CC model so:
--   • replication is free (server Parts replicate to all clients automatically)
--   • FogManager's LocalTransparencyModifier sweep covers them as model descendants

local ORB_COUNT  = 3
local ORB_RADIUS = 10    -- studs from CC centre
local ORB_Y_OFF  = 7     -- studs above base top
local ORB_SPEED  = 120   -- degrees per second
local ORB_TICK   = 0.05  -- update rate (20 fps is smooth enough for rotation)

-- Returns a stop() function; call it to kill the loop and destroy the orbs.
local function spawnResearchOrbs(buildingId: string): (() -> ())?
	local buildingsF = workspace:FindFirstChild("Buildings") :: Folder?
	if not buildingsF then return nil end
	local model = buildingsF:FindFirstChild(buildingId) :: Model?
	if not model then return nil end
	local base  = model:FindFirstChild("Base") :: BasePart?
	if not base then return nil end

	local orbs: { Part } = {}
	for i = 1, ORB_COUNT do
		local orb          = Instance.new("Part")
		orb.Name           = "ResearchOrb"
		orb.Shape          = Enum.PartType.Ball
		orb.Size           = Vector3.new(1.4, 1.4, 1.4)
		orb.Material       = Enum.Material.Neon
		orb.Color          = Color3.fromRGB(0, 210, 255)
		orb.Anchored       = true
		orb.CanCollide     = false
		orb.CastShadow     = false
		orb.Position       = base.Position    -- will be corrected on first tick
		orb.Parent         = model            -- child of CC → fog of war handled automatically
		table.insert(orbs, orb)
	end

	local running = true
	local angle   = 0

	task.spawn(function()
		while running do
			local dt = task.wait(ORB_TICK)
			local b  = model:FindFirstChild("Base") :: BasePart?
			if not b or not model.Parent then break end

			angle = (angle + ORB_SPEED * dt) % 360
			local cx = b.Position.X
			local cy = b.Position.Y + b.Size.Y / 2 + ORB_Y_OFF
			local cz = b.Position.Z

			for i, orb in orbs do
				if not orb.Parent then break end
				local ang = math.rad(angle + (i - 1) * (360 / ORB_COUNT))
				orb.Position = Vector3.new(
					cx + math.cos(ang) * ORB_RADIUS,
					cy,
					cz + math.sin(ang) * ORB_RADIUS
				)
			end
		end
		-- Clean up regardless of why the loop ended
		for _, orb in orbs do
			if orb.Parent then orb:Destroy() end
		end
	end)

	return function() running = false end
end

local ResearchManager = {}

type ResearchState = {
	done:       { [string]: boolean },
	inProgress: { [string]: boolean },
}

local playerResearch: { [number]: ResearchState } = {}

local function getState(player: any): ResearchState
	local id = player.UserId
	if not playerResearch[id] then
		playerResearch[id] = { done = {}, inProgress = {} }
	end
	return playerResearch[id]
end

function ResearchManager.hasResearch(player: any, techName: string): boolean
	local state = getState(player)
	return state.done[techName] == true
end

function ResearchManager.resetPlayer(player: any)
	playerResearch[player.UserId] = { done = {}, inProgress = {} }
end

-- AI-side research trigger: identical logic to the remote handler but skips
-- FireClient calls (AI bots have no real client to update).
function ResearchManager.startForPlayer(player: any, _workshopId: string, techName: string)
	local tech = (Config.RESEARCH :: any)[techName]
	if not tech then return end

	local state = getState(player)
	if state.done[techName] then return end
	if state.inProgress[techName] then return end
	if tech.requires and not state.done[tech.requires :: string] then return end

	state.inProgress[techName] = true

	task.spawn(function()
		local elapsed   = 0
		local totalTime = tech.time :: number
		while elapsed < totalTime do
			local dt = task.wait(0.2)
			if not state.inProgress[techName] then return end
			elapsed = math.min(elapsed + dt, totalTime)
		end
		state.inProgress[techName] = nil
		state.done[techName]       = true
	end)
end

function ResearchManager.init()
	RemoteHandler.get(Config.REMOTES.StartResearch).OnServerEvent:Connect(
		function(player: any, _buildingId: any, techName: any)
			if type(_buildingId) ~= "string" or type(techName) ~= "string" then return end
			local tech = (Config.RESEARCH :: any)[techName]
			if not tech then return end

			local state = getState(player)
			if state.done[techName] then return end
			if state.inProgress[techName] then return end
			-- Enforce one research at a time server-side
			for _, v in state.inProgress do if v then return end end
			-- Check prerequisite (e.g. RocketBarrage requires ConcussionShells)
			if tech.requires and not state.done[tech.requires :: string] then return end

			state.inProgress[techName] = true

			local stopOrbs = spawnResearchOrbs(_buildingId)

			task.spawn(function()
				local elapsed   = 0
				local totalTime = tech.time :: number

				while elapsed < totalTime do
					local dt = task.wait(0.2)
					if not state.inProgress[techName] then
						if stopOrbs then stopOrbs() end
						return
					end
					elapsed = math.min(elapsed + dt, totalTime)
					local progress = elapsed / totalTime
					RemoteHandler.get(Config.REMOTES.ResearchUpdate):FireClient(
						player, techName, progress
					)
				end

				if stopOrbs then stopOrbs() end
				state.inProgress[techName] = nil
				state.done[techName]       = true
				RemoteHandler.get(Config.REMOTES.ResearchCompleted):FireClient(player, techName)
			end)
		end
	)
end

return ResearchManager
