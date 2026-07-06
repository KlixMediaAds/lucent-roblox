--!strict
--[[
    MotherPanel — command-card menu for the Hollowed "Mother" (their spike Command
    Center). Renders as a larger 2×2 tile grid (cols = 2).

    Rooted (structure) state → four options:
        Leech · Land Moth · Polyp   (each instant-trains beside the Mother)
        Uproot                       (lift the Mother into a moveable unit)

    Mobile (uprooted) state → a single option:
        Downroot                     (root back down; restores the build options)

    All production/mobility is server-authoritative; this panel only sends intent
    (Network.trainFromMother / Network.mobilizeCC) and reflects the mobile state fed
    in via setMobileState() from init.client's CCMobileSync handler.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))
local CommandCard       = require(script.Parent:WaitForChild("CommandCard"))
local ViewportPreview   = require(script.Parent:WaitForChild("ViewportPreview"))

local MotherPanel = {}
local C           = UILib.C
local OWNER       = "mother"

-- ── State ─────────────────────────────────────────────────────────────────────
local activeCCId:   string? = nil
local networkRef:   any
local resourcesFn:  (() -> number)?
local isMobile      = false

-- ── Colours ───────────────────────────────────────────────────────────────────
local LEECH_COL    = Color3.fromRGB(120, 190,  90)
local MOTH_COL     = Color3.fromRGB(170, 100, 220)
local POLYP_COL    = Color3.fromRGB(150, 150, 160)
local UPROOT_COL   = Color3.fromRGB( 20, 200, 160)
local DOWNROOT_COL = Color3.fromRGB(225, 130,  20)

type Opt = { key: string, name: string, icon: string, color: Color3, desc: string }
local OPTIONS: { Opt } = {
	{ key = "Leech", name = "LEECH", icon = "🪱", color = LEECH_COL, desc = "Spawn a Leech. Select it to burrow for passive income." },
	{ key = "Biter", name = "BITER", icon = "🦟", color = MOTH_COL,  desc = "Spawn a Biter — a simple melee combatant (can evolve once Biter Genome is researched)." },
	{ key = "Polyp", name = "POLYP", icon = "⬤",  color = POLYP_COL, desc = "Spawn a Polyp. Select it to morph into a Brain or Creepy Turret." },
}

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
	for i, opt in OPTIONS do
		local cost = (Config.UNIT_TYPES :: any)[opt.key].cost
		local slot: CommandCard.Slot = {
			index   = i,
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

	table.insert(slots, {
		index   = #OPTIONS + 1,
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
	CommandCard.show(OWNER, buildPage())
end

function MotherPanel.hide()
	activeCCId = nil
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
