local Players          = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local GuiService       = game:GetService("GuiService")

local UnitController = {}

local localPlayer  = Players.LocalPlayer
local mouse        = localPlayer:GetMouse()
local selected: {string}  = {}
local knownUnits: {[string]: {part: BasePart, ownerId: number}} = {}
local knownBuildings: {[string]: {base: BasePart, ownerId: number, buildingType: string}} = {}
local selectionBoxes: {[string]: SelectionBox} = {}
local onChangedCb: ((number) -> ())?
local onBarracksSelectedCb: ((string?) -> ())?
local isBlockedFn: (() -> boolean)?
local dragFrame: Frame?

local dragStart  = Vector2.zero
local dragEnd    = Vector2.zero
local isDragging = false
local MIN_DRAG   = 8   -- pixels

local function syncSelectionBoxes()
	-- Remove boxes for units no longer selected
	local selectedSet: {[string]: boolean} = {}
	for _, id in selected do selectedSet[id] = true end

	for id, box in selectionBoxes do
		if not selectedSet[id] then
			box:Destroy()
			selectionBoxes[id] = nil
		end
	end

	-- Add boxes for newly selected units
	for _, id in selected do
		if selectionBoxes[id] then continue end
		local info = knownUnits[id]
		if not info or not info.part.Parent then continue end  -- stale / destroyed

		local box                  = Instance.new("SelectionBox")
		box.Adornee                = info.part
		box.Color3                 = Color3.fromRGB(0, 200, 255)
		box.LineThickness          = 0.06
		box.SurfaceTransparency    = 0.8
		box.SurfaceColor3          = Color3.fromRGB(0, 200, 255)
		box.Parent                 = workspace

		selectionBoxes[id] = box

		-- Clean up automatically if the unit is destroyed
		info.part.Destroying:Connect(function()
			local b = selectionBoxes[id]
			if b then b:Destroy(); selectionBoxes[id] = nil end
		end)
	end
end

local function notify()
	syncSelectionBoxes()
	if onChangedCb then onChangedCb(#selected) end
end

local function clearSelection()
	selected = {}
	notify()
end

local function addToSelection(id: string)
	for _, v in selected do if v == id then return end end
	table.insert(selected, id)
	notify()
end

local function hitUnit(): string?
	local ray    = mouse.UnitRay
	local result = workspace:Raycast(ray.Origin, ray.Direction * 2000)
	if not result then return nil end
	for id, info in knownUnits do
		if info.part == result.Instance and info.ownerId == localPlayer.UserId then
			return id
		end
	end
	return nil
end

local function hitBuilding(): string?
	local ray    = mouse.UnitRay
	local result = workspace:Raycast(ray.Origin, ray.Direction * 2000)
	if not result then return nil end
	for id, info in knownBuildings do
		if info.base == result.Instance and info.ownerId == localPlayer.UserId then
			return id
		end
	end
	return nil
end

local function boxSelect(x0: number, y0: number, x1: number, y1: number)
	selected = {}
	for id, info in knownUnits do
		if info.ownerId ~= localPlayer.UserId then continue end
		local sp = workspace.CurrentCamera:WorldToViewportPoint(info.part.Position)
		if sp.X >= x0 and sp.X <= x1 and sp.Y >= y0 and sp.Y <= y1 and sp.Z > 0 then
			table.insert(selected, id)
		end
	end
	notify()
end

function UnitController.init(network, cameraModule, frame: Frame, isBlocked: () -> boolean)
	dragFrame    = frame
	isBlockedFn  = isBlocked

	-- Track all replicated units; auto-clean when a unit is destroyed
	network.onUnitSpawned(function(id: string, ownerId: number, _pos: Vector3)
		task.spawn(function()
			local folder = workspace:WaitForChild("Units", 10)
			if not folder then return end
			local part = folder:WaitForChild(id, 10) :: BasePart
			if not part then return end
			knownUnits[id] = { part = part, ownerId = ownerId }

			part.Destroying:Connect(function()
				knownUnits[id] = nil
				-- Remove from active selection
				for i = #selected, 1, -1 do
					if selected[i] == id then table.remove(selected, i); break end
				end
				-- Clean up SelectionBox
				local box = selectionBoxes[id]
				if box then box:Destroy(); selectionBoxes[id] = nil end
				notify()
			end)
		end)
	end)

	-- Track all replicated buildings for click detection
	network.onBuildingPlaced(function(id: string, ownerId: number, _pos: Vector3, buildingType: string)
		task.spawn(function()
			local folder = workspace:WaitForChild("Buildings", 10)
			if not folder then return end
			local model = folder:WaitForChild(id, 10)
			if not model then return end
			local base = model:WaitForChild("Base", 5) :: BasePart
			if not base then return end
			knownBuildings[id] = { base = base, ownerId = ownerId, buildingType = buildingType or "Barracks" }
		end)
	end)

	-- Input
	UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe then return end

		-- F2: select all owned living units (works even during building placement)
		if input.KeyCode == Enum.KeyCode.F2 then
			selected = {}
			for id, info in knownUnits do
				if info.ownerId == localPlayer.UserId and info.part.Parent then
					table.insert(selected, id)
				end
			end
			notify()
			if onBarracksSelectedCb then onBarracksSelectedCb(nil) end
			return
		end

		if isBlockedFn and isBlockedFn() then return end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragStart  = UserInputService:GetMouseLocation()
			dragEnd    = dragStart
			isDragging = true

		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			if #selected == 0 then return end
			local ground = cameraModule.getGroundPosition()
			if ground then network.moveUnits(selected, ground) end

		elseif input.KeyCode == Enum.KeyCode.Escape then
			if onBarracksSelectedCb then onBarracksSelectedCb(nil) end
		end
	end)

	-- Mouse move: update drag box
	UserInputService.InputChanged:Connect(function(input)
		if not isDragging then return end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
		dragEnd = UserInputService:GetMouseLocation()
		local d = dragEnd - dragStart
		if math.abs(d.X) > MIN_DRAG or math.abs(d.Y) > MIN_DRAG then
			if dragFrame then
				-- GetMouseLocation() is in raw viewport space; ScreenGui positions
				-- are offset by the GUI inset (top bar), so subtract it.
				local inset = GuiService:GetGuiInset()
				local x0 = math.min(dragStart.X, dragEnd.X) - inset.X
				local y0 = math.min(dragStart.Y, dragEnd.Y) - inset.Y
				dragFrame.Position = UDim2.fromOffset(x0, y0)
				dragFrame.Size     = UDim2.fromOffset(math.abs(d.X), math.abs(d.Y))
				dragFrame.Visible  = true
			end
		end
	end)

	-- LMB up: finalise selection
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		if not isDragging then return end
		isDragging = false
		if dragFrame then dragFrame.Visible = false end
		if isBlockedFn and isBlockedFn() then return end

		local d = dragEnd - dragStart
		if math.abs(d.X) > MIN_DRAG or math.abs(d.Y) > MIN_DRAG then
			-- Box select
			clearSelection()
			boxSelect(
				math.min(dragStart.X, dragEnd.X), math.min(dragStart.Y, dragEnd.Y),
				math.max(dragStart.X, dragEnd.X), math.max(dragStart.Y, dragEnd.Y)
			)
			if onBarracksSelectedCb then onBarracksSelectedCb(nil) end
		else
			-- Single click — check unit first, then barracks
			local uid = hitUnit()
			if uid then
				if not UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then clearSelection() end
				addToSelection(uid)
				if onBarracksSelectedCb then onBarracksSelectedCb(nil) end
			else
				local bid = hitBuilding()
				if bid then
					clearSelection()
					local info = knownBuildings[bid]
					if info and info.buildingType == "Barracks" then
						if onBarracksSelectedCb then onBarracksSelectedCb(bid) end
					else
						if onBarracksSelectedCb then onBarracksSelectedCb(nil) end
					end
				else
					clearSelection()
					if onBarracksSelectedCb then onBarracksSelectedCb(nil) end
				end
			end
		end
	end)
end

function UnitController.getSelected(): {string}
	return selected
end

function UnitController.onSelectionChanged(fn: (number) -> ())
	onChangedCb = fn
end

function UnitController.onBarracksSelected(fn: (string?) -> ())
	onBarracksSelectedCb = fn
end

return UnitController
