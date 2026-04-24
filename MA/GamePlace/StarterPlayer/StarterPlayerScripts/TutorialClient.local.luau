-- Disabled. TutorialController owns the live tutorial flow.
return

-- Legacy TutorialClient retained below for reference only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local UserInputService = game:GetService("UserInputService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local Events = ReplicatedStorage:WaitForChild("Events")
local AdvanceEvent = Events:WaitForChild("AdvanceTutorial")
local TutorialStatusEvent = Events:WaitForChild("TutorialStatus")
local Assets = ReplicatedStorage:WaitForChild("Assets")

-- ============================================
-- WAIT FOR SERVER DATA
-- ============================================

local serverData = nil
local dataReceived = false
local abortIfResolvedTutorialState = nil

print("[TutorialClient] Awaiting initial tutorial status from server...")

TutorialStatusEvent.OnClientEvent:Connect(function(data)
	serverData = data
	dataReceived = true
	print("[TutorialClient] Received tutorial status from server.")
	if abortIfResolvedTutorialState then
		abortIfResolvedTutorialState("server data")
	end
end)

-- ============================================
-- UI REFERENCES
-- ============================================

local ScreenGui = PlayerGui:WaitForChild("TutorialUI", 10)
if not ScreenGui then
	warn("[TutorialClient] TutorialUI not found in PlayerGui. Aborting.")
	return
end
ScreenGui.DisplayOrder = 50

local Card = ScreenGui:WaitForChild("Card")
local Title = Card:WaitForChild("Title")
local Desc = Card:WaitForChild("Desc")
local SkipBtn = Card:WaitForChild("SkipButton")
local Notice = Card:WaitForChild("Notice")
local ViewContainer = Card:WaitForChild("ViewContainer")
local Viewport = ViewContainer:WaitForChild("Viewport")
local ArrowFrame = ScreenGui:WaitForChild("ArrowFrame")
local rotateConn = nil
local tutorialShuttingDown = false

-- Setup viewport camera
local ViewCamera = Instance.new("Camera")
ViewCamera.Parent = Viewport
Viewport.CurrentCamera = ViewCamera

-- ============================================
-- TUTORIAL STEPS
-- ============================================

local STEPS = {
	{
		Title = "Start With Cabins",
		Text = "Open Build and place one cabin. Cabins create beds, and beds are what drive your guest population.",
		TargetBtn = "Build",
		Model = "Dark Small Cabin",
		RequiredType = "House",
	},
	{
		Title = "Place A Rental Shop",
		Text = "Place a rental shop. Rentals are part of your first real money loop, and many guests need gear before they can ski.",
		TargetBtn = "Build",
		Model = "Rental Shop",
		RequiredType = "Rental",
	},
	{
		Title = "Build A Beginner Lift",
		Text = "Build a Magic Carpet or chairlift. Place the bottom first, then the top, so guests can reach your run.",
		TargetBtn = "Build",
		Model = "Magic Carpet",
		RequiredTypes = {"Carpet", "TwoPoint"},
	},
	{
		Title = "Start The Lift",
		Text = "Open the Lifts panel from the dock and start your lift. A placed lift still does nothing until it is running.",
		TargetBtn = "Lifts",
		Model = nil,
		IsComplete = true,
		AutoAdvanceDelay = 5,
	},
	{
		Title = "Draw A Slope",
		Text = "Open Slope and draw a run back down the mountain. Lifts need a ride down or guests cannot complete the loop.",
		TargetBtn = "Slope",
		Model = nil,
		RequiredType = "Slope",
	},
	{
		Title = "Add Food Service",
		Text = "Place a restaurant or food building. Food is one of the easiest early ways to improve income and guest happiness.",
		TargetBtn = "Build",
		Model = nil,
		RequiredType = "Food",
	},
	{
		Title = "Hire Your First Employee",
		Text = "Open Employees and hire one staff member. Staff improve service and help each guest be worth more to your resort.",
		TargetBtn = "Employees",
		Model = nil,
		RequiredEmployeeCount = 1,
	},
	{
		Title = "Understand The Money Loop",
		Text = "Your early economy is simple: more beds bring more guests, then rentals, lifts, and food turn those guests into income. Expand that loop first.",
		TargetBtn = nil,
		Model = nil,
		IsComplete = true,
		AutoAdvanceDelay = 6,
	},
}

local function resolveTutorialState()
	local stage = tonumber(Player:GetAttribute("TutorialStage")) or 0
	if serverData and tonumber(serverData.Stage) then
		stage = math.max(stage, tonumber(serverData.Stage))
	end
	local skipped = Player:GetAttribute("TutorialSkipped") == true
	local completed = Player:GetAttribute("TutorialCompleted") == true
	if serverData then
		skipped = skipped or serverData.Skipped == true
		completed = completed or serverData.Completed == true
	end
	return {
		Skipped = skipped,
		Completed = completed,
		Stage = stage,
	}
end

local function tutorialShouldAbort()
	local state = resolveTutorialState()
	return state.Skipped or state.Completed or state.Stage >= #STEPS, state
end

local function waitForResolvedTutorialState(timeoutSeconds)
	local deadline = tick() + timeoutSeconds
	while tick() < deadline do
		local shouldAbort = tutorialShouldAbort()
		if shouldAbort then
			return true
		end
		local slotAssigned = Player:GetAttribute("SlotNum") ~= nil
		local hasTutorialAttrs = Player:GetAttribute("TutorialStage") ~= nil
			or Player:GetAttribute("TutorialSkipped") ~= nil
			or Player:GetAttribute("TutorialCompleted") ~= nil
		if dataReceived and slotAssigned then
			return tutorialShouldAbort()
		end
		if slotAssigned and hasTutorialAttrs then
			return tutorialShouldAbort()
		end
		task.wait(0.1)
	end
	warn("[TutorialClient] Tutorial state was slow to resolve. Falling back to current attributes.")
	return tutorialShouldAbort()
end

local function shutdownTutorialUi(reason)
	local shouldAbort, state = tutorialShouldAbort()
	if not shouldAbort or tutorialShuttingDown then
		return false
	end
	tutorialShuttingDown = true
	print(string.format("[TutorialClient] Tutorial blocked by %s. Stage=%s Skipped=%s Completed=%s", tostring(reason), tostring(state.Stage), tostring(state.Skipped), tostring(state.Completed)))
	if rotateConn then
		rotateConn:Disconnect()
		rotateConn = nil
	end
	ArrowFrame.Visible = false
	if ScreenGui and ScreenGui.Parent then
		ScreenGui:Destroy()
	end
	return true
end

abortIfResolvedTutorialState = shutdownTutorialUi

if waitForResolvedTutorialState(12) then
	print("[TutorialClient] Tutorial flagged as skipped, completed, or already beyond the last step. Exiting.")
	return
end

Player:GetAttributeChangedSignal("TutorialSkipped"):Connect(function()
	shutdownTutorialUi("TutorialSkipped attribute")
end)
Player:GetAttributeChangedSignal("TutorialCompleted"):Connect(function()
	shutdownTutorialUi("TutorialCompleted attribute")
end)
Player:GetAttributeChangedSignal("TutorialStage"):Connect(function()
	shutdownTutorialUi("TutorialStage attribute")
end)

print("[TutorialClient] Proceeding with tutorial initiation.")

-- ============================================
-- HELPERS
-- ============================================

local function ShowModel(modelName)
	if rotateConn then rotateConn:Disconnect() end
	Viewport:ClearAllChildren()

	ViewCamera = Instance.new("Camera")
	ViewCamera.Parent = Viewport
	Viewport.CurrentCamera = ViewCamera

	if not modelName then return end

	local source = nil
	for _, cat in pairs(Assets:GetChildren()) do
		local found = cat:FindFirstChild(modelName)
		if found then source = found break end
	end

	if source then
		local clone = source:Clone()

		if clone:IsA("Folder") then
			local subModel = clone:FindFirstChild("StartStation") or clone:FindFirstChildOfClass("Model")
			if subModel then
				local temp = subModel:Clone()
				clone:Destroy()
				clone = temp
			else
				clone:Destroy()
				return
			end
		end

		clone.Parent = Viewport

		local cf, size = clone:GetBoundingBox()
		local dist = math.max(size.X, size.Y, size.Z) * 1.8

		rotateConn = RunService.RenderStepped:Connect(function()
			local angle = tick() * 0.4
			local offset = Vector3.new(math.sin(angle)*dist, size.Y*0.6, math.cos(angle)*dist)
			ViewCamera.CFrame = CFrame.lookAt(cf.Position + offset, cf.Position)
		end)
	else
		warn("[TutorialClient] Could not find model in Assets for viewport display: " .. tostring(modelName))
	end
end

local function PointToButton(targetName)
	if not targetName then
		ArrowFrame.Visible = false
		return
	end

	local hud = PlayerGui:FindFirstChild("MainHUD")
	if not hud then
		ArrowFrame.Visible = false
		return
	end

	local target = nil
	for _, v in pairs(hud:GetDescendants()) do
		if v.Name == targetName and v:IsA("GuiObject") then
			target = v
			break
		end
	end

	if target then
		ArrowFrame.Visible = true
		print("[TutorialClient] Hooked directional arrow to UI target: " .. targetName)

		task.spawn(function()
			while ArrowFrame.Visible and target and target.Parent do
				local absPos = target.AbsolutePosition
				local absSize = target.AbsoluteSize
				local bounce = math.sin(tick() * 5) * 8

				ArrowFrame.Position = UDim2.new(0, absPos.X + absSize.X/2 - 20, 0, absPos.Y - 45 + bounce)
				task.wait()
			end
		end)
	else
		ArrowFrame.Visible = false
		warn("[TutorialClient] Failed to find UI target for arrow hook: " .. targetName)
	end
end

local function getCardTargetPosition()
	if UserInputService.TouchEnabled then
		return UDim2.new(0.5, 0, 0.22, 0)
	end
	return UDim2.new(0.18, 0, 0.3, 0)
end

local function PlaySuccess()
	print("[TutorialClient] Executing success visual and audio effects.")
	local rng = Random.new()
	for i = 1, 30 do
		local p = Instance.new("Frame", ScreenGui)
		p.Size = UDim2.new(0, 8, 0, 8)
		p.Position = Card.Position + UDim2.new(0.5, 0, 0.3, 0)
		p.BackgroundColor3 = Color3.fromHSV(rng:NextNumber(), 0.9, 1)
		p.BorderSizePixel = 0
		p.ZIndex = 100

		local dest = UDim2.new(
			0.5 + rng:NextNumber(-0.4, 0.4), 0,
			0.3 + rng:NextNumber(-0.3, 0.4), 0
		)

		TweenService:Create(p, TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = dest,
			Rotation = rng:NextNumber(-180, 180),
			BackgroundTransparency = 1
		}):Play()
		Debris:AddItem(p, 1.5)
	end

	local s = Instance.new("Sound", PlayerGui)
	s.SoundId = "rbxassetid://2553995383"
	s.Volume = 0.4
	s:Play()
	Debris:AddItem(s, 2)
end

local function ownsTutorialObject(obj)
	if not obj or not obj:IsA("Model") then
		return false
	end
	local builderId = tonumber(obj:GetAttribute("PlacedByUserId"))
	if builderId and builderId == Player.UserId then
		return true
	end
	local ownerId = tonumber(obj:GetAttribute("Owner")) or tonumber(obj:GetAttribute("OwnerId"))
	return ownerId ~= nil and ownerId == Player.UserId
end

local function CountOwnedEmployees()
	local employeesFolder = Workspace:FindFirstChild("Employees")
	if not employeesFolder then
		return 0
	end

	local count = 0
	for _, obj in ipairs(employeesFolder:GetChildren()) do
		if ownsTutorialObject(obj) then
			count += 1
		end
	end
	return count
end

local function CheckStepComplete(step)
	local placed = Workspace:FindFirstChild("PlacedObjects")
	if step.RequiredEmployeeCount then
		return CountOwnedEmployees() >= step.RequiredEmployeeCount
	end
	if not placed then return false end

	if step.RequiredBuildings then
		for _, obj in pairs(placed:GetDescendants()) do
			if ownsTutorialObject(obj) then
				for _, buildingName in ipairs(step.RequiredBuildings) do
					if obj.Name == buildingName then
						return true
					end
				end
			end
		end
	end

	if step.RequiredTypes then
		for _, obj in pairs(placed:GetDescendants()) do
			if ownsTutorialObject(obj) then
				local objType = obj:GetAttribute("Type")
				for _, requiredType in ipairs(step.RequiredTypes) do
					if objType == requiredType then
						return true
					end
				end
			end
		end
	end

	if step.RequiredType then
		for _, obj in pairs(placed:GetDescendants()) do
			if ownsTutorialObject(obj) and obj:GetAttribute("Type") == step.RequiredType then
				return true
			end
		end
	end

	if step.IsComplete then
		return true
	end

	return false
end

-- ============================================
-- MAIN TUTORIAL LOOP
-- ============================================

task.spawn(function()
	task.wait(2) 

	local resolvedState = resolveTutorialState()
	local startStage = resolvedState.Stage
	print("[TutorialClient] Initializing tutorial sequence at Stage: " .. tostring(startStage))

	if shutdownTutorialUi("pre-start validation") then
		return
	end

	if startStage >= #STEPS then 
		print("[TutorialClient] Start stage exceeds sequence length. Terminating.")
		return 
	end

	local targetCardPosition = getCardTargetPosition()
	Card.Visible = true
	Card.Position = UDim2.new(-0.35, 0, targetCardPosition.Y.Scale, targetCardPosition.Y.Offset)
	Card:TweenPosition(targetCardPosition, "Out", "Back", 0.8, true)
	task.wait(0.8)

	local skipped = false

	local skipConn = SkipBtn.Activated:Connect(function()
		print("[TutorialClient] Player initiated tutorial skip.")
		skipped = true
		Player:SetAttribute("TutorialSkipped", true)
		Player:SetAttribute("TutorialCompleted", false)
		Player:SetAttribute("TutorialStage", #STEPS)
		AdvanceEvent:FireServer("Skip") 

		ArrowFrame.Visible = false
		Card:TweenPosition(UDim2.new(targetCardPosition.X.Scale, targetCardPosition.X.Offset, 1.2, 0), "In", "Back", 0.5, true)
		task.wait(0.5)
		ScreenGui:Destroy()
	end)

	for i = startStage + 1, #STEPS do
		if skipped then break end

		local step = STEPS[i]
		print("[TutorialClient] Displaying tutorial step index: " .. tostring(i))

		Title.Text = step.Title
		Desc.Text = step.Text
		Notice.Text = string.format("Step %d of %d", i, #STEPS)
		ShowModel(step.Model)
		PointToButton(step.TargetBtn)

		if step.IsComplete then
			task.wait(step.AutoAdvanceDelay or 5)
		else
			repeat
				task.wait(0.5)
			until CheckStepComplete(step) or skipped
		end

		if skipped then break end

		print("[TutorialClient] Completed step index: " .. tostring(i))
		PlaySuccess()
		AdvanceEvent:FireServer("Advance", i)
		task.wait(1.5)
	end

	skipConn:Disconnect()

	if not skipped then
		print("[TutorialClient] Full tutorial sequence completed.")
		Player:SetAttribute("TutorialCompleted", true)
		Player:SetAttribute("TutorialSkipped", false)
		Player:SetAttribute("TutorialStage", #STEPS)
		AdvanceEvent:FireServer("Complete")

		ArrowFrame.Visible = false
		Card:TweenPosition(UDim2.new(targetCardPosition.X.Scale, targetCardPosition.X.Offset, 1.2, 0), "In", "Back", 0.8, true)
		task.wait(1)
		ScreenGui:Destroy()
	end
end)

print("[TutorialClient] V2.0 Initialized")