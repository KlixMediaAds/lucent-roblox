--[[
	AlertManager — throttled "under attack" pings sent to a unit/building's owner.

	Both UnitManager (army) and BuildingManager (base) funnel damage events here
	via `report`. Alerts are throttled per-player, per-map-region, per-category so
	a sustained battle produces one steady ping per area instead of a flood, while
	attacks in different places each get their own ping.

	The client (MiniMap + HUD) decides how to present the alert; this module only
	decides *whether* and *where* to fire.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local RemoteHandler     = require(Shared:WaitForChild("RemoteHandler"))

local AlertManager = {}

local CELL     = 80    -- studs per region; one ping per region+category per window
local THROTTLE = 4.0   -- seconds between pings for the same region + category

-- categoryId keeps the region key numeric (no per-hit string allocation).
local CATEGORY_ID: { [string]: number } = { base = 0, army = 1 }

-- userId → { [regionKey]: os.clock() of last fire }
local lastFire: { [number]: { [number]: number } } = {}

--[[
	Reports that `owner`'s entity took damage at `worldPos`. `category` is
	"base" (building) or "army" (unit). No-op for AI owners (negative UserId /
	no Parent) and for the same region+category within the throttle window.
]]
function AlertManager.report(owner: any, worldPos: Vector3, category: string)
	-- Real, connected players only — AI owners are mock tables (UserId < 0).
	if not owner or owner.UserId <= 0 or not owner.Parent then return end

	local cx  = math.floor(worldPos.X / CELL) + 128   -- +128 keeps the key positive
	local cz  = math.floor(worldPos.Z / CELL) + 128
	local key = (cx * 256 + cz) * 2 + (CATEGORY_ID[category] or 0)

	local byUser = lastFire[owner.UserId]
	if not byUser then
		byUser = {}
		lastFire[owner.UserId] = byUser
	end

	local now = os.clock()
	if (byUser[key] or 0) + THROTTLE > now then return end
	byUser[key] = now

	RemoteHandler.get(Config.REMOTES.AttackAlert):FireClient(owner, worldPos, category)
end

-- Drops a player's throttle state (call when they leave to avoid a slow leak).
function AlertManager.clearPlayer(userId: number)
	lastFire[userId] = nil
end

return AlertManager
