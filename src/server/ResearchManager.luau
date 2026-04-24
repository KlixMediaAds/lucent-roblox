--!strict
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local RemoteHandler     = require(Shared:WaitForChild("RemoteHandler"))

local ResearchManager = {}

local completionHooks: { (any, string) -> () } = {}

function ResearchManager.addCompletionHook(fn: (any, string) -> ())
	table.insert(completionHooks, fn)
end

type PlayerState = {
	done:        { [string]: boolean },
	excluded:    { [string]: boolean },
	builds:      { [string]: number  },
	kills:       number,
	trained:     { [string]: number  },
	groupsFired: { [string]: boolean },
}

local playerState: { [number]: PlayerState } = {}

local function getState(player: any): PlayerState
	local id = player.UserId
	if not playerState[id] then
		playerState[id] = {
			done        = {},
			excluded    = {},
			builds      = {},
			kills       = 0,
			trained     = {},
			groupsFired = {},
		}
	end
	return playerState[id]
end

local function conditionMet(state: PlayerState, cond: any): boolean
	local t = cond.type :: string
	if t == "building" then
		local name  = cond.name :: string
		local count = cond.count :: number
		if name == "any" then
			local total = 0
			for _, v in state.builds do total += v end
			return total >= count
		else
			return (state.builds[name] or 0) >= count
		end
	elseif t == "kill" then
		return state.kills >= (cond.count :: number)
	elseif t == "train" then
		local name = cond.name :: string
		return (state.trained[name] or 0) >= (cond.count :: number)
	end
	return false
end

-- Forward-declared so grantTech and checkConditions can mutually call each other
local checkConditions: (any) -> ()

local function grantTech(player: any, techName: string)
	local state = getState(player)
	state.done[techName] = true
	RemoteHandler.get(Config.REMOTES.UnlockGranted):FireClient(player, techName)
	for _, hook in completionHooks do hook(player, techName) end
	checkConditions(player)  -- re-evaluate anything that was blocked by this prerequisite
end

checkConditions = function(player: any)
	local state = getState(player)

	-- Gather which groups have a member whose conditions are newly met
	local pendingGroups: { [string]: { string } } = {}

	for techName, unlock in (Config.UNLOCKS :: any) do
		if state.done[techName]     then continue end
		if state.excluded[techName] then continue end

		local requires = unlock.requires :: string?
		if requires and not state.done[requires] then continue end

		if not conditionMet(state, unlock.cond) then continue end

		local group = unlock.group :: string?
		if not group then
			-- No group: grant immediately
			grantTech(player, techName)
		else
			if not state.groupsFired[group] then
				if not pendingGroups[group] then pendingGroups[group] = {} end
				table.insert(pendingGroups[group], techName)
			end
		end
	end

	-- Fire one choice prompt per pending group
	for group, options in pendingGroups do
		-- Collect all members of this group (not just the ones whose cond is met)
		local allOptions: { string } = {}
		for techName, unlock in (Config.UNLOCKS :: any) do
			if (unlock.group :: string?) == group then
				table.insert(allOptions, techName)
			end
		end
		state.groupsFired[group] = true
		RemoteHandler.get(Config.REMOTES.UnlockChoice):FireClient(player, group, allOptions)
	end
end

-- ── Public recording API ──────────────────────────────────────────────────────

local function fireProgressSync(player: any)
	local state = getState(player)
	RemoteHandler.get(Config.REMOTES.CondProgressSync):FireClient(player, {
		kills   = state.kills,
		builds  = state.builds,
		trained = state.trained,
	})
end

function ResearchManager.recordBuildingPlaced(player: any, buildingType: string)
	if not player or player.UserId <= 0 then return end
	local state = getState(player)
	state.builds[buildingType] = (state.builds[buildingType] or 0) + 1
	checkConditions(player)
	fireProgressSync(player)
end

function ResearchManager.recordEnemyKilled(attackerUserIdStr: string)
	local uid = tonumber(attackerUserIdStr)
	if not uid or uid <= 0 then return end
	local player = Players:GetPlayerByUserId(uid)
	if not player then return end
	local state = getState(player)
	state.kills += 1
	checkConditions(player)
	fireProgressSync(player)
end

function ResearchManager.recordUnitTrained(player: any, unitType: string)
	if not player or player.UserId <= 0 then return end
	local state = getState(player)
	state.trained[unitType] = (state.trained[unitType] or 0) + 1
	checkConditions(player)
	fireProgressSync(player)
end

-- ── Compatibility API (used by UnitManager, BuildingManager, AIManager) ───────

function ResearchManager.hasResearch(player: any, techName: string): boolean
	local state = getState(player)
	return state.done[techName] == true
end

function ResearchManager.resetPlayer(player: any)
	playerState[player.UserId] = {
		done        = {},
		excluded    = {},
		builds      = {},
		kills       = 0,
		trained     = {},
		groupsFired = {},
	}
	fireProgressSync(player)
end

function ResearchManager.getStats(player: any): { kills: number, unitsTrained: number, buildingsBuilt: number }
	local state = getState(player)
	local totalTrained = 0
	for _, v in state.trained do totalTrained += v end
	local totalBuilds = 0
	for _, v in state.builds do totalBuilds += v end
	return { kills = state.kills, unitsTrained = totalTrained, buildingsBuilt = totalBuilds }
end

-- AI shortcut: grant a tech directly without conditions (bots don't do the gallery flow)
function ResearchManager.startForPlayer(player: any, _workshopId: string, techName: string)
	local tech = (Config.UNLOCKS :: any)[techName]
	if not tech then return end
	local state = getState(player)
	if state.done[techName] then return end
	grantTech(player, techName)
end

function ResearchManager.init()
	-- Handle player's choice in a grouped unlock
	RemoteHandler.get(Config.REMOTES.UnlockChoose).OnServerEvent:Connect(
		function(player: any, techName: any)
			if type(techName) ~= "string" then return end
			local unlock = (Config.UNLOCKS :: any)[techName]
			if not unlock then return end

			local state = getState(player)
			if state.done[techName] or state.excluded[techName] then return end

			local group = unlock.group :: string?

			-- Validate: the group choice was already fired for this player
			if group and not state.groupsFired[group] then return end

			-- Grant chosen tech, exclude all other members of the same group
			grantTech(player, techName)
			if group then
				for otherName, otherUnlock in (Config.UNLOCKS :: any) do
					if (otherUnlock.group :: string?) == group and otherName ~= techName then
						state.excluded[otherName] = true
					end
				end
			end
		end
	)
end

return ResearchManager
