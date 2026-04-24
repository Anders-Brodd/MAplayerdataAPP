-- DEPRECATED: Replaced by ShopClient.local.luau (unified shop)
if true then
	return
end

-- MoneyShopClient: opens from TopBar "More" button + auto-opens on insufficient funds
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")
local PolicyService = game:GetService("PolicyService")
local AdService = game:GetService("AdService")

-- Must match the placement ID registered in Creator Hub → Monetization → Rewarded Ads
local MONEY_PLACEMENT_ID = 297325229327538
local player = Players.LocalPlayer
local PlayerGui = player:WaitForChild("PlayerGui")

local gui = PlayerGui:WaitForChild("MoneyShopGui")
local main = gui:WaitForChild("Main")
local header = main:WaitForChild("Header")
local closeBtn = header:WaitForChild("CloseButton")

local adSection = main:WaitForChild("AdBoostSection")
local watchAdBtn = adSection:WaitForChild("WatchAdBtn")
local timerLabel = adSection:WaitForChild("BoostTimerLabel")

local purchaseContainer = main:WaitForChild("PurchaseContainer")
local Events = ReplicatedStorage:WaitForChild("Events")
local RequestAdBoost     = Events:WaitForChild("RequestAdBoost")
local AdBoostResult      = Events:WaitForChild("AdBoostResult")
local RequestMoneyAdInfo = Events:WaitForChild("RequestMoneyAdInfo", 15)
local MoneyAdInfo        = Events:WaitForChild("MoneyAdInfo", 15)
-- Robux "Resort Bond" product — grants same 5%-of-net-worth reward as the ad.
local MONEY_BOND_PRODUCT_ID = 3557185185

local currencyType = "Money"
local boostUiToken = 0

-- Cached reward info from server (refreshed when shop opens / MoneyAdInfo fires).
local cachedNetWorth  = 0
local cachedUseCount  = 0
local cachedResetTime = 0
local cachedReward    = 0
local cachedPct       = 0.05

-- Ad eligibility (nil = not yet checked)
local adsEligible = nil

local function bindGuiButton(button, callback)
	if not (button and callback and button:IsA("GuiButton")) then return end
	button.Active = true
	button.Selectable = true
	button.AutoButtonColor = true
	button.Activated:Connect(callback)
end

-- ── AD ELIGIBILITY CHECK ──
local function hideAdSection()
	adSection.Visible = false
	adsEligible = false
end

task.spawn(function()
	-- Server sets AdsEligible attribute on join; use it as a fast path.
	local serverEligible = player:GetAttribute("AdsEligible")
	if serverEligible == false then hideAdSection(); return end

	local ok, policyInfo = pcall(function()
		return PolicyService:GetPolicyInfoForPlayerAsync(player)
	end)
	if not ok or not policyInfo or not policyInfo.AreAdsAllowed then
		hideAdSection(); return
	end
	adsEligible = true
	pcall(function()
		AdService:RegisterAdOpportunityAsync(watchAdBtn, MONEY_PLACEMENT_ID)
	end)
end)

-- ── OPEN / CLOSE ──
local isOpen = false
local TweenService = game:GetService("TweenService")
local uiScale = main:FindFirstChildOfClass("UIScale") or Instance.new("UIScale", main)

-- ── DYNAMIC AD SECTION WIDGETS ──
-- Created once and updated via updateAdSectionUI().
local rewardLabel, infoLabel, resetLabel, buyBtn

local function ensureAdWidgets()
	if rewardLabel then return end

	-- Reward amount label (big, shows e.g. "▶  Get $12,500")
	rewardLabel = watchAdBtn:FindFirstChild("Label") or Instance.new("TextLabel")
	rewardLabel.Name = "Label"
	rewardLabel.Size = UDim2.new(1, -8, 1, 0)
	rewardLabel.Position = UDim2.fromOffset(4, 0)
	rewardLabel.BackgroundTransparency = 1
	rewardLabel.Text = "▶  Watch Ad"
	rewardLabel.TextSize = 14
	rewardLabel.Font = Enum.Font.GothamBold
	rewardLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
	rewardLabel.TextXAlignment = Enum.TextXAlignment.Center
	rewardLabel.ZIndex = watchAdBtn.ZIndex + 1
	rewardLabel.Parent = watchAdBtn

	-- "Buy Resort Bond for Robux" button
	buyBtn = adSection:FindFirstChild("BuyBondBtn") or Instance.new("TextButton")
	buyBtn.Name = "BuyBondBtn"
	buyBtn.Size = UDim2.new(0.48, -3, 0, 36)
	buyBtn.Position = UDim2.new(0.52, 3, 0, watchAdBtn.Position.Y.Offset)
	buyBtn.BackgroundColor3 = Color3.fromRGB(26, 80, 38)
	buyBtn.BorderSizePixel = 0
	buyBtn.Text = "💸  Buy"
	buyBtn.TextSize = 13
	buyBtn.Font = Enum.Font.GothamBold
	buyBtn.TextColor3 = Color3.fromRGB(100, 255, 120)
	buyBtn.ZIndex = watchAdBtn.ZIndex
	Instance.new("UICorner", buyBtn).CornerRadius = UDim.new(0, 8)
	buyBtn.Parent = adSection

	-- Resize WatchAdBtn to left half
	watchAdBtn.Size = UDim2.new(0.48, -3, watchAdBtn.Size.Y.Scale, watchAdBtn.Size.Y.Offset)

	-- Info label: "Each use -0.5% • Resets daily"
	infoLabel = adSection:FindFirstChild("AdInfoLabel") or Instance.new("TextLabel")
	infoLabel.Name = "AdInfoLabel"
	infoLabel.Size = UDim2.new(1, 0, 0, 16)
	infoLabel.Position = UDim2.new(
		watchAdBtn.Position.X.Scale, watchAdBtn.Position.X.Offset,
		0, watchAdBtn.Position.Y.Offset + 40)
	infoLabel.BackgroundTransparency = 1
	infoLabel.Text = "Each use −0.5% • Resets daily"
	infoLabel.TextSize = 11
	infoLabel.Font = Enum.Font.Gotham
	infoLabel.TextColor3 = Color3.fromRGB(140, 145, 155)
	infoLabel.TextXAlignment = Enum.TextXAlignment.Center
	infoLabel.ZIndex = watchAdBtn.ZIndex
	infoLabel.Parent = adSection

	-- Reset countdown label
	resetLabel = adSection:FindFirstChild("ResetCountdown") or Instance.new("TextLabel")
	resetLabel.Name = "ResetCountdown"
	resetLabel.Size = UDim2.new(1, 0, 0, 14)
	resetLabel.Position = UDim2.new(
		infoLabel.Position.X.Scale, infoLabel.Position.X.Offset,
		0, infoLabel.Position.Y.Offset + 18)
	resetLabel.BackgroundTransparency = 1
	resetLabel.Text = ""
	resetLabel.TextSize = 11
	resetLabel.Font = Enum.Font.Gotham
	resetLabel.TextColor3 = Color3.fromRGB(120, 125, 138)
	resetLabel.TextXAlignment = Enum.TextXAlignment.Center
	resetLabel.ZIndex = watchAdBtn.ZIndex
	resetLabel.Parent = adSection

	-- Wire buy button
	buyBtn.Activated:Connect(function()
		pcall(function()
			MarketplaceService:PromptProductPurchase(player, MONEY_BOND_PRODUCT_ID)
		end)
	end)
end

local function formatCountdown(seconds)
	local s = math.max(0, math.floor(seconds))
	local h = math.floor(s / 3600)
	local m = math.floor((s % 3600) / 60)
	local sec = s % 60
	if h > 0 then
		return string.format("%dh %02dm", h, m)
	end
	return string.format("%dm %02ds", m, sec)
end

local function formatMoney(amount)
	if amount >= 1e6 then return string.format("$%.1fM", amount / 1e6) end
	if amount >= 1000 then return string.format("$%.1fK", amount / 1000) end
	return string.format("$%d", math.floor(amount))
end

local function updateAdSectionUI()
	if not adSection.Visible then return end
	ensureAdWidgets()

	local reward  = cachedReward
	local pct     = cachedPct * 100             -- as percentage e.g. 5.0
	local uses    = cachedUseCount
	local nw      = cachedNetWorth

	if rewardLabel then
		if reward > 0 then
			rewardLabel.Text = string.format("▶  Get %s (%.1f%%)", formatMoney(reward), pct)
			watchAdBtn.BackgroundTransparency = adCooldown and 0.5 or 0
			if buyBtn then
				buyBtn.Text = string.format("💸  Buy %s", formatMoney(reward))
			end
		else
			rewardLabel.Text = "▶  Watch Ad"
			if buyBtn then buyBtn.Text = "💸  Buy" end
		end
	end

	if infoLabel then
		if nw > 0 then
			local nextPct = math.max(0.5, pct - 0.5)
			infoLabel.Text = string.format(
				"%.1f%% of %s resort value • Next use: %.1f%% • Each use −0.5%%",
				pct, formatMoney(nw), nextPct)
		ends
	end

	if resetLabel then
		local remaining = cachedResetTime - os.time()
		if remaining > 0 then
			resetLabel.Text = string.format("Daily reset in %s • %d uses today", formatCountdown(remaining), uses)
		else
			resetLabel.Text = "Resets daily • 0 uses today"
		end
	end
end

-- Keep the reset countdown ticking while the shop is open.
local resetUpdateConn

local function openShop()
	if isOpen then return end
	isOpen = true
	main.Visible = true
	uiScale.Scale = 0.85
	TweenService:Create(uiScale, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}):Play()

	-- Request fresh reward info and start countdown tick.
	if RequestMoneyAdInfo then pcall(function() RequestMoneyAdInfo:FireServer() end) end
	updateAdSectionUI()

	if resetUpdateConn then resetUpdateConn:Disconnect() end
	resetUpdateConn = RunService.Heartbeat:Connect(function()
		if not isOpen then resetUpdateConn:Disconnect(); resetUpdateConn = nil; return end
		if resetLabel then
			local remaining = cachedResetTime - os.time()
			if remaining > 0 then
				resetLabel.Text = string.format("Daily reset in %s • %d uses today", formatCountdown(remaining), cachedUseCount)
			else
				resetLabel.Text = "Resets daily • 0 uses today"
			end
		end
	end)
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

-- ── HOOK: TopBar > Money > More button ──
task.spawn(function()
	local MainHUD = PlayerGui:WaitForChild("MainHUD", 15)
	if not MainHUD then warn("[MoneyShopClient] MainHUD not found") return end
	local Top = MainHUD:WaitForChild("Top", 10)
	if not Top then warn("[MoneyShopClient] MainHUD.Top not found") return end
	local TopBar = Top:WaitForChild("TopBar", 10)
	if not TopBar then warn("[MoneyShopClient] TopBar not found") return end
	local Money = TopBar:WaitForChild("Money", 10)
	if not Money then warn("[MoneyShopClient] TopBar.Money not found") return end
	
	-- Find the "More" button — could be named "More" as a child of Money
	local moreBtn = Money:WaitForChild("More", 10)
	if not moreBtn then
		-- Search descendants in case it's nested
		for _, desc in ipairs(Money:GetDescendants()) do
			if desc.Name == "More" and (desc:IsA("TextButton") or desc:IsA("ImageButton") or desc:IsA("Frame")) then
				moreBtn = desc
				break
			end
		end
	end
	
	if moreBtn then
		if moreBtn:IsA("GuiButton") then
			bindGuiButton(moreBtn, function()
				if isOpen then closeShop() else openShop() end
			end)
		else
			-- If it's a Frame, listen for InputBegan
			moreBtn.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
					if isOpen then closeShop() else openShop() end
				end
			end)
		end
		print("[MoneyShopClient] Hooked to TopBar > Money > More button")
	else
		warn("[MoneyShopClient] 'More' button not found in TopBar.Money — shop has no open trigger!")
	end
end)

-- ── AUTO-OPEN ON INSUFFICIENT FUNDS ──
-- PlacementClient fires "Not Enough Money" locally via ClientNotification BindableEvent.
-- The server can also fire it via NotificationEvent remote. We listen to both.
task.spawn(function()
	local lastAutoOpen = 0
	
-- Ad-prompt dialog: shown when a player can't afford a building but the ad would cover it.
		local adPromptDialog
		local function showAdPromptForBuild(itemCost, itemName)
			if adPromptDialog and adPromptDialog.Parent then adPromptDialog:Destroy() end
			local dialog = Instance.new("Frame")
			dialog.Name = "AdBuildPrompt"
			dialog.Size = UDim2.fromOffset(320, 160)
			dialog.AnchorPoint = Vector2.new(0.5, 0.5)
			dialog.Position = UDim2.fromScale(0.5, 0.5)
			dialog.BackgroundColor3 = Color3.fromRGB(15, 17, 22)
			dialog.BorderSizePixel = 0
			dialog.ZIndex = 40
			Instance.new("UICorner", dialog).CornerRadius = UDim.new(0, 12)
			local stroke = Instance.new("UIStroke", dialog)
			stroke.Color = Color3.fromRGB(80, 120, 200)
			stroke.Thickness = 1

			local function makeLabel(text, yOff, size, color, font)
				local lbl = Instance.new("TextLabel", dialog)
				lbl.Size = UDim2.new(1, -24, 0, size)
				lbl.Position = UDim2.fromOffset(12, yOff)
				lbl.BackgroundTransparency = 1
				lbl.Text = text
				lbl.TextSize = size
				lbl.Font = font or Enum.Font.Gotham
				lbl.TextColor3 = color or Color3.fromRGB(220, 220, 225)
				lbl.TextXAlignment = Enum.TextXAlignment.Center
				lbl.TextWrapped = true
				lbl.ZIndex = 41
				return lbl
			end

			local shortName = type(itemName) == "string" and itemName or "this item"
			local rewardStr = formatMoney(cachedReward)
			local costStr   = formatMoney(itemCost)
			makeLabel("Can't afford " .. shortName, 10, 14, Color3.fromRGB(220,220,225), Enum.Font.GothamBold)
			makeLabel(string.format("Cost: %s  •  Ad reward: %s", costStr, rewardStr), 30, 12, Color3.fromRGB(140,145,160))
			if cachedReward >= itemCost then
				makeLabel("Watch the ad to get " .. rewardStr .. " and buy it!", 52, 12, Color3.fromRGB(100,220,120))
			end

			local btnY = 90
			local function makeBtn(text, xPct, bgColor, textColor, cb)
				local btn = Instance.new("TextButton", dialog)
				btn.Size = UDim2.new(0.3, -6, 0, 34)
				btn.Position = UDim2.new(xPct, 3, 0, btnY)
				btn.BackgroundColor3 = bgColor
				btn.BorderSizePixel = 0
				btn.Text = text
				btn.TextSize = 12
				btn.Font = Enum.Font.GothamBold
				btn.TextColor3 = textColor
				btn.ZIndex = 42
				Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)
				btn.Activated:Connect(function()
					dialog:Destroy(); adPromptDialog = nil
					cb()
				end)
				return btn
			end

			if adsEligible ~= false and cachedReward >= itemCost then
				makeBtn("▶ Watch Ad",  0,    Color3.fromRGB(20,80,40),   Color3.fromRGB(100,255,130), function()
					-- Trigger the ad just like the main watch-ad button
					watchAdBtn:GetPropertyChangedSignal("BackgroundTransparency")
					RequestAdBoost:FireServer(currencyType)
					adCooldown = true
				end)
				makeBtn("💸 Buy",      0.33, Color3.fromRGB(20,50,90),   Color3.fromRGB(100,180,255), function()
					pcall(function() MarketplaceService:PromptProductPurchase(player, MONEY_BOND_PRODUCT_ID) end)
				end)
				makeBtn("Cancel",    0.67, Color3.fromRGB(50,25,25),   Color3.fromRGB(200,120,120), function() end)
			else
				-- Ad not eligible or reward too small — just open the money shop
				dialog:Destroy(); adPromptDialog = nil
				openShop()
				return
			end

			dialog.Parent = PlayerGui:WaitForChild("MainHUD", 1) or PlayerGui
			adPromptDialog = dialog
			-- Auto-dismiss after 30 s
			task.delay(30, function()
				if adPromptDialog == dialog then dialog:Destroy(); adPromptDialog = nil end
			end)
		end

		local function checkAndOpen(category, title, message, duration, itemCost, itemName)
			if title == "Not Enough Money" or title == "NOT ENOUGH MONEY" then
				local now = os.clock()
				if now - lastAutoOpen > 3 then
					lastAutoOpen = now
					-- Show the ad prompt if we have a specific cost and ads could cover it;
					-- otherwise fall back to the money shop.
					if itemCost and itemCost > 0 and adsEligible ~= false and cachedReward >= itemCost then
						showAdPromptForBuild(itemCost, itemName)
					else
						openShop()
					end
			end
		end
	end
	
	-- Listen to the remote NotificationEvent from server
	local NotificationEvent = Events:FindFirstChild("NotificationEvent")
	if NotificationEvent and NotificationEvent:IsA("RemoteEvent") then
		NotificationEvent.OnClientEvent:Connect(checkAndOpen)
	end
	
	-- Listen to the local ClientNotification BindableEvent (used by PlacementClient)
	local ClientNotification = ReplicatedStorage:FindFirstChild("ClientNotification")
	if not ClientNotification then
		-- Wait a bit in case it's created later by NotificationHandler
		ClientNotification = ReplicatedStorage:WaitForChild("ClientNotification", 10)
	end
	
	if ClientNotification and ClientNotification:IsA("BindableEvent") then
		ClientNotification.Event:Connect(checkAndOpen)
	end
	
	-- Also check player attribute set by server
	player:GetAttributeChangedSignal("ShopAutoOpen"):Connect(function()
		local val = player:GetAttribute("ShopAutoOpen")
		if val == true then
			player:SetAttribute("ShopAutoOpen", nil)
			openShop()
		end
	end)
end)

-- ── AD BOOST ──
local adCooldown = false

local function resetAdUi(message)
	boostUiToken += 1
	timerLabel.Text = message or ""
	timerLabel.Visible = message ~= nil and message ~= ""
	watchAdBtn.BackgroundTransparency = 0
	adCooldown = false
	updateAdSectionUI()
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

AdBoostResult.OnClientEvent:Connect(function(boostType, success, endTime, failureMessage, reward)
	if boostType ~= currencyType then return end
	if success then
		-- Money reward is instant — just reset the button and show a flash.
		boostUiToken += 1
		watchAdBtn.BackgroundTransparency = 0
		adCooldown = false
		timerLabel.Visible = false
		-- UI refresh happens via MoneyAdInfo event fired by server after granting.
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

-- Receive fresh reward info from server.
if MoneyAdInfo then
	MoneyAdInfo.OnClientEvent:Connect(function(netWorth, useCount, resetTime, reward, pct)
		cachedNetWorth  = netWorth  or 0
		cachedUseCount  = useCount  or 0
		cachedResetTime = resetTime or 0
		cachedReward    = reward    or 0
		cachedPct       = pct       or 0.05
		updateAdSectionUI()
	end)
end

-- ── PURCHASE BUTTONS ──
for _, btn in ipairs(purchaseContainer:GetChildren()) do
	if btn:IsA("TextButton") then
		btn.MouseButton1Click:Connect(function()
			local productId = btn:GetAttribute("DevProductId")
			if productId and productId > 0 then
				MarketplaceService:PromptProductPurchase(player, productId)
			else
				warn("[MoneyShopClient] DevProductId not configured for " .. btn.Name)
			end
		end)
	end
end