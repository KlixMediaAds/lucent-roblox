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

    The tile's face is a 3D viewport, not a glyph: at rest it is a close-up of the
    Mother's own head. While the sight is up and hovering one of her plants, it swaps to
    a preview of what injecting that plant would give (a Leech, an egg nest), so the
    yield is seen and not just read. MotherInject pushes those hovers in via setHover.

    The panel only sends intent. The walk, the injection and the plants are all
    server-authoritative (Network.injectGround). Aiming lives in MotherInject, which
    init.client hooks up through MotherPanel.onInject.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local CommandCard       = require(script.Parent:WaitForChild("CommandCard"))
local ViewportPreview   = require(script.Parent:WaitForChild("ViewportPreview"))

local MotherPanel = {}
local OWNER       = "mother"

-- ── State ─────────────────────────────────────────────────────────────────────
local activeCCId:  string? = nil
local resourcesFn: (() -> number)?
local injectFn:    ((string) -> ())? = nil
local isAiming     = false

-- What the tile's viewport is showing. nil = the Mother's own face (the resting look);
-- otherwise the InjectPlants `preview` name of whatever the sight is currently over, so
-- the tile turns into a picture of what that plant would become. MotherInject pushes this
-- through setHover while aiming.
local hoverPreview: string? = nil

-- ── Colours ───────────────────────────────────────────────────────────────────
local INJECT_COL = Color3.fromRGB(196,  90, 255)

-- ── Tile face ─────────────────────────────────────────────────────────────────
-- The 3D thumbnails the one tile can wear. The resting face is a close-up of the
-- Mother's head; each other entry is what an injectable plant under the sight would turn
-- into, keyed by the `preview` name on its InjectPlants.INJECT row.
local VP_PX = Vector2.new(64, 64)   -- the card rescales it to the tile; this is the build size
local PREVIEWS: { [string]: () -> ViewportFrame } = {
	leech = function() return ViewportPreview.forLeech(false, VP_PX) end,
	nest  = function() return ViewportPreview.forEggSacNest(VP_PX) end,
	gland = function() return ViewportPreview.forGland(VP_PX) end,
}

-- viewportKey + factory for the face the tile should be wearing right now. The command
-- card caches viewports by key, so swapping faces on hover costs nothing after the first
-- build of each.
local function tileFace(): (string, () -> ViewportFrame)
	local factory = hoverPreview and PREVIEWS[hoverPreview]
	if factory then
		return "mother:inject:" .. (hoverPreview :: string), factory
	end
	return "mother:head", function() return ViewportPreview.forMotherHead(VP_PX) end
end

-- ── Spike cooldown ────────────────────────────────────────────────────────────
-- Injecting is free; what limits it is the spike's cooldown. The server stamps the
-- moment it is next usable on the Mother's base as "InjectReadyAt", on the shared
-- workspace:GetServerTimeNow() clock, so this side needs nothing but the attribute.
local function ccBase(): BasePart?
	if not activeCCId then return nil end
	local folder = workspace:FindFirstChild("Buildings")
	local model  = folder and folder:FindFirstChild(activeCCId :: string)
	return model and model:FindFirstChild("Base") :: BasePart? or nil
end

local function injectReadyAt(): number
	local base = ccBase()
	local v    = base and base:GetAttribute("InjectReadyAt")
	return type(v) == "number" and v or 0
end

local function injectCooldownLeft(): number
	return math.max(0, injectReadyAt() - workspace:GetServerTimeNow())
end

-- How long her spike's window currently IS, which Spike Glands shorten. The server
-- restates it on the base whenever the gland count moves, so this is always the real
-- number; the Config default only stands in before the first one is published.
local function injectCooldownLength(): number
	local base = ccBase()
	local v    = base and base:GetAttribute("InjectCooldown")
	return type(v) == "number" and v or Config.MOTHER_INJECT_COOLDOWN
end

-- Is she already on her way to (or standing over) a wound? The cooldown does not start
-- until the spike actually goes in, so without this the tile would read as idle for the
-- whole walk. Pressing it during that re-aims her rather than ordering a second wound,
-- and the tile says so.
local function injectBusy(): boolean
	local base = ccBase()
	return base ~= nil and base:GetAttribute("InjectBusy") == true
end

-- ── Page builder ────────────────────────────────────────────────────────────────
local function buildPage(): CommandCard.Page
	local cost    = Config.MOTHER_INJECT_COST
	local res     = resourcesFn and resourcesFn() or 0
	local canPay  = cost <= 0 or res >= cost
	local readyAt = injectReadyAt()
	local onCd    = readyAt > workspace:GetServerTimeNow()
	local cdLen   = injectCooldownLength()
	local cdText  = string.format("%.3g", cdLen)
	-- `working` = an order is in flight: she is walking to a wound, standing over one, or
	-- waiting out the clock partway through a queued run. The server accepts a press in
	-- that state (it re-aims her, or stacks another spot behind the run), so the tile has
	-- to stay pressable through it -- the cooldown alone only blocks a FRESH injection.
	local working = injectBusy()
	local busy    = working and not onCd

	local vpKey, vpFactory = tileFace()

	local slot: CommandCard.Slot = {
		index   = 1,
		name    = isAiming and "INJECT (PICK A SPOT)"
			or (busy and "INJECT (ON HER WAY)" or "INJECT"),
		label   = isAiming and "PICK A SPOT"
			or (busy and "ON HER WAY" or "INJECT"),
		viewportKey     = vpKey,
		viewportFactory = vpFactory,
		hotkey  = "R",
		color   = INJECT_COL,
		cost    = cost > 0 and cost or nil,
		enabled = canPay and (working or not onCd),
		-- The card runs the countdown itself off this window, so a ticking cooldown costs
		-- no re-renders here.
		cooldownUntil = onCd and readyAt or nil,
		cooldownTotal = cdLen,
		desc    = onCd
			and ("Her spike is spent. It takes " .. cdText
				.. " seconds to be ready to drive in again.")
			or (busy and not isAiming
			and ("She is walking to the spot. Her spike does not go on cooldown until it "
				.. "actually goes in. Press again to send her somewhere else instead.")
			or (isAiming
			and "Click the ground to send her. Hold [Shift] to queue several. Right-click or [Esc] to call it off."
			or ("Pick a point on the ground. The Mother walks to it, sinks her spike in, and "
				.. Config.MOTHER_INJECT_PLANTS .. " plants tear their way up out of the soil. "
				.. "Aim at a plant she has already grown and it bursts instead, giving up "
				.. "what it was growing. A frond gives a Spike Gland, and every gland "
				.. "standing cuts her cooldown by "
				.. math.floor(Config.GLAND_COOLDOWN_REDUCTION * 100 + 0.5) .. "%. "
				.. "Costs nothing; her spike needs " .. cdText .. " seconds between wounds."))),
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
	-- Exactly the server's refusal: the cooldown only blocks STARTING a run. With one
	-- already in flight the press re-aims her or adds to it, which is always allowed.
	if not injectBusy() and injectCooldownLeft() > 0 then return end
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
	-- Leaving targeting drops whatever the sight was over, so the tile goes back to
	-- wearing the Mother's face.
	if not aiming then hoverPreview = nil end
	renderIfActive()
end

-- What the targeting sight is currently over, as an InjectPlants `preview` name (nil for
-- bare ground, or for a plant with nothing to give yet). The tile turns into a picture of
-- what that plant would become, so the player sees the yield before paying for it.
-- MotherInject drives this while aiming.
function MotherPanel.setHover(preview: string?)
	if hoverPreview == preview then return end
	hoverPreview = preview
	renderIfActive()
end

-- The card animates a cooldown it has been given, but it cannot know when a NEW window
-- opens or when the tile becomes pressable again -- both change what buildPage produces.
-- Watching the replicated timestamp catches both, including a queued wound restarting the
-- clock while the tile is already dark, and costs one re-render per transition.
local shownReadyAt = 0
local shownOnCd    = false
local shownCdLen   = 0
local shownBusy    = false
RunService.Heartbeat:Connect(function()
	if not MotherPanel.isVisible() then return end
	local readyAt = injectReadyAt()
	local onCd    = readyAt > workspace:GetServerTimeNow()
	-- The window's LENGTH is watched too: raising or losing a Spike Gland moves it while
	-- nothing else about the tile changes, and the tooltip states the number. So is the
	-- busy flag, which is what the tile wears for the whole walk out to the wound.
	local cdLen   = injectCooldownLength()
	local busy    = injectBusy()
	if readyAt ~= shownReadyAt or onCd ~= shownOnCd
		or cdLen ~= shownCdLen or busy ~= shownBusy then
		shownReadyAt, shownOnCd, shownCdLen, shownBusy = readyAt, onCd, cdLen, busy
		renderIfActive()
	end
end)

function MotherPanel.refreshIfVisible()
	renderIfActive()
end

function MotherPanel.isVisible(): boolean
	return activeCCId ~= nil and CommandCard.isOwner(OWNER)
end

return MotherPanel
