--!strict
--[[
    EggPanel — command-card menu shown when one of the Mother's Egg-Sac eggs is selected.
    Renders as a 2×2 tile grid, offering the same four choices an Embryo had.

    A nest's egg grows on a flat clock (Config.EGG_GROW_TIME) and then sits RIPE. Picking a
    tile sends Network.assignEgg, which ORDERS that creature out of every ripe egg in the
    selection: each shell then carries it for Config.EGG_HATCH_TIME before the creature
    climbs out, and only then is the shell spent and regrown. Picking is an order, not a
    delivery, so a full cycle is grow + hatch.

    The egg is the timer, not the price. Ordering charges the creature's own cost
    (Config.UNIT_TYPES[key].cost) per egg, so a multi-egg order costs that many times over
    and stops at whatever the player can actually pay for.

    Nothing here is a standing order. An egg remembers no creature between hatches, so the
    tiles are one-shot commands rather than a setting, and the grid is dead until at least
    one selected egg has finished growing.

    Tiles are presented the way the Bonfire presents its summon choice (DeployerPanel):
    every face is a 3D preview of the creature, built by ViewportPreview off the same
    UnitVisuals geometry the live unit is drawn with, not a glyph.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config          = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local CommandCard     = require(script.Parent:WaitForChild("CommandCard"))
local ViewportPreview = require(script.Parent:WaitForChild("ViewportPreview"))

local EggPanel = {}
local OWNER    = "egg"

local LAMPREY_COL = Color3.fromRGB(120, 190,  60)
local HAGFISH_COL = Color3.fromRGB( 90, 200, 150)
local ROLLER_COL  = Color3.fromRGB(150,  70, 110)
local NEEDLER_COL = Color3.fromRGB(170, 100,  60)

type Opt = { key: string, name: string, color: Color3, desc: string }
local OPTIONS: { Opt } = {
	{ key = "Lamprey", name = "LAMPREY", color = LAMPREY_COL, desc = "This egg hatches Lampreys." },
	{ key = "Hagfish", name = "HAGFISH", color = HAGFISH_COL, desc = "This egg hatches Hagfish." },
	{ key = "Roller",  name = "ROLLER",  color = ROLLER_COL,  desc = "This egg hatches Rollers, fast armored grinders." },
	{ key = "Needler", name = "NEEDLER", color = NEEDLER_COL, desc = "This egg hatches Needlers, slow stalkers that strike with one long insect arm." },
}

-- ── State ─────────────────────────────────────────────────────────────────────
-- The selected egg + its tentacle-tree descendants; a unit choice applies to all of them.
local activeEggIds: { string } = {}
local networkRef:   any
local resourcesFn:  (() -> number)?
-- Live EggReady watches on the selected eggs, so the grid opens up the moment one of them
-- finishes growing and closes again as they are spent. Dropped on hide.
local watches: { RBXScriptConnection } = {}

function EggPanel.init(network: any, getResources: (() -> number)?)
	networkRef  = network
	resourcesFn = getResources
end

-- The egg part behind an egg id: the clump Model under workspace.EggNests carries the id
-- as its name, and the shell itself is its "Egg" child. Same part the world mark
-- (EggReadyIcon) reads, so panel and world can never disagree on which eggs are ripe.
local function eggPart(eggId: string): BasePart?
	local root = workspace:FindFirstChild("EggNests")
	if not root then return nil end
	for _, clutch in root:GetChildren() do
		local clump = clutch:FindFirstChild(eggId)
		if clump then return clump:FindFirstChild("Egg") :: BasePart? end
	end
	return nil
end

-- How many of the selected eggs are ripe. A pick spends exactly these; the rest are still
-- growing and are simply not part of the order.
local function readyCount(): number
	local n = 0
	for _, id in activeEggIds do
		local part = eggPart(id)
		if part and part:GetAttribute("EggReady") == true then n += 1 end
	end
	return n
end

local function buildPage(): CommandCard.Page
	local slots: { CommandCard.Slot } = {}
	local ready = readyCount()
	local funds = resourcesFn and resourcesFn() or 0
	for i, opt in OPTIONS do
		local key    = opt.key
		local def    = (Config.UNIT_TYPES :: any)[key]
		local cost   = (def and def.cost) or 0
		-- Enough for at least one. A press with several ripe eggs buys as many as the
		-- balance covers, so the bar to showing the tile as usable is one creature.
		local canPay = cost <= 0 or funds >= cost
		table.insert(slots, {
			index   = i,
			name    = opt.name,
			cost    = cost > 0 and cost or nil,
			-- The creature itself, rendered from the same builder that draws it in the
			-- world, rather than a glyph standing in for it. The card caches these by key,
			-- so the four models are built once for the whole session.
			viewportKey     = "unit:" .. key,
			viewportFactory = function() return ViewportPreview.forUnit(key, Vector2.new(64, 64)) end,
			color   = opt.color,
			-- Nothing can be hatched out of an egg that is still growing, and nothing can be
			-- paid for out of an empty wallet.
			enabled = ready > 0 and canPay,
			-- How many creatures this press would actually produce, which is not the same
			-- as how many eggs are selected once some of them are mid-regrow.
			badge   = ready > 1 and ("×" .. ready) or nil,
			desc    = ready <= 0
				and (opt.desc .. " Nothing ripe. An egg takes "
					.. Config.EGG_GROW_TIME .. "s to ripen before it can be ordered from.")
				or (not canPay
				and (opt.desc .. " Costs " .. cost .. " per egg, which you cannot afford.")
				or (opt.desc .. " Ordered out of "
					.. (ready > 1 and (ready .. " ripe eggs, " .. (cost * ready) .. " total")
						or "this egg")
					.. ". Takes " .. Config.EGG_HATCH_TIME .. "s to come out; the shell then "
					.. "regrows over " .. Config.EGG_GROW_TIME .. "s.")),
			onClick = function()
				-- Sent per egg; the server ignores any that are not ripe.
				for _, id in activeEggIds do networkRef.assignEgg(id, opt.key) end
			end,
		})
	end
	local n = #activeEggIds
	local header = (n > 1) and ("EGGS ×" .. n) or "EGG"
	return { header = header, slots = slots, cols = 2 }
end

local function renderIfActive()
	if #activeEggIds > 0 and CommandCard.isOwner(OWNER) then
		CommandCard.update(OWNER, buildPage())
	end
end

local function dropWatches()
	for _, c in watches do c:Disconnect() end
	table.clear(watches)
end

-- ── Public API ────────────────────────────────────────────────────────────────
function EggPanel.show(eggIds: { string })
	dropWatches()
	activeEggIds = eggIds
	-- Ripeness is server-owned, so the grid follows the attribute coming back rather than
	-- being toggled optimistically: one re-render per egg that ripens or is spent.
	for _, id in eggIds do
		local part = eggPart(id)
		if part then
			table.insert(watches, part:GetAttributeChangedSignal("EggReady"):Connect(renderIfActive))
		end
	end
	CommandCard.show(OWNER, buildPage())
end

function EggPanel.hide()
	dropWatches()
	activeEggIds = {}
	CommandCard.hide(OWNER)
end

-- Re-render for affordability when the balance moves, like every other purchasing panel.
function EggPanel.refreshIfVisible()
	renderIfActive()
end

function EggPanel.isActive(): boolean
	return #activeEggIds > 0 and CommandCard.isOwner(OWNER)
end

return EggPanel
