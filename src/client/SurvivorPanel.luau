--!strict
--[[
    SurvivorPanel — command-card menu shown when one or more owned Survivors are
    selected (the unit equivalent of the building panels).

    Right now it offers a single action: UPGRADE TO SNIPER, which re-kits every
    selected Survivor into a Sniper (long range, slow, high damage) for a per-unit
    cost. Snipers are intentionally NOT summonable at the Bonfire — this is the only
    way to field them.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))

local ViewportPreview   = require(script.Parent:WaitForChild("ViewportPreview"))
local CommandCard       = require(script.Parent:WaitForChild("CommandCard"))

local SurvivorPanel = {}
local OWNER         = "unit"

local SNIPER_OLIVE = Color3.fromRGB(96, 116, 72)

-- ── State ─────────────────────────────────────────────────────────────────────
local activeIds:  { string } = {}
local networkRef: any
local resourcesFn: (() -> number)?

function SurvivorPanel.init(network: any, getResourcesFn: () -> number)
	networkRef  = network
	resourcesFn = getResourcesFn
end

-- ── Command-card page ───────────────────────────────────────────────────────────
local function buildPage(): CommandCard.Page
	local n   = #activeIds
	local res = resourcesFn and resourcesFn() or 0
	-- Cost scales with how many are selected (each Survivor is upgraded).
	local totalCost = Config.SNIPER_UPGRADE_COST * math.max(1, n)
	local affordAll = res >= totalCost

	local slots: { CommandCard.Slot } = {
		{
			index           = 1,
			name            = "Upgrade to Sniper",
			cost            = totalCost,
			color           = SNIPER_OLIVE,
			enabled         = affordAll,
			locked          = false,
			viewportKey     = "unit:Sniper",
			viewportFactory = function() return ViewportPreview.forUnit("Sniper", Vector2.new(64, 64)) end,
			desc            = (n > 1)
				and ("Re-kit all " .. n .. " selected Survivors with a long-range sniper rifle (slow, high damage).")
				or  "Re-kit this Survivor with a long-range sniper rifle: slow fire, high damage.",
			onClick         = function()
				if not affordAll then return end
				if networkRef and #activeIds > 0 then
					networkRef.upgradeUnit(activeIds, "Sniper")
				end
				-- The units become Snipers server-side; nothing left to upgrade here.
				SurvivorPanel.hide()
			end,
		},
	}

	local header = (n > 1) and ("SURVIVORS ×" .. n) or "SURVIVOR"
	return { header = header, slots = slots }
end

-- ── Public API ────────────────────────────────────────────────────────────────
-- `ids` = the currently-selected owned Survivor unit ids.
function SurvivorPanel.show(ids: { string })
	activeIds = ids
	CommandCard.show(OWNER, buildPage())
end

function SurvivorPanel.hide()
	activeIds = {}
	CommandCard.hide(OWNER)
end

-- Re-render (e.g. when resources change) so affordability tracks live.
function SurvivorPanel.refreshIfVisible()
	if #activeIds > 0 and CommandCard.isOwner(OWNER) then
		CommandCard.update(OWNER, buildPage())
	end
end

function SurvivorPanel.isActive(): boolean
	return #activeIds > 0 and CommandCard.isOwner(OWNER)
end

return SurvivorPanel
