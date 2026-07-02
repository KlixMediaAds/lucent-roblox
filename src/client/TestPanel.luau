--!strict
--[[
    TestPanel — command-card menu for the TEST building (a 4×4-tile "super bonfire").

    Selecting a TEST building opens a three-way menu on the command card:
      • UPGRADES  — two SEPARATE repeatable upgrades: SUPPLY (+capacity) and
                    SPAWN RATE (shorter summon interval). Each is purchased and
                    tracked independently (unlike the Bonfire's combined Empower).
      • UNITS     — the same unit grid as the Bonfire: pick which unit the building
                    auto-summons (sends SetTestType).
      • STRUCTURES— the Command Center build options (handed off to HUD's build page
                    via the showStructures callback, with a BACK slot to return here).

    Like the Bonfire, the TEST building auto-summons its chosen unit for free up to a
    capacity, on an interval. A slim BillboardGui progress bar on its base shows the
    summon countdown (driven by TestUpdate.progress).
]]

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))
local ViewportPreview   = require(script.Parent:WaitForChild("ViewportPreview"))
local CommandCard       = require(script.Parent:WaitForChild("CommandCard"))

local TestPanel   = {}
local localPlayer = Players.LocalPlayer
local C           = UILib.C
local OWNER       = "test"

-- ── Callbacks / deps ───────────────────────────────────────────────────────────
local networkRef:       any
local hasResearchFn:    ((string) -> boolean)?
local resourcesFn:      (() -> number)?
local showStructuresFn: ((backFn: () -> ()) -> ())?
local hideStructuresFn: (() -> ())?

-- ── State ────────────────────────────────────────────────────────────────────
local activeTestId: string? = nil
local view: string = "menu"            -- "menu" | "units" | "upgrades"
local structuresOpen = false

type TestState = {
	unitType:    string,
	supplyLevel: number,
	rateLevel:   number,
	capacity:    number,
	supplyCost:  number,
	rateCost:    number,
	progress:    number,
}
local testState: { [string]: TestState } = {}

local function stateFor(id: string): TestState
	local s = testState[id]
	if not s then
		s = { unitType = "Survivor", supplyLevel = 0, rateLevel = 0,
			capacity = Config.TEST_BASE_CAPACITY, supplyCost = Config.testSupplyCost(0),
			rateCost = Config.testRateCost(0), progress = 0 }
		testState[id] = s
	end
	return s
end

-- ── Unit definitions (mirrors DeployerPanel) ───────────────────────────────────
local PURPLE       = Color3.fromRGB(160,  80, 230)
local MEDIC_TEAL   = Color3.fromRGB( 50, 200, 160)
local HOWITZER_OLV = Color3.fromRGB(138, 168,  52)
local FOAM_BLUE    = Color3.fromRGB(160, 220, 255)
local UPGRADE_COLOR = Color3.fromRGB(232, 196, 120)  -- gold

type UnitDef = { key: string, label: string, icon: string, color: Color3 }
-- Snipers are NOT summoned here — they're a field upgrade on a selected Survivor.
local UNIT_DEFS: { UnitDef } = {
	{ key = "Survivor", label = "Survivor", icon = "⚔",  color = C.GREEN      },
	{ key = "Tank",     label = "Tank",     icon = "⬡",  color = C.BARRACKS   },
	{ key = "Howitzer", label = "Howitzer", icon = "💣", color = HOWITZER_OLV },
	{ key = "Elite",    label = "Elite",    icon = "★",  color = PURPLE       },
	{ key = "Medic",    label = "Medic",    icon = "✚",  color = MEDIC_TEAL   },
	{ key = "Foamer",   label = "Foamer",   icon = "🫧", color = FOAM_BLUE    },
}
local UNIT_COLOR: { [string]: Color3 } = {
	Survivor = C.GREEN, Tank = C.BARRACKS, Howitzer = HOWITZER_OLV,
	Elite = PURPLE, Medic = MEDIC_TEAL, Foamer = FOAM_BLUE,
}
local RESEARCH_GATE: { [string]: string } = { Elite = "EliteUnits", Medic = "MedicUnit" }

-- ── World display (slim summon progress bar on the base) ───────────────────────
local testBillboards: { [string]: BillboardGui } = {}

local function getTestBase(id: string): BasePart?
	local bf    = workspace:FindFirstChild("Buildings") :: Folder?
	local model = bf and bf:FindFirstChild(id)
	return model and model:FindFirstChild("Base") :: BasePart?
end

local function destroyDisplay(id: string)
	local bb = testBillboards[id]
	if bb and bb.Parent then bb:Destroy() end
	testBillboards[id] = nil
end

local function updateWorldDisplay(id: string, unitType: string, progress: number)
	local base = getTestBase(id)
	if not base then destroyDisplay(id); return end

	local bb = testBillboards[id]
	if not bb or not bb.Parent then
		bb              = Instance.new("BillboardGui")
		bb.Name         = "TestDisplay"
		bb.Size         = UDim2.fromOffset(50, 6)
		bb.StudsOffset  = Vector3.new(0, base.Size.Y / 2 + 6, 0)
		bb.AlwaysOnTop  = false
		bb.MaxDistance  = 350
		bb.LightInfluence = 0
		bb.Parent       = base
		testBillboards[id] = bb

		local track                  = Instance.new("Frame")
		track.Name                   = "ProgTrack"
		track.Size                   = UDim2.new(1, 0, 1, 0)
		track.BackgroundColor3       = Color3.fromRGB(20, 22, 28)
		track.BackgroundTransparency = 0.3
		track.BorderSizePixel        = 0
		track.Parent                 = bb
		local ptc = Instance.new("UICorner"); ptc.CornerRadius = UDim.new(1, 0); ptc.Parent = track
		local pts = Instance.new("UIStroke"); pts.Color = Color3.fromRGB(0, 0, 0); pts.Thickness = 1; pts.Transparency = 0.35; pts.Parent = track

		local fill                   = Instance.new("Frame")
		fill.Name                    = "Fill"
		fill.Size                    = UDim2.new(0, 0, 1, 0)
		fill.BackgroundColor3        = PURPLE
		fill.BorderSizePixel         = 0
		fill.Parent                  = track
		local pfc = Instance.new("UICorner"); pfc.CornerRadius = UDim.new(1, 0); pfc.Parent = fill

		base.Destroying:Connect(function() destroyDisplay(id) end)
	end

	local track = bb:FindFirstChild("ProgTrack") :: Frame?
	local fill  = track and track:FindFirstChild("Fill") :: Frame?
	if fill then
		fill.Size             = UDim2.new(math.clamp(progress, 0, 1), 0, 1, 0)
		fill.BackgroundColor3 = UNIT_COLOR[unitType] or PURPLE
	end
end

-- ── Pages ──────────────────────────────────────────────────────────────────────
local renderIfActive: () -> ()

local function backSlot(): CommandCard.Slot
	return {
		index   = 9,
		name    = "BACK",
		color   = Color3.fromRGB(150, 160, 178),
		icon    = "←",
		desc    = "Return to the TEST menu",
		onClick = function() TestPanel.showMenu() end,
	}
end

local function buildMenuPage(): CommandCard.Page
	local slots: { CommandCard.Slot } = {
		{
			index = 1, name = "UPGRADES", color = UPGRADE_COLOR, icon = "✦",
			desc = "Supply & spawn-rate upgrades",
			onClick = function() view = "upgrades"; renderIfActive() end,
		},
		{
			index = 2, name = "UNITS", color = PURPLE, icon = "⚔",
			desc = "Pick which unit this building auto-summons",
			onClick = function() view = "units"; renderIfActive() end,
		},
		{
			index = 3, name = "STRUCTURES", color = C.ACCENT, icon = "🏛",
			desc = "Command Center build options",
			onClick = function()
				if not showStructuresFn then return end
				structuresOpen = true
				showStructuresFn(function() TestPanel.showMenu() end)
			end,
		},
	}
	return { header = "TEST", slots = slots }
end

local function buildUnitsPage(): CommandCard.Page
	local current = activeTestId and stateFor(activeTestId).unitType or "Survivor"
	local slots: { CommandCard.Slot } = {}
	for i, def in UNIT_DEFS do
		local key    = def.key
		local gate   = RESEARCH_GATE[key]
		local locked = gate ~= nil and not (hasResearchFn and hasResearchFn(gate))
		table.insert(slots, {
			index           = i,
			name            = key:upper(),
			color           = def.color,
			locked          = locked,
			icon            = def.icon,
			viewportKey     = "unit:" .. key,
			viewportFactory = function() return ViewportPreview.forUnit(key, Vector2.new(64, 64)) end,
			badge           = (key == current) and "✓" or nil,
			desc            = locked and "Locked — research required" or ("Summon " .. key),
			onClick         = function()
				if locked then return end
				if activeTestId then networkRef.setTestType(activeTestId, key) end
			end,
		})
	end
	table.insert(slots, backSlot())
	return { header = "TEST · UNITS", slots = slots }
end

local function buildUpgradesPage(): CommandCard.Page
	local s   = activeTestId and stateFor(activeTestId) or stateFor("_")
	local res = resourcesFn and resourcesFn() or 0

	local supplyMaxed = s.supplyLevel >= Config.TEST_SUPPLY_MAX_LEVEL
	local rateMaxed   = s.rateLevel   >= Config.TEST_RATE_MAX_LEVEL

	local slots: { CommandCard.Slot } = {
		{
			index           = 1,
			name            = "SUPPLY",
			color           = UPGRADE_COLOR,
			cost            = (not supplyMaxed) and s.supplyCost or nil,
			enabled         = (not supplyMaxed) and res >= s.supplyCost,
			locked          = supplyMaxed,
			icon            = "▦",
			desc            = supplyMaxed
				and ("Max supply — capacity " .. s.capacity)
				or  ("Capacity " .. s.capacity .. " → " .. (s.capacity + Config.TEST_SUPPLY_CAP_STEP)),
			onClick         = function()
				if supplyMaxed or not activeTestId then return end
				networkRef.upgradeTest(activeTestId, "supply")
			end,
		},
		{
			index           = 2,
			name            = "SPAWN RATE",
			color           = Color3.fromRGB(120, 224, 255),
			cost            = (not rateMaxed) and s.rateCost or nil,
			enabled         = (not rateMaxed) and res >= s.rateCost,
			locked          = rateMaxed,
			icon            = "⏱",
			desc            = rateMaxed
				and ("Max spawn rate — interval " .. string.format("%.1fs", Config.testInterval(s.rateLevel)))
				or  ("Faster summons (interval "
					.. string.format("%.1fs → %.1fs", Config.testInterval(s.rateLevel), Config.testInterval(s.rateLevel + 1)) .. ")"),
			onClick         = function()
				if rateMaxed or not activeTestId then return end
				networkRef.upgradeTest(activeTestId, "rate")
			end,
		},
		backSlot(),
	}
	return { header = "TEST · UPGRADES", slots = slots }
end

local function buildPage(): CommandCard.Page
	if view == "units" then
		return buildUnitsPage()
	elseif view == "upgrades" then
		return buildUpgradesPage()
	end
	return buildMenuPage()
end

renderIfActive = function()
	if activeTestId and CommandCard.isOwner(OWNER) then
		CommandCard.update(OWNER, buildPage())
	end
end

-- ── Init ──────────────────────────────────────────────────────────────────────
function TestPanel.init(network, hasResearch, getResources, showStructures, hideStructures)
	networkRef       = network
	hasResearchFn    = hasResearch
	resourcesFn      = getResources
	showStructuresFn = showStructures
	hideStructuresFn = hideStructures

	network.onTestUpdate(function(id, unitType, progress, supplyLevel, rateLevel, capacity, supplyCost, rateCost, _justUpgraded)
		local s = stateFor(id)
		s.unitType    = unitType
		s.progress    = progress
		s.supplyLevel = supplyLevel
		s.rateLevel   = rateLevel
		s.capacity    = capacity
		s.supplyCost  = supplyCost
		s.rateCost    = rateCost
		updateWorldDisplay(id, unitType, progress)
		if id == activeTestId then renderIfActive() end
	end)
end

-- ── Public API ──────────────────────────────────────────────────────────────
function TestPanel.show(id: string)
	activeTestId   = id
	view           = "menu"
	structuresOpen = false
	CommandCard.show(OWNER, buildPage())
end

-- Re-show the top-level menu (used by the BACK slots, incl. from STRUCTURES).
function TestPanel.showMenu()
	if not activeTestId then return end
	if structuresOpen and hideStructuresFn then hideStructuresFn() end
	structuresOpen = false
	view           = "menu"
	CommandCard.show(OWNER, buildPage())
end

function TestPanel.hide()
	if structuresOpen and hideStructuresFn then hideStructuresFn() end
	structuresOpen = false
	activeTestId   = nil
	view           = "menu"
	CommandCard.hide(OWNER)
end

function TestPanel.refreshIfVisible()
	renderIfActive()
end

function TestPanel.isVisible(): boolean
	return activeTestId ~= nil and CommandCard.isOwner(OWNER)
end

return TestPanel
