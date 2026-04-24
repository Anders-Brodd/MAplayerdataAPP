--[[
Script: SandboxClient
Description: Handles UI interactions, animations, and remote events for the SandboxPanel. Integrates with the MainHUD Dock to control Sandbox button visibility and interaction strictly based on slot type.
Old Features: Verified authorization with SandboxServer. Hooked up all UI buttons for Economy, Guests, Weather, World, and Debug categories. Polled and updated debug stats. Managed tab switching and open/close animations. Bound 'P' key to toggle the UI. Flashed a warning if opening was attempted in a normal slot.
Added/Removed: Removed the 'P' keybind completely as requested. The menu can now only be opened via the dock button. The dock button is strictly hidden unless the current session is an explicitly authorized Sandbox slot. Added a hard lockout preventing the menu from opening or any action buttons from firing if the slot is not a Sandbox slot.
]]

-- SCRIPT: SandboxClient (StarterPlayerScripts)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local Gui = PlayerGui:FindFirstChild("SandboxUI") or PlayerGui:FindFirstChild("SandboxPanel")
if not Gui then
	Gui = PlayerGui:WaitForChild("SandboxUI", 10) or PlayerGui:WaitForChild("SandboxPanel", 10)
end

-- Dock Button Ref
local MainHUD = PlayerGui:WaitForChild("MainHUD", 10)
local Dock = MainHUD and MainHUD:WaitForChild("Dock", 10)
local DockAspectConstraint = Dock and Dock:FindFirstChild("UIAspectRatioConstraint")
local DefaultDockAspectRatio = DockAspectConstraint and DockAspectConstraint.AspectRatio or nil
local SandboxDockAspectRatio = DefaultDockAspectRatio and ((DefaultDockAspectRatio / 5) * 6) or nil
local SandBoxDockBtn = Dock and (Dock:FindFirstChild("SandBox") or Dock:WaitForChild("SandBox", 10))

if SandBoxDockBtn then
	SandBoxDockBtn.Visible = false -- Hidden until authorized
end

local Main = nil
local Header = nil
local TitleLabel = nil
local CloseBtn = nil
local TabsFrame = nil
local ContentScroll = nil

local function findFirstChildByNames(parent, names)
	if not parent then
		return nil
	end
	for _, name in ipairs(names) do
		local child = parent:FindFirstChild(name)
		if child then
			return child
		end
	end
	return nil
end

local function bindButtonPress(button, callback)
	if not button or not button:IsA("GuiButton") then
		return
	end
	button.Active = true
	button.Selectable = true
	button.AutoButtonColor = true
	button.Activated:Connect(callback)
end

-- ─── REMOTES ─────────────────────────────────────────────
local SandboxEvents = ReplicatedStorage:WaitForChild("SandboxEvents", 10)
if not SandboxEvents then return end

local SandboxAction = SandboxEvents:WaitForChild("SandboxAction")
local SandboxAuth   = SandboxEvents:WaitForChild("SandboxAuth")

local Events = ReplicatedStorage:WaitForChild("Events")
local ClosePanels = Events:FindFirstChild("ClosePanels")
if not ClosePanels then
	ClosePanels = Instance.new("BindableEvent")
	ClosePanels.Name = "ClosePanels"
	ClosePanels.Parent = Events
end

-- ─── AUTH CHECK ──────────────────────────────────────────
local authorized = false

local function applyDockVisibility()
	if SandBoxDockBtn and SandBoxDockBtn.Parent then
		SandBoxDockBtn.Visible = authorized
	end
	if DockAspectConstraint and DefaultDockAspectRatio then
		DockAspectConstraint.AspectRatio = authorized and (SandboxDockAspectRatio or DefaultDockAspectRatio) or DefaultDockAspectRatio
	end
end

local function refreshAuthorization()
	local ok, res = pcall(function() return SandboxAuth:InvokeServer() end)
	if not ok or type(res) ~= "table" then
		return
	end

	local nextAuthorized = (res.allowed == true) and (res.isSandboxSlot == true)
	local wasAuthorized = authorized
	authorized = nextAuthorized
	applyDockVisibility()

	if authorized and not wasAuthorized then
	
	end
end

task.spawn(function()
	task.wait(2) -- Give SlotDataLoader time to initialize
	for i = 1, 6 do
		refreshAuthorization()
		if authorized then
			break
		end
		task.wait(i <= 4 and 1 or 3)
	end
end)

if SandBoxDockBtn then
	SandBoxDockBtn:GetPropertyChangedSignal("Visible"):Connect(function()
		if authorized and not SandBoxDockBtn.Visible then
			task.defer(applyDockVisibility)
		end
	end)
end

Player:GetAttributeChangedSignal("SandboxMode"):Connect(function()
	task.defer(refreshAuthorization)
end)

local slotData = ReplicatedStorage:WaitForChild("SlotData", 30)
if slotData then
	slotData:GetAttributeChangedSignal("SandboxMode"):Connect(function()
		task.defer(refreshAuthorization)
	end)
	-- Check immediately in case attribute was already set
	task.defer(refreshAuthorization)
end

-- Attribute changes above handle later sandbox-mode transitions without permanent polling.

if not Gui then
	
	return
end

Main = Gui:FindFirstChild("Main") or Gui:WaitForChild("Main")
Header = Main:WaitForChild("Header")
TitleLabel = findFirstChildByNames(Header, {"TitleLabel", "Title"})
CloseBtn = findFirstChildByNames(Header, {"CloseBtn", "CloseBtnButton", "Close"})
TabsFrame = findFirstChildByNames(Main, {"TabsFrame"}) or findFirstChildByNames(Header, {"CategoryTabs", "TabsFrame"})
ContentScroll = Main:WaitForChild("ContentScroll")

if not CloseBtn or not TabsFrame then
	warn("[SandboxClient] Sandbox UI is missing required header controls.")
	return
end

local function Fire(cat, act, params)
	if not authorized then return end -- Strict lock: Cannot fire events if not authorized
	SandboxAction:FireServer(cat, act, params or {})
end

-- ─── ANIMATION / BUTTON HELPERS ──────────────────────────
local T = {
	BgAccent  = Color3.fromRGB(17, 19, 24),
	TextMain  = Color3.fromRGB(240, 240, 245),
	Red       = Color3.fromRGB(255, 8, 53),
	SandboxGold = Color3.fromRGB(255, 190, 30),
}

local function animateBtn(btn)
	local initColor = btn.BackgroundColor3
	btn.MouseEnter:Connect(function()
		TweenService:Create(btn, TweenInfo.new(0.1), {BackgroundColor3=Color3.new(math.min(initColor.R+0.06,1), math.min(initColor.G+0.06,1), math.min(initColor.B+0.06,1))}):Play()
	end)
	btn.MouseLeave:Connect(function()
		TweenService:Create(btn, TweenInfo.new(0.1), {BackgroundColor3=initColor}):Play()
	end)
	return function()
		TweenService:Create(btn, TweenInfo.new(0.05), {Size=UDim2.new(1, -4, 0, 32)}):Play()
		task.wait(0.05)
		TweenService:Create(btn, TweenInfo.new(0.1), {Size=UDim2.new(1, 0, 0, 36)}):Play()
	end
end

-- Hook up an action to a button by name inside a UI frame
local function hookAction(parent, btnName, cb)
	local btn = parent:FindFirstChild(btnName, true)
	if btn and btn:IsA("TextButton") then
		local anim = animateBtn(btn)
		bindButtonPress(btn, function()
			if not authorized then return end -- Strict lock: UI buttons do nothing
			anim()
			cb()
		end)
	end
end

-- ─── BIND ACTIONS ────────────────────────────────────────

-- Economy
local pEcon = ContentScroll:WaitForChild("Economy")
hookAction(pEcon, "Add1K",   function() Fire("Economy", "Add", {amount=1000}) end)
hookAction(pEcon, "Add10K",  function() Fire("Economy", "Add", {amount=10000}) end)
hookAction(pEcon, "Add100K", function() Fire("Economy", "Add", {amount=100000}) end)
hookAction(pEcon, "Add1M",   function() Fire("Economy", "Add", {amount=1000000}) end)
hookAction(pEcon, "MaxCash", function() Fire("Economy", "Max") end)
hookAction(pEcon, "SetBtn",  function()
	local inp = pEcon:FindFirstChild("Input", true)
	if inp then local v = tonumber(inp.Text) if v then Fire("Economy", "Set", {amount=v}) end end
end)
hookAction(pEcon, "ResetBtn",function() Fire("Economy", "Reset") end)
hookAction(pEcon, "AutoIncome", function() Fire("Economy", "ToggleAutoIncome") end)
hookAction(pEcon, "TriggerSpike", function() Fire("Economy", "TriggerSpike") end)

-- Guests
local pGuest = ContentScroll:WaitForChild("Guests")
hookAction(pGuest, "Spawn5",   function() Fire("Guests", "Spawn", {count=5}) end)
hookAction(pGuest, "Spawn25",  function() Fire("Guests", "Spawn", {count=25}) end)
hookAction(pGuest, "Spawn100", function() Fire("Guests", "Spawn", {count=100}) end)
hookAction(pGuest, "Spawn500", function() Fire("Guests", "Spawn", {count=500}) end)
hookAction(pGuest, "ClearAll", function() Fire("Guests", "Clear") end)
hookAction(pGuest, "KillAll",  function() Fire("Guests", "KillAll") end)
hookAction(pGuest, "MaxHappy", function() Fire("Guests", "MaxHappy") end)
hookAction(pGuest, "Miserable",function() Fire("Guests", "Miserable") end)
hookAction(pGuest, "Freeze",   function() Fire("Guests", "Freeze") end)
hookAction(pGuest, "Unfreeze", function() Fire("Guests", "Unfreeze") end)
hookAction(pGuest, "GiveSkis", function() Fire("Guests", "GiveSkis") end)
hookAction(pGuest, "FreezeAI", function() Fire("Guests", "FreezeAI") end)
hookAction(pGuest, "ForceSki", function() Fire("Guests", "ForceSki") end)

-- Weather
local pWeath = ContentScroll:WaitForChild("Weather")
hookAction(pWeath, "Clear",    function() Fire("Weather", "Preset", {preset="Clear"}) end)
hookAction(pWeath, "LightSnow",function() Fire("Weather", "Preset", {preset="LightSnow"}) end)
hookAction(pWeath, "HeavySnow",function() Fire("Weather", "Preset", {preset="HeavySnow"}) end)
hookAction(pWeath, "Blizzard", function() Fire("Weather", "Preset", {preset="Blizzard"}) end)
hookAction(pWeath, "Winter",   function() Fire("Weather", "Season", {season="Winter"}) end)
hookAction(pWeath, "Spring",   function() Fire("Weather", "Season", {season="Spring"}) end)
hookAction(pWeath, "Summer",   function() Fire("Weather", "Season", {season="Summer"}) end)
hookAction(pWeath, "Fall",     function() Fire("Weather", "Season", {season="Autumn"}) end)
hookAction(pWeath, "Dawn",     function() Fire("Time", "SetClock", {hour=6}) end)
hookAction(pWeath, "Noon",     function() Fire("Time", "SetClock", {hour=12}) end)
hookAction(pWeath, "Sunset",   function() Fire("Time", "SetClock", {hour=19}) end)
hookAction(pWeath, "Midnight", function() Fire("Time", "SetClock", {hour=0}) end)
hookAction(pWeath, "Pause",    function() Fire("Time", "Pause") end)
hookAction(pWeath, "Normal",   function() Fire("Time", "SpeedNormal") end)
hookAction(pWeath, "Speed2x",  function() Fire("Time", "Speed2x") end)
hookAction(pWeath, "Speed10x", function() Fire("Time", "Speed10x") end)
hookAction(pWeath, "NextDay",  function() Fire("Time", "NextDay") end)

-- World
local pWorld = ContentScroll:WaitForChild("World")
hookAction(pWorld, "TpPeak",      function() Fire("World", "TeleportTop") end)
hookAction(pWorld, "TpBottom",    function() Fire("World", "TeleportBottom") end)
hookAction(pWorld, "ClearTrees",  function() Fire("World", "ClearTrees") end)
hookAction(pWorld, "RandomTrees", function() Fire("World", "RandomizeTrees") end)
hookAction(pWorld, "ClearSlopes", function() Fire("World", "ClearSlopes") end)
hookAction(pWorld, "ClearPaths",  function() Fire("World", "ClearPaths") end)
hookAction(pWorld, "FillLifts",   function() Fire("World", "FillLifts") end)
hookAction(pWorld, "ResetQueues", function() Fire("World", "ResetQueues") end)
hookAction(pWorld, "ClearBuildings", function() Fire("World", "ClearBuildings") end)
hookAction(pWorld, "NukeAll",     function()
	Fire("World", "ClearSlopes") Fire("World", "ClearTrees") Fire("Guests", "Clear") Fire("World", "ClearBuildings")
end)

-- Debug
local pDebug = ContentScroll:WaitForChild("Debug")
local sandboxTargetRoster = {}
local sandboxTargetIndex = 1

local debugActionRow = pDebug:FindFirstChild("Row2_DevActs")
if not debugActionRow then
	debugActionRow = Instance.new("Frame")
	debugActionRow.Name = "Row2_DevActs"
	debugActionRow.Size = UDim2.new(1, 0, 0, 36)
	debugActionRow.BackgroundTransparency = 1
	debugActionRow.LayoutOrder = 5
	debugActionRow.Parent = pDebug
end

debugActionRow.BackgroundTransparency = 1
debugActionRow.LayoutOrder = 5
debugActionRow.Size = UDim2.new(1, 0, 0, 36)

local debugActionLayout = debugActionRow:FindFirstChildOfClass("UIGridLayout")
if not debugActionLayout then
	debugActionLayout = Instance.new("UIGridLayout")
	debugActionLayout.Parent = debugActionRow
end
debugActionLayout.CellSize = UDim2.new(0.49, 0, 1, 0)
debugActionLayout.CellPadding = UDim2.new(0.02, 0, 0, 0)
debugActionLayout.FillDirectionMaxCells = 2
debugActionLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
debugActionLayout.SortOrder = Enum.SortOrder.LayoutOrder

local function ensureDebugActionButton(buttonName, buttonText, color, order)
	local button = debugActionRow:FindFirstChild(buttonName)
	if not (button and button:IsA("TextButton")) then
		button = Instance.new("TextButton")
		button.Name = buttonName
		button.Parent = debugActionRow
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = button
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(18, 22, 28)
		stroke.Transparency = 0.15
		stroke.Parent = button
		local padding = Instance.new("UIPadding")
		padding.PaddingLeft = UDim.new(0, 8)
		padding.PaddingRight = UDim.new(0, 8)
		padding.Parent = button
	end
	button.LayoutOrder = order or 1
	button.Size = UDim2.new(1, 0, 1, 0)
	button.BackgroundColor3 = color or Color3.fromRGB(17, 19, 24)
	button.TextColor3 = Color3.fromRGB(240, 240, 245)
	button.Text = buttonText
	button.Font = Enum.Font.GothamBold
	button.TextSize = 14
	button.TextScaled = true
	button.Visible = true
	button.Active = true
	button.Selectable = true
	button.AutoButtonColor = true
	button.ZIndex = 2
	return button
end

local targetRow = Instance.new("Frame")
targetRow.Name = "TargetPlayerRow"
targetRow.Size = UDim2.new(1, 0, 0, 36)
targetRow.BackgroundColor3 = Color3.fromRGB(17, 19, 24)
targetRow.LayoutOrder = 1
targetRow.Parent = pDebug
local targetCorner = Instance.new("UICorner")
targetCorner.CornerRadius = UDim.new(0, 8)
targetCorner.Parent = targetRow

local targetPrev = Instance.new("TextButton")
targetPrev.Name = "TargetPrev"
targetPrev.Size = UDim2.fromOffset(32, 28)
targetPrev.Position = UDim2.fromOffset(8, 4)
targetPrev.BackgroundColor3 = Color3.fromRGB(34, 37, 43)
targetPrev.Text = "<"
targetPrev.TextColor3 = Color3.fromRGB(240, 240, 245)
targetPrev.Font = Enum.Font.GothamBlack
targetPrev.TextSize = 16
targetPrev.Parent = targetRow
local targetPrevCorner = Instance.new("UICorner")
targetPrevCorner.CornerRadius = UDim.new(0, 8)
targetPrevCorner.Parent = targetPrev

local targetNext = Instance.new("TextButton")
targetNext.Name = "TargetNext"
targetNext.Size = UDim2.fromOffset(32, 28)
targetNext.Position = UDim2.new(1, -40, 0, 4)
targetNext.BackgroundColor3 = Color3.fromRGB(34, 37, 43)
targetNext.Text = ">"
targetNext.TextColor3 = Color3.fromRGB(240, 240, 245)
targetNext.Font = Enum.Font.GothamBlack
targetNext.TextSize = 16
targetNext.Parent = targetRow
local targetNextCorner = Instance.new("UICorner")
targetNextCorner.CornerRadius = UDim.new(0, 8)
targetNextCorner.Parent = targetNext

local targetLabel = Instance.new("TextLabel")
targetLabel.Name = "TargetLabel"
targetLabel.Size = UDim2.new(1, -92, 1, 0)
targetLabel.Position = UDim2.fromOffset(46, 0)
targetLabel.BackgroundTransparency = 1
targetLabel.TextColor3 = Color3.fromRGB(240, 240, 245)
targetLabel.Font = Enum.Font.GothamBold
targetLabel.TextSize = 13
targetLabel.Text = "Target: You"
targetLabel.Parent = targetRow

local function refreshSandboxTargetUi()
	sandboxTargetRoster = {Player}
	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		if otherPlayer ~= Player then
			table.insert(sandboxTargetRoster, otherPlayer)
		end
	end
	table.sort(sandboxTargetRoster, function(a, b)
		if a == Player then return true end
		if b == Player then return false end
		return string.lower(a.DisplayName) < string.lower(b.DisplayName)
	end)
	if sandboxTargetIndex > #sandboxTargetRoster then
		sandboxTargetIndex = 1
	end
	if sandboxTargetIndex < 1 then
		sandboxTargetIndex = 1
	end
	local targetPlayer = sandboxTargetRoster[sandboxTargetIndex] or Player
	if targetPlayer == Player then
		targetLabel.Text = "Target: You"
	else
		targetLabel.Text = "Target: " .. targetPlayer.DisplayName .. " (@" .. targetPlayer.Name .. ")"
	end
end

local function getSandboxTargetPlayer()
	return sandboxTargetRoster[sandboxTargetIndex] or Player
end

bindButtonPress(targetPrev, function()
	if #sandboxTargetRoster <= 1 then return end
	sandboxTargetIndex -= 1
	if sandboxTargetIndex < 1 then
		sandboxTargetIndex = #sandboxTargetRoster
	end
	refreshSandboxTargetUi()
end)

bindButtonPress(targetNext, function()
	if #sandboxTargetRoster <= 1 then return end
	sandboxTargetIndex += 1
	if sandboxTargetIndex > #sandboxTargetRoster then
		sandboxTargetIndex = 1
	end
	refreshSandboxTargetUi()
end)

Players.PlayerAdded:Connect(function()
	refreshSandboxTargetUi()
end)
Players.PlayerRemoving:Connect(function()
	refreshSandboxTargetUi()
end)
refreshSandboxTargetUi()

ensureDebugActionButton("MaxAllStats", "Max all stats", Color3.fromRGB(56, 78, 118), 1)
ensureDebugActionButton("UnlockResearch", "Unlock all research", Color3.fromRGB(120, 60, 230), 2)

if not pDebug:FindFirstChild("RatingInput") then
	local function createRowBtn(name, text, color)
		local b = Instance.new("TextButton")
		b.Name = name
		b.Size = UDim2.new(1, 0, 0, 36)
		b.BackgroundColor3 = color or Color3.fromRGB(17, 19, 24)
		b.TextColor3 = Color3.fromRGB(240, 240, 245)
		b.Text = text
		b.Font = Enum.Font.GothamMedium
		b.TextSize = 14
		local c = Instance.new("UICorner", b); c.CornerRadius = UDim.new(0, 8)
		b.Parent = pDebug
		return b
	end

	local newInp = Instance.new("TextBox")
	newInp.Name = "RatingInput"
	newInp.Size = UDim2.new(1, 0, 0, 36)
	newInp.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
	newInp.TextColor3 = Color3.new(1, 1, 1)
	newInp.Text = "5"
	newInp.PlaceholderText = "Type rating then press ENTER"
	newInp.Font = Enum.Font.GothamMedium
	newInp.TextSize = 14
	local c = Instance.new("UICorner", newInp); c.CornerRadius = UDim.new(0, 8)
	newInp.Parent = pDebug

	local setBtn = createRowBtn("SetRatingBtn", "Set Rating to Input", Color3.fromRGB(17, 50, 90))

	-- Just fire on enter instead of needing a button!
	newInp.FocusLost:Connect(function()
		local v = tonumber(newInp.Text)
		local targetPlayer = getSandboxTargetPlayer()
		if v and targetPlayer then
			Fire("Debug", "SetRating", {value = v, targetUserId = targetPlayer.UserId, targetName = targetPlayer.Name})
		end
	end)
end

hookAction(pDebug, "RefreshStats", function() Fire("Debug", "GetStats") end)
hookAction(pDebug, "MaxAllStats",  function()
	local targetPlayer = getSandboxTargetPlayer()
	Fire("Debug", "MaxAllStats", {targetUserId = targetPlayer.UserId, targetName = targetPlayer.Name})
end)
hookAction(pDebug, "UnlockResearch",function()
	local targetPlayer = getSandboxTargetPlayer()
	Fire("Debug", "UnlockResearch", {targetUserId = targetPlayer.UserId, targetName = targetPlayer.Name})
end)
hookAction(pDebug, "SetRatingBtn", function()
	local inp = pDebug:FindFirstChild("RatingInput", true)
	local targetPlayer = getSandboxTargetPlayer()
	if inp and targetPlayer then
		local v = tonumber(inp.Text)
		if v then
			Fire("Debug", "SetRating", {value = v, targetUserId = targetPlayer.UserId, targetName = targetPlayer.Name})
		end
	end
end)

-- STATS LOOP
local statsGrid = pDebug:WaitForChild("StatsGrid")
task.spawn(function()
	while task.wait(1) do
		if not authorized then continue end
		if Main.Visible then
			Fire("Debug", "GetStats")
		end
		local get = function(n) local s=statsGrid:FindFirstChild(n) return s and s:FindFirstChild("Val") end
		local gVal = get("StatGuests"); if gVal then gVal.Text = tostring(Player:GetAttribute("SB_GuestCount") or "?") end
		local mVal = get("StatMoney"); if mVal then mVal.Text = "$"..(Player:GetAttribute("SB_Money") or "?") end
		local tVal = get("StatTemp"); if tVal then tVal.Text = math.floor(tonumber(Player:GetAttribute("SB_Temp")) or 0).."°C" end
		local wVal = get("StatWind"); if wVal then wVal.Text = tostring(math.floor(tonumber(Player:GetAttribute("SB_WindSpeed")) or 0)) end
		local sVal = get("StatSeason"); if sVal then sVal.Text = tostring(Player:GetAttribute("SB_Season") or "?") end
		local snVal = get("StatSnow"); if snVal then snVal.Text = tostring(math.floor(tonumber(Player:GetAttribute("SB_SnowRate")) or 0)) end
	end
end)

-- ─── NAV LOGIC ───────────────────────────────────────────
local SECTIONS = {"Economy", "Guests", "Weather", "World", "Debug"}
local activeSection = nil

local function refreshContentCanvas()
	local page = activeSection and ContentScroll:FindFirstChild(activeSection)
	if not page then return end
	local targetHeight = math.max(page.AbsoluteSize.Y + 20, ContentScroll.AbsoluteWindowSize.Y + 4)
	ContentScroll.CanvasSize = UDim2.new(0, 0, 0, targetHeight)
end

local function SwitchTab(id)
	activeSection = id
	for _, sec in ipairs(SECTIONS) do
		local pg = ContentScroll:FindFirstChild(sec)
		local btn = TabsFrame:FindFirstChild(sec)
		if not pg or not btn then continue end
		pg.Visible = (sec == id)
		if sec == id then
			TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3=Color3.fromRGB(17,50,90), TextColor3=Color3.fromRGB(100,190,255)}):Play()
			ContentScroll.CanvasPosition = Vector2.new(0, 0)
			task.defer(refreshContentCanvas)
		else
			TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3=T.BgAccent, TextColor3=T.TextMain}):Play()
		end
	end
end

for _, sec in ipairs(SECTIONS) do
	local btn = TabsFrame:FindFirstChild(sec)
	if btn then
		bindButtonPress(btn, function()
			SwitchTab(sec)
		end)
	end
	local page = ContentScroll:FindFirstChild(sec)
	if page then
		page:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			if activeSection == sec then
				task.defer(refreshContentCanvas)
			end
		end)
	end
end
ContentScroll:GetPropertyChangedSignal("AbsoluteWindowSize"):Connect(function()
	task.defer(refreshContentCanvas)
end)
SwitchTab("Economy")

-- ─── OPEN / CLOSE ANIMATION ──────────────────────────────
local isOpen = false
local uiScale = nil
local panelTweenToken = 0
local activeBackgroundTween = nil
local activeScaleTween = nil
if not Main:FindFirstChild("UIScale") then
	uiScale = Instance.new("UIScale")
	uiScale.Parent = Main
else
	uiScale = Main:FindFirstChild("UIScale")
end

local function cancelPanelTweens()
	if activeBackgroundTween then
		activeBackgroundTween:Cancel()
		activeBackgroundTween = nil
	end
	if activeScaleTween then
		activeScaleTween:Cancel()
		activeScaleTween = nil
	end
end

local function OpenPanel()
	if not authorized then return end
	panelTweenToken += 1
	local tweenToken = panelTweenToken
	isOpen = true
	ClosePanels:Fire("Sandbox")
	cancelPanelTweens()
	Main.Visible = true
	Main.Active = true
	uiScale.Scale = 0.8
	Main.BackgroundTransparency = 1
	activeBackgroundTween = TweenService:Create(Main, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		BackgroundTransparency = 0
	})
	activeScaleTween = TweenService:Create(uiScale, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = 1
	})
	activeBackgroundTween:Play()
	activeScaleTween:Play()
	task.delay(0.2, function()
		if tweenToken == panelTweenToken and isOpen then
			Fire("Debug", "GetStats")
		end
	end)
end

local function ClosePanel()
	panelTweenToken += 1
	local tweenToken = panelTweenToken
	isOpen = false
	cancelPanelTweens()
	activeBackgroundTween = TweenService:Create(Main, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		BackgroundTransparency = 1
	})
	activeScaleTween = TweenService:Create(uiScale, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Scale = 0.8
	})
	activeBackgroundTween:Play()
	activeScaleTween:Play()
	task.delay(0.2, function()
		if tweenToken == panelTweenToken and not isOpen then
			Main.Visible = false
		end
	end)
end

ClosePanels.Event:Connect(function(source)
	if source == "Sandbox" then return end
	if isOpen then ClosePanel() end
end)

local function HandleToggleRequest()
	if not authorized then return end -- Strict lock: menu will not open if not authorized
	if isOpen then ClosePanel() else OpenPanel() end
end

bindButtonPress(CloseBtn, ClosePanel)

if SandBoxDockBtn then
	bindButtonPress(SandBoxDockBtn, HandleToggleRequest)
end

-- ─── DRAGGABLE UI ──────────────────────────────────────────
local dragging = false
local dragInput, mousePos, framePos

Header.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		mousePos = input.Position
		framePos = Main.Position

		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				dragging = false
			end
		end)
	end
end)

Header.InputChanged:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
		dragInput = input
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if input == dragInput and dragging then
		local delta = input.Position - mousePos
		Main.Position = UDim2.new(
			framePos.X.Scale, framePos.X.Offset + delta.X,
			framePos.Y.Scale, framePos.Y.Offset + delta.Y
		)
	end
end)