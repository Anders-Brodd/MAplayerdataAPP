-- DEPRECATED: Replaced by ShopClient.local.luau (unified shop)
if true then
	return
end

--[=[
  Adds the 2x Money Gamepass button to the Money Shop
]=]--
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local player = Players.LocalPlayer
local PlayerGui = player:WaitForChild("PlayerGui")
local GAMEPASS_ID = 1708924275 -- 2x Money gamepass

local function SetupGamepassButton()
	local moneyShopGui = PlayerGui:WaitForChild("MoneyShopGui", 15)
	if not moneyShopGui then
		warn("[MoneyShopGamepassButton] MoneyShopGui not found")
		return false
	end

	local main = moneyShopGui:FindFirstChild("Main")
	if not main then
		warn("[MoneyShopGamepassButton] Main frame not found")
		return false
	end

	local gamepassButton = main:FindFirstChild("Gamepass")
	if not gamepassButton then
		warn("[MoneyShopGamepassButton] Gamepass button not found in Main")
		return false
	end

	-- Update visual elements
	local amountLabel = gamepassButton:FindFirstChild("AmountLabel")
	if amountLabel then
		amountLabel.Text = "2X MONEY"
		amountLabel.TextColor3 = Color3.fromRGB(255, 215, 0)
	end

	local priceLabel = gamepassButton:FindFirstChild("PriceLabel")
	if priceLabel then
		priceLabel.Text = "R$ 399"
	end

	-- Update stroke to gold color
	local stroke = gamepassButton:FindFirstChild("UIStroke")
	if stroke then
		stroke.Color = Color3.fromRGB(255, 215, 0)
	end

	-- Update indicator to gold
	local indicator = gamepassButton:FindFirstChild("Indicator")
	if indicator then
		indicator.BackgroundColor3 = Color3.fromRGB(255, 215, 0)
	end

	-- Hook up click handler
	gamepassButton.MouseButton1Click:Connect(function()
		pcall(function()
			MarketplaceService:PromptGamePassPurchase(player, GAMEPASS_ID)
		end)
	end)

	print("[MoneyShopGamepassButton] Gamepass button setup complete")
	return true
end

task.spawn(function()
	for attempt = 1, 10 do
		if SetupGamepassButton() then
			break
		end

		if attempt < 10 then
			task.wait(1)
		else
			warn("[MoneyShopGamepassButton] Failed to setup gamepass button after 10 attempts")
		end
	end
end)