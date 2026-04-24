-- DonateClient (LocalScript in PlayerScripts)

local MarketplaceService = game:GetService("MarketplaceService")
local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local TweenService       = game:GetService("TweenService")

local BUTTON_PRODUCTS = {
	["10"]     = 3564073373,
	["100"]    = 3564073211,
	["1000"]   = 3564073482,
	["10000"]  = 3564073603,
	["100000"] = 3564073751,
}

local GOALS = { 10000, 25000, 100000, 1000000, 10000000 }

local TWEEN_IN  = TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local TWEEN_OUT = TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
local POS_OPEN  = UDim2.new(0.5, 0, 0.5, 0)
local POS_CLOSE = UDim2.new(0.5, 0, 0.65, 0)

local BAR_TWEEN = TweenInfo.new(0.6, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

local player     = Players.LocalPlayer
local playerGui  = player:WaitForChild("PlayerGui")
local slotGui    = playerGui:WaitForChild("SlotSelectionGui")
local donationUI = slotGui:WaitForChild("DonationUI")
local canvas     = donationUI:WaitForChild("CanvasGroup")
local frame      = canvas:WaitForChild("Frame")
local buttons    = frame:WaitForChild("Buttons")
local lbFrame    = frame:WaitForChild("Leaderboard")
local template   = lbFrame:WaitForChild("Template")
local exitBtn    = donationUI:WaitForChild("Exit")
local shadow     = donationUI:WaitForChild("Shadow")
local goalGroup  = donationUI:WaitForChild("Goal")
local goalFilled = goalGroup:WaitForChild("Filled")
local goalText   = goalGroup:WaitForChild("Text")
local exitStroke = exitBtn:FindFirstChildWhichIsA("UIStroke")
local goalStroke = goalGroup:FindFirstChildWhichIsA("UIStroke")

local DonationUpdated = ReplicatedStorage:WaitForChild("DonationUpdated")
local GetDonationData = ReplicatedStorage:WaitForChild("GetDonationData")
local OpenDonationUI  = ReplicatedStorage:WaitForChild("OpenDonationUI")

template.Visible  = false
donationUI.Visible = false
canvas.AnchorPoint = Vector2.new(0.5, 0.5)

local function formatNumber(n)
	local s, result, len = tostring(math.floor(n)), "", 0
	len = #s
	for i = 1, len do
		if i > 1 and (len - i + 1) % 3 == 0 then
			result = result .. " "
		end
		result = result .. s:sub(i, i)
	end
	return result
end

local function abbreviate(n)
	if n >= 1000000 then
		return string.format("%.2fM", n / 1000000)
	elseif n >= 10000 then
		local v = n / 1000
		if v >= 100 then
			return string.format("%dk", math.floor(v))
		else
			return string.format("%.1fk", v)
		end
	else
		return formatNumber(n)
	end
end

local function getCurrentGoal(total)
	for _, g in ipairs(GOALS) do
		if total < g then return g end
	end
	return GOALS[#GOALS]
end

local function updateUI(total, leaderboard)
	local currentGoal = getCurrentGoal(total)
	local progress    = math.clamp(total / currentGoal, 0, 1)
	TweenService:Create(goalFilled, BAR_TWEEN, { Size = UDim2.new(progress, 0, 1, 0) }):Play()
	goalText.Text = string.format(
		"<i>goal:</i> <b>%s / %s</b>",
		formatNumber(total),
		formatNumber(currentGoal)
	)

	for _, child in ipairs(lbFrame:GetChildren()) do
		if child ~= template and child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	for _, entry in ipairs(leaderboard) do
		local row          = template:Clone()
		row.Visible        = true
		row.Placement.Text = "#" .. tostring(entry.placement)
		row.User.Text      = entry.user
		row.Display.Text   = entry.user
		row.Donated.Amount.Text = abbreviate(entry.donated)
		row.Parent         = lbFrame
	end
end

local function openDonationUI()
	donationUI.Visible = true
	canvas.Position          = POS_CLOSE
	canvas.GroupTransparency = 1
	goalGroup.GroupTransparency = 1
	shadow.ImageTransparency = 1
	exitBtn.BackgroundTransparency = 1
	exitBtn.TextTransparency       = 1
	if exitStroke then exitStroke.Transparency = 1 end
	if goalStroke then goalStroke.Transparency = 1 end
	TweenService:Create(canvas,   TWEEN_IN, { Position = POS_OPEN, GroupTransparency = 0 }):Play()
	TweenService:Create(goalGroup, TWEEN_IN, { GroupTransparency = 0 }):Play()
	TweenService:Create(shadow,   TWEEN_IN, { ImageTransparency = 0.36 }):Play()
	TweenService:Create(exitBtn,  TWEEN_IN, { BackgroundTransparency = 0, TextTransparency = 0 }):Play()
	if exitStroke then TweenService:Create(exitStroke, TWEEN_IN, { Transparency = 0 }):Play() end
	if goalStroke then TweenService:Create(goalStroke, TWEEN_IN, { Transparency = 0 }):Play() end
end

local function closeDonationUI()
	TweenService:Create(canvas,    TWEEN_OUT, { Position = POS_CLOSE, GroupTransparency = 1 }):Play()
	TweenService:Create(goalGroup, TWEEN_OUT, { GroupTransparency = 1 }):Play()
	TweenService:Create(shadow,    TWEEN_OUT, { ImageTransparency = 1 }):Play()
	TweenService:Create(exitBtn,   TWEEN_OUT, { BackgroundTransparency = 1, TextTransparency = 1 }):Play()
	if exitStroke then TweenService:Create(exitStroke, TWEEN_OUT, { Transparency = 1 }):Play() end
	if goalStroke then TweenService:Create(goalStroke, TWEEN_OUT, { Transparency = 1 }):Play() end
	task.delay(TWEEN_OUT.Time, function()
		donationUI.Visible = false
	end)
end

for name, productId in pairs(BUTTON_PRODUCTS) do
	local btn = buttons:FindFirstChild(name)
	if btn then
		btn.MouseButton1Click:Connect(function()
			MarketplaceService:PromptProductPurchase(player, productId)
		end)
	else
		warn("DonateClient: button not found —", name)
	end
end

exitBtn.MouseButton1Click:Connect(closeDonationUI)

OpenDonationUI.OnClientEvent:Connect(openDonationUI)

local ok, total, leaderboard = pcall(function()
	return GetDonationData:InvokeServer()
end)
if ok and total then
	updateUI(total, leaderboard)
end

DonationUpdated.OnClientEvent:Connect(updateUI)