local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

-- Safely find the Label in the hierarchy
local MainHUD = PlayerGui:WaitForChild("MainHUD", 10)
local Label
if MainHUD then
	local Top = MainHUD:WaitForChild("Top", 10)
	if Top then
		local TopBar = Top:WaitForChild("TopBar", 10)
		if TopBar then
			local Money = TopBar:WaitForChild("Money", 10)
			if Money then
				Label = Money:WaitForChild("MoneyText", 10)
			end
		end
	end
end

if not Label then
	warn("MoneyUpdate: MoneyText label not found!")
	return
end

local MoneyUpdateEvent = ReplicatedStorage:WaitForChild("Events"):WaitForChild("MoneyUpdate")
local MONEY_READY_ATTR = "MoneyReady"

local function formatMoney(amount)
	local value = tonumber(amount) or 0
	local absValue = math.abs(value)
	local function formatScaled(divisor, suffix)
		local scaled = value / divisor
		local text
		if math.abs(scaled) >= 100 then
			text = string.format("%.0f%s", scaled, suffix)
		else
			text = string.format("%.1f%s", scaled, suffix)
		end
		return text:gsub("%.0([KMBT])", "%1")
	end
	if absValue >= 1000000000 then
		return "$ " .. formatScaled(1000000000, "B")
	elseif absValue >= 1000000 then
		return "$ " .. formatScaled(1000000, "M")
	elseif absValue >= 1000 then
		return "$ " .. formatScaled(1000, "K")
	end
	return "$ " .. tostring(math.floor(value + (value >= 0 and 0.5 or -0.5)))
end

local function isMoneyReady()
	return Player:GetAttribute(MONEY_READY_ATTR) == true
end

local function applyMoney(amount)
	if not isMoneyReady() then
		Label.Text = "Loading..."
		return
	end
	Label.Text = formatMoney(amount)
end

local function refreshFromPlayerState()
	if not isMoneyReady() then
		Label.Text = "Loading..."
		return
	end
	local attrMoney = Player:GetAttribute("Money")
	if attrMoney ~= nil then
		applyMoney(attrMoney)
		return
	end
	local leaderstats = Player:FindFirstChild("leaderstats")
	local cash = leaderstats and leaderstats:FindFirstChild("Cash")
	if cash then
		applyMoney(cash.Value)
		return
	end
	Label.Text = formatMoney(0)
end

MoneyUpdateEvent.OnClientEvent:Connect(function(amount)
	applyMoney(amount)
end)

local leaderstats = Player:FindFirstChild("leaderstats") or Player:WaitForChild("leaderstats", 15)
if leaderstats then
	local cash = leaderstats:FindFirstChild("Cash") or leaderstats:WaitForChild("Cash", 15)
	if cash then
		cash.Changed:Connect(function(value)
			applyMoney(value)
		end)
	end
end

Player:GetAttributeChangedSignal(MONEY_READY_ATTR):Connect(refreshFromPlayerState)
Player:GetAttributeChangedSignal("Money"):Connect(refreshFromPlayerState)
refreshFromPlayerState()