-- TutorialController V2.7

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GuiService = game:GetService("GuiService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

-- ─── Wait for MainHUD ───
local MainHUD = PlayerGui:WaitForChild("MainHUD", 20)
if not MainHUD then
	warn("[TutorialController] MainHUD not found in PlayerGui. Aborting.")
	return
end

local TutorialFrame = MainHUD:WaitForChild("Tutorial", 10)
if not TutorialFrame then
	warn("[TutorialController] Tutorial frame not found. Aborting.")
	return
end

local Content = TutorialFrame:WaitForChild("Content")
local Shadows = TutorialFrame:WaitForChild("Shadows")
local PageLayout = Content:WaitForChild("UIPageLayout")

-- ─── Save/Load events ───
local Events = ReplicatedStorage:WaitForChild("Events", 10)
local SaveTutorialSlide = Events:WaitForChild("SaveTutorialSlide", 10)
local GetTutorialSlide  = Events:WaitForChild("GetTutorialSlide", 10)
local AdvanceEvent      = Events and Events:FindFirstChild("AdvanceTutorial")

local IS_STUDIO = RunService:IsStudio()

local TUTORIAL_SLIDE_COUNT = 9
local tutorialOpen = false
local currentSlide = 1
local stopDockBounce
local stopBuildFlash
local withCooldown
local buttonCooldown = false

withCooldown = function(fn)
	return function()
		if buttonCooldown then return end
		buttonCooldown = true
		task.spawn(fn)
		task.delay(1, function() buttonCooldown = false end)
	end
end

local function saveSlide(slideNumber)
	if SaveTutorialSlide then
		SaveTutorialSlide:FireServer(slideNumber)
	end
end

local function loadSavedSlide()
	local stageAttribute = tonumber(Player:GetAttribute("TutorialStage"))
	if stageAttribute and stageAttribute >= 1 then
		return stageAttribute
	end
	if GetTutorialSlide then
		local ok, result = pcall(function()
			return GetTutorialSlide:InvokeServer()
		end)
		if ok and type(result) == "number" then
			return result
		end
	end
	return 1
end

local function isTutorialOwnedPlacement(item)
	if not item or not item:IsA("Model") then
		return false
	end
	local builderId = tonumber(item:GetAttribute("PlacedByUserId"))
	if builderId and builderId == Player.UserId then
		return true
	end
	local ownerId = tonumber(item:GetAttribute("Owner")) or tonumber(item:GetAttribute("OwnerId"))
	return ownerId ~= nil and ownerId == Player.UserId
end

-- ─── Skip Confirmation ───
local SkipConfirmation = TutorialFrame:WaitForChild("SkipConfirmation", 10)
local SKIP_CONFIRM_HIDDEN = UDim2.new(0.5, 0, 1.5, 0)
local SKIP_CONFIRM_SHOWN  = UDim2.new(0.5, 0, 0.5, 0)
local SKIP_CONFIRM_TWEEN  = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local SKIP_CONFIRM_CLOSE  = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

if SkipConfirmation then
	SkipConfirmation.AnchorPoint = Vector2.new(0.5, 0.5)
	SkipConfirmation.Position    = SKIP_CONFIRM_HIDDEN
	SkipConfirmation.Visible     = false
end

local function performTutorialSkip()
	print("[TutorialController] Player confirmed skip via tutorial fallback.")
	Player:SetAttribute("TutorialSkipped", true)
	Player:SetAttribute("TutorialCompleted", true)
	saveSlide(TUTORIAL_SLIDE_COUNT)
	if AdvanceEvent then AdvanceEvent:FireServer("Skip") end
	if stopDockBounce then stopDockBounce() end
	if stopBuildFlash then stopBuildFlash() end
	tutorialOpen = false
	TweenService:Create(Content, TweenInfo.new(0.35, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), { Position = UDim2.new(0, 0, -1.575, 0) }):Play()
	TweenService:Create(Shadows, TweenInfo.new(0.35, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), { Position = UDim2.new(0, 0, -1.5, 0) }):Play()
	task.delay(0.35, function()
		TutorialFrame.Visible = false
	end)
end

local function showSkipConfirmation()
	if not SkipConfirmation then
		performTutorialSkip()
		return
	end
	SkipConfirmation.Position = SKIP_CONFIRM_HIDDEN
	SkipConfirmation.Visible  = true
	TweenService:Create(SkipConfirmation, SKIP_CONFIRM_TWEEN, { Position = SKIP_CONFIRM_SHOWN }):Play()
end

local function hideSkipConfirmation()
	if not SkipConfirmation then return end
	local t = TweenService:Create(SkipConfirmation, SKIP_CONFIRM_CLOSE, { Position = SKIP_CONFIRM_HIDDEN })
	t.Completed:Once(function()
		SkipConfirmation.Visible = false
	end)
	t:Play()
end

if SkipConfirmation then
	local Buttons = SkipConfirmation:FindFirstChild("Buttons")
	if Buttons then
		local continueBtn = Buttons:FindFirstChild("Continue")
		if continueBtn then
			continueBtn.Activated:Connect(function()
				hideSkipConfirmation()
			end)
		end

		local skipBtn = Buttons:FindFirstChild("Skip")
		if skipBtn then
			skipBtn.Activated:Connect(withCooldown(function()
				hideSkipConfirmation()
				performTutorialSkip()
			end))
		end
	end
end

-- ─── Dock buttons ───
local Dock             = MainHUD:WaitForChild("Dock", 10)
local DockBuild        = Dock and Dock:WaitForChild("Build", 10)
local DockLifts        = Dock and Dock:WaitForChild("Lifts", 10)
local DockResearch     = Dock and Dock:WaitForChild("Research", 10)
local DockEmployees    = Dock and Dock:WaitForChild("Employees", 10)

local DockBuildIcon     = DockBuild     and DockBuild:FindFirstChild("Icon")
local DockLiftsIcon     = DockLifts     and DockLifts:FindFirstChild("Icon")
local DockResearchIcon  = DockResearch  and DockResearch:FindFirstChild("Icon")
local DockEmployeesIcon = DockEmployees and DockEmployees:FindFirstChild("Icon")

-- ─── Arrow ImageLabel ───
local DockTutorialLabel = TutorialFrame:FindFirstChild("Arrow")

local ICON_RED   = Color3.fromRGB(240, 20, 53)
local ICON_WHITE = Color3.fromRGB(255, 255, 255)

local COLOR_TWEEN_INFO = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- ─── Bounce tween constants ───
local BOUNCE_HALF    = 0.55
local BOUNCE_INFO_UP = TweenInfo.new(BOUNCE_HALF, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 0, false)
local ARROW_POS_DOWN = UDim2.new(0.5, 0, -0.5, 0)
local ARROW_POS_UP   = UDim2.new(0.5, 0, -0.7, 0)

local dockBounceActive = false
local dockBounceThread = nil

local BUILD_ARROW_SLIDES     = { [1] = true, [2] = true, [3] = true, [5] = true, [7] = true }
local LIFTS_ARROW_SLIDES     = { [4] = true }
local RESEARCH_ARROW_SLIDES  = { [6] = true }
local EMPLOYEES_ARROW_SLIDES = { [8] = true }

local liftsEverOpened     = false
local researchEverOpened  = false
local employeesEverOpened = false

local buildArrowDismissedOnSlide = {}

local function setIconColor(icon, color)
	if not icon then return end
	TweenService:Create(icon, COLOR_TWEEN_INFO, { ImageColor3 = color }):Play()
end

stopDockBounce = function()
	dockBounceActive = false
	if dockBounceThread then
		task.cancel(dockBounceThread)
		dockBounceThread = nil
	end
	if DockTutorialLabel then
		DockTutorialLabel.Visible = false
	end
	setIconColor(DockBuildIcon, ICON_WHITE)
	setIconColor(DockLiftsIcon, ICON_WHITE)
	setIconColor(DockResearchIcon, ICON_WHITE)
	setIconColor(DockEmployeesIcon, ICON_WHITE)
end

local function startDockBounceOn(parentButton, icon)
	if not DockTutorialLabel or not parentButton then return end
	stopDockBounce()

	DockTutorialLabel.Parent      = parentButton
	DockTutorialLabel.AnchorPoint = Vector2.new(0.5, 1)
	DockTutorialLabel.Size        = UDim2.new(1, 0, 1, 0)
	DockTutorialLabel.Position    = ARROW_POS_DOWN
	DockTutorialLabel.ZIndex      = (parentButton.ZIndex or 1) + 2
	DockTutorialLabel.Visible     = true

	if icon then icon.ImageColor3 = ICON_RED end

	dockBounceActive = true

	dockBounceThread = task.spawn(function()
		while dockBounceActive do
			local t1pos = TweenService:Create(DockTutorialLabel, BOUNCE_INFO_UP, { Position = ARROW_POS_UP })
			local t1col = icon and TweenService:Create(icon, BOUNCE_INFO_UP, { ImageColor3 = ICON_WHITE })
			t1pos:Play()
			if t1col then t1col:Play() end
			t1pos.Completed:Wait()
			if not dockBounceActive then break end

			local t2pos = TweenService:Create(DockTutorialLabel, BOUNCE_INFO_UP, { Position = ARROW_POS_DOWN })
			local t2col = icon and TweenService:Create(icon, BOUNCE_INFO_UP, { ImageColor3 = ICON_RED })
			t2pos:Play()
			if t2col then t2col:Play() end
			t2pos.Completed:Wait()
		end
	end)

	print("[TutorialController] Dock bounce started on: " .. parentButton.Name)
end

if DockTutorialLabel and DockBuild then
	DockTutorialLabel.Parent  = DockBuild
	DockTutorialLabel.Visible = false
end

local refreshArrowForSlide
currentSlide = 1

-- ─── BuildFrame highlight flash ───────────────────────────────────────────────

-- Maps slide index -> list of building names that should flash in BuildFrame.Content
local SLIDE_BUILD_HIGHLIGHTS = {
	[1] = { "Small Cabin (Dark)", "Small Cabin (Light)" },
	[2] = { "Rental Shop" },
	[3] = { "Surface Tow", "Magic Carpet" },
	[5] = { "Black Slope", "Blue Slope", "Double Black Slope", "Green Slope", "Glade", "Triple Black Slope" },
	[7] = { "Snack Bar", "Small Restaurant", "Medium Restaurant (Light)", "Medium Restaurant (Dark)", "Large Restaurant" },
}

local FLASH_COLOR_RED   = Color3.fromRGB(240, 20, 53)
local FLASH_COLOR_WHITE = Color3.fromRGB(255, 255, 255)
local FLASH_HALF        = 0.6  -- seconds per half-cycle
local FLASH_STROKE_THICKNESS = 0.1  -- scaled

local activeFlashThreads = {}   -- frame -> thread
local activeStrokes      = {}   -- frame -> UIStroke

stopBuildFlash = function()
	for frame, thread in pairs(activeFlashThreads) do
		task.cancel(thread)
		local stroke = activeStrokes[frame]
		if stroke then
			stroke:Destroy()
		end
	end
	activeFlashThreads = {}
	activeStrokes      = {}
end

local function flashFrame(frame)
	-- Don't double-flash the same frame
	if activeFlashThreads[frame] then return end

	-- Create UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.LineJoinMode    = Enum.LineJoinMode.Round
	stroke.Thickness       = FLASH_STROKE_THICKNESS
	stroke.Color           = FLASH_COLOR_RED
	stroke.Parent          = frame
	activeStrokes[frame]   = stroke

	local FLASH_INFO = TweenInfo.new(FLASH_HALF, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

	local thread = task.spawn(function()
		while true do
			TweenService:Create(stroke, FLASH_INFO, { Color = FLASH_COLOR_WHITE }):Play()
			task.wait(FLASH_HALF)
			TweenService:Create(stroke, FLASH_INFO, { Color = FLASH_COLOR_RED }):Play()
			task.wait(FLASH_HALF)
		end
	end)

	activeFlashThreads[frame] = thread
end

-- Finds frames inside BuildFrame.Content whose Title TextLabel matches a given name list
local function applyBuildHighlightsForSlide(slideIndex)
	stopBuildFlash()

	local names = SLIDE_BUILD_HIGHLIGHTS[slideIndex]
	if not names or #names == 0 then return end

	local BuildFrame = MainHUD:FindFirstChild("BuildFrame")
	if not BuildFrame then return end
	local BuildContent = BuildFrame:FindFirstChild("Content")
	if not BuildContent then return end

	-- Build a lookup set
	local nameSet = {}
	for _, n in ipairs(names) do nameSet[n] = true end

	for _, child in ipairs(BuildContent:GetChildren()) do
		if child:IsA("Frame") then
			local titleLabel = child:FindFirstChild("Title")
			if titleLabel and titleLabel:IsA("TextLabel") then
				if nameSet[titleLabel.Text] then
					flashFrame(child)
				end
			end
		end
	end
end

-- Stop flash for a specific building name (called on placement)
local function stopFlashForBuilding(buildingName)
	local BuildFrame = MainHUD:FindFirstChild("BuildFrame")
	if not BuildFrame then return end
	local BuildContent = BuildFrame:FindFirstChild("Content")
	if not BuildContent then return end

	for _, child in ipairs(BuildContent:GetChildren()) do
		if child:IsA("Frame") then
			local titleLabel = child:FindFirstChild("Title")
			if titleLabel and titleLabel:IsA("TextLabel") and titleLabel.Text == buildingName then
				local thread = activeFlashThreads[child]
				if thread then
					task.cancel(thread)
					activeFlashThreads[child] = nil
				end
				local stroke = activeStrokes[child]
				if stroke then
					stroke:Destroy()
					activeStrokes[child] = nil
				end
			end
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────

-- ─── Watch BuildFrame ───
local BuildFrame = MainHUD:FindFirstChild("BuildFrame")
local function onBuildFrameOpened()
	buildArrowDismissedOnSlide[currentSlide] = true
	setIconColor(DockBuildIcon, ICON_WHITE)
	stopDockBounce()
	-- Re-apply highlights now that the frame is open
	applyBuildHighlightsForSlide(currentSlide)
	print("[TutorialController] BuildFrame opened — build arrow dismissed for slide " .. currentSlide)
end

local function connectBuildFrameWatcher(frame)
	frame:GetPropertyChangedSignal("Visible"):Connect(function()
		if frame.Visible then
			onBuildFrameOpened()
		else
			-- Frame closed — stop flash to avoid orphaned strokes
			stopBuildFlash()
		end
	end)
end

task.delay(8, function()
	local frame = BuildFrame or MainHUD:FindFirstChild("BuildFrame")
	if frame then
		connectBuildFrameWatcher(frame)
	else
		MainHUD.ChildAdded:Connect(function(child)
			if child.Name == "BuildFrame" then
				connectBuildFrameWatcher(child)
			end
		end)
	end
end)

-- ─── Watch ResearchFrame ───
local ResearchFrame = MainHUD:FindFirstChild("ResearchFrame")
local function onResearchFrameOpened()
	if researchEverOpened then return end
	researchEverOpened = true
	setIconColor(DockResearchIcon, ICON_WHITE)
	stopDockBounce()
	if refreshArrowForSlide then refreshArrowForSlide(currentSlide or 1) end
	print("[TutorialController] ResearchFrame opened — research arrow dismissed.")
end

local function connectResearchFrameWatcher(frame)
	frame:GetPropertyChangedSignal("Visible"):Connect(function()
		if frame.Visible then onResearchFrameOpened() end
	end)
end

task.delay(8, function()
	local frame = ResearchFrame or MainHUD:FindFirstChild("ResearchFrame")
	if frame then
		connectResearchFrameWatcher(frame)
	else
		MainHUD.ChildAdded:Connect(function(child)
			if child.Name == "ResearchFrame" then
				connectResearchFrameWatcher(child)
			end
		end)
	end
end)

-- ─── Watch EmployeesFrame ───
local EmployeesFrame = MainHUD:FindFirstChild("EmployeesFrame")
local function onEmployeesFrameOpened()
	if employeesEverOpened then return end
	employeesEverOpened = true
	setIconColor(DockEmployeesIcon, ICON_WHITE)
	stopDockBounce()
	if refreshArrowForSlide then refreshArrowForSlide(currentSlide or 1) end
	print("[TutorialController] EmployeesFrame opened — employees arrow dismissed.")
end

local function connectEmployeesFrameWatcher(frame)
	frame:GetPropertyChangedSignal("Visible"):Connect(function()
		if frame.Visible then onEmployeesFrameOpened() end
	end)
end

task.delay(8, function()
	local frame = EmployeesFrame or MainHUD:FindFirstChild("EmployeesFrame")
	if frame then
		connectEmployeesFrameWatcher(frame)
	else
		MainHUD.ChildAdded:Connect(function(child)
			if child.Name == "EmployeesFrame" then
				connectEmployeesFrameWatcher(child)
			end
		end)
	end
end)

-- ─── Per-slide arrow logic ───
refreshArrowForSlide = function(index)
	if BUILD_ARROW_SLIDES[index] then
		setIconColor(DockLiftsIcon, ICON_WHITE)
		setIconColor(DockResearchIcon, ICON_WHITE)
		setIconColor(DockEmployeesIcon, ICON_WHITE)
		if not buildArrowDismissedOnSlide[index] then
			startDockBounceOn(DockBuild, DockBuildIcon)
		else
			stopDockBounce()
			setIconColor(DockBuildIcon, ICON_WHITE)
		end
	elseif LIFTS_ARROW_SLIDES[index] then
		setIconColor(DockBuildIcon, ICON_WHITE)
		setIconColor(DockResearchIcon, ICON_WHITE)
		setIconColor(DockEmployeesIcon, ICON_WHITE)
		if not liftsEverOpened then
			startDockBounceOn(DockLifts, DockLiftsIcon)
		else
			stopDockBounce()
			setIconColor(DockLiftsIcon, ICON_WHITE)
		end
	elseif RESEARCH_ARROW_SLIDES[index] then
		setIconColor(DockBuildIcon, ICON_WHITE)
		setIconColor(DockLiftsIcon, ICON_WHITE)
		setIconColor(DockEmployeesIcon, ICON_WHITE)
		if not researchEverOpened then
			startDockBounceOn(DockResearch, DockResearchIcon)
		else
			stopDockBounce()
			setIconColor(DockResearchIcon, ICON_WHITE)
		end
	elseif EMPLOYEES_ARROW_SLIDES[index] then
		setIconColor(DockBuildIcon, ICON_WHITE)
		setIconColor(DockLiftsIcon, ICON_WHITE)
		setIconColor(DockResearchIcon, ICON_WHITE)
		if not employeesEverOpened then
			startDockBounceOn(DockEmployees, DockEmployeesIcon)
		else
			stopDockBounce()
			setIconColor(DockEmployeesIcon, ICON_WHITE)
		end
	else
		setIconColor(DockBuildIcon, ICON_WHITE)
		setIconColor(DockLiftsIcon, ICON_WHITE)
		setIconColor(DockResearchIcon, ICON_WHITE)
		setIconColor(DockEmployeesIcon, ICON_WHITE)
		stopDockBounce()
	end
end

-- ─── Check if tutorial was already completed / skipped ───
local function hasCompletedState()
	return Player:GetAttribute("TutorialCompleted") == true
		or Player:GetAttribute("TutorialSkipped") == true
end

local function shouldSuppressTutorialOpen()
	return hasCompletedState()
end

local function waitForServerTutorialState()
	local waited = 0
	while waited < 20 do
		if Player:GetAttribute("TutorialStateReady") == true then
			return true
		end
		task.wait(0.25)
		waited += 0.25
	end
	warn("[TutorialController] Timed out waiting for server tutorial state readiness.")
	return false
end

local tutorialStateReady = waitForServerTutorialState()
if not tutorialStateReady then
	warn("[TutorialController] Proceeding with fallback tutorial state due readiness timeout.")
end

if shouldSuppressTutorialOpen() then
	TutorialFrame.Visible = false
	stopDockBounce()
	return
end

-- ─── Slide references ───
local SLIDE_COUNT = TUTORIAL_SLIDE_COUNT
local slides = {}
for i = 1, SLIDE_COUNT do
	local slide = Content:FindFirstChild(tostring(i) .. ".")
	if slide then
		slides[i] = slide
	else
		warn("[TutorialController] Missing slide: " .. tostring(i) .. ".")
	end
end

currentSlide = 1
local furthestSlideReached = 1
local buttonCooldown = false
tutorialOpen = false
local isSilentLoad   = false

-- ─── Tween helpers ───
local TWEEN_TIME = 0.35
local TWEEN_INFO = TweenInfo.new(TWEEN_TIME, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

local CONTENT_ONSCREEN  = UDim2.new(0.02, 0, 0.4, 0)
local CONTENT_OFFSCREEN = UDim2.new(0, 0, -1.575, 0)
local SHADOWS_ONSCREEN  = UDim2.new(0, 0, 0, 0)
local SHADOWS_OFFSCREEN = UDim2.new(0, 0, -1.5, 0)

local function tweenOffScreen()
	TweenService:Create(Content, TWEEN_INFO, { Position = CONTENT_OFFSCREEN }):Play()
	TweenService:Create(Shadows, TWEEN_INFO, { Position = SHADOWS_OFFSCREEN }):Play()
end

local function tweenOnScreen()
	TweenService:Create(Content, TWEEN_INFO, { Position = CONTENT_ONSCREEN }):Play()
	TweenService:Create(Shadows, TWEEN_INFO, { Position = SHADOWS_ONSCREEN }):Play()
end

-- ─── UI Overlap Monitor ───
local function isPanelActuallyOnScreen(guiObject)
	if not guiObject.Visible then return false end
	local viewportSize = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or GuiService:GetScreenResolution()
	local absPos  = guiObject.AbsolutePosition
	local absSize = guiObject.AbsoluteSize
	if absSize.X <= 0 or absSize.Y <= 0 then return false end
	local right  = absPos.X + absSize.X
	local bottom = absPos.Y + absSize.Y
	return absPos.X < viewportSize.X and right > 0 and absPos.Y < viewportSize.Y and bottom > 0
end

local function countBlockingPanels()
	local activePanels = 0
	for _, child in ipairs(MainHUD:GetChildren()) do
		if child:IsA("Frame") and child ~= TutorialFrame then
			if isPanelActuallyOnScreen(child) and (
				child.Name == "BuildFrame" or child.Name == "SettingsFrame"
					or child.Name == "ResearchFrame" or child.Name == "EmployeesFrame"
					or child.Name == "CalendarFrame" or child.Name == "ResortMenu"
				) then
				activePanels += 1
			end
		end
	end
	return activePanels
end

local function syncTutorialPanelVisibility(forceOnScreen)
	if not tutorialOpen then return end
	if Player:GetAttribute("TutorialCompleted") ~= true and Player:GetAttribute("TutorialSkipped") ~= true then
		TutorialFrame.Visible = true
	end
	if forceOnScreen then
		tweenOnScreen()
		return
	end
	if countBlockingPanels() > 0 then
		tweenOffScreen()
	else
		tweenOnScreen()
	end
end

local function setupUIMonitor()
	local function checkPanels()
		syncTutorialPanelVisibility(false)
	end
	for _, child in ipairs(MainHUD:GetChildren()) do
		if child:IsA("Frame") and child ~= TutorialFrame then
			child:GetPropertyChangedSignal("Visible"):Connect(checkPanels)
		end
	end
	MainHUD.ChildAdded:Connect(function(child)
		if child:IsA("Frame") and child ~= TutorialFrame then
			child:GetPropertyChangedSignal("Visible"):Connect(checkPanels)
		end
	end)
end
setupUIMonitor()

-- ─── Red arrow bounce animation (per slide Icon) ───
local arrowConnections = {}

local function startArrowBounce(slide)
	for _, conn in ipairs(arrowConnections) do conn:Disconnect() end
	arrowConnections = {}
	if not slide then return end
	local outerIcon = slide:FindFirstChild("Icon")
	if not outerIcon then return end
	local basePos   = outerIcon.Position
	local startTime = tick()
	local conn = RunService.RenderStepped:Connect(function()
		if not outerIcon or not outerIcon.Parent then return end
		local elapsed = tick() - startTime
		local offset  = math.sin(elapsed * 2.5 * math.pi) * 6
		outerIcon.Position = UDim2.new(
			basePos.X.Scale, basePos.X.Offset,
			basePos.Y.Scale, basePos.Y.Offset + offset
		)
	end)
	table.insert(arrowConnections, conn)
end

-- ─── Navigate to a slide ───
local refreshForwardButtons

local function goToSlide(index)
	index = math.clamp(index, 1, SLIDE_COUNT)
	currentSlide = index
	furthestSlideReached = math.max(furthestSlideReached, index)
	if tutorialOpen and Player:GetAttribute("TutorialCompleted") ~= true and Player:GetAttribute("TutorialSkipped") ~= true then
		TutorialFrame.Visible = true
	end

	-- Clear build flash whenever slide changes; re-apply if BuildFrame is open
	stopBuildFlash()
	local bf = MainHUD:FindFirstChild("BuildFrame")
	if bf and bf.Visible then
		applyBuildHighlightsForSlide(index)
	end

	refreshArrowForSlide(index)
	if refreshForwardButtons then refreshForwardButtons() end

	local targetSlide = slides[index]
	if targetSlide then
		PageLayout:JumpTo(targetSlide)
		startArrowBounce(targetSlide)
	end

	if not isSilentLoad then
		saveSlide(index)
	end

	print(string.format("[TutorialController] Showing slide %d / %d", index, SLIDE_COUNT))
	task.defer(function()
		if tutorialOpen and currentSlide == index and reconcileCurrentSlideProgress then
			reconcileCurrentSlideProgress()
		end
	end)
end

local function scheduleStageReconcile()
	if stageReconcileScheduled then return end
	stageReconcileScheduled = true
	task.defer(function()
		stageReconcileScheduled = false
		if not tutorialOpen then return end
		if hasCompletedState() then
			if stopDockBounce then stopDockBounce() end
			if stopBuildFlash then stopBuildFlash() end
			tutorialOpen = false
			TutorialFrame.Visible = false
			return
		end
		local stageAttr = tonumber(Player:GetAttribute("TutorialStage"))
		if stageAttr and stageAttr >= 1 and stageAttr < SLIDE_COUNT and stageAttr > currentSlide then
			print(string.format("[TutorialController] Recovering tutorial to slide %d from server attributes.", stageAttr))
			goToSlide(stageAttr)
		end
	end)
end

Player:GetAttributeChangedSignal("TutorialStage"):Connect(function()
	scheduleStageReconcile()
end)

-- ─── Placement detection ───
local SLIDE_PLACEMENT_TRIGGERS = {
	[1] = { ["Small Cabin (Dark)"] = true, ["Small Cabin (Light)"] = true },
	[2] = { ["Rental Shop"] = true },
	[3] = { ["Surface Tow"] = true, ["Magic Carpet"] = true },
	[5] = {
		["Black Slope"]        = true,
		["Blue Slope"]         = true,
		["Double Black Slope"] = true,
		["Green Slope"]        = true,
		["Glade"]              = true,
		["Triple Black Slope"] = true,
	},
	[7] = {
		["Snack Bar"]                 = true,
		["Small Restaurant"]          = true,
		["Medium Restaurant (Light)"] = true,
		["Medium Restaurant (Dark)"]  = true,
		["Large Restaurant"]          = true,
	},
}

local placementAdvanced = {}
local placedObjectsWatchActive = false
local reconcileCurrentSlideProgress
local placementReconcileScheduled = false
local liftAdvanced = false
local stageReconcileScheduled = false

local function schedulePlacementReconcile(delaySeconds)
	if placementReconcileScheduled then return end
	placementReconcileScheduled = true
	task.delay(delaySeconds or 0.15, function()
		placementReconcileScheduled = false
		if tutorialOpen and reconcileCurrentSlideProgress then
			reconcileCurrentSlideProgress()
		end
	end)
end

local function onItemPlaced(itemName)
	if not tutorialOpen then return end
	local triggers = SLIDE_PLACEMENT_TRIGGERS[currentSlide]
	if not triggers or not triggers[itemName] then return end
	if placementAdvanced[currentSlide] then return end
	placementAdvanced[currentSlide] = true

	-- Stop flashing this specific building immediately
	stopFlashForBuilding(itemName)

	print(string.format("[TutorialController] '%s' placed — advancing from slide %d to %d.", itemName, currentSlide, currentSlide + 1))
	if currentSlide < SLIDE_COUNT then
		goToSlide(currentSlide + 1)
	end
end

local function findExistingPlacementForSlide(slideIndex)
	local triggers = SLIDE_PLACEMENT_TRIGGERS[slideIndex]
	if not triggers then return nil end

	local placedFolder = workspace:FindFirstChild("PlacedObjects")
	if not placedFolder then return nil end

	for _, item in ipairs(placedFolder:GetDescendants()) do
		if isTutorialOwnedPlacement(item) then
			if triggers[item.Name] then
				return item.Name
			end
			if slideIndex == 3 then
				local itemType = item:GetAttribute("Type")
				if itemType == "Carpet" and triggers["Magic Carpet"] then
					return "Magic Carpet"
				elseif itemType == "TwoPoint" and triggers["Surface Tow"] then
					return "Surface Tow"
				end
			end
		end
	end

	return nil
end

reconcileCurrentSlideProgress = function()
	if not tutorialOpen then return end

	local existingPlacement = findExistingPlacementForSlide(currentSlide)
	if existingPlacement and not placementAdvanced[currentSlide] then
		print(string.format("[TutorialController] Reconciled existing placement '%s' for slide %d.", existingPlacement, currentSlide))
		onItemPlaced(existingPlacement)
		return
	end

	if currentSlide == 4 and not liftAdvanced then
		local placedFolder = workspace:FindFirstChild("PlacedObjects")
		if not placedFolder then return end
		for _, lift in ipairs(placedFolder:GetDescendants()) do
			if isTutorialOwnedPlacement(lift) then
				local liftType = lift:GetAttribute("Type")
				if (liftType == "TwoPoint" or liftType == "Carpet") and lift:GetAttribute("Status") == "Running" then
					liftAdvanced = true
					print("[TutorialController] Reconciled running lift for slide 4 — advancing to slide 5.")
					liftsEverOpened = true
					setIconColor(DockLiftsIcon, ICON_WHITE)
					stopDockBounce()
					goToSlide(5)
					return
				end
			end
		end
	end
end

-- ─── Lift Status "Running" detection (slide 4) ───
local liftStatusConnections = {}

local function watchLiftStatus(lift)
	if not isTutorialOwnedPlacement(lift) then return end
	local conn = lift:GetAttributeChangedSignal("Status"):Connect(function()
		if liftAdvanced then return end
		if not tutorialOpen then return end
		if currentSlide ~= 4 then return end
		if lift:GetAttribute("Status") == "Running" then
			liftAdvanced = true
			print("[TutorialController] Lift started — advancing from slide 4 to 5.")
			liftsEverOpened = true
			setIconColor(DockLiftsIcon, ICON_WHITE)
			stopDockBounce()
			goToSlide(5)
		end
	end)
	table.insert(liftStatusConnections, conn)
end

local function watchPlacedObjects()
	if placedObjectsWatchActive then return end
	placedObjectsWatchActive = true

	local function beginWatching(placedFolder)
		local preExisting = {}
		local function watchLiftTree(instance)
			if instance:IsA("Model") then
				watchLiftStatus(instance)
			end
			for _, descendant in ipairs(instance:GetDescendants()) do
				if descendant:IsA("Model") then
					watchLiftStatus(descendant)
				end
			end
		end

		for _, item in ipairs(placedFolder:GetChildren()) do
			preExisting[item] = true
			watchLiftTree(item)
		end
		schedulePlacementReconcile(0.05)
		placedFolder.ChildAdded:Connect(function(item)
			if preExisting[item] then return end
			if isTutorialOwnedPlacement(item) then
				onItemPlaced(item.Name)
			end
			watchLiftTree(item)
			schedulePlacementReconcile()
		end)
		placedFolder.DescendantAdded:Connect(function(descendant)
			if descendant:IsA("Model") then
				watchLiftTree(descendant)
			end
			schedulePlacementReconcile()
		end)
	end

	local placedFolder = workspace:FindFirstChild("PlacedObjects")
	if placedFolder then
		beginWatching(placedFolder)
	else
		workspace.ChildAdded:Connect(function(child)
			if child.Name == "PlacedObjects" then
				beginWatching(child)
			end
		end)
	end
end

-- ─── Research completion detection (slide 6) ───
local researchAdvanced = false

local function setupResearchDetection()
	local ResearchUpdate = Events and Events:FindFirstChild("ResearchUpdate")
	if not ResearchUpdate then
		warn("[TutorialController] ResearchUpdate event not found.")
		return
	end
	ResearchUpdate.OnClientEvent:Connect(function(snapshot)
		if researchAdvanced then return end
		if not tutorialOpen then return end
		if currentSlide ~= 6 then return end
		if type(snapshot) ~= "table" then return end
		if type(snapshot.Unlocked) ~= "table" then return end
		if snapshot.Unlocked["Guest_Services"] == true then
			researchAdvanced = true
			researchEverOpened = true
			setIconColor(DockResearchIcon, ICON_WHITE)
			stopDockBounce()
			print("[TutorialController] Guest_Services researched — advancing from slide 6 to 7.")
			goToSlide(7)
		end
	end)
end

-- ─── Employee hire detection (slide 8) ───
local employeeAdvanced = false

local function setupEmployeeDetection()
	local HireResultEvent = Events and Events:FindFirstChild("EmployeeHireResult")
	if not HireResultEvent then
		warn("[TutorialController] EmployeeHireResult event not found.")
		return
	end
	HireResultEvent.OnClientEvent:Connect(function(result)
		if employeeAdvanced then return end
		if not tutorialOpen then return end
		if currentSlide ~= 8 then return end
		if type(result) ~= "table" then return end
		if result.success == true then
			employeeAdvanced = true
			employeesEverOpened = true
			setIconColor(DockEmployeesIcon, ICON_WHITE)
			stopDockBounce()
			print("[TutorialController] Employee hired — advancing from slide 8 to 9.")
			goToSlide(9)
		end
	end)
end

-- ─── Wire buttons for every slide ───
withCooldown = function(fn)
	return function()
		if buttonCooldown then return end
		buttonCooldown = true
		task.spawn(fn)
		task.delay(1, function() buttonCooldown = false end)
	end
end

refreshForwardButtons = function()
	for i = 1, SLIDE_COUNT do
		local slide = slides[i]
		local buttonsFolder = slide and slide:FindFirstChild("Buttons")
		local nextBtn = buttonsFolder and buttonsFolder:FindFirstChild("Next")
		if nextBtn and nextBtn:IsA("GuiButton") then
			local canAdvance = i < furthestSlideReached
			nextBtn.Visible = canAdvance
			nextBtn.Active = canAdvance
			nextBtn.AutoButtonColor = canAdvance
			nextBtn.TextTransparency = canAdvance and 0 or 0.4
		end
	end
end

for i = 1, SLIDE_COUNT do
	local slide = slides[i]
	if not slide then continue end
	local buttonsFolder = slide:FindFirstChild("Buttons")
	if not buttonsFolder then continue end

	local backBtn = buttonsFolder:FindFirstChild("Back")
	local skipBtn = buttonsFolder:FindFirstChild("Skip")
	local doneBtn = buttonsFolder:FindFirstChild("Done")
	local nextBtn = buttonsFolder:FindFirstChild("Next")

	if i < SLIDE_COUNT and not nextBtn then
		local sourceButton = skipBtn or backBtn
		if sourceButton and sourceButton:IsA("TextButton") then
			nextBtn = sourceButton:Clone()
			nextBtn.Name = "Next"
			nextBtn.Text = "Next"
			nextBtn.Parent = buttonsFolder
			local nextIcon = nextBtn:FindFirstChild("Icon")
			if nextIcon then nextIcon:Destroy() end
		end
	end

	if backBtn then
		backBtn.LayoutOrder = 1
		backBtn.Activated:Connect(withCooldown(function()
			if currentSlide > 1 then
				goToSlide(currentSlide - 1)
			else
				tweenOffScreen()
				task.delay(TWEEN_TIME, function() TutorialFrame.Visible = false end)
				tutorialOpen = false
				stopDockBounce()
				stopBuildFlash()
			end
		end))
	end

	if nextBtn and nextBtn:IsA("GuiButton") then
		nextBtn.LayoutOrder = backBtn and 2 or 1
		nextBtn.Activated:Connect(withCooldown(function()
			if currentSlide < furthestSlideReached then
				goToSlide(currentSlide + 1)
			end
		end))
		local nextLabel = nextBtn:FindFirstChildWhichIsA("TextLabel")
		if nextLabel then nextLabel.Text = "Next" end
	end

	if skipBtn then
		skipBtn.LayoutOrder = nextBtn and ((backBtn and 3) or 2) or (backBtn and 2 or 1)
		skipBtn.Activated:Connect(withCooldown(function()
			showSkipConfirmation()
		end))
	end

	if doneBtn then
		doneBtn.Activated:Connect(withCooldown(function()
			print("[TutorialController] Player completed tutorial.")
			Player:SetAttribute("TutorialCompleted", true)
			Player:SetAttribute("TutorialSkipped", false)
			saveSlide(TUTORIAL_SLIDE_COUNT)
			if AdvanceEvent then AdvanceEvent:FireServer("Complete") end
			tweenOffScreen()
			task.delay(TWEEN_TIME, function() TutorialFrame.Visible = false end)
			tutorialOpen = false
			if stopDockBounce then stopDockBounce() end
			stopBuildFlash()
		end))
	end
end

refreshForwardButtons()

-- ─── Mobile Swipe Support ───
local UserInputService = game:GetService("UserInputService")
UserInputService.TouchSwipe:Connect(function(swipeDirection, numberOfTouches, gameProcessedEvent)
	if not tutorialOpen or gameProcessedEvent then return end
	if numberOfTouches and numberOfTouches > 1 then return end
	if buttonCooldown then return end
	if swipeDirection == Enum.SwipeDirection.Left then
		if currentSlide < furthestSlideReached then
			buttonCooldown = true
			goToSlide(currentSlide + 1)
			task.delay(1, function() buttonCooldown = false end)
		end
	elseif swipeDirection == Enum.SwipeDirection.Right then
		if currentSlide > 1 and currentSlide < furthestSlideReached then
			buttonCooldown = true
			goToSlide(currentSlide - 1)
			task.delay(1, function() buttonCooldown = false end)
		end
	end
end)

-- ─── Open the tutorial ───
local function openTutorial(startSlide)
	if tutorialOpen or shouldSuppressTutorialOpen() then return end
	tutorialOpen = true
	isSilentLoad = true

	if startSlide and startSlide > 1 then
		if startSlide > 4 then liftsEverOpened      = true end
		if startSlide > 6 then researchEverOpened   = true end
		if startSlide > 8 then employeesEverOpened  = true end
		for s = 1, startSlide - 1 do placementAdvanced[s] = true end
		if startSlide > 4 then liftAdvanced     = true end
		if startSlide > 6 then researchAdvanced  = true end
		if startSlide > 8 then employeeAdvanced  = true end
	end

	goToSlide(startSlide or 1)
	isSilentLoad = false
	scheduleStageReconcile()

	watchPlacedObjects()
	setupResearchDetection()
	setupEmployeeDetection()
	task.defer(function()
		if tutorialOpen and reconcileCurrentSlideProgress then
			reconcileCurrentSlideProgress()
		end
	end)

	Content.Position = CONTENT_OFFSCREEN
	Shadows.Position = SHADOWS_OFFSCREEN
	TutorialFrame.Visible = true

	task.delay(0.3, function()
		if not tutorialOpen or not TutorialFrame.Visible then return end
		tweenOnScreen()
	end)

	print(string.format("[TutorialController] Tutorial opened on slide %d.", startSlide or 1))
end

-- ─── Wait for character load-lock to release ───
local function waitForLoadLockRelease()
	local character = Player.Character or Player.CharacterAdded:Wait()
	local humanoid = character:FindFirstChildWhichIsA("Humanoid")
	if not humanoid then
		character:WaitForChild("Humanoid", 15)
		humanoid = character:FindFirstChildWhichIsA("Humanoid")
	end
	if not humanoid then return end
	local waited = 0
	while waited < 60 do
		local root = character:FindFirstChild("HumanoidRootPart")
		local loadUnlocked = Player:GetAttribute("WorldLoadLocked") ~= true
		local rootReady = (not root) or root.Anchored == false
		if loadUnlocked and rootReady and humanoid.Health > 0 then return end
		task.wait(0.5)
		waited += 0.5
	end
	warn("[TutorialController] Timed out waiting for load lock release (60s).")
end

-- ─── Auto-open: load saved slide first ───
task.delay(2, function()
	if shouldSuppressTutorialOpen() then
		stopDockBounce()
		TutorialFrame.Visible = false
		return
	end

	waitForLoadLockRelease()

	if shouldSuppressTutorialOpen() then
		stopDockBounce()
		TutorialFrame.Visible = false
		return
	end

	local savedSlide = loadSavedSlide()
	if savedSlide >= SLIDE_COUNT then
		Player:SetAttribute("TutorialCompleted", true)
		stopDockBounce()
		TutorialFrame.Visible = false
		return
	end
	openTutorial(savedSlide)
end)

-- ─── Listen for completion/skip from server ───
local function handleExternalClose()
	if not hasCompletedState() then return end
	stopDockBounce()
	stopBuildFlash()
	if tutorialOpen then
		tweenOffScreen()
		task.delay(TWEEN_TIME, function() TutorialFrame.Visible = false end)
	end
	tutorialOpen = false
	TutorialFrame.Visible = false
end

Player:GetAttributeChangedSignal("TutorialCompleted"):Connect(handleExternalClose)
Player:GetAttributeChangedSignal("TutorialSkipped"):Connect(handleExternalClose)

TutorialFrame:GetPropertyChangedSignal("Visible"):Connect(function()
	if tutorialOpen and Player:GetAttribute("TutorialCompleted") ~= true and Player:GetAttribute("TutorialSkipped") ~= true and TutorialFrame.Visible == false then
		task.defer(function()
			if tutorialOpen and Player:GetAttribute("TutorialCompleted") ~= true and Player:GetAttribute("TutorialSkipped") ~= true then
				TutorialFrame.Visible = true
				syncTutorialPanelVisibility(false)
			end
		end)
	end
end)

print("[TutorialController] V2.7 Initialized — MainHUD.Tutorial connected.")