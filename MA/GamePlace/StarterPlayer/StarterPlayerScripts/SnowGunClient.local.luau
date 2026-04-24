local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local SnowGunShared = require(ReplicatedStorage:WaitForChild("SnowGunShared"))

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local Camera = Workspace.CurrentCamera

local Events = ReplicatedStorage:WaitForChild("Events")
local GunInteractEvent = Events:WaitForChild("SnowGunInteract")
local PreferenceSync = Events:FindFirstChild("PlayerPreferenceSync")

local PlacedObjects = Workspace:WaitForChild("PlacedObjects")

local ScreenGui = PlayerGui:WaitForChild("SnowGunUI")
local MainFrame = ScreenGui:WaitForChild("Main")
local Header = MainFrame:WaitForChild("Header")
local Subtitle = Header:WaitForChild("Subtitle")
local CloseBtn = Header:WaitForChild("CloseButton")

local SpeedContainer = MainFrame:WaitForChild("SpeedContainer")
local SettingsContainer = MainFrame:WaitForChild("SettingsContainer")

local BtnSlow = SpeedContainer:WaitForChild("SLOW")
local BtnMed = SpeedContainer:WaitForChild("MEDIUM")
local BtnFast = SpeedContainer:WaitForChild("FAST")
local BtnOff = SpeedContainer:WaitForChild("OFF")

local BtnMute = SettingsContainer:WaitForChild("MUTE SOUND")
local BtnPerf = SettingsContainer:WaitForChild("PERF MODE")

local GunNames = SnowGunShared.GetItemNames(true)
local ActiveModel = nil
local modelHooks = {}

local soundMuted = false
local perfMode = false

local applyMuteToAllModels

local uiScale = MainFrame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
uiScale.Parent = MainFrame

local function bindButton(button, callback)
	if not button or not button:IsA("GuiButton") then
		return
	end
	button.Active = true
	button.Selectable = true
	button.AutoButtonColor = true
	button.Activated:Connect(callback)
end

local function isInteractionBlocked()
	local modeState = PlayerGui:FindFirstChild("ModeState") or ReplicatedStorage:FindFirstChild("ModeState")
	local modeValue = modeState and modeState.Value or ""
	return modeValue ~= ""
end

local function getStoredSettings()
	if PreferenceSync and PreferenceSync:IsA("RemoteFunction") then
		local ok, payload = pcall(function()
			return PreferenceSync:InvokeServer("Get")
		end)
		if ok and type(payload) == "table" and type(payload.Settings) == "table" then
			return payload.Settings
		end
	end
	return nil
end

soundMuted = Player:GetAttribute("Settings_SnowGunMute") == true
perfMode = Player:GetAttribute("Settings_SnowGunPerf") == true
Player:SetAttribute("Settings_SnowGunMute", soundMuted)
Player:SetAttribute("Settings_SnowGunPerf", perfMode)

local function saveSetting(key, value)
	Player:SetAttribute("Settings_" .. key, value)
	if PreferenceSync and PreferenceSync:IsA("RemoteFunction") then
		task.spawn(function()
			pcall(function()
				PreferenceSync:InvokeServer("SetSettings", {[key] = value})
			end)
		end)
	end
end

local function setButtonVisual(button, enabled)
	local targetColor = enabled and Color3.fromRGB(50, 50, 60) or Color3.fromRGB(35, 35, 40)
	TweenService:Create(button, TweenInfo.new(0.18), {BackgroundColor3 = targetColor}):Play()
	
	local indicator = button:FindFirstChild("Indicator")
	if indicator then
		indicator.BackgroundTransparency = enabled and 0 or 0.82
	end
	local stroke = button:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Transparency = enabled and 0 or 0.45
	end
	local label = button:FindFirstChildWhichIsA("TextLabel")
	if label then
		label.TextColor3 = enabled and Color3.fromRGB(240, 240, 245) or Color3.fromRGB(180, 180, 188)
	end
end

local function updateSpeedVisuals(currentState)
	local stateUpper = currentState and currentState:upper() or "OFF"
	for _, data in ipairs({
		{Btn = BtnSlow, State = "SLOW"},
		{Btn = BtnMed, State = "MEDIUM"},
		{Btn = BtnFast, State = "FAST"},
		{Btn = BtnOff, State = "OFF"},
	}) do
		setButtonVisual(data.Btn, data.State == stateUpper)
	end
end

local function updateSettingsVisuals()
	setButtonVisual(BtnMute, soundMuted)
	setButtonVisual(BtnPerf, perfMode)
end

task.spawn(function()
	local storedSettings = getStoredSettings()
	if type(storedSettings) ~= "table" then
		return
	end
	
	soundMuted = storedSettings.SnowGunMute == true or soundMuted
	perfMode = storedSettings.SnowGunPerf == true or perfMode
	Player:SetAttribute("Settings_SnowGunMute", soundMuted)
	Player:SetAttribute("Settings_SnowGunPerf", perfMode)
	
	updateSettingsVisuals()
	applyMuteToAllModels()
end)

local function cacheOriginalVolume(sound)
	if not sound or not sound:IsA("Sound") then
		return nil
	end
	local original = sound:GetAttribute("SnowGunOriginalVolume")
	if type(original) ~= "number" then
		original = sound.Volume
		sound:SetAttribute("SnowGunOriginalVolume", original)
	end
	return original
end

local function applyMuteToModel(model)
	local rig = SnowGunShared.ResolveRig(model)
	if not rig then
		return
	end
	for _, sound in ipairs({rig.WaterSound, rig.RunSound, rig.CompressorSound, rig.PressureSound}) do
		if sound then
			local original = cacheOriginalVolume(sound)
			if original then
				sound.Volume = soundMuted and 0 or original
			end
		end
	end
end

local function forEachSnowGun(callback)
	for _, model in ipairs(PlacedObjects:GetDescendants()) do
		if model:IsA("Model") and SnowGunShared.IsSnowGunName(model.Name) then
			callback(model)
		end
	end
	for _, model in ipairs(Workspace:GetChildren()) do
		if model ~= PlacedObjects and model:IsA("Model") and SnowGunShared.IsSnowGunName(model.Name) then
			callback(model)
		end
	end
end

applyMuteToAllModels = function()
	forEachSnowGun(applyMuteToModel)
end

local function hookModel(model)
	if modelHooks[model] or not SnowGunShared.IsSnowGunName(model.Name) then
		return
	end
	
	modelHooks[model] = {
		state = model:GetAttributeChangedSignal("State"):Connect(function()
			task.defer(function()
				if model.Parent then
					applyMuteToModel(model)
					if ActiveModel == model then
						updateSpeedVisuals(model:GetAttribute("State") or "Off")
					end
				end
			end)
		end),
		desc = model.DescendantAdded:Connect(function(desc)
			if desc:IsA("Sound") then
				task.defer(function()
					if model.Parent then
						applyMuteToModel(model)
					end
				end)
			end
		end),
	}
	applyMuteToModel(model)
end

forEachSnowGun(hookModel)
PlacedObjects.ChildAdded:Connect(function(child)
	if SnowGunShared.IsSnowGunName(child.Name) then
		hookModel(child)
	end
end)
Workspace.ChildAdded:Connect(function(child)
	if child ~= PlacedObjects and SnowGunShared.IsSnowGunName(child.Name) then
		hookModel(child)
	end
end)

local function closeMenu()
	local t = TweenService:Create(uiScale, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {Scale = 0.85})
	t:Play()
	t.Completed:Once(function()
		if ActiveModel == nil then
			ScreenGui.Enabled = false
			MainFrame.Visible = false
		end
	end)
	ActiveModel = nil
end

local function openMenu(model)
	if not model then
		return
	end
	
	ActiveModel = model
	Subtitle.Text = "SYSTEM: " .. string.upper(model.Name)
	
	ScreenGui.Enabled = true
	MainFrame.Visible = true
	MainFrame.BackgroundTransparency = 0
	uiScale.Scale = 0.85
	
	updateSpeedVisuals(model:GetAttribute("State") or "Off")
	updateSettingsVisuals()
	applyMuteToModel(model)
	
	TweenService:Create(uiScale, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}):Play()
end

local function tryOpenFromScreenPosition(position)
	if isInteractionBlocked() then
		return
	end
	
	local unitRay = Camera:ScreenPointToRay(position.X, position.Y)
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Include
	rayParams.FilterDescendantsInstances = {PlacedObjects, Workspace}
	
	local result = Workspace:Raycast(unitRay.Origin, unitRay.Direction * 1000, rayParams)
	if not (result and result.Instance) then
		return
	end
	
	local model = result.Instance
	while model and model.Parent ~= PlacedObjects and model.Parent ~= Workspace do
		model = model.Parent
	end
	
	if model and table.find(GunNames, model.Name) then
		openMenu(model)
	end
end

UserInputService.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		tryOpenFromScreenPosition(input.Position)
	end
end)

local function sendState(state)
	if not ActiveModel then
		return
	end
	GunInteractEvent:FireServer("SetState", {Model = ActiveModel, State = state})
	updateSpeedVisuals(state)
	applyMuteToModel(ActiveModel)
end

bindButton(BtnSlow, function() sendState("Slow") end)
bindButton(BtnMed, function() sendState("Medium") end)
bindButton(BtnFast, function() sendState("Fast") end)
bindButton(BtnOff, function() sendState("Off") end)

bindButton(BtnMute, function()
	soundMuted = not soundMuted
	saveSetting("SnowGunMute", soundMuted)
	updateSettingsVisuals()
	applyMuteToAllModels()
end)

bindButton(BtnPerf, function()
	perfMode = not perfMode
	saveSetting("SnowGunPerf", perfMode)
	updateSettingsVisuals()
end)

bindButton(CloseBtn, closeMenu)

Player:GetAttributeChangedSignal("Settings_SnowGunMute"):Connect(function()
	soundMuted = Player:GetAttribute("Settings_SnowGunMute") == true
	updateSettingsVisuals()
	applyMuteToAllModels()
end)

Player:GetAttributeChangedSignal("Settings_SnowGunPerf"):Connect(function()
	perfMode = Player:GetAttribute("Settings_SnowGunPerf") == true
	updateSettingsVisuals()
end)

GunInteractEvent.OnClientEvent:Connect(function(action, args)
	if action == "OpenUI" and args and args.Model then
		openMenu(args.Model)
	end
end)

ScreenGui.Enabled = false
MainFrame.Visible = false
updateSettingsVisuals()

print("[SnowGunClient] UI reconnected.")