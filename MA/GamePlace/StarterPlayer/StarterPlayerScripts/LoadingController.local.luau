--[[ 
    AAA LOADING SCREEN CONTROLLER - VISIBILITY FIX
]]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local ContentProvider = game:GetService("ContentProvider")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local MONEY_READY_ATTR = "MoneyReady"
local TUTORIAL_READY_ATTR = "TutorialStateReady"
local serverMarkedComplete = false
local loaderClosed = false
local completeMarkedAt = nil
local READY_CLOSE_TIMEOUT_SECONDS = 30
local WORLD_LOCK_CLOSE_TIMEOUT_SECONDS = 30
local MAX_BOOT_CLOSE_TIMEOUT_SECONDS = 75
local loadingUpdateConnection = nil
local worldLockFallbackWarned = false
local bootStartedAt = os.clock()
local forcedRecoveryTriggered = false

local function releaseFocusedTextBox()
	local focused = UserInputService:GetFocusedTextBox()
	if focused then
		pcall(function()
			focused:ReleaseFocus()
		end)
	end
end

local Events = ReplicatedStorage:WaitForChild("Events")
local LoadingUpdate = Events:WaitForChild("LoadingUpdate")

print("Init: Services and references loaded")

-- Configuration
local CONFIG = {
	SlideshowInterval = 6,
	FadeTime = 1.0,
	Images = {
		"rbxassetid://107424416978945", 
		"rbxassetid://76709032150196",
		"rbxassetid://73420874506395",
		"rbxassetid://89639381686848",
	},
	Tips = {
		"Update log: guest fixes are live and guests should ride lifts and ski again.",
		"Update log: we made gameplay fixes and cleanup across guests, UI, and slopes.",
		"Need help or want to report bugs faster? Join our Discord.",
		"If something still feels off after the fixes, send it in Discord."
	}
}

-- 1. Get GUI Safely
print("Init: Waiting for WorldLoadingGui...")
local gui = playerGui:WaitForChild("WorldLoadingGui", 10)
if not gui then 
	warn("Error: Loading GUI not found after 10s")
	return 
end

-- FORCE VISIBILITY
gui.Enabled = true
gui.IgnoreGuiInset = true -- Ensures it covers the top bar
print("Init: GUI found. Forced Enabled = true")

-- 2. Skip if not first player
if #Players:GetPlayers() > 1 then
	print("Init: Not first player, destroying loader")
	gui:Destroy()
	return
end

-- 3. References (With WaitForChild for critical parts)
local main = gui:WaitForChild("MainContainer")
local bgContainer = gui:WaitForChild("BackgroundContainer")

-- FORCE CONTAINER VISIBILITY
main.Visible = true
bgContainer.Visible = true
print("Init: Containers forced Visible = true")

local img1 = bgContainer:WaitForChild("ImageView1")
local img2 = bgContainer:WaitForChild("ImageView2")

img1.Visible = true
img2.Visible = true
img1.ImageTransparency = 0
img2.ImageTransparency = 1
img1.ScaleType = Enum.ScaleType.Crop
img2.ScaleType = Enum.ScaleType.Crop
img1.ResampleMode = Enum.ResamplerMode.Default
img2.ResampleMode = Enum.ResamplerMode.Default

local titleArea = main:WaitForChild("TitleArea")
local statusText = titleArea:WaitForChild("ActionStatus")
local gameTitle = titleArea:FindFirstChild("GameTitle")
local spinner = titleArea:FindFirstChild("LoadingSpinner")

local barContainer = main:WaitForChild("BarContainer")
local barFill = barContainer:WaitForChild("Fill")
local barGlow = barFill:FindFirstChild("Glow")

local tipContainer = main:WaitForChild("TipContainer")
local tipTitle = tipContainer:WaitForChild("TipTitle")
local tipText = tipContainer:WaitForChild("TipText")
print("Init: Child references established")

main.BackgroundColor3 = Color3.fromRGB(9, 14, 20)
main.BackgroundTransparency = 1

for _, section in ipairs({titleArea, barContainer, tipContainer}) do
	section.BackgroundTransparency = 1
	section.BackgroundColor3 = Color3.fromRGB(7, 12, 18)
end
statusText.TextTransparency = 0.02
statusText.TextStrokeTransparency = 0.75
if gameTitle then
	gameTitle.TextTransparency = 0
	gameTitle.TextStrokeTransparency = 0.72
end
if tipTitle then
	tipTitle.TextTransparency = 0.02
	tipTitle.TextStrokeTransparency = 0.78
end
if tipText then
	tipText.TextTransparency = 0.02
	tipText.TextStrokeTransparency = 0.8
end

if tipTitle and tipTitle.Parent then
	tipTitle.Text = "LATEST UPDATE"
end

-- 4. Safe Tween Function (Prevents Errors)
local function tween(inst, props, info)
	if not inst or not inst.Parent then return end
	pcall(function()
		TweenService:Create(inst, info or TweenInfo.new(0.3), props):Play()
	end)
end

-- 5. Background Loop
task.spawn(function()
	print("Loop: Preloading images...")
	local imgInstances = {}
	for _, id in ipairs(CONFIG.Images) do
		local dec = Instance.new("ImageLabel")
		dec.Image = id
		table.insert(imgInstances, dec)
	end
	pcall(function()
		ContentProvider:PreloadAsync(imgInstances)
	end)
	
	print("Loop: Background slideshow started")
	
	local index = 1
	img1.Image = CONFIG.Images[1]
	img1.Size = UDim2.fromScale(1.08, 1.08)
	img1.Position = UDim2.fromScale(-0.04, -0.04)
	img2.ImageTransparency = 1
	img2.Size = UDim2.fromScale(1.08, 1.08)
	img2.Position = UDim2.fromScale(-0.04, -0.04)
	
	while gui.Parent do
		task.wait(CONFIG.SlideshowInterval)
		if not gui.Parent then break end
		
		index = index + 1
		if index > #CONFIG.Images then index = 1 end
		
		img2.Image = CONFIG.Images[index]
		
		tween(img2, {ImageTransparency = 0}, TweenInfo.new(CONFIG.FadeTime))
		tween(img1, {ImageTransparency = 1}, TweenInfo.new(CONFIG.FadeTime))
		task.wait(CONFIG.FadeTime)
		
		-- Swap logic
		img1.Image = img2.Image
		img1.ImageTransparency = 0
		img2.ImageTransparency = 1
	end
end)

-- 7. Animation Loop (Pulse/Rotate)
task.spawn(function()
	print("Loop: Animation effects started")
	local t = 0
	while gui.Parent do
		t = t + 0.05
		-- Spinner
		if spinner and spinner.Parent then
			spinner.Rotation = spinner.Rotation + 3
		end
		-- Title Breath
		if gameTitle and gameTitle.Parent then
			local stroke = gameTitle:FindFirstChildWhichIsA("UIStroke")
			if stroke then
				stroke.Transparency = 0.5 + (math.sin(t) * 0.2)
			end
		end
		-- Glow Pulse
		if barGlow and barGlow.Parent then
			barGlow.BackgroundTransparency = 0.5 + (math.sin(t * 5) * 0.3)
		end
		task.wait(0.03)
	end
end)

-- 8. Tip Loop
task.spawn(function()
	print("Loop: Tips system started")
	while gui.Parent and tipText and tipText.Parent do
		task.wait(5)
		tween(tipText, {TextTransparency = 1}, TweenInfo.new(0.5))
		task.wait(0.5)
		
		if not tipText.Parent then break end
		tipText.Text = CONFIG.Tips[math.random(1, #CONFIG.Tips)]
		
		if tipTitle and tipTitle.Parent then
			tipTitle.Text = "LATEST UPDATE"
		end
		tween(tipText, {TextTransparency = 0}, TweenInfo.new(0.5))
	end
end)

-- 9. Status Updates
local STATUS_SHORTCUTS = {
	{pattern = "teleport", text = "ENTERING RESORT"},
	{pattern = "spawn", text = "SPAWNING YOU"},
	{pattern = "terrain", text = "BUILDING TERRAIN"},
	{pattern = "weather", text = "SETTING WEATHER"},
	{pattern = "guest", text = "PREPARING GUESTS"},
	{pattern = "tree", text = "PLANTING TREES"},
	{pattern = "lift", text = "SETTING LIFTS"},
	{pattern = "final", text = "FINAL TOUCHES"},
}

local function normalizeStatusMessage(msg)
	local raw = tostring(msg or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
	if raw == "" then
		return "LOADING"
	end
	
	local lower = string.lower(raw)
	for _, entry in ipairs(STATUS_SHORTCUTS) do
		if string.find(lower, entry.pattern, 1, true) then
			return entry.text
		end
	end
	
	local upper = string.upper(raw)
	if #upper > 24 then
		upper = upper:sub(1, 21) .. "..."
	end
	return upper
end

local function updateStatus(msg)
	if not statusText or not statusText.Parent then return end
	statusText.Text = normalizeStatusMessage(msg)
	statusText.TextTransparency = 0.02
end

local function updateProgress(val)
	if not barFill or not barFill.Parent then return end
	local cleanVal = math.clamp(tonumber(val) or 0, 0, 100)
	tween(barFill, {Size = UDim2.new(cleanVal/100, 0, 1, 0)}, TweenInfo.new(0.5, Enum.EasingStyle.Quad))
end

local function isWorldLoadLockBlocking()
	if player:GetAttribute("WorldLoadLocked") ~= true then
		return false
	end
	if not serverMarkedComplete then
		return true
	end
	local sinceComplete = completeMarkedAt and (tick() - completeMarkedAt) or 0
	if sinceComplete < WORLD_LOCK_CLOSE_TIMEOUT_SECONDS then
		return true
	end
	if not worldLockFallbackWarned then
		worldLockFallbackWarned = true
		warn("[LoadingController] WorldLoadLocked stayed true after load completed; allowing client recovery fallback.")
	end
	return false
end

local function canCloseLoader()
	if loaderClosed or not serverMarkedComplete then
		return false
	end
	if isWorldLoadLockBlocking() then
		return false
	end
	local sinceComplete = completeMarkedAt and (tick() - completeMarkedAt) or 0

	local moneyReady = player:GetAttribute(MONEY_READY_ATTR) == true
	if not moneyReady then
		local moneyAttr = player:GetAttribute("Money")
		if sinceComplete >= READY_CLOSE_TIMEOUT_SECONDS and typeof(moneyAttr) == "number" then
			moneyReady = true
		else
			return false
		end
	end

	local tutorialReady = player:GetAttribute(TUTORIAL_READY_ATTR) == true
	if not tutorialReady then
		if sinceComplete >= READY_CLOSE_TIMEOUT_SECONDS then
			tutorialReady = true
		else
			return false
		end
	end

	return moneyReady and tutorialReady
end

local function canForceRecoverClientControl()
	if isWorldLoadLockBlocking() then
		return false
	end
	if player:GetAttribute("FreecamActive") == true then
		return false
	end
	local modeState = player:FindFirstChild("PlayerGui") and player.PlayerGui:FindFirstChild("ModeState")
	if modeState and tostring(modeState.Value or "") ~= "" then
		return false
	end
	if workspace:FindFirstChild("PlacementFreecamRoot") or workspace:FindFirstChild("BuilderStudioFreecamRoot") then
		return false
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.SeatPart then
		return false
	end
	return true
end

local function recoverClientControlState()
	if player:GetAttribute("WorldLoadLocked") == true and serverMarkedComplete then
		local sinceComplete = completeMarkedAt and (tick() - completeMarkedAt) or 0
		if sinceComplete >= WORLD_LOCK_CLOSE_TIMEOUT_SECONDS then
			pcall(function()
				player:SetAttribute("WorldLoadLocked", false)
			end)
		end
	end
	local camera = workspace.CurrentCamera
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")

	if root then
		root.Anchored = false
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
	if humanoid then
		humanoid.PlatformStand = false
		humanoid.AutoRotate = true
	end
	if camera then
		camera.CameraType = Enum.CameraType.Custom
		camera.CameraSubject = humanoid or root or camera.CameraSubject
		if camera.CameraSubject == nil and player.Character then
			camera.CameraSubject = player.Character:FindFirstChildOfClass("Humanoid")
		end
	end
	releaseFocusedTextBox()
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true

	local playerScripts = player:FindFirstChild("PlayerScripts")
	local playerModule = playerScripts and playerScripts:FindFirstChild("PlayerModule")
	if playerModule then
		pcall(function()
			local controls = require(playerModule):GetControls()
			if controls then
				controls:Enable()
			end
		end)
	end
end

local function clearStaleSessionBlockers()
	local modeState = playerGui:FindFirstChild("ModeState")
	if modeState and modeState:IsA("StringValue") then
		modeState.Value = ""
	end

	local playerScripts = player:FindFirstChild("PlayerScripts")
	local playerModule = playerScripts and playerScripts:FindFirstChild("PlayerModule")
	if playerModule then
		pcall(function()
			local controls = require(playerModule):GetControls()
			if controls then
				controls:Enable()
			end
		end)
	end

	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Custom
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		camera.CameraSubject = humanoid or root or camera.CameraSubject
	end

	releaseFocusedTextBox()
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

local function forceCloseLoader(reason)
	if loaderClosed or forcedRecoveryTriggered then
		return
	end
	forcedRecoveryTriggered = true
	serverMarkedComplete = true
	completeMarkedAt = completeMarkedAt or os.clock()

	local closePanels = Events:FindFirstChild("ClosePanels")
	if closePanels and closePanels:IsA("BindableEvent") then
		pcall(function()
			closePanels:Fire("LoadingRecovery")
		end)
	end

	releaseFocusedTextBox()
	clearStaleSessionBlockers()
	recoverClientControlState()
	warn(('[LoadingController] Forced loader recovery after %.1fs (%s).'):format(os.clock() - bootStartedAt, tostring(reason or "timeout")))
	closeLoaderIfReady()
end

local function closeLoaderIfReady()
	if not canCloseLoader() then
		return
	end
	loaderClosed = true
	if loadingUpdateConnection then
		loadingUpdateConnection:Disconnect()
		loadingUpdateConnection = nil
	end
	print("Logic: Loading complete condition met")
	task.wait(1)
	tween(main, {Position = UDim2.fromScale(0, -0.1), GroupTransparency = 1}, TweenInfo.new(1))
	tween(bgContainer, {BackgroundTransparency = 1}, TweenInfo.new(1))
	tween(img1, {ImageTransparency = 1}, TweenInfo.new(1))
	tween(img2, {ImageTransparency = 1}, TweenInfo.new(1))
	task.wait(1)
	if gui then
		print("Cleanup: Destroying GUI")
		gui:Destroy()
	end
	task.defer(function()
		for _ = 1, 120 do
			if canForceRecoverClientControl() then
				recoverClientControlState()
			end
			local camera = workspace.CurrentCamera
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if canForceRecoverClientControl() and camera and camera.CameraType == Enum.CameraType.Custom and camera.CameraSubject and humanoid and root then
				break
			end
			task.wait(0.25)
		end
	end)
end

player:GetAttributeChangedSignal("WorldLoadLocked"):Connect(closeLoaderIfReady)
player:GetAttributeChangedSignal(MONEY_READY_ATTR):Connect(closeLoaderIfReady)
player:GetAttributeChangedSignal(TUTORIAL_READY_ATTR):Connect(closeLoaderIfReady)

-- 10. Connection (disconnect when loader closes so Output does not keep showing stale restore lines)
loadingUpdateConnection = LoadingUpdate.OnClientEvent:Connect(function(message, stage, progress)
	if loaderClosed then
		return
	end
	if RunService:IsStudio() then
		print("Event: Status='" .. tostring(message) .. "' | Prog=" .. tostring(progress))
	end
	updateStatus(message)
	updateProgress(progress)

	if (tonumber(progress) or 0) >= 100 or string.match(string.lower(tostring(message)), "complete") then
		if not serverMarkedComplete then
			completeMarkedAt = tick()
		end
		serverMarkedComplete = true
		closeLoaderIfReady()
	end
end)

task.spawn(function()
	while gui.Parent and not loaderClosed do
		task.wait(1)
		if not serverMarkedComplete and (os.clock() - bootStartedAt) >= MAX_BOOT_CLOSE_TIMEOUT_SECONDS then
			forceCloseLoader("boot timeout without server completion")
			break
		end
		if serverMarkedComplete then
			closeLoaderIfReady()
		end
	end
end)