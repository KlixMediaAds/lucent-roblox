--!strict
--[[
	PlayerStats — the two numbers a player card shows about whoever owns it:

	  firstJoin  — unix seconds of the very first time they ever loaded the place
	  playSecs   — seconds spent in ACTUAL MATCHES, lobby time excluded
	  badges     — badge id → unix seconds it was earned (see Config.BADGES)

	Persistence
	-----------
	Backed by a DataStore, one key per user. Everything is written through a single
	entry point (`flush`) that uses UpdateAsync, so two servers holding the same player
	(a rejoin mid-save, a teleport) merge instead of clobbering: playtime is accumulated
	as a DELTA on top of whatever the store already holds, and firstJoin always keeps the
	EARLIER of the two.

	DataStores are unavailable in a lot of legitimate situations — Studio without API
	access, a brand-new place, an outage. None of those should break the menu, so a
	failed load leaves the player on a fresh profile that still tracks the session
	correctly; it just will not survive the session. `available` records which case we
	are in so the UI can say "this session only" rather than quietly showing a wrong
	lifetime number.

	Replication
	-----------
	Both figures are written to the Player as attributes, which replicate to every
	client for free. That is what lets you hover ANOTHER player's card and see their
	stats without a remote, a request, or a round trip.

	Match time only
	---------------
	`setMatchActive` is driven by the server's match lifecycle. Time accrues only
	between a match starting and it ending; a player sitting in the ready-up lobby, or
	on the end screen, is not playing and is not charged for it.
]]

local DataStoreService  = game:GetService("DataStoreService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local PlayerStats = {}

-- ── Attributes (replicated; the client reads these directly) ──────────────────
PlayerStats.ATTR_FIRST_JOIN = "StatsFirstJoin"   -- unix seconds, 0 while unknown
PlayerStats.ATTR_PLAY_SECS  = "StatsPlaySecs"    -- lifetime seconds in matches
PlayerStats.ATTR_LOADED     = "StatsLoaded"      -- false until the profile has resolved
-- One attribute per badge rather than a table, since attributes cannot hold tables. The
-- value is the unix second it was earned; absent means the player does not hold it.
PlayerStats.ATTR_BADGE_PREFIX = "StatsBadge_"

local STORE_NAME  = "PlayerStats_v1"
local SAVE_PERIOD = 120    -- seconds between periodic flushes of a live session
local PUSH_PERIOD = 5      -- seconds between attribute refreshes while a match runs
local LOAD_TRIES  = 3

-- ── State ─────────────────────────────────────────────────────────────────────
type Profile = {
	firstJoin:  number,                      -- unix seconds; 0 until known
	baseSecs:   number,                      -- playtime already persisted in the store
	unsaved:    number,                      -- match seconds accrued here and not yet written
	loaded:     boolean,                     -- the store answered (even if with "no record")
	badges:     { [string]: number },        -- badge id → unix second earned
	newBadges:  { [string]: number },        -- earned here and not yet written
}

local profiles: { [number]: Profile } = {}
local store: DataStore? = nil
local available   = false   -- did the DataStore open at all
local matchActive = false
local accrueAcc   = 0
local pushAcc     = 0
local saveAcc     = 0

-- ── Store access ──────────────────────────────────────────────────────────────
local function getStore(): DataStore?
	if store then return store end
	local ok, res = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok and res then
		store     = res
		available = true
		return store
	end
	return nil
end

local function totalSecs(p: Profile): number
	return p.baseSecs + p.unsaved
end

local function push(player: Player)
	local p = profiles[player.UserId]
	if not p then return end
	player:SetAttribute(PlayerStats.ATTR_FIRST_JOIN, p.firstJoin)
	player:SetAttribute(PlayerStats.ATTR_PLAY_SECS, math.floor(totalSecs(p)))
	player:SetAttribute(PlayerStats.ATTR_LOADED, p.loaded)
	for id in Config.BADGES do
		local earned = p.badges[id] or p.newBadges[id]
		player:SetAttribute(PlayerStats.ATTR_BADGE_PREFIX .. id, earned)
	end
end

-- Award any badge whose condition now holds and that the player does not already have.
-- The award moment is stored, so a badge outlives the condition that granted it: a beta
-- tester stays one after the beta closes.
local function awardBadges(p: Profile)
	if p.badges.BetaTester == nil and p.newBadges.BetaTester == nil then
		if os.time() < Config.BETA_TESTER_UNTIL then
			p.newBadges.BetaTester = os.time()
		end
	end
end

-- ── Load ──────────────────────────────────────────────────────────────────────
local function load(player: Player)
	local userId = player.UserId
	local p: Profile = { firstJoin = 0, baseSecs = 0, unsaved = 0, loaded = false,
		badges = {}, newBadges = {} }
	profiles[userId] = p
	push(player)

	-- Guests / Studio's fake -1 ids have nothing to persist against.
	if userId <= 0 then
		p.firstJoin = os.time()
		p.loaded    = true
		awardBadges(p)
		push(player)
		return
	end

	local ds = getStore()
	if not ds then
		-- No store at all: run the session on a fresh profile so playtime still ticks and
		-- the UI has something honest to show, flagged as unloaded.
		p.firstJoin = os.time()
		awardBadges(p)
		push(player)
		return
	end

	local key = "u_" .. userId
	for attempt = 1, LOAD_TRIES do
		local ok, data = pcall(function()
			return (ds :: DataStore):GetAsync(key)
		end)
		if ok then
			if type(data) == "table" then
				p.firstJoin = tonumber((data :: any).firstJoin) or os.time()
				p.baseSecs  = tonumber((data :: any).playSecs) or 0
				local b = (data :: any).badges
				if type(b) == "table" then
					for id, at in b do
						if type(id) == "string" and type(at) == "number" then p.badges[id] = at end
					end
				end
			else
				-- No record: this IS their first time, which is exactly what we are here
				-- to remember.
				p.firstJoin = os.time()
			end
			p.loaded = true
			break
		end
		if attempt < LOAD_TRIES then task.wait(2 ^ attempt) end
	end

	if not p.loaded and p.firstJoin == 0 then p.firstJoin = os.time() end
	awardBadges(p)
	if not player.Parent then profiles[userId] = nil; return end
	push(player)
end

-- ── Save ──────────────────────────────────────────────────────────────────────
-- Writes the unsaved delta and clears it. UpdateAsync rather than SetAsync so a second
-- server holding this player adds to the same total instead of overwriting it.
local function flush(userId: number)
	local p = profiles[userId]
	if not p or userId <= 0 then return end
	local delta = math.floor(p.unsaved)
	local pending = next(p.newBadges) ~= nil
	if delta <= 0 and not pending and p.loaded then return end

	local ds = getStore()
	if not ds then return end

	local mine    = p.firstJoin
	-- Snapshotted before the call: the session keeps running during UpdateAsync, and a
	-- badge earned mid-write must not be cleared as though it had been saved.
	local writing: { [string]: number } = {}
	for id, at in p.newBadges do writing[id] = at end

	local ok = pcall(function()
		(ds :: DataStore):UpdateAsync("u_" .. userId, function(old)
			local prevSecs  = 0
			local prevFirst = 0
			local merged: { [string]: number } = {}
			if type(old) == "table" then
				prevSecs  = tonumber((old :: any).playSecs) or 0
				prevFirst = tonumber((old :: any).firstJoin) or 0
				local ob = (old :: any).badges
				if type(ob) == "table" then
					for id, at in ob do
						if type(id) == "string" and type(at) == "number" then merged[id] = at end
					end
				end
			end
			-- A badge already in the store keeps its ORIGINAL award moment: re-awarding one
			-- must never reset how long the player has held it.
			for id, at in writing do
				if merged[id] == nil then merged[id] = at end
			end
			-- The earliest first-join wins: a failed load must never be able to move a
			-- veteran's join date forward to today.
			local first = prevFirst
			if first <= 0 or (mine > 0 and mine < first) then first = mine end
			return { firstJoin = first, playSecs = prevSecs + delta, badges = merged }
		end)
	end)

	if ok then
		p.baseSecs += delta
		p.unsaved  -= delta
		for id, at in writing do
			p.badges[id]    = p.badges[id] or at
			p.newBadges[id] = nil
		end
	end
end

-- ── Public ────────────────────────────────────────────────────────────────────
-- Only true while a match is actually being played. Lobby and end-screen time is not
-- playtime, which is the whole point of tracking it separately from session length.
function PlayerStats.setMatchActive(isActive: boolean)
	if matchActive == isActive then return end
	matchActive = isActive
	accrueAcc   = 0
	-- Push once on the edge so a card opened right after a match ends is already correct.
	for _, player in Players:GetPlayers() do push(player) end
end

function PlayerStats.isAvailable(): boolean
	return available
end

function PlayerStats.init()
	getStore()

	for _, player in Players:GetPlayers() do task.spawn(load, player) end
	Players.PlayerAdded:Connect(function(player) task.spawn(load, player) end)

	Players.PlayerRemoving:Connect(function(player)
		flush(player.UserId)
		profiles[player.UserId] = nil
	end)

	RunService.Heartbeat:Connect(function(dt)
		if matchActive then
			accrueAcc += dt
			-- Accrued in whole seconds so the stored number never drifts on fractions.
			if accrueAcc >= 1 then
				local whole = math.floor(accrueAcc)
				accrueAcc -= whole
				for _, player in Players:GetPlayers() do
					local p = profiles[player.UserId]
					if p then p.unsaved += whole end
				end
			end

			pushAcc += dt
			if pushAcc >= PUSH_PERIOD then
				pushAcc = 0
				for _, player in Players:GetPlayers() do push(player) end
			end
		end

		saveAcc += dt
		if saveAcc >= SAVE_PERIOD then
			saveAcc = 0
			for _, player in Players:GetPlayers() do
				local uid = player.UserId
				task.spawn(flush, uid)
			end
		end
	end)

	-- Last write before the server closes. Roblox holds shutdown open for this, so the
	-- final minutes of a session are not lost.
	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			flush(player.UserId)
		end
	end)
end

return PlayerStats
