-- DEPRECATED: Replaced by ShopClient.local.luau (unified shop)
if true then
	return
end

-- ResearchShopClient: opens from the "Buy RP" button in ResearchFrame header
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local PolicyService = game:GetService("PolicyService")
local AdService = game:GetService("AdService")

-- Must match the placement ID registered in Creator Hub → Monetization → Rewarded Ads
local RESEARCH_PLACEMENT_ID = 318737320373663
local player = Players.LocalPlayer
local PlayerGui = player:WaitForChild("PlayerGui")

local gui = PlayerGui:WaitForChild("ResearchShopGui")
local main = gui:WaitForChild("Main")
local header = main:WaitForChild("Header")
local closeBtn = header:WaitForChild("CloseButton")

local adSection = main:WaitForChild("AdBoostSection")
local watchAdBtn = adSection:WaitForChild("WatchAdBtn")
local timerLabel = adSection:WaitForChild("BoostTimerLabel")

local purchaseContainer = main:WaitForChild("PurchaseContainer")

local Events = ReplicatedStorage:WaitForChild("Events")
local RequestAdBoost = Events:WaitForChild("RequestAdBoost")
local AdBoostResult = Events:WaitForChild("AdBoostResult")

local GAMEPASS_ID = 1753340250 -- 2x Research Points gamepass
local currencyType = "Research"
local boostUiToken = 0

local function bindGuiButton(button, callback)
	if not (button and callback and button:IsA("GuiButton")) then return end
	button.Active = true
	button.Selectable = true
	button.AutoButtonColor = true
	button.Activated:Connect(callback)
end

-- ── AD ELIGIBILITY CHECK ──
-- Hide the ad section entirely if the player is not eligible to see ads
task.spawn(function()
	local ok, policyInfo = pcall(function()
		return PolicyService:GetPolicyInfoForPlayerAsync(player)
	end)
	if not ok then
		warn("[ResearchShopClient] PolicyService check failed: " .. tostring(policyInfo) .. " — hiding ad section")
		adSection.Visible = false
		return
	end
	if not policyInfo or not policyInfo.AreAdsAllowed then
		warn("[ResearchShopClient] Ads not allowed for this player (AreAdsAllowed=false) — hiding ad section")
		adSection.Visible = false
		return
	end
	-- Register the watch-ad button as an ad opportunity so Roblox's ad network
	-- knows this placement is active and can serve inventory to eligible players.
	-- Without this call the placement receives no ad fills (revenue = 0).
	pcall(function()
		AdService:RegisterAdOpportunityAsync(watchAdBtn, RESEARCH_PLACEMENT_ID)
	end)
end)

local PRODUCT_IDS = {
	["Option_1"] = 3557198648, -- R$ 49
	["Option_2"] = 3557198849, -- R$ 149
	["Option_3"] = 3557199096, -- R$ 449
	["Option_4"] = 3557199251, -- R$ 999
}

-- ── OPEN / CLOSE ──
local isOpen = false
local TweenService = game:GetService("TweenService")
local uiScale = main:FindFirstChildOfClass("UIScale") or Instance.new("UIScale", main)

local function openShop()
	if isOpen then return end
	isOpen = true
	main.Visible = true
	uiScale.Scale = 0.85
	TweenService:Create(uiScale, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}):Play()
end

local function closeShop()
	if not isOpen then return end
	isOpen = false
	local t = TweenService:Create(uiScale, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {Scale = 0.85})
	t:Play()
	t.Completed:Once(function()
		if not isOpen then main.Visible = false end
	end)
end

bindGuiButton(closeBtn, closeShop)

-- ── HOOK: Find existing "Buy RP" button in ResearchFrame Header ──
task.spawn(function()
	local MainHUD = PlayerGui:WaitForChild("MainHUD", 15)
	if not MainHUD then warn("[ResearchShopClient] MainHUD not found") return end
	local ResearchFrame = MainHUD:WaitForChild("ResearchFrame", 10)
	if not ResearchFrame then warn("[ResearchShopClient] ResearchFrame not found") return end
	local ResearchHeader = ResearchFrame:WaitForChild("Header", 10)
	if not ResearchHeader then warn("[ResearchShopClient] ResearchFrame.Header not found") return end

	local buyBtn = ResearchHeader:WaitForChild("RPLabel", 10)
	if not buyBtn then
		warn("[ResearchShopClient] BuyRPButton not found in ResearchFrame.Header!")
		return
	end

	bindGuiButton(buyBtn, function()
		if isOpen then closeShop() else openShop() end
	end)

	print("[ResearchShopClient] Connected to BuyRPButton in ResearchFrame header")
end)

-- ── AD BOOST ──
local adCooldown = false

local function resetAdUi(message)
	boostUiToken += 1
	timerLabel.Text = message or ""
	timerLabel.Visible = message ~= nil and message ~= ""
	watchAdBtn.BackgroundTransparency = 0
	local label = watchAdBtn:FindFirstChild("Label")
	if label then label.Text = "▶  WATCH AD" end
	adCooldown = false
end

local function startBoostCountdown(endTime)
	boostUiToken += 1
	local myToken = boostUiToken
	local label = watchAdBtn:FindFirstChild("Label")
	adCooldown = true
	if label then label.Text = "ACTIVE ✓" end
	watchAdBtn.BackgroundTransparency = 0.5
	timerLabel.Visible = true
	
	task.spawn(function()
		while myToken == boostUiToken do
			local remaining = (endTime or 0) - os.time()
			if remaining <= 0 then
				resetAdUi(nil)
				break
			end
			local mins = math.floor(remaining / 60)
			local secs = remaining % 60
			timerLabel.Text = string.format("BOOST ACTIVE — %d:%02d", mins, secs)
			task.wait(1)
		end
	end)
end

watchAdBtn.MouseButton1Click:Connect(function()
	if adCooldown then return end
	adCooldown = true
	local label = watchAdBtn:FindFirstChild("Label")
	if label then label.Text = "CHECKING..." end
	timerLabel.Visible = false

	-- Pre-check ad availability locally before involving the server.
	-- This gives instant feedback when there's no fill/inventory right now.
	local availOk, availResult = pcall(function()
		return AdService:GetAdAvailabilityNowAsync(Enum.AdFormat.RewardedVideo)
	end)
	if availOk and type(availResult) == "table" then
		local avail = availResult.AdAvailabilityResult
		if avail == Enum.AdAvailabilityResult.PlayerIneligible
			or avail == Enum.AdAvailabilityResult.DeviceIneligible
			or avail == Enum.AdAvailabilityResult.ExperienceIneligible
			or avail == Enum.AdAvailabilityResult.PublisherIneligible then
			adSection.Visible = false
			return
		end
		if avail == Enum.AdAvailabilityResult.NoFill then
			local msg = "No ads available right now. Try again later."
			resetAdUi(msg)
			task.delay(3, function()
				if timerLabel.Parent and timerLabel.Text == msg then
					timerLabel.Text = ""
					timerLabel.Visible = false
				end
			end)
			return
		end
	end

	RequestAdBoost:FireServer(currencyType)

	-- 30 seconds: ads can take time to load on slow connections
	task.delay(30, function()
		if adCooldown and watchAdBtn.Parent then
			resetAdUi("Ad request timed out. Try again.")
			task.delay(2.5, function()
				if boostUiToken > 0 and timerLabel.Parent and timerLabel.Text == "Ad request timed out. Try again." then
					timerLabel.Text = ""
					timerLabel.Visible = false
				end
			end)
		end
	end)
end)

AdBoostResult.OnClientEvent:Connect(function(boostType, success, endTime, failureMessage)
	if boostType ~= currencyType then return end
	if success then
		startBoostCountdown(endTime)
	else
		resetAdUi(failureMessage)
		if failureMessage and failureMessage ~= "" then
			task.delay(2.5, function()
				if timerLabel.Parent and timerLabel.Text == failureMessage then
					timerLabel.Text = ""
					timerLabel.Visible = false
				end
			end)
		end
	end
end)

-- ── PURCHASE BUTTONS ──
for _, btn in ipairs(purchaseContainer:GetChildren()) do
	if btn:IsA("TextButton") then
		local productId = PRODUCT_IDS[btn.Name]
		if productId then
			btn.MouseButton1Click:Connect(function()
				MarketplaceService:PromptProductPurchase(player, productId)
			end)
		else
			warn("[ResearchShopClient] No product ID mapped for button: " .. btn.Name)
		end
	end
end

-- ── GAMEPASS BUTTON ──
local gamepassButton = main:FindFirstChild("Gamepass")
if gamepassButton then
	gamepassButton.MouseButton1Click:Connect(function()
		pcall(function()
			MarketplaceService:PromptGamePassPurchase(player, GAMEPASS_ID)
		end)
	end)
	print("[ResearchShopClient] Gamepass button setup complete")
else
	warn("[ResearchShopClient] Gamepass button not found in Main")
end