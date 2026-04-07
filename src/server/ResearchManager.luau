local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local RemoteHandler     = require(Shared:WaitForChild("RemoteHandler"))

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

			state.inProgress[techName] = true

			task.spawn(function()
				local elapsed   = 0
				local totalTime = tech.time :: number

				while elapsed < totalTime do
					local dt = task.wait(0.2)
					if not state.inProgress[techName] then return end
					elapsed = math.min(elapsed + dt, totalTime)
					local progress = elapsed / totalTime
					RemoteHandler.get(Config.REMOTES.ResearchUpdate):FireClient(
						player, techName, progress
					)
				end

				state.inProgress[techName] = nil
				state.done[techName]       = true
				RemoteHandler.get(Config.REMOTES.ResearchCompleted):FireClient(player, techName)
			end)
		end
	)
end

return ResearchManager
