--[=[ PATH: StarterPlayerScripts/CodeBoostHudClient | TYPE: LocalScript ]=]--

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local mainHud = playerGui:WaitForChild("MainHUD")

local hud = Instance.new("Frame")
hud.Name = "CodeBoostHUD"
hud.AnchorPoint = Vector2.new(1, 1)
hud.Position = UDim2.new(1, -12, 1, -12)
hud.Size = UDim2.fromOffset(252, 120)
hud.BackgroundTransparency = 1
hud.BorderSizePixel = 0
hud.Visible = false
hud.Parent = mainHud

local closeButton = Instance.new("TextButton")
closeButton.Name = "CloseButton"
closeButton.Size = UDim2.fromOffset(24, 24)
closeButton.Position = UDim2.new(1, -24, 0, 0)
closeButton.BackgroundColor3 = Color3.fromRGB(24, 27, 34)
closeButton.BackgroundTransparency = 0.08
closeButton.BorderSizePixel = 0
closeButton.Text = "X"
closeButton.TextColor3 = Color3.fromRGB(240, 240, 240)
closeButton.Font = Enum.Font.GothamBold
closeButton.TextSize = 12
closeButton.AutoButtonColor = true
closeButton.Parent = hud
local closeCorner = Instance.new("UICorner")
closeCorner.CornerRadius = UDim.new(0, 7)
closeCorner.Parent = closeButton

local title = Instance.new("TextLabel")
title.Name = "Title"
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(0, 2)
title.Size = UDim2.new(1, -28, 0, 18)
title.Text = "CODE BOOSTS"
title.TextColor3 = Color3.fromRGB(255, 215, 130)
title.Font = Enum.Font.GothamBold
title.TextSize = 12
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = hud

local list = Instance.new("Frame")
list.Name = "List"
list.BackgroundTransparency = 1
list.Position = UDim2.fromOffset(0, 24)
list.Size = UDim2.new(1, 0, 1, -24)
list.Parent = hud

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 6)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = list

local boostRows = {}
local boostsHiddenByPlayer = false

local boostDefs = {
	{ Key = "Money", Prefix = "CodeMoneyBoost", Color = Color3.fromRGB(120, 220, 140) },
	{ Key = "Guests", Prefix = "CodeGuestBoost", Color = Color3.fromRGB(130, 200, 255) },
	{ Key = "Research", Prefix = "CodeResearchBoost", Color = Color3.fromRGB(255, 180, 120) },
}

local function getViewportSize()
	local camera = Workspace.CurrentCamera
	if camera then
		return camera.ViewportSize
	end
	return Vector2.new(1280, 720)
end

local function updateHudSize(visibleRows)
	local viewport = getViewportSize()
	local width = math.clamp(math.floor(viewport.X * 0.22), 212, 288)
	local rowHeight = (viewport.X < 700 or viewport.Y < 500) and 26 or 28
	local titleHeight = 22
	hud.Size = UDim2.fromOffset(width, titleHeight + 6 + (visibleRows * (rowHeight + 6)))
	closeButton.Position = UDim2.new(1, -24, 0, 0)
end

local cameraViewportConnection = nil
local function bindViewportWatcher()
	if cameraViewportConnection then
		cameraViewportConnection:Disconnect()
		cameraViewportConnection = nil
	end
	local camera = Workspace.CurrentCamera
	if camera then
		cameraViewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			if hud.Visible then
				local visibleRows = 0
				for _, row in pairs(boostRows) do
					if row.Visible then
						visibleRows += 1
					end
				end
				updateHudSize(visibleRows)
			end
		end)
	end
end

local function getOrCreateRow(key, color)
	local row = boostRows[key]
	if row and row.Parent then
		return row
	end
	row = Instance.new("Frame")
	row.Name = key
	row.Size = UDim2.new(1, 0, 0, 22)
	row.BackgroundColor3 = Color3.fromRGB(24, 27, 34)
	row.BorderSizePixel = 0
	row.Parent = list
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 7)
	corner.Parent = row

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "Name"
	nameLabel.BackgroundTransparency = 1
	nameLabel.Position = UDim2.fromOffset(8, 0)
	nameLabel.Size = UDim2.new(0.55, 0, 1, 0)
	nameLabel.Text = string.upper(key)
	nameLabel.TextColor3 = color
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextSize = 11
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.Parent = row

	local timerLabel = Instance.new("TextLabel")
	timerLabel.Name = "Timer"
	timerLabel.BackgroundTransparency = 1
	timerLabel.Position = UDim2.new(0.55, 0, 0, 0)
	timerLabel.Size = UDim2.new(0.45, -8, 1, 0)
	timerLabel.Text = "00:00"
	timerLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
	timerLabel.Font = Enum.Font.GothamBold
	timerLabel.TextSize = 11
	timerLabel.TextXAlignment = Enum.TextXAlignment.Right
	timerLabel.Parent = row

	boostRows[key] = row
	return row
end

local function formatRemaining(seconds)
	local s = math.max(0, math.floor(seconds + 0.5))
	local minutes = math.floor(s / 60)
	local rem = s % 60
	return string.format("%02d:%02d", minutes, rem)
end

local function refreshBoostHud()
	local now = os.time()
	local activeCount = 0
	for _, def in ipairs(boostDefs) do
		local activeAttr = def.Prefix .. "Active"
		local endAttr = def.Prefix .. "EndTime"
		local multAttr = def.Prefix .. "Multiplier"
		local active = player:GetAttribute(activeAttr) == true
		local endsAt = tonumber(player:GetAttribute(endAttr)) or 0
		local multiplier = tonumber(player:GetAttribute(multAttr)) or 1
		local remaining = endsAt - now
		if active and remaining > 0 then
			activeCount += 1
			local row = getOrCreateRow(def.Key, def.Color)
			row.Visible = true
			local timer = row:FindFirstChild("Timer")
			if timer and timer:IsA("TextLabel") then
				timer.Text = string.format("x%.2g  %s", multiplier, formatRemaining(remaining))
			end
		else
			local row = boostRows[def.Key]
			if row then
				row.Visible = false
			end
		end
	end

	if activeCount == 0 then
		boostsHiddenByPlayer = false
		hud.Visible = false
		return
	end

	updateHudSize(activeCount)
	hud.Visible = not boostsHiddenByPlayer
end

closeButton.Activated:Connect(function()
	boostsHiddenByPlayer = true
	hud.Visible = false
end)

Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	bindViewportWatcher()
	if hud.Visible then
		local visibleRows = 0
		for _, row in pairs(boostRows) do
			if row.Visible then
				visibleRows += 1
			end
		end
		updateHudSize(visibleRows)
	end
end)

bindViewportWatcher()

task.spawn(function()
	while true do
		refreshBoostHud()
		task.wait(0.25)
	end
end)
