local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local modeState = playerGui:FindFirstChild("ModeState") or Instance.new("StringValue")
modeState.Name = "ModeState"
modeState.Parent = playerGui

local BASE_WALK_SPEED = 150
local SPRINT_WALK_SPEED = 225
local MOBILE_BUTTON_NAME = "SprintButtonGui"

local humanoid = nil
local rootPart = nil
local desktopSprintHeld = false
local mobileSprintToggled = false
local sprintButtonGui = nil
local sprintButton = nil

local function ensureSprintButton()
	if sprintButtonGui and sprintButtonGui.Parent then
		return
	end

	sprintButtonGui = playerGui:FindFirstChild(MOBILE_BUTTON_NAME)
	if not sprintButtonGui then
		sprintButtonGui = Instance.new("ScreenGui")
		sprintButtonGui.Name = MOBILE_BUTTON_NAME
		sprintButtonGui.ResetOnSpawn = true
		sprintButtonGui.IgnoreGuiInset = true
		sprintButtonGui.DisplayOrder = 5
		sprintButtonGui.Parent = playerGui
	end

	sprintButton = sprintButtonGui:FindFirstChild("SprintButton")
	if sprintButton and sprintButton:IsA("GuiButton") then
		return
	end

	sprintButton = Instance.new("TextButton")
	sprintButton.Name = "SprintButton"
	sprintButton.AnchorPoint = Vector2.new(1, 1)
	sprintButton.Position = UDim2.new(1, -28, 1, -286)
	sprintButton.Size = UDim2.new(0, 124, 0, 48)
	sprintButton.BackgroundColor3 = Color3.fromRGB(26, 96, 118)
	sprintButton.BackgroundTransparency = 0.12
	sprintButton.BorderSizePixel = 0
	sprintButton.AutoButtonColor = true
	sprintButton.Font = Enum.Font.GothamBold
	sprintButton.TextSize = 14
	sprintButton.TextColor3 = Color3.fromRGB(245, 251, 255)
	sprintButton.Text = "RUN"
	sprintButton.Visible = false
	sprintButton.Parent = sprintButtonGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = sprintButton

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(126, 220, 241)
	stroke.Transparency = 0.18
	stroke.Thickness = 1.5
	stroke.Parent = sprintButton

	sprintButton.Activated:Connect(function()
		mobileSprintToggled = not mobileSprintToggled
	end)
end

local function isTouchSprintEnabled()
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local function canControlMovement()
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	if player:GetAttribute("WorldLoadLocked") == true then
		return false
	end
	if modeState.Value ~= "" then
		return false
	end
	if humanoid.PlatformStand or humanoid.Sit then
		return false
	end
	local state = humanoid:GetState()
	if state == Enum.HumanoidStateType.Dead or state == Enum.HumanoidStateType.Seated then
		return false
	end
	return true
end

local function wantsSprint()
	return desktopSprintHeld or mobileSprintToggled
end

local function isPlacementControlVisible()
	for _, name in ipairs({
		"Rotate", "RotateButton", "RotateBtn",
		"Place", "PlaceButton", "ActionButton",
		"Cancel", "CancelButton", "CancelBar",
		"DeleteButton", "MobileControls", "MobileControlsGui"
	}) do
		local candidate = playerGui:FindFirstChild(name, true)
		if candidate and candidate:IsA("GuiObject") and candidate.Visible then
			return true
		end
	end
	return false
end

local function updateSprintButton()
	if not sprintButton then
		return
	end

	local visible = isTouchSprintEnabled()
		and humanoid ~= nil
		and humanoid.Health > 0
		and modeState.Value == ""
		and not isPlacementControlVisible()
	sprintButton.Visible = visible
	if not visible then
		return
	end

	local active = wantsSprint() and canControlMovement()
	sprintButton.Text = active and "WALK" or "RUN"
	sprintButton.BackgroundColor3 = active and Color3.fromRGB(76, 164, 90) or Color3.fromRGB(26, 96, 118)
	local stroke = sprintButton:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = active and Color3.fromRGB(193, 242, 176) or Color3.fromRGB(126, 220, 241)
	end
end

local function getAdminOverrideSpeed()
	local override = player:GetAttribute("AdminWalkSpeed")
	if type(override) == "number" and override > 0 then
		return math.clamp(override, 1, 500)
	end
	return nil
end

local function applyMovementState()
	if not humanoid then
		updateSprintButton()
		return
	end

	if not canControlMovement() then
		updateSprintButton()
		return
	end

	local targetSpeed = getAdminOverrideSpeed() or BASE_WALK_SPEED
	if not getAdminOverrideSpeed() and wantsSprint() and humanoid.MoveDirection.Magnitude > 0.01 then
		targetSpeed = SPRINT_WALK_SPEED
	end

	if math.abs((humanoid.WalkSpeed or 0) - targetSpeed) > 0.01 then
		humanoid.WalkSpeed = targetSpeed
	end

	updateSprintButton()
end

local function restoreMovementState(character)
	if not character then
		return
	end

	humanoid = character:WaitForChild("Humanoid")
	rootPart = character:FindFirstChild("HumanoidRootPart")
	desktopSprintHeld = false
	mobileSprintToggled = false

	humanoid.PlatformStand = false
	humanoid.AutoRotate = true
	humanoid.AutoJumpEnabled = false
	humanoid.WalkSpeed = getAdminOverrideSpeed() or BASE_WALK_SPEED

	if humanoid.UseJumpPower then
		humanoid.JumpPower = humanoid.JumpPower > 0 and humanoid.JumpPower or 50
	else
		humanoid.JumpHeight = humanoid.JumpHeight > 0 and humanoid.JumpHeight or 7.2
	end

	if rootPart then
		rootPart.Anchored = false
		rootPart.AssemblyLinearVelocity = Vector3.zero
		rootPart.AssemblyAngularVelocity = Vector3.zero
	end

	humanoid:GetPropertyChangedSignal("MoveDirection"):Connect(applyMovementState)
	humanoid:GetPropertyChangedSignal("PlatformStand"):Connect(applyMovementState)
	humanoid:GetPropertyChangedSignal("Sit"):Connect(applyMovementState)
	humanoid.StateChanged:Connect(function()
		applyMovementState()
	end)
	humanoid.Died:Connect(function()
		desktopSprintHeld = false
		mobileSprintToggled = false
		updateSprintButton()
	end)

	applyMovementState()
end

ensureSprintButton()

modeState:GetPropertyChangedSignal("Value"):Connect(function()
	if modeState.Value ~= "" then
		mobileSprintToggled = false
	end
	applyMovementState()
end)

player:GetAttributeChangedSignal("WorldLoadLocked"):Connect(function()
	if player:GetAttribute("WorldLoadLocked") == true then
		mobileSprintToggled = false
	end
	applyMovementState()
end)

player:GetAttributeChangedSignal("AdminWalkSpeed"):Connect(function()
	applyMovementState()
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
		desktopSprintHeld = true
		applyMovementState()
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
		desktopSprintHeld = false
		applyMovementState()
	end
end)

RunService.RenderStepped:Connect(function()
	applyMovementState()
end)

if player.Character then
	task.defer(restoreMovementState, player.Character)
end

player.CharacterAdded:Connect(restoreMovementState)
