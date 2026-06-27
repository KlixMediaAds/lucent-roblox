--!strict
--[[
    CCMobilePanel — Command Center mobility action for the command-card grid.

    The CC's build page (shown when the player selects their CC or presses [Space])
    appends one mobility slot, supplied by CCMobilePanel.getSlot(). The slot cycles
    through four states based on research + unlock + mobile status:
      Needs Research  →  Unlock ◆200  →  Mobilize  →  Deploy

    All network/state logic is preserved; only the presentation changed from a
    radial bubble to a single grid slot owned by the HUD build page.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))
local CommandCard       = require(script.Parent:WaitForChild("CommandCard"))

local CCMobilePanel = {}
local C             = UILib.C

-- ── Colors ─────────────────────────────────────────────────────────────────────
local UNLOCK_COLOR = Color3.fromRGB(110, 55, 210)
local MOBILIZE_COL = Color3.fromRGB(20,  200, 160)
local DEPLOY_COL   = Color3.fromRGB(225, 130, 20)

-- ── State ─────────────────────────────────────────────────────────────────────
local activeCCId:    string? = nil
local networkRef:    any
local getResources:  (() -> number)?
local hasResearchFn: ((string) -> boolean)?
local refreshFn:     (() -> ())?      -- re-render the CC page (set by init.client)

local ccIsUnlocked = false
local ccIsMobile   = false

-- ── Init ──────────────────────────────────────────────────────────────────────
function CCMobilePanel.init(network: any, getResourcesFn: () -> number, hasResearch: (string) -> boolean)
	networkRef    = network
	getResources  = getResourcesFn
	hasResearchFn = hasResearch
end

-- Register a callback that re-renders the CC build page (so live mobile-state syncs
-- update the slot). init.client wires this.
function CCMobilePanel.onRefresh(fn: () -> ())
	refreshFn = fn
end

-- ── Slot builder ────────────────────────────────────────────────────────────────
-- Returns the mobility slot for the CC build page. `index` is assigned by the HUD
-- when it appends the slot.
function CCMobilePanel.getSlot(ccId: string): CommandCard.Slot
	local researched = hasResearchFn and hasResearchFn("MobileCC") or false
	local res        = getResources and getResources() or 0

	local name, desc, color, icon = "MOBILITY", "Needs research", C.BORDER_LO, "🦾"
	local cost: number? = nil
	local locked = false
	local enabled = true

	if not researched then
		locked = true
	elseif not ccIsUnlocked then
		name, desc, color, icon = "MOBILIZE CC", "Unlock Command Center mobility", UNLOCK_COLOR, "🦾"
		cost    = Config.MOBILE_CC_COST
		enabled = res >= Config.MOBILE_CC_COST
	elseif ccIsMobile then
		name, desc, color, icon = "DEPLOY", "Set the Command Center back down", DEPLOY_COL, "⬛"
	else
		name, desc, color, icon = "MOBILIZE", "Lift the Command Center to relocate", MOBILIZE_COL, "▶"
	end

	return {
		index   = 1,   -- overwritten by HUD.showBuildPage when appended
		name    = name,
		desc    = desc,
		color   = color,
		icon    = icon,
		cost    = cost,
		locked  = locked,
		enabled = enabled,
		onClick = function()
			if not researched then return end
			if not ccIsUnlocked and res < (Config.MOBILE_CC_COST :: number) then return end
			networkRef.mobilizeCC(ccId)
		end,
	}
end

-- ── Public API (selection lifecycle) ───────────────────────────────────────────

function CCMobilePanel.show(ccId: string)
	activeCCId = ccId
end

function CCMobilePanel.hide()
	activeCCId = nil
end

function CCMobilePanel.setMobileState(isUnlocked: boolean, isMobile: boolean)
	ccIsUnlocked = isUnlocked
	ccIsMobile   = isMobile
	if activeCCId and refreshFn then refreshFn() end
end

function CCMobilePanel.refreshIfVisible()
	if activeCCId and refreshFn then refreshFn() end
end

function CCMobilePanel.isVisible(): boolean
	return activeCCId ~= nil
end

return CCMobilePanel
