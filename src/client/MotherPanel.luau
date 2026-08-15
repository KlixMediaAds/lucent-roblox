--!strict
--[[
    MotherPanel: command-card page for the Hollowed "Mother" (their spike Command
    Center). It is the Hollowed player's default card: init.client feeds it to the
    command card as the fallback page, so it sits open whenever nothing is selected.

    The grid holds ONE action, a single button filling the whole frame (cols = 1):

        INJECT   → [R], or the tile: pick a point on the ground; the Mother walks over (uprooting
                   herself if she was rooted), drives her spike in, and three plants
                   rise out of the wound. She roots back down afterwards. Holding [Shift]
                   on the pick queues it, so a whole run of wounds can be laid out at once.

    The panel only sends intent. The walk, the injection and the plants are all
    server-authoritative (Network.injectGround). Aiming lives in MotherInject, which
    init.client hooks up through MotherPanel.onInject.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local CommandCard       = require(script.Parent:WaitForChild("CommandCard"))

local MotherPanel = {}
local OWNER       = "mother"

-- ── State ─────────────────────────────────────────────────────────────────────
local activeCCId:  string? = nil
local resourcesFn: (() -> number)?
local injectFn:    ((string) -> ())? = nil
local isAiming     = false

-- ── Colours ───────────────────────────────────────────────────────────────────
local INJECT_COL = Color3.fromRGB(196,  90, 255)

-- ── Page builder ────────────────────────────────────────────────────────────────
local function buildPage(): CommandCard.Page
	local cost    = Config.MOTHER_INJECT_COST
	local res     = resourcesFn and resourcesFn() or 0
	local canPay  = cost <= 0 or res >= cost

	local slot: CommandCard.Slot = {
		index   = 1,
		name    = isAiming and "INJECT (PICK A SPOT)" or "INJECT",
		label   = isAiming and "PICK A SPOT" or "INJECT",
		icon    = "⬇",
		hotkey  = "R",
		color   = INJECT_COL,
		cost    = cost > 0 and cost or nil,
		enabled = canPay,
		desc    = isAiming
			and "Click the ground to send her. Hold [Shift] to queue several. Right-click or [Esc] to call it off."
			or ("Pick a point on the ground. The Mother walks to it, sinks her spike in, and "
				.. Config.MOTHER_INJECT_PLANTS .. " plants tear their way up out of the soil. "
				.. "Aim at a plant she has already grown and it bursts instead, giving up "
				.. "what it was growing."),
		onClick = function() MotherPanel.triggerInject() end,
	}

	-- cols = 1 → one tile that fills the whole grid frame.
	return { header = "MOTHER", slots = { slot }, cols = 1 }
end

local function renderIfActive()
	if activeCCId and CommandCard.isOwner(OWNER) then
		CommandCard.update(OWNER, buildPage())
	end
end

-- ── Public API ────────────────────────────────────────────────────────────────
-- `network` is unused: the injection request goes out through MotherInject, which owns
-- the ground-targeting mode. Kept in the signature so the wiring in init.client reads
-- like every other panel's.
function MotherPanel.init(_network: any, getResources: () -> number)
	resourcesFn = getResources
end

-- Called when the player presses INJECT. init.client hands this to MotherInject,
-- which runs the ground-targeting mode.
function MotherPanel.onInject(fn: (ccId: string) -> ())
	injectFn = fn
end

-- Arms the injection, exactly as clicking the tile would. Shared with the [R] hotkey
-- in init.client, so the key and the tile cannot drift apart on cost or state checks.
function MotherPanel.triggerInject()
	if not activeCCId then return end
	local cost = Config.MOTHER_INJECT_COST
	local res  = resourcesFn and resourcesFn() or 0
	if cost > 0 and res < cost then return end
	if injectFn then injectFn(activeCCId :: string) end
end

function MotherPanel.show(ccId: string)
	activeCCId = ccId
	CommandCard.show(OWNER, buildPage())
end

function MotherPanel.hide()
	activeCCId = nil
	CommandCard.hide(OWNER)
end

-- Flips the button to its "waiting for you to click the ground" face.
function MotherPanel.setAiming(aiming: boolean)
	if isAiming == aiming then return end
	isAiming = aiming
	renderIfActive()
end

function MotherPanel.refreshIfVisible()
	renderIfActive()
end

function MotherPanel.isVisible(): boolean
	return activeCCId ~= nil and CommandCard.isOwner(OWNER)
end

return MotherPanel
