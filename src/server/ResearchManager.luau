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
	done:      { [string]: boolean },
	excluded:  { [string]: boolean },
	builds:    { [string]: number  },
	kills:     number,
	trained:   { [string]: number  },
	upgrading: { [string]: number  },  -- techName → server end-time of its 30 s research
}

local playerState: { [number]: PlayerState } = {}

local function getState(player: any): PlayerState
	local id = player.UserId
	if not playerState[id] then
		playerState[id] = {
			done      = {},
			excluded  = {},
			builds    = {},
			kills     = 0,
			trained   = {},
			upgrading = {},
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

local function categoryOf(techName: string): string
	local unlock = (Config.UNLOCKS :: any)[techName]
	return unlock and (unlock.category :: string?) or "Infra"
end

-- True if a sibling in the same mutually-exclusive group has already been chosen.
local function isExcluded(state: PlayerState, techName: string): boolean
	if state.excluded[techName] then return true end
	local unlock = (Config.UNLOCKS :: any)[techName]
	local group  = unlock and (unlock.group :: string?)
	if not group then return false end
	for other, otherU in (Config.UNLOCKS :: any) do
		if other ~= techName and (otherU.group :: string?) == group and state.done[other] then
			return true
		end
	end
	return false
end

-- All requirements satisfied to begin researching this tech (does not check
-- concurrency, done/in-progress state, or exclusion — callers handle those).
local function requirementsMet(state: PlayerState, techName: string): boolean
	local unlock = (Config.UNLOCKS :: any)[techName]
	if not unlock then return false end
	local requires = unlock.requires :: string?
	if requires and not state.done[requires] then return false end
	return conditionMet(state, unlock.cond)
end

local function grantTech(player: any, techName: string)
	local state = getState(player)
	if state.done[techName] then return end
	state.done[techName]      = true
	state.upgrading[techName] = nil

	-- Lock out the other members of a mutually-exclusive group.
	local unlock = (Config.UNLOCKS :: any)[techName]
	local group  = unlock and (unlock.group :: string?)
	if group then
		for other, otherU in (Config.UNLOCKS :: any) do
			if other ~= techName and (otherU.group :: string?) == group then
				state.excluded[other] = true
			end
		end
	end

	RemoteHandler.get(Config.REMOTES.UnlockGranted):FireClient(player, techName)
	for _, hook in completionHooks do hook(player, techName) end
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
	fireProgressSync(player)
end

function ResearchManager.recordEnemyKilled(attackerUserIdStr: string)
	local uid = tonumber(attackerUserIdStr)
	if not uid or uid <= 0 then return end
	local player = Players:GetPlayerByUserId(uid)
	if not player then return end
	local state = getState(player)
	state.kills += 1
	fireProgressSync(player)
end

-- Batched variant: credit several kills to one attacker with a single progress sync.
-- The central death-removal loop can free many units in one frame, so it tallies per
-- attacker and applies the totals here to avoid one remote fire per kill.
function ResearchManager.recordEnemyKills(attackerUserIdStr: string, count: number)
	if count <= 0 then return end
	local uid = tonumber(attackerUserIdStr)
	if not uid or uid <= 0 then return end
	local player = Players:GetPlayerByUserId(uid)
	if not player then return end
	local state = getState(player)
	state.kills += count
	fireProgressSync(player)
end

function ResearchManager.recordUnitTrained(player: any, unitType: string)
	if not player or player.UserId <= 0 then return end
	local state = getState(player)
	state.trained[unitType] = (state.trained[unitType] or 0) + 1
	fireProgressSync(player)
end

-- ── Manual upgrade flow ───────────────────────────────────────────────────────

-- Player clicked UPGRADE. Validate requirements & concurrency, then start a timed
-- research that grants the tech when it completes.
function ResearchManager.requestUpgrade(player: any, techName: string)
	if not player or player.UserId <= 0 then return end
	if type(techName) ~= "string" then return end
	local unlock = (Config.UNLOCKS :: any)[techName]
	if not unlock then return end

	local state = getState(player)
	if state.done[techName] then return end
	if state.upgrading[techName] then return end
	if isExcluded(state, techName) then return end
	if not requirementsMet(state, techName) then return end

	-- Concurrency cap is per-category.
	local cat = categoryOf(techName)
	local active = 0
	for name in state.upgrading do
		if categoryOf(name) == cat then active += 1 end
	end
	if active >= Config.MAX_CONCURRENT_RESEARCH then return end

	local endTime = workspace:GetServerTimeNow() + Config.UPGRADE_TIME
	state.upgrading[techName] = endTime
	RemoteHandler.get(Config.REMOTES.UpgradeStarted):FireClient(player, techName, endTime)

	task.delay(Config.UPGRADE_TIME, function()
		-- Bail if the player reset (state table swapped) or the research was cleared.
		if getState(player) ~= state then return end
		if not state.upgrading[techName] then return end
		grantTech(player, techName)
	end)
end

-- ── Compatibility API (used by UnitManager, BuildingManager, AIManager) ───────

function ResearchManager.hasResearch(player: any, techName: string): boolean
	local state = getState(player)
	return state.done[techName] == true
end

function ResearchManager.resetPlayer(player: any)
	playerState[player.UserId] = {
		done      = {},
		excluded  = {},
		builds    = {},
		kills     = 0,
		trained   = {},
		upgrading = {},
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

-- AI shortcut: grant a tech directly without conditions or the research timer.
function ResearchManager.startForPlayer(player: any, _workshopId: string, techName: string)
	local tech = (Config.UNLOCKS :: any)[techName]
	if not tech then return end
	local state = getState(player)
	if state.done[techName] then return end
	grantTech(player, techName)
end

function ResearchManager.init()
	RemoteHandler.get(Config.REMOTES.RequestUpgrade).OnServerEvent:Connect(
		function(player: any, techName: any)
			ResearchManager.requestUpgrade(player, techName)
		end
	)
end

return ResearchManager
