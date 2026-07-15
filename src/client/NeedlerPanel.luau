--!strict
--[[
    NeedlerPanel — command-card menu shown when one or more owned Needlers are selected.
    Renders as a 2×2 tile grid (the Hollowed unit style).

    A Needler can fuse with a nearby owned Needler, stacking their bodies into one (up to
    Config.NEEDLER_MERGE_MAX). The panel offers a single action:

        MERGE — each selected Needler folds in its nearest owned Needler within range.

    The merge is refused server-side if the two stacks together would exceed the cap, so a
    stack that is already full (or has no small-enough partner nearby) shows the button
    locked. Stack sizes are read live from the server-set "NeedlerCount" attribute on each
    Needler's pivot part, so the card updates the instant a merge lands.
]]

local Players     = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config      = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local CommandCard = require(script.Parent:WaitForChild("CommandCard"))

local NeedlerPanel = {}
local OWNER        = "needler"
local localPlayer  = Players.LocalPlayer

local MERGE_COL = Color3.fromRGB(190, 120, 70)

-- ── State ─────────────────────────────────────────────────────────────────────
local activeIds:  { string } = {}
local networkRef: any
local attrConns:  { RBXScriptConnection } = {}

function NeedlerPanel.init(network: any)
	networkRef = network
end

-- ── Helpers ─────────────────────────────────────────────────────────────────────
local function unitsFolder(): Folder?
	return workspace:FindFirstChild("Units") :: Folder?
end

local function unitPart(id: string): BasePart?
	local uf = unitsFolder()
	return uf and uf:FindFirstChild(id) :: BasePart?
end

local function stackOf(part: BasePart): number
	return (part:GetAttribute("NeedlerCount") :: number?) or 1
end

-- Is there any OTHER owned Needler within range of `part` small enough to fold in?
local function hasMergePartner(part: BasePart, myCount: number): boolean
	if myCount >= Config.NEEDLER_MERGE_MAX then return false end
	local uf = unitsFolder()
	if not uf then return false end
	local myStr = tostring(localPlayer.UserId)
	local pos   = part.Position
	for _, other in uf:GetChildren() do
		if other == part or not other:IsA("BasePart") then continue end
		local tv = other:FindFirstChild("UnitType") :: StringValue?
		local ov = other:FindFirstChild("OwnerId")  :: StringValue?
		if not tv or tv.Value ~= "Needler" then continue end
		if not ov or ov.Value ~= myStr then continue end
		if myCount + stackOf(other) > Config.NEEDLER_MERGE_MAX then continue end
		if (other.Position - pos).Magnitude <= Config.NEEDLER_MERGE_RANGE then
			return true
		end
	end
	return false
end

local function renderIfActive()
	if #activeIds > 0 and CommandCard.isOwner(OWNER) then
		CommandCard.update(OWNER, NeedlerPanel._buildPage())
	end
end

-- ── Command-card page ───────────────────────────────────────────────────────────
function NeedlerPanel._buildPage(): CommandCard.Page
	local n = #activeIds

	-- Enable MERGE if at least one selected Needler has a legal partner nearby.
	local canMerge = false
	local maxStack = 1
	for _, id in activeIds do
		local part = unitPart(id)
		if part then
			local c = stackOf(part)
			maxStack = math.max(maxStack, c)
			if hasMergePartner(part, c) then canMerge = true end
		end
	end

	local desc
	if canMerge then
		desc = "Fold the nearest friendly Needler within range into this body, stacking their arms into one larger creature (up to " .. Config.NEEDLER_MERGE_MAX .. ")."
	elseif maxStack >= Config.NEEDLER_MERGE_MAX then
		desc = "This body is already at full size (" .. Config.NEEDLER_MERGE_MAX .. ")."
	else
		desc = "No friendly Needler small enough is in range to merge with."
	end

	local slots: { CommandCard.Slot } = {
		{
			index   = 1,
			name    = "MERGE",
			icon    = "🕷",
			color   = MERGE_COL,
			enabled = canMerge,
			locked  = not canMerge,
			desc    = desc,
			onClick = function()
				for _, id in activeIds do networkRef.mergeNeedler(id) end
			end,
		},
	}

	local header = (n > 1) and ("NEEDLERS ×" .. n) or ("NEEDLER  ×" .. maxStack)
	return { header = header, slots = slots, cols = 2 }
end

local function clearConns()
	for _, c in attrConns do c:Disconnect() end
	table.clear(attrConns)
end

-- ── Public API ────────────────────────────────────────────────────────────────
function NeedlerPanel.show(ids: { string })
	activeIds = ids
	clearConns()
	-- Re-render live as any selected Needler's stack size changes (after a merge).
	for _, id in ids do
		local part = unitPart(id)
		if part then
			table.insert(attrConns, part:GetAttributeChangedSignal("NeedlerCount"):Connect(renderIfActive))
		end
	end
	CommandCard.show(OWNER, NeedlerPanel._buildPage())
end

function NeedlerPanel.hide()
	activeIds = {}
	clearConns()
	CommandCard.hide(OWNER)
end

function NeedlerPanel.refreshIfVisible()
	renderIfActive()
end

function NeedlerPanel.isActive(): boolean
	return #activeIds > 0 and CommandCard.isOwner(OWNER)
end

return NeedlerPanel
