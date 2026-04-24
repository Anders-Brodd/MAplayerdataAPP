--[=[ PATH: StarterPlayerScripts/RemovalClient | TYPE: LocalScript ]=]--
--[[
	🗑️ REMOVAL CLIENT V9 (SMART SELECTION)
	
	CHANGES:
	- ✅ DEEP SEARCH: Walks up the hierarchy to find the main "TwoPoint" lift model.
	- ✅ VISUALS: Keeps the tiny red cursor.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BuildStatusIndicator = require(ReplicatedStorage:WaitForChild("BuildStatusIndicator"))
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")

local Player = Players.LocalPlayer
local Mouse = Player:GetMouse()
local Events = ReplicatedStorage:WaitForChild("Events")
local RequestRemoveItem = Events:WaitForChild("RequestRemoveItem")
local RequestRemoveSlopeNet = Events:FindFirstChild("RequestRemoveSlopeNet")
local ClosePanels = Events:FindFirstChild("ClosePanels")
if not ClosePanels then
	ClosePanels = Instance.new("BindableEvent")
	ClosePanels.Name = "ClosePanels"
	ClosePanels.Parent = Events
end

-- // CONFIG //
local DELETE_ICON_ID = "rbxassetid://109195174097293" 
local ICON_SIZE = 20 

-- // UI FINDER //
local PlayerGui = Player:WaitForChild("PlayerGui")
local MainHUD = PlayerGui:WaitForChild("MainHUD")
local BuildFrame = MainHUD:WaitForChild("BuildFrame")

local DeleteButton = nil
local ToggleRemoveMode
local bindGuiButton
local BoundDeleteButtons = {}

local function isDeleteButtonInteractable(button)
	return button
		and button:IsA("GuiButton")
		and button.Visible
		and button.Active
		and button.AbsoluteSize.X > 0
		and button.AbsoluteSize.Y > 0
end

local function findActiveDeleteButton()
	local fallback = nil
	for _, desc in ipairs(MainHUD:GetDescendants()) do
		if desc:IsA("GuiButton") and (desc.Name == "Delete" or desc.Name == "Remove") then
			fallback = fallback or desc
			if isDeleteButtonInteractable(desc) then
				return desc
			end
		end
	end
	return fallback
end

local function bindDeleteButton(button)
	if not button or BoundDeleteButtons[button] then
		return
	end
	BoundDeleteButtons[button] = true
	bindGuiButton(button, function()
		local activeButton = findActiveDeleteButton()
		if activeButton and activeButton ~= button and isDeleteButtonInteractable(activeButton) then
			return
		end
		ToggleRemoveMode()
	end)
end

local function bindAvailableDeleteButtons()
	DeleteButton = findActiveDeleteButton()
	for _, desc in ipairs(MainHUD:GetDescendants()) do
		if desc:IsA("GuiButton") and (desc.Name == "Delete" or desc.Name == "Remove") then
			bindDeleteButton(desc)
		end
	end
end

DeleteButton = findActiveDeleteButton()

-- // CURSOR //
local CursorGui = PlayerGui:WaitForChild("RemovalCursor", 5)
local CursorImage = CursorGui and CursorGui:WaitForChild("CursorImage", 2)

-- // STATE //
local isRemoving = false
local isDragDeleteActive = false
local isDragging = false
local hoverSelectionBox = nil
local currentRemovalTarget = nil
local reopenBuildFrameOnExit = false
local deleteFeedbackToken = 0
local isGeneratedSlopeNet

local TARGET_REFRESH_INTERVAL = 1 / 30
local FALLBACK_SEARCH_INTERVAL = 0.12
local UUID_CACHE_REFRESH_INTERVAL = 0.75

local placedModelsByUUID = {}
local cachedPlacedRemovables = {}
local lastUuidCacheRefresh = 0
local lastFallbackSearchAt = 0
local lastFallbackAimPoint = Vector2.zero
local lastFallbackModel = nil
local lastTargetRefreshAt = 0

local function showDeleteFailure(message)
	deleteFeedbackToken += 1
	local token = deleteFeedbackToken
	BuildStatusIndicator.show(PlayerGui, tostring(message or "DELETE FAILED"))
	task.delay(1.5, function()
		if deleteFeedbackToken == token then
			BuildStatusIndicator.hide(PlayerGui)
		end
	end)
end

local function invokeRemovalRemote(model)
	if isGeneratedSlopeNet(model) and RequestRemoveSlopeNet then
		return pcall(function()
			return RequestRemoveSlopeNet:InvokeServer(model)
		end)
	end
	return pcall(function()
		return RequestRemoveItem:InvokeServer(model)
	end)
end

local function ensureHoverSelectionBox()
	if hoverSelectionBox and hoverSelectionBox.Parent then
		return hoverSelectionBox
	end

	hoverSelectionBox = Instance.new("SelectionBox")
	hoverSelectionBox.Name = "RemovalHoverSelection"
	hoverSelectionBox.Color3 = Color3.new(1, 0, 0)
	hoverSelectionBox.LineThickness = 0.1
	hoverSelectionBox.Parent = workspace
	return hoverSelectionBox
end

local POS_OPEN = UDim2.new(0.5, 0, 0.5, 0)
local POS_CLOSED = UDim2.new(0.5, 0, 1.5, 0)
local CONFIRM_HIDDEN = UDim2.new(0.5, 0, 1.5, 0)
local CONFIRM_SHOWN = UDim2.new(0.5, 0, 0.5, 0)
local CONFIRM_SHOW_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CONFIRM_HIDE_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

-- // MODE CONFLICT PREVENTION //
-- Create a shared state so Placement and Removal don't run together
local ModeState = PlayerGui:FindFirstChild("ModeState") or Instance.new("StringValue", PlayerGui)
ModeState.Name = "ModeState"
ModeState.Value = "" -- "", "Placing", "Removing"

local function IsMobileRemovalMode()
	if not UserInputService.TouchEnabled then return false end
	if not UserInputService.MouseEnabled or not UserInputService.KeyboardEnabled then return true end
	local camera = workspace.CurrentCamera
	if camera and camera.ViewportSize.X > 0 then
		return camera.ViewportSize.X <= 1366
	end
	return true
end

bindGuiButton = function(button, callback)
	if not button or not button:IsA("GuiButton") then
		return
	end
	button.Active = true
	button.Selectable = true
	button.AutoButtonColor = true
	button.Activated:Connect(callback)
end

local function GetRemovalAimScreenPosition()
	local camera = workspace.CurrentCamera
	if IsMobileRemovalMode() and camera then
		local viewport = camera.ViewportSize
		return Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)
	end
	local mousePos = UserInputService:GetMouseLocation()
	return Vector2.new(mousePos.X, mousePos.Y)
end

local function GetCursorGuiPosition(screenPoint)
	if not CursorGui or CursorGui.IgnoreGuiInset then
		return screenPoint
	end
	local insetTopLeft = GuiService:GetGuiInset()
	return screenPoint - insetTopLeft
end

-- // HELPER: Find Root Model //
local TREE_NAME_HINTS = {"tree", "pine", "spruce", "fir", "birch", "cedar", "oak", "snow"}

local function looksLikeNaturalTree(inst)
	if not inst or inst == workspace then return false end
	if inst.GetAttribute and inst:GetAttribute("UUID") then return false end
	if inst.GetAttribute and inst:GetAttribute("Type") == "Tree" then return true end
	local lowerName = string.lower(inst.Name)
	for _, pattern in ipairs(TREE_NAME_HINTS) do
		if string.find(lowerName, pattern, 1, true) then
			return true
		end
	end
	return false
end

isGeneratedSlopeNet = function(model)
	if not model or not model:IsA("Model") then return false end
	if model:GetAttribute("GeneratedSlopeNet") == true or model:GetAttribute("Type") == "SlopeNet" then
		return true
	end
	local parent = model.Parent
	return model.Name == "Net"
		and parent ~= nil
		and parent:IsA("Model")
		and (parent:GetAttribute("Type") == "Slope" or parent:GetAttribute("RawPoints") ~= nil)
end

local function isSlopeRootModel(model)
	if not model or not model:IsA("Model") then return false end
	return model:GetAttribute("Type") == "Slope"
		or model:GetAttribute("RawPoints") ~= nil
end

local function refreshRemovalCaches(force)
	local now = os.clock()
	if not force and (now - lastUuidCacheRefresh) < UUID_CACHE_REFRESH_INTERVAL then
		return
	end

	lastUuidCacheRefresh = now
	table.clear(placedModelsByUUID)
	table.clear(cachedPlacedRemovables)

	local placedFolder = workspace:FindFirstChild("PlacedObjects")
	if not placedFolder then
		return
	end

	for _, child in ipairs(placedFolder:GetChildren()) do
		if child:IsA("Model") then
			local uuid = child:GetAttribute("UUID")
			if type(uuid) == "string" and uuid ~= "" then
				placedModelsByUUID[uuid] = child
				table.insert(cachedPlacedRemovables, child)
			elseif isSlopeRootModel(child) or isGeneratedSlopeNet(child) then
				table.insert(cachedPlacedRemovables, child)
			end

			local slopeNet = child:FindFirstChild("Net")
			if slopeNet and slopeNet:IsA("Model") and isGeneratedSlopeNet(slopeNet) then
				table.insert(cachedPlacedRemovables, slopeNet)
			end
		end
	end
end

local function findPlacedModelByUUID(uuid)
	if type(uuid) ~= "string" or uuid == "" then
		return nil
	end

	refreshRemovalCaches(false)
	local cached = placedModelsByUUID[uuid]
	if cached and cached.Parent then
		return cached
	end

	refreshRemovalCaches(true)
	cached = placedModelsByUUID[uuid]
	if cached and cached.Parent then
		return cached
	end
	return nil
end

local function GetRemovableModel(part)
	if not part then return nil end
	local current = part
	local treeCandidate = nil

	-- 1. Check if it's a visual chair (Visual_UUID folder) or Queue ropes
	local currentParent = current.Parent
	if currentParent and (current.Name:match("Chair") or currentParent.Name:match("Visual_") or currentParent.Name:match("QueueRopes_")) then
		-- This is a client-side visual. We can't delete it directly.
		-- We need to find the server model.
		-- Trick: Visuals are usually named "Visual_[UUID]" or "QueueRopes_[UUID]".
		local visualFolder = currentParent
		if visualFolder.Name:match("Visual_") then
			local uuid = visualFolder.Name:gsub("Visual_", "")
			return findPlacedModelByUUID(uuid)
		elseif visualFolder.Name:match("QueueRopes_") then
			local uuid = visualFolder.Name:gsub("QueueRopes_", "")
			return findPlacedModelByUUID(uuid)
		end
	end

	-- 2. Walk up to find main model or a natural tree root.
	while current and current ~= workspace do
		if current.Name == "PlacedObjects" then return nil end -- Stop at folder

		if current:IsA("Model") and isGeneratedSlopeNet(current) then
			return current
		end

		if current:IsA("Model") and (current:GetAttribute("UUID") or isSlopeRootModel(current)) then
			return current
		end

		local parent = current.Parent
		if parent and (parent.Name == "TreeFolder" or parent.Name == "ClientTrees") then
			return current
		end

		if looksLikeNaturalTree(current) then
			treeCandidate = current
		end

		current = parent
	end

	return treeCandidate
end

-- // LOGIC //
ToggleRemoveMode = function()
	-- CHECK FOR CONFLICT: Don't enable while any other build sub-mode is active
	if not isRemoving and ModeState.Value ~= "" and ModeState.Value ~= "Removing" then
		return
	end

	isRemoving = not isRemoving
	ModeState.Value = isRemoving and "Removing" or ""

	if isRemoving then
		reopenBuildFrameOnExit = BuildFrame.Visible
		ClosePanels:Fire("Removal")
		local isMobile = IsMobileRemovalMode()
		UserInputService.MouseIconEnabled = not isMobile
		CursorImage.Visible = not isMobile

		if BuildFrame.Visible then
			TweenService:Create(BuildFrame, TweenInfo.new(0.3), {Position = POS_CLOSED}):Play()
			task.delay(0.3, function()
				if isRemoving and BuildFrame.Parent then
					BuildFrame.Visible = false
				end
			end)
		end

		ensureHoverSelectionBox()
		refreshRemovalCaches(true)
		lastTargetRefreshAt = 0
		lastFallbackSearchAt = 0
		lastFallbackModel = nil
	else
		UserInputService.MouseIconEnabled = true
		CursorImage.Visible = false
		if hoverSelectionBox then hoverSelectionBox.Adornee = nil end
		currentRemovalTarget = nil
		lastFallbackModel = nil

		if reopenBuildFrameOnExit and BuildFrame.Parent then
			BuildFrame.Visible = true
			TweenService:Create(BuildFrame, TweenInfo.new(0.4), {Position = POS_OPEN}):Play()
		end
		reopenBuildFrameOnExit = false
	end
end

local function FindScreenSpaceRemovalFallback(camera, aimPoint)
	local now = os.clock()
	if (now - lastFallbackSearchAt) < FALLBACK_SEARCH_INTERVAL then
		if (aimPoint - lastFallbackAimPoint).Magnitude < 8 then
			return lastFallbackModel
		end
	end

	lastFallbackSearchAt = now
	lastFallbackAimPoint = aimPoint
	refreshRemovalCaches(false)

	local bestModel = nil
	local bestDistance = math.huge
	local seen = {}
	for _, removable in ipairs(cachedPlacedRemovables) do
		if removable and removable.Parent and not seen[removable] then
			seen[removable] = true
			local focusPos, focusSize
			if removable:IsA("Model") then
				local ok, cf, size = pcall(function()
					return removable:GetBoundingBox()
				end)
				if ok and cf and size then
					focusPos = cf.Position
					focusSize = size
				end
			elseif removable:IsA("BasePart") then
				focusPos = removable.Position
				focusSize = removable.Size
			end

			if focusPos and focusSize then
				local viewportPoint, onScreen = camera:WorldToViewportPoint(focusPos)
				if onScreen and viewportPoint.Z > 0 then
					local screenDistance = (Vector2.new(viewportPoint.X, viewportPoint.Y) - aimPoint).Magnitude
					local maxExtent = math.max(focusSize.X, focusSize.Y, focusSize.Z)
					local screenRadius = math.clamp((maxExtent / math.max(16, viewportPoint.Z)) * 900, 18, 90)
					if screenDistance <= screenRadius and screenDistance < bestDistance then
						bestDistance = screenDistance
						bestModel = removable
					end
				end
			end
		end
	end

	lastFallbackModel = bestModel
	return bestModel
end

local function GetMouseTarget()
	local camera = workspace.CurrentCamera
	if not camera then return nil end
	local aimPoint = GetRemovalAimScreenPosition()

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude

	local ignoreList = {Player.Character}
	local guestFolder = workspace:FindFirstChild("Guests")
	if guestFolder then table.insert(ignoreList, guestFolder) end
	local freecamPart = workspace:FindFirstChild("PlacementFreecamRoot")
	if freecamPart then table.insert(ignoreList, freecamPart) end

	params.FilterDescendantsInstances = ignoreList

	local sampleOffsets = {
		Vector2.zero,
		Vector2.new(-10, 0), Vector2.new(10, 0),
		Vector2.new(0, -10), Vector2.new(0, 10),
		Vector2.new(-14, -14), Vector2.new(14, -14),
		Vector2.new(-14, 14), Vector2.new(14, 14),
	}
	local fallbackInstance = nil

	for _, offset in ipairs(sampleOffsets) do
		local samplePoint = aimPoint + offset
		local ray = camera:ViewportPointToRay(samplePoint.X, samplePoint.Y)
		local result = workspace:Raycast(ray.Origin, ray.Direction * 8000, params)
		local hitInstance = result and result.Instance or nil
		if hitInstance then
			local removable = GetRemovableModel(hitInstance)
			if removable then
				return hitInstance
			end
			fallbackInstance = fallbackInstance or hitInstance
		end
	end

	if fallbackInstance and GetRemovableModel(fallbackInstance) then
		return fallbackInstance
	end
	return FindScreenSpaceRemovalFallback(camera, aimPoint) or fallbackInstance
end

local isConfirming = false

local function askForConfirmation(model, callback)
	local original = MainHUD:FindFirstChild("Tutorial") and MainHUD.Tutorial:FindFirstChild("SkipConfirmation")
	if not original then
		callback(true)
		return
	end

	isConfirming = true
	local confirmUI = original:Clone()
	confirmUI.Name = "DeleteConfirm"
	confirmUI.AnchorPoint = Vector2.new(0.5, 0.5)
	confirmUI.Position = CONFIRM_HIDDEN
	confirmUI.Parent = MainHUD
	confirmUI.Visible = true
	TweenService:Create(confirmUI, CONFIRM_SHOW_TWEEN, {Position = CONFIRM_SHOWN}):Play()

	local header = confirmUI:FindFirstChild("Header")
	if header and header:FindFirstChild("TextLabel") then
		header.TextLabel.Text = "CONFIRM DELETE"
	end

	local mainText = confirmUI:FindFirstChild("MainText")
	if mainText then
		local pTime = model:GetAttribute("PlacementTime") or 0
		local refundPercent = (os.time() - pTime <= 30) and "100%" or "80%"
		mainText.Text = "Are you sure you want to delete this?\nYou will receive a " .. refundPercent .. " refund."
	end

	local buttons = confirmUI:FindFirstChild("Buttons")
	if buttons then
		local btnYes = buttons:FindFirstChild("Continue")
		local btnNo = buttons:FindFirstChild("Skip")
		local function closeConfirm(confirmed)
			local tween = TweenService:Create(confirmUI, CONFIRM_HIDE_TWEEN, {Position = CONFIRM_HIDDEN})
			tween.Completed:Once(function()
				if confirmUI.Parent then
					confirmUI:Destroy()
				end
				isConfirming = false
				callback(confirmed)
			end)
			tween:Play()
		end
		if btnYes then
			btnYes.Text = "DELETE"
			btnYes.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
			btnYes.Activated:Connect(function()
				closeConfirm(true)
			end)
		end
		if btnNo then
			btnNo.Text = "CANCEL"
			btnNo.Activated:Connect(function()
				closeConfirm(false)
			end)
		end
	else
		confirmUI:Destroy()
		isConfirming = false
		callback(true)
	end
end

local function HandleClick()
	if not isRemoving or isConfirming then return end
	local model = currentRemovalTarget
	if not model then
		local target = GetMouseTarget()
		model = GetRemovableModel(target)
	end

	if model then
		local mType = model:GetAttribute("Type")
		local isExpensive = (mType == "Slope" or mType == "TwoPoint" or mType == "Carpet")
		
		if isExpensive then
			askForConfirmation(model, function(confirmed)
				if not confirmed then
					return
				end
				BuildStatusIndicator.show(PlayerGui, "DELETING...")
				local success, result = invokeRemovalRemote(model)
				if success and result ~= false then
					BuildStatusIndicator.hide(PlayerGui)
					currentRemovalTarget = nil
					if hoverSelectionBox then hoverSelectionBox.Adornee = nil end
				else
					showDeleteFailure((not success and tostring(result)) or (type(result) == "string" and result) or "DELETE FAILED")
				end
			end)
		else
			BuildStatusIndicator.show(PlayerGui, "DELETING...")
			local success, result = invokeRemovalRemote(model)
			if success and result ~= false then
				BuildStatusIndicator.hide(PlayerGui)
				currentRemovalTarget = nil
				if hoverSelectionBox then hoverSelectionBox.Adornee = nil end
			else
				showDeleteFailure((not success and tostring(result)) or (type(result) == "string" and result) or "DELETE FAILED")
			end
		end
	end
end

local function UpdateLoop()
	if not isRemoving then return end
	local aimPoint = GetRemovalAimScreenPosition()
	if not IsMobileRemovalMode() and CursorImage then
		local cursorPoint = GetCursorGuiPosition(aimPoint)
		CursorImage.Position = UDim2.fromOffset(cursorPoint.X, cursorPoint.Y)
	end

	local now = os.clock()
	local shouldRefreshTarget = (now - lastTargetRefreshAt) >= TARGET_REFRESH_INTERVAL
	if isDragging and isDragDeleteActive then
		shouldRefreshTarget = true
	end

	if shouldRefreshTarget then
		lastTargetRefreshAt = now
		local target = GetMouseTarget()
		currentRemovalTarget = GetRemovableModel(target)
	end

	local model = currentRemovalTarget
	if model and not model.Parent then
		model = nil
		currentRemovalTarget = nil
	end

	local selectionBox = isRemoving and ensureHoverSelectionBox() or hoverSelectionBox
	if model and selectionBox then
		selectionBox.Adornee = model
	elseif selectionBox then
		selectionBox.Adornee = nil
	end

	if IsMobileRemovalMode() and TargetLabel and DeleteBtn then
		if model then
			TargetLabel.Text = string.format("TARGET: %s", model.Name)
			DeleteBtn.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			DeleteBtn.TextColor3 = Color3.fromRGB(180, 30, 30)
		else
			TargetLabel.Text = "CENTER ON AN ITEM TO DELETE"
			DeleteBtn.BackgroundColor3 = Color3.fromRGB(120, 120, 120)
			DeleteBtn.TextColor3 = Color3.fromRGB(235, 235, 235)
		end
	end

	if isDragging and isDragDeleteActive and model then
		HandleClick()
	end
end

-- // MOBILE DELETE UI //
local MobileDeleteGui = PlayerGui:WaitForChild("MobileDeleteUI", 5)
local MobileDeleteBar = MobileDeleteGui and MobileDeleteGui:WaitForChild("DeleteBar", 2)
local ModeLabel = MobileDeleteBar and MobileDeleteBar:WaitForChild("ModeLabel", 2)
local DoneBtn = MobileDeleteBar and MobileDeleteBar:WaitForChild("DoneBtn", 2)
local DeleteBtn = MobileDeleteBar and MobileDeleteBar:WaitForChild("DeleteBtn", 2)
local TargetLabel = MobileDeleteBar and MobileDeleteBar:WaitForChild("TargetLabel", 2)
local MobileReticle = MobileDeleteGui and MobileDeleteGui:WaitForChild("MobileDeleteReticle", 2)

if DoneBtn then
	bindGuiButton(DoneBtn, function()
		if isRemoving then ToggleRemoveMode() end
	end)
end

if DeleteBtn then
	bindGuiButton(DeleteBtn, function()
		if isRemoving and IsMobileRemovalMode() then
			HandleClick()
		end
	end)
	
	DeleteBtn.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
			if isRemoving and IsMobileRemovalMode() then
				isDragging = true
			end
		end
	end)
	DeleteBtn.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
			isDragging = false
		end
	end)
end

-- // PC TOOLTIP UI //
local TooltipGui = PlayerGui:WaitForChild("DeleteTooltipUI", 5)
local TooltipLabel = TooltipGui and TooltipGui:WaitForChild("TooltipLabel", 2)

if TooltipLabel then TooltipLabel.Text = "G — Toggle Mode (CLICK)" end
if ModeLabel then ModeLabel.Text = "MODE: CLICK" end

if ModeLabel then
	ModeLabel.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			isDragDeleteActive = not isDragDeleteActive
			ModeLabel.Text = isDragDeleteActive and "MODE: DRAG" or "MODE: CLICK"
			if TooltipLabel then TooltipLabel.Text = isDragDeleteActive and "G — Toggle Mode (DRAG)" or "G — Toggle Mode (CLICK)" end
		end
	end)
end

-- Show/hide mobile delete bar
local origToggle = ToggleRemoveMode
ToggleRemoveMode = function()
	origToggle()
	local isMobile = IsMobileRemovalMode()

	if isMobile then
		if MobileDeleteGui then MobileDeleteGui.Enabled = isRemoving end
		if CursorImage then CursorImage.Visible = false end
		if MobileReticle then MobileReticle.Visible = isRemoving end
	else
		if MobileDeleteGui then MobileDeleteGui.Enabled = false end
		if MobileReticle then MobileReticle.Visible = false end
		if TooltipGui then TooltipGui.Enabled = isRemoving end
	end
end

bindAvailableDeleteButtons()

task.spawn(function()
	while task.wait(0.5) do
		bindAvailableDeleteButtons()
	end
end)

local function updateMobileDeleteLayout()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local insetTopLeft, insetBottomRight = GuiService:GetGuiInset()
	local viewport = camera.ViewportSize
	local safeWidth = math.max(320, viewport.X - insetTopLeft.X - insetBottomRight.X)
	local barHeight = safeWidth < 540 and 64 or 50
	if MobileDeleteBar then
		MobileDeleteBar.Size = UDim2.new(1, 0, 0, barHeight)
		MobileDeleteBar.Position = UDim2.new(0, 0, 0, insetTopLeft.Y)
	end
	if ModeLabel then
		ModeLabel.Position = UDim2.new(0, 12, 0, 0)
		ModeLabel.Size = UDim2.new(0.28, 0, 1, 0)
		ModeLabel.TextSize = safeWidth < 540 and 14 or 16
	end
	if TargetLabel then
		TargetLabel.Position = UDim2.new(0.3, 0, 0, 0)
		TargetLabel.Size = UDim2.new(0.22, 0, 1, 0)
		TargetLabel.TextSize = safeWidth < 540 and 12 or 14
	end
	if DeleteBtn then
		DeleteBtn.AnchorPoint = Vector2.new(1, 0.5)
		DeleteBtn.Position = UDim2.new(1, -118, 0.5, 0)
		DeleteBtn.Size = UDim2.new(0, safeWidth < 540 and 94 or 120, 0, safeWidth < 540 and 40 or 36)
		DeleteBtn.TextSize = safeWidth < 540 and 14 or 16
	end
	if DoneBtn then
		DoneBtn.AnchorPoint = Vector2.new(1, 0.5)
		DoneBtn.Position = UDim2.new(1, -12, 0.5, 0)
		DoneBtn.Size = UDim2.new(0, safeWidth < 540 and 94 or 100, 0, safeWidth < 540 and 40 or 36)
		DoneBtn.TextSize = safeWidth < 540 and 14 or 16
	end
end

local function isPointerBlockedByGui(pointer)
	for _, obj in ipairs(PlayerGui:GetGuiObjectsAtPosition(pointer.X, pointer.Y)) do
		local rootGui = obj:FindFirstAncestorWhichIsA("ScreenGui")
		local rootName = rootGui and rootGui.Name or ""
		if obj.Visible and rootName ~= "RemovalCursor" and rootName ~= "MobileDeleteUI" and rootName ~= "DeleteTooltipUI" and rootName ~= "MainHUD" and rootName ~= "NoticeGui" and rootName ~= "MoneyEffectUI" and rootName ~= "ToolbarUI" and rootName ~= "PlacementCostUI" and rootName ~= "CrosshairGui" then
			return true
		end
	end
	return false
end

UserInputService.InputBegan:Connect(function(i, p)
	if p then return end
	if i.UserInputType == Enum.UserInputType.MouseButton1 then
		local pointer = Vector2.new(i.Position.X, i.Position.Y)
		if isPointerBlockedByGui(pointer) then return end
		if not IsMobileRemovalMode() or UserInputService.MouseEnabled then
			if isDragDeleteActive then isDragging = true end
			HandleClick()
		end
	elseif i.UserInputType == Enum.UserInputType.Touch then
		if IsMobileRemovalMode() then return end
		local pointer = Vector2.new(i.Position.X, i.Position.Y)
		if isPointerBlockedByGui(pointer) then return end
		if isDragDeleteActive then isDragging = true end
		HandleClick()
	elseif i.KeyCode == Enum.KeyCode.Z or i.KeyCode == Enum.KeyCode.Escape then 
		if isRemoving then ToggleRemoveMode() end
	elseif i.KeyCode == Enum.KeyCode.G then
		if isRemoving then
			isDragDeleteActive = not isDragDeleteActive
			if ModeLabel then ModeLabel.Text = isDragDeleteActive and "MODE: DRAG" or "MODE: CLICK" end
			if TooltipLabel then TooltipLabel.Text = isDragDeleteActive and "G — Toggle Mode (DRAG)" or "G — Toggle Mode (CLICK)" end
		end
	end
end)

UserInputService.InputEnded:Connect(function(i, p)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
		isDragging = false
	end
end)

RunService.RenderStepped:Connect(UpdateLoop)

updateMobileDeleteLayout()
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(updateMobileDeleteLayout)
task.spawn(function()
	while task.wait(0.5) do
		if MobileDeleteGui and MobileDeleteGui.Parent then
			updateMobileDeleteLayout()
		end
	end
end)

ClosePanels.Event:Connect(function(source)
	if source == "Removal" then return end
	if isRemoving then ToggleRemoveMode() end
end)

Player.CharacterAdded:Connect(function()
	task.defer(function()
		isRemoving = false
		isDragging = false
		currentRemovalTarget = nil
		reopenBuildFrameOnExit = false
		ModeState.Value = ""
		UserInputService.MouseIconEnabled = true
		if CursorImage then CursorImage.Visible = false end
		if hoverSelectionBox then
			hoverSelectionBox.Adornee = nil
			if not hoverSelectionBox.Parent then
				ensureHoverSelectionBox()
			end
		end
		if MobileDeleteGui then MobileDeleteGui.Enabled = false end
		if MobileReticle then MobileReticle.Visible = false end
		if TooltipGui then TooltipGui.Enabled = false end
	end)
end)