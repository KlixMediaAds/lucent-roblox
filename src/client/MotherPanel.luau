--!strict
--[[
    MotherPanel — command-card menu for the Hollowed "Mother" (their spike Command
    Center). Renders as a larger 2×2 tile grid (cols = 2).

    Rooted (structure) state → three options:
        Leech · Egg Sacs             (Leech instant-trains beside the Mother; Egg Sacs is
                                      a repeatable upgrade that plants nests which auto-hatch
                                      Embryos)
        Uproot                       (lift the Mother into a moveable unit)

    Mobile (uprooted) state → a single option:
        Downroot                     (root back down; restores the build options)

    All production/mobility is server-authoritative; this panel only sends intent
    (Network.trainFromMother / Network.mobilizeCC) and reflects the mobile state fed
    in via setMobileState() from init.client's CCMobileSync handler.
]]

local Workspace         = game:GetService("Workspace")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))
local CommandCard       = require(script.Parent:WaitForChild("CommandCard"))
local ViewportPreview   = require(script.Parent:WaitForChild("ViewportPreview"))

local MotherPanel = {}
local C           = UILib.C
local OWNER       = "mother"
local localPlayer = Players.LocalPlayer

-- ── State ─────────────────────────────────────────────────────────────────────
local activeCCId:   string? = nil
local networkRef:   any
local resourcesFn:  (() -> number)?
local isMobile      = false
local eggSacConn:   RBXScriptConnection? = nil

-- ── Colours ───────────────────────────────────────────────────────────────────
local LEECH_COL    = Color3.fromRGB(120, 190,  90)
local EGGSAC_COL   = Color3.fromRGB(255, 140,  70)
local UPROOT_COL   = Color3.fromRGB( 20, 200, 160)
local DOWNROOT_COL = Color3.fromRGB(225, 130,  20)

type Opt = { key: string, name: string, icon: string, color: Color3, desc: string }
-- Leech is the only direct train (index 1); the Egg Sacs upgrade (index 2) and Uproot
-- (index 3) are built separately in buildPage().
local OPTIONS: { Opt } = {
	{ key = "Leech", name = "LEECH", icon = "🪱", color = LEECH_COL, desc = "Spawn a Leech. Select it to burrow for passive income." },
}

-- The live EggSacLevel is replicated on the Mother's model as an attribute (stamped by
-- the server on each purchase), so the panel reads it straight off the workspace model.
local function activeMotherModel(): Instance?
	if not activeCCId then return nil end
	local bf = Workspace:FindFirstChild("Buildings")
	return bf and bf:FindFirstChild(activeCCId) or nil
end
local function eggSacLevel(): number
	local m = activeMotherModel()
	return m and (m:GetAttribute("EggSacLevel") :: number? or 0) or 0
end

-- ── Page builder ────────────────────────────────────────────────────────────────
local function buildPage(): CommandCard.Page
	local slots: { CommandCard.Slot } = {}

	if isMobile then
		table.insert(slots, {
			index   = 1,
			name    = "DOWNROOT",
			icon    = "⬇",
			color   = DOWNROOT_COL,
			desc    = "Root the Mother back down — restores the build options.",
			onClick = function()
				if activeCCId then networkRef.mobilizeCC(activeCCId) end
			end,
		})
		return { header = "MOTHER", slots = slots, cols = 2 }
	end

	local res = resourcesFn and resourcesFn() or 0

	-- Leech (grid slot 1) — direct train beside the Mother.
	for _, opt in OPTIONS do
		local cost = (Config.UNIT_TYPES :: any)[opt.key].cost
		local slot: CommandCard.Slot = {
			index   = 1,
			name    = opt.name,
			icon    = opt.icon,
			color   = opt.color,
			cost    = cost,
			enabled = res >= cost,
			desc    = opt.desc,
			onClick = function()
				if not activeCCId then return end
				if (resourcesFn and resourcesFn() or 0) < cost then return end
				networkRef.trainFromMother(activeCCId, opt.key)
			end,
		}
		-- Show the Leech as a 3D thumbnail (like units in the Bonfire grid) instead of an emoji.
		if opt.key == "Leech" then
			slot.icon            = nil
			slot.viewportKey     = "unit:Leech"
			slot.viewportFactory = function() return ViewportPreview.forUnit("Leech", Vector2.new(64, 64)) end
		end
		table.insert(slots, slot)
	end

	-- Egg Sacs upgrade (grid slot 2) — repeatable purchase that plants nests + raises
	-- the auto-spawn Embryo cap. Level is read live off the Mother model's attribute.
	local level    = eggSacLevel()
	local maxLevel  = Config.MOTHER_EGGSAC_MAX_LEVEL
	local maxed     = level >= maxLevel
	local sacCost   = Config.MOTHER_EGGSAC_COST
	table.insert(slots, {
		index   = 2,
		name    = "EGG SACS",
		color   = EGGSAC_COL,
		-- 3D thumbnail of the egg nest (with an egg in it) instead of an emoji.
		viewportKey     = "eggsacnest",
		viewportFactory = function() return ViewportPreview.forEggSacNest(Vector2.new(64, 64)) end,
		cost    = maxed and nil or sacCost,
		badge   = "Lv " .. level .. "/" .. maxLevel,
		enabled = (not maxed) and res >= sacCost,
		locked  = maxed,
		desc    = maxed
			and ("Egg Sacs maxed — the Mother auto-hatches up to " .. Config.eggSacCapacity(level) .. " Embryos from her nests.")
			or ("Grow an Egg Sac cluster: plants nests beside the Mother that auto-hatch Embryos for free. +"
				.. Config.MOTHER_EGGSAC_PER_LEVEL .. " max Embryos per tier (" .. maxLevel .. " tiers)."),
		onClick = function()
			if not activeCCId then return end
			if eggSacLevel() >= maxLevel then return end
			if (resourcesFn and resourcesFn() or 0) < sacCost then return end
			networkRef.upgradeEggSacs(activeCCId)
		end,
	})

	-- Embryo evolution is always available now (no unlock needed), so the Mother no
	-- longer has an Evolve tile — Uproot takes grid slot 3.
	table.insert(slots, {
		index   = 3,
		name    = "UPROOT",
		icon    = "⬆",
		color   = UPROOT_COL,
		desc    = "Lift the Mother into a moveable unit (right-click to move).",
		onClick = function()
			if activeCCId then networkRef.mobilizeCC(activeCCId) end
		end,
	})

	return { header = "MOTHER", slots = slots, cols = 2 }
end

local function renderIfActive()
	if activeCCId and CommandCard.isOwner(OWNER) then
		CommandCard.update(OWNER, buildPage())
	end
end

-- ── Public API ────────────────────────────────────────────────────────────────
function MotherPanel.init(network: any, getResources: () -> number)
	networkRef   = network
	resourcesFn  = getResources
end

function MotherPanel.show(ccId: string)
	activeCCId = ccId
	-- Live-refresh the Egg Sacs tile when this Mother's level changes (purchase lands).
	if eggSacConn then eggSacConn:Disconnect(); eggSacConn = nil end
	local model = activeMotherModel()
	if model then
		eggSacConn = model:GetAttributeChangedSignal("EggSacLevel"):Connect(renderIfActive)
	end
	CommandCard.show(OWNER, buildPage())
end

function MotherPanel.hide()
	activeCCId = nil
	if eggSacConn then eggSacConn:Disconnect(); eggSacConn = nil end
	CommandCard.hide(OWNER)
end

-- Fed by init.client's CCMobileSync handler so Uproot ⇄ Downroot flips live.
function MotherPanel.setMobileState(mobile: boolean)
	isMobile = mobile
	renderIfActive()
end

function MotherPanel.refreshIfVisible()
	renderIfActive()
end

function MotherPanel.isVisible(): boolean
	return activeCCId ~= nil and CommandCard.isOwner(OWNER)
end

return MotherPanel
