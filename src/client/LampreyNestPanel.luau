--!strict
--[[
    LampreyNestPanel — Command-card page for the Lamprey Nest building.

    Product slots: Lamprey / Hagfish / Broodmother. Each click pays that unit's egg
    cost and asks the server to birth one egg (server caps concurrent eggs at
    LAMPREY_NEST_MAX_EGGS, shared across all). A fourth slot is the one-time "Launcher"
    rally upgrade. Eggs are real parts parented to the nest model, counted directly
    off the replicated model; the header shows the live egg count.
]]

local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))
local ViewportPreview   = require(script.Parent:WaitForChild("ViewportPreview"))
local CommandCard       = require(script.Parent:WaitForChild("CommandCard"))

local LampreyNestPanel = {}
local C                = UILib.C
local OWNER            = "nest"

-- ── State ─────────────────────────────────────────────────────────────────────
local activeNestId:  string? = nil
local networkRef:    any
local getResources:  (() -> number)?
local getMultiIdsFn: (() -> {string})?

local LAMPREY_GRN = Color3.fromRGB(120, 190, 60)
local HAGFISH_PUR = Color3.fromRGB(170, 70, 130)
local BROOD_VIO   = Color3.fromRGB(150, 90, 230)
local RALLY_COL   = Color3.fromRGB(220, 150, 60)

type ProductDef = { unitType: string, cost: number, color: Color3, emoji: string }
local PRODUCTS: { ProductDef } = {
	{ unitType = "Lamprey",     cost = Config.LAMPREY_EGG_COST,     color = LAMPREY_GRN, emoji = "🪱" },
	{ unitType = "Hagfish",     cost = Config.HAGFISH_EGG_COST,     color = HAGFISH_PUR, emoji = "🐍" },
	{ unitType = "Broodmother", cost = Config.BROODMOTHER_EGG_COST, color = BROOD_VIO,   emoji = "🦑" },
}

-- True once the rally launcher has been bought (read off a replicated model attribute)
local function nestHasRally(nestId: string?): boolean
	if not nestId then return false end
	local bf    = workspace:FindFirstChild("Buildings") :: Folder?
	local model = bf and bf:FindFirstChild(nestId)
	return model ~= nil and model:GetAttribute("RallyUpgrade") == true
end
LampreyNestPanel.nestHasRally = nestHasRally

-- ── Egg counting (off the replicated nest model) ───────────────────────────────
local function eggCount(nestId: string): number
	local bf    = workspace:FindFirstChild("Buildings") :: Folder?
	local model = bf and bf:FindFirstChild(nestId)
	if not model then return 0 end
	local n = 0
	for _, child in model:GetChildren() do
		if child:IsA("BasePart") and child.Name:match("^Egg_") then n += 1 end
	end
	return n
end

-- ── Page builder ────────────────────────────────────────────────────────────────
local function buildPage(): CommandCard.Page
	local res   = getResources and getResources() or 0
	local count = activeNestId and eggCount(activeNestId) or 0
	local full  = count >= Config.LAMPREY_NEST_MAX_EGGS

	local slots: { CommandCard.Slot } = {}
	for i, def in PRODUCTS do
		local ut = def.unitType
		table.insert(slots, {
			index           = i,
			name            = ut:upper(),
			cost            = def.cost,
			color           = def.color,
			locked          = full,
			enabled         = res >= def.cost,
			icon            = def.emoji,
			viewportKey     = "unit:" .. ut,
			viewportFactory = function() return ViewportPreview.forUnit(ut, Vector2.new(64, 64)) end,
			desc            = full and "Nest is full" or ("Lay a " .. ut .. " egg"),
			onClick         = function()
				if not activeNestId or full or res < def.cost then return end
				local ids = getMultiIdsFn and getMultiIdsFn() or { activeNestId }
				networkRef.lampreyEgg(ids, ut)
			end,
		})
	end

	-- Launcher rally upgrade (one-time)
	local owned   = nestHasRally(activeNestId)
	local rallyOk = res >= Config.LAMPREY_NEST_RALLY_COST
	table.insert(slots, {
		index   = 4,
		name    = "LAUNCHER",
		cost    = owned and nil or Config.LAMPREY_NEST_RALLY_COST,
		color   = RALLY_COL,
		locked  = owned,
		enabled = rallyOk,
		icon    = "🎯",
		badge   = owned and "✓" or nil,
		desc    = owned and "Owned — right-click to set rally" or "Launch eggs to a rally point",
		onClick = function()
			if not activeNestId or owned or not rallyOk then return end
			local ids = getMultiIdsFn and getMultiIdsFn() or { activeNestId }
			networkRef.upgradeNest(ids)
		end,
	})

	return { header = "NEST  ·  Eggs " .. count .. "/" .. Config.LAMPREY_NEST_MAX_EGGS, slots = slots }
end

local function renderIfActive()
	if activeNestId and CommandCard.isOwner(OWNER) then
		CommandCard.update(OWNER, buildPage())
	end
end

-- Heartbeat refresh while open (egg counts change as eggs are laid / hatch).
local refreshConn: RBXScriptConnection?
local function startRefreshLoop()
	if refreshConn then refreshConn:Disconnect() end
	refreshConn = RunService.Heartbeat:Connect(function()
		if not (activeNestId and CommandCard.isOwner(OWNER)) then
			if refreshConn then refreshConn:Disconnect(); refreshConn = nil end
			return
		end
		renderIfActive()
	end)
end

-- ── Init ──────────────────────────────────────────────────────────────────────
function LampreyNestPanel.init(network: any, getResourcesFn: () -> number, getMultiIds: (() -> {string})?)
	networkRef    = network
	getResources  = getResourcesFn
	getMultiIdsFn = getMultiIds
end

-- ── Public API ────────────────────────────────────────────────────────────────
function LampreyNestPanel.show(nestId: string)
	activeNestId = nestId
	CommandCard.show(OWNER, buildPage())
	startRefreshLoop()

	-- Auto-close if the nest is destroyed
	task.spawn(function()
		local bf = workspace:WaitForChild("Buildings", 10) :: Folder?
		if not bf then return end
		local model = bf:WaitForChild(nestId, 10)
		if not model then return end
		local base = model:FindFirstChild("Base") :: BasePart?
		if not base then return end
		local conn: RBXScriptConnection
		conn = base.Destroying:Connect(function()
			conn:Disconnect()
			if activeNestId == nestId then
				LampreyNestPanel.hide()
			end
		end)
	end)
end

function LampreyNestPanel.hide()
	activeNestId = nil
	CommandCard.hide(OWNER)
end

function LampreyNestPanel.refreshIfVisible()
	renderIfActive()
end

return LampreyNestPanel
