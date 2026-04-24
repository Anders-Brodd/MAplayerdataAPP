--[=[ PATH: StarterPlayerScripts/ShopClient | TYPE: LocalScript ]=]--
-- ════════════════════════════════════════════════════════════════════
--  SHOP CLIENT  —  Unified shop for passes, subscriptions, boosts & ads.
--  Replaces MoneyShopClient, ResearchShopClient, and GuestsGamepassButton.
--  Opens via: ShopButton in TopBar, Money "More", Guests "More",
--             Research "Buy RP", or auto-open on insufficient funds.
-- ════════════════════════════════════════════════════════════════════

local Players            = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local TweenService       = game:GetService("TweenService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local PolicyService      = game:GetService("PolicyService")
local AdService          = game:GetService("AdService")
local RunService         = game:GetService("RunService")

local player    = Players.LocalPlayer
local PlayerGui = player:WaitForChild("PlayerGui")
local Events    = ReplicatedStorage:WaitForChild("Events")

local RequestAdBoost     = Events:WaitForChild("RequestAdBoost")
local AdBoostResult      = Events:WaitForChild("AdBoostResult")
local RequestMoneyAdInfo = Events:WaitForChild("RequestMoneyAdInfo", 15)
local MoneyAdInfo        = Events:WaitForChild("MoneyAdInfo", 15)

-- ── AD CONFIG ─────────────────────────────────────────────────────
local MONEY_PLACEMENT_ID    = 297325229327538
local RESEARCH_PLACEMENT_ID = 318737320373663
local MONEY_BOND_PRODUCT_ID = 3557185185

-- ── SHOP DATA ─────────────────────────────────────────────────────

local GAME_PASSES = {
	{ id = 1708924275,  name = "2x Money",               desc = "Double all money income",                       icon = "💰", color = Color3.fromRGB(255, 200, 40) },
	{ id = 1708162428,  name = "2x Guests",              desc = "Double your resort guest capacity",             icon = "👥", color = Color3.fromRGB(80, 180, 255) },
	{ id = 1753340250,  name = "2x Research Points",     desc = "Double research point earnings",                icon = "🔬", color = Color3.fromRGB(160, 100, 255) },
	{ id = 1708600326,  name = "More Employees",         desc = "Hire additional employees for your resort",     icon = "👷", color = Color3.fromRGB(100, 200, 120) },
	{ id = 1705719197,  name = "Time Setter",            desc = "Control the time of day in your resort",        icon = "🕐", color = Color3.fromRGB(255, 160, 60) },
	{ id = 1707796502,  name = "Weather Controller",     desc = "Set weather conditions in your resort",         icon = "🌦️", color = Color3.fromRGB(100, 180, 220) },
	{ id = 1704778044,  name = "Controller+",            desc = "Enhanced controller support & shortcuts",       icon = "🎮", color = Color3.fromRGB(180, 120, 220) },
	{ id = 1705274438,  name = "Freecam+",               desc = "Unlock free camera for cinematic views",        icon = "📷", color = Color3.fromRGB(200, 160, 100) },
	{ id = 1792834210,  name = "Slot Data Limit Bypass",  desc = "Remove the 300 building limit",                icon = "🏗️", color = Color3.fromRGB(120, 200, 180) },
	{ id = 1793522272,  name = "Always Active Resort",    desc = "Your resort stays joinable when you're offline", icon = "🌐", color = Color3.fromRGB(80, 200, 160) },
}

local SUBSCRIPTIONS = {
	{ key = "Sub_ResortPass",     name = "Resort Pass",      desc = "All passes + unlimited slots + premium daily rewards",  icon = "⭐", color = Color3.fromRGB(255, 200, 50) },
	{ key = "Sub_UnlimitedSlots", name = "Unlimited Slots",  desc = "Unlock all 12 save slots",                             icon = "💾", color = Color3.fromRGB(100, 180, 255) },
	{ key = "Sub_PremiumRewards", name = "Premium Rewards",  desc = "2x daily reward multiplier",                           icon = "🎁", color = Color3.fromRGB(220, 120, 255) },
	{ key = "Sub_VIP",            name = "VIP",              desc = "Chat color, resort nameplate, featured in lobby",       icon = "👑", color = Color3.fromRGB(255, 180, 60) },
}

local DEV_PRODUCTS = {
	{ id = 3557184373,  name = "$10K Cash",    desc = "Instant $10,000",    icon = "💵", color = Color3.fromRGB(80, 180, 80),  category = "Money" },
	{ id = 3557184641,  name = "$50K Cash",    desc = "Instant $50,000",    icon = "💵", color = Color3.fromRGB(80, 180, 80),  category = "Money" },
	{ id = 3557184919,  name = "$250K Cash",   desc = "Instant $250,000",   icon = "💵", color = Color3.fromRGB(80, 180, 80),  category = "Money" },
	{ id = 3557185185,  name = "Resort Bond",  desc = "5% of net worth",    icon = "💸", color = Color3.fromRGB(60, 160, 80),  category = "Money" },
	{ id = 3557198648,  name = "100 RP",       desc = "Instant 100 RP",     icon = "🧪", color = Color3.fromRGB(120, 80, 220), category = "Research" },
	{ id = 3557198849,  name = "500 RP",       desc = "Instant 500 RP",     icon = "🧪", color = Color3.fromRGB(120, 80, 220), category = "Research" },
	{ id = 3557199096,  name = "2,000 RP",     desc = "Instant 2,000 RP",   icon = "🧪", color = Color3.fromRGB(120, 80, 220), category = "Research" },
	{ id = 3557199251,  name = "8,000 RP",     desc = "Instant 8,000 RP",   icon = "🧪", color = Color3.fromRGB(120, 80, 220), category = "Research" },
	{ id = 3575009101,  name = "Extra Slot",   desc = "+1 save slot (max 12)", icon = "💾", color = Color3.fromRGB(100, 160, 220), category = "Slots" },
}

-- ── THEME ─────────────────────────────────────────────────────────

local THEME = {
	Bg          = Color3.fromRGB(14, 16, 22),
	Panel       = Color3.fromRGB(20, 23, 32),
	TabActive   = Color3.fromRGB(45, 50, 70),
	TabInactive = Color3.fromRGB(28, 31, 42),
	CardBg      = Color3.fromRGB(26, 30, 42),
	CardHover   = Color3.fromRGB(34, 38, 52),
	Text        = Color3.fromRGB(230, 230, 240),
	SubText     = Color3.fromRGB(140, 145, 165),
	Owned       = Color3.fromRGB(60, 180, 80),
	Active      = Color3.fromRGB(80, 160, 255),
	AdGreen     = Color3.fromRGB(22, 70, 34),
	AdBorder    = Color3.fromRGB(60, 180, 80),
}

-- ── WAIT FOR SHOP GUI ─────────────────────────────────────────────

local gui = PlayerGui:WaitForChild("ShopGui", 15)
if not gui then
	warn("[ShopClient] ShopGui not found — run ShopCMDBar in Studio first")
	return
end

local bg    = gui:WaitForChild("BG")
local panel = bg:WaitForChild("Panel")

-- ── HELPERS ───────────────────────────────────────────────────────

local function bindGuiButton(button, callback)
	if not (button and callback and button:IsA("GuiButton")) then return end
	button.Active = true
	button.Selectable = true
	button.AutoButtonColor = true
	button.Activated:Connect(callback)
end

local uiScale = panel:FindFirstChildOfClass("UIScale")
if not uiScale then
	uiScale = Instance.new("UIScale")
	uiScale.Parent = panel
end

local function formatMoney(amount)
	if amount >= 1e6 then return string.format("$%.1fM", amount / 1e6) end
	if amount >= 1000 then return string.format("$%.1fK", amount / 1000) end
	return string.format("$%d", math.floor(amount))
end

local function formatCountdown(seconds)
	local s = math.max(0, math.floor(seconds))
	local h = math.floor(s / 3600)
	local m = math.floor((s % 3600) / 60)
	local sec = s % 60
	if h > 0 then return string.format("%dh %02dm", h, m) end
	return string.format("%dm %02ds", m, sec)
end

-- ── AD STATE ──────────────────────────────────────────────────────

local adsEligible = nil  -- nil = not checked yet
local moneyAdCooldown = false
local researchAdCooldown = false
local moneyBoostUiToken = 0
local researchBoostUiToken = 0

-- Money bond reward cache
local cachedNetWorth  = 0
local cachedUseCount  = 0
local cachedResetTime = 0
local cachedReward    = 0
local cachedPct       = 0.05

-- Ad eligibility check
task.spawn(function()
	local serverEligible = player:GetAttribute("AdsEligible")
	if serverEligible == false then adsEligible = false; return end

	local ok, policyInfo = pcall(function()
		return PolicyService:GetPolicyInfoForPlayerAsync(player)
	end)
	if not ok or not policyInfo or not policyInfo.AreAdsAllowed then
		adsEligible = false
		return
	end
	adsEligible = true
end)

-- Money ad info from server
if MoneyAdInfo then
	MoneyAdInfo.OnClientEvent:Connect(function(netWorth, useCount, resetTime, reward, pct)
		cachedNetWorth  = netWorth  or 0
		cachedUseCount  = useCount  or 0
		cachedResetTime = resetTime or 0
		cachedReward    = reward    or 0
		cachedPct       = pct       or 0.05
	end)
end

-- ── OPEN / CLOSE ──────────────────────────────────────────────────

local isOpen = false
local activeTab = "Passes"
-- Forward declarations
local setActiveTab

local function openShop(tab: string?)
	if isOpen and tab and tab ~= activeTab then
		setActiveTab(tab)
		return
	end
	if isOpen then return end
	isOpen = true
	gui.Enabled = true
	uiScale.Scale = 0.9
	panel.Visible = true
	TweenService:Create(uiScale, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	if tab then setActiveTab(tab) end
	-- Request fresh money ad info
	if RequestMoneyAdInfo then pcall(function() RequestMoneyAdInfo:FireServer() end) end
end

local function closeShop()
	if not isOpen then return end
	isOpen = false
	local tween = TweenService:Create(uiScale, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = 0.9 })
	tween:Play()
	tween.Completed:Connect(function()
		if not isOpen then
			panel.Visible = false
			gui.Enabled = false
		end
	end)
end

local function toggleShop()
	if isOpen then closeShop() else openShop() end
end

-- ── BUILD UI ──────────────────────────────────────────────────────

-- Header
local header = Instance.new("Frame")
header.Name = "Header"
header.Size = UDim2.new(1, 0, 0, 48)
header.BackgroundTransparency = 1
header.Parent = panel

local title = Instance.new("TextLabel")
title.Name = "Title"
title.Text = "🛒  SHOP"
title.Size = UDim2.new(1, -56, 1, 0)
title.Position = UDim2.fromOffset(16, 0)
title.BackgroundTransparency = 1
title.TextColor3 = THEME.Text
title.TextSize = 20
title.Font = Enum.Font.GothamBold
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = header

local closeBtn = Instance.new("TextButton")
closeBtn.Name = "CloseButton"
closeBtn.Text = "✕"
closeBtn.Size = UDim2.new(0, 40, 0, 40)
closeBtn.Position = UDim2.new(1, -46, 0, 4)
closeBtn.BackgroundTransparency = 1
closeBtn.TextColor3 = THEME.SubText
closeBtn.TextSize = 18
closeBtn.Font = Enum.Font.GothamBold
closeBtn.Parent = header
bindGuiButton(closeBtn, closeShop)

-- Tab bar
local tabBar = Instance.new("Frame")
tabBar.Name = "TabBar"
tabBar.Size = UDim2.new(1, -24, 0, 32)
tabBar.Position = UDim2.fromOffset(12, 50)
tabBar.BackgroundTransparency = 1
tabBar.Parent = panel

local tabLayout = Instance.new("UIListLayout")
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.Padding = UDim.new(0, 6)
tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
tabLayout.Parent = tabBar

local TABS = { "Passes", "Subscriptions", "Boosts" }
local tabButtons = {}

-- Content scroll frame
local content = Instance.new("ScrollingFrame")
content.Name = "Content"
content.Size = UDim2.new(1, -24, 1, -96)
content.Position = UDim2.fromOffset(12, 88)
content.BackgroundTransparency = 1
content.BorderSizePixel = 0
content.ScrollBarThickness = 4
content.CanvasSize = UDim2.new(0, 0, 0, 0)
content.AutomaticCanvasSize = Enum.AutomaticSize.Y
content.ScrollingDirection = Enum.ScrollingDirection.Y
content.Parent = panel

local contentLayout = Instance.new("UIListLayout")
contentLayout.Padding = UDim.new(0, 8)
contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
contentLayout.Parent = content

local contentPad = Instance.new("UIPadding")
contentPad.PaddingBottom = UDim.new(0, 12)
contentPad.Parent = content

-- ── SUBSCRIPTION ID LOOKUP ────────────────────────────────────────
local SUBSCRIPTION_IDS_RAW = {
	Sub_ResortPass     = "EXP-250027655716536898",
	Sub_UnlimitedSlots = "EXP-4763590370263171569",
	Sub_PremiumRewards = "EXP-7331536610573550159",
	Sub_VIP            = "EXP-7351729691373470262",
}

-- ── CARD BUILDER ──────────────────────────────────────────────────

local function createCard(parent: ScrollingFrame, item: any, layoutOrder: number, cardType: string)
	local card = Instance.new("Frame")
	card.Name = "Card_" .. (item.name or item.key or "")
	card.Size = UDim2.new(1, 0, 0, 72)
	card.BackgroundColor3 = THEME.CardBg
	card.BorderSizePixel = 0
	card.LayoutOrder = layoutOrder
	card.Parent = parent
	Instance.new("UICorner", card).CornerRadius = UDim.new(0, 10)

	-- Accent bar
	local accent = Instance.new("Frame")
	accent.Name = "Accent"
	accent.Size = UDim2.new(0, 4, 1, -12)
	accent.Position = UDim2.fromOffset(0, 6)
	accent.BackgroundColor3 = item.color or THEME.Active
	accent.BorderSizePixel = 0
	accent.Parent = card
	Instance.new("UICorner", accent).CornerRadius = UDim.new(0, 2)

	-- Icon
	local iconLabel = Instance.new("TextLabel")
	iconLabel.Name = "Icon"
	iconLabel.Text = item.icon or "🛒"
	iconLabel.Size = UDim2.new(0, 36, 0, 36)
	iconLabel.Position = UDim2.fromOffset(14, 18)
	iconLabel.BackgroundTransparency = 1
	iconLabel.TextSize = 24
	iconLabel.Font = Enum.Font.GothamBold
	iconLabel.Parent = card

	-- Name
	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "Name"
	nameLabel.Text = item.name or "Unknown"
	nameLabel.Size = UDim2.new(1, -180, 0, 22)
	nameLabel.Position = UDim2.fromOffset(56, 14)
	nameLabel.BackgroundTransparency = 1
	nameLabel.TextColor3 = THEME.Text
	nameLabel.TextSize = 14
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.Parent = card

	-- Description
	local descLabel = Instance.new("TextLabel")
	descLabel.Name = "Desc"
	descLabel.Text = item.desc or ""
	descLabel.Size = UDim2.new(1, -180, 0, 18)
	descLabel.Position = UDim2.fromOffset(56, 38)
	descLabel.BackgroundTransparency = 1
	descLabel.TextColor3 = THEME.SubText
	descLabel.TextSize = 12
	descLabel.Font = Enum.Font.Gotham
	descLabel.TextXAlignment = Enum.TextXAlignment.Left
	descLabel.TextTruncate = Enum.TextTruncate.AtEnd
	descLabel.Parent = card

	-- Action button
	local actionBtn = Instance.new("TextButton")
	actionBtn.Name = "ActionBtn"
	actionBtn.Size = UDim2.new(0, 90, 0, 32)
	actionBtn.Position = UDim2.new(1, -104, 0.5, -16)
	actionBtn.BorderSizePixel = 0
	actionBtn.TextSize = 12
	actionBtn.Font = Enum.Font.GothamBold
	actionBtn.TextColor3 = Color3.new(1, 1, 1)
	actionBtn.Parent = card
	Instance.new("UICorner", actionBtn).CornerRadius = UDim.new(0, 8)

	if cardType == "pass" then
		local owned = false
		local ok, result = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, item.id)
		end)
		if ok then owned = result end

		if owned then
			actionBtn.Text = "✓ OWNED"
			actionBtn.BackgroundColor3 = THEME.Owned
			actionBtn.AutoButtonColor = false
		else
			actionBtn.Text = "BUY"
			actionBtn.BackgroundColor3 = item.color or THEME.Active
			bindGuiButton(actionBtn, function()
				pcall(function()
					MarketplaceService:PromptGamePassPurchase(player, item.id)
				end)
			end)
		end

	elseif cardType == "subscription" then
		local subActive = player:GetAttribute(item.key) == true
		if subActive then
			actionBtn.Text = "✓ ACTIVE"
			actionBtn.BackgroundColor3 = THEME.Owned
			actionBtn.AutoButtonColor = false
		else
			actionBtn.Text = "SUBSCRIBE"
			actionBtn.BackgroundColor3 = item.color or THEME.Active
			bindGuiButton(actionBtn, function()
				pcall(function()
					MarketplaceService:PromptSubscriptionPurchase(player, SUBSCRIPTION_IDS_RAW[item.key])
				end)
			end)
		end

	elseif cardType == "product" then
		actionBtn.Text = "BUY"
		actionBtn.BackgroundColor3 = item.color or THEME.Active
		bindGuiButton(actionBtn, function()
			pcall(function()
				MarketplaceService:PromptProductPurchase(player, item.id)
			end)
		end)
	end

	-- Hover effect
	card.MouseEnter:Connect(function()
		TweenService:Create(card, TweenInfo.new(0.12), { BackgroundColor3 = THEME.CardHover }):Play()
	end)
	card.MouseLeave:Connect(function()
		TweenService:Create(card, TweenInfo.new(0.12), { BackgroundColor3 = THEME.CardBg }):Play()
	end)

	return card
end

-- ── AD CARD BUILDER ───────────────────────────────────────────────

local function createAdCard(parent: ScrollingFrame, layoutOrder: number, adType: string)
	if adsEligible == false then return nil end

	local isMoney = adType == "Money"
	local placementId = if isMoney then MONEY_PLACEMENT_ID else RESEARCH_PLACEMENT_ID
	local accentColor = if isMoney then Color3.fromRGB(80, 200, 80) else Color3.fromRGB(160, 100, 255)

	local card = Instance.new("Frame")
	card.Name = "AdCard_" .. adType
	card.Size = UDim2.new(1, 0, 0, if isMoney then 110 else 72)
	card.BackgroundColor3 = THEME.AdGreen
	card.BorderSizePixel = 0
	card.LayoutOrder = layoutOrder
	card.Parent = parent
	Instance.new("UICorner", card).CornerRadius = UDim.new(0, 10)
	local stroke = Instance.new("UIStroke")
	stroke.Color = accentColor
	stroke.Thickness = 1
	stroke.Transparency = 0.6
	stroke.Parent = card

	-- Accent bar
	local accent = Instance.new("Frame")
	accent.Name = "Accent"
	accent.Size = UDim2.new(0, 4, 1, -12)
	accent.Position = UDim2.fromOffset(0, 6)
	accent.BackgroundColor3 = accentColor
	accent.BorderSizePixel = 0
	accent.Parent = card
	Instance.new("UICorner", accent).CornerRadius = UDim.new(0, 2)

	-- "FREE" badge
	local badge = Instance.new("TextLabel")
	badge.Name = "Badge"
	badge.Text = "FREE"
	badge.Size = UDim2.new(0, 36, 0, 16)
	badge.Position = UDim2.fromOffset(14, 6)
	badge.BackgroundColor3 = accentColor
	badge.TextColor3 = Color3.new(0, 0, 0)
	badge.TextSize = 10
	badge.Font = Enum.Font.GothamBold
	badge.Parent = card
	Instance.new("UICorner", badge).CornerRadius = UDim.new(0, 4)

	local titleText = if isMoney then "Watch Ad — Money Reward" else "Watch Ad — 2x RP Boost (5 min)"
	local descText = if isMoney then "Earn resort bond reward by watching a short ad" else "Double research points for 5 minutes"

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "Name"
	nameLabel.Text = titleText
	nameLabel.Size = UDim2.new(1, -180, 0, 22)
	nameLabel.Position = UDim2.fromOffset(56, 14)
	nameLabel.BackgroundTransparency = 1
	nameLabel.TextColor3 = THEME.Text
	nameLabel.TextSize = 14
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.Parent = card

	local descLabel = Instance.new("TextLabel")
	descLabel.Name = "Desc"
	descLabel.Text = descText
	descLabel.Size = UDim2.new(1, -180, 0, 18)
	descLabel.Position = UDim2.fromOffset(56, 38)
	descLabel.BackgroundTransparency = 1
	descLabel.TextColor3 = THEME.SubText
	descLabel.TextSize = 12
	descLabel.Font = Enum.Font.Gotham
	descLabel.TextXAlignment = Enum.TextXAlignment.Left
	descLabel.TextTruncate = Enum.TextTruncate.AtEnd
	descLabel.Parent = card

	-- Watch Ad button
	local watchBtn = Instance.new("TextButton")
	watchBtn.Name = "WatchAdBtn"
	watchBtn.Text = "▶ WATCH AD"
	watchBtn.Size = UDim2.new(0, 90, 0, 32)
	watchBtn.Position = UDim2.new(1, -104, 0, 18)
	watchBtn.BackgroundColor3 = accentColor
	watchBtn.BorderSizePixel = 0
	watchBtn.TextSize = 11
	watchBtn.Font = Enum.Font.GothamBold
	watchBtn.TextColor3 = Color3.new(0, 0, 0)
	watchBtn.Parent = card
	Instance.new("UICorner", watchBtn).CornerRadius = UDim.new(0, 8)

	-- Register ad opportunity
	pcall(function()
		AdService:RegisterAdOpportunityAsync(watchBtn, placementId)
	end)

	-- Status label (timer / error / etc.)
	local statusLabel = Instance.new("TextLabel")
	statusLabel.Name = "StatusLabel"
	statusLabel.Size = UDim2.new(1, -24, 0, 14)
	statusLabel.Position = UDim2.fromOffset(56, 56)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Text = ""
	statusLabel.TextColor3 = THEME.SubText
	statusLabel.TextSize = 11
	statusLabel.Font = Enum.Font.Gotham
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.Parent = card

	-- Money-specific: reward info row + Buy Bond button
	local buyBondBtn
	if isMoney then
		local rewardInfo = Instance.new("TextLabel")
		rewardInfo.Name = "RewardInfo"
		rewardInfo.Size = UDim2.new(1, -24, 0, 14)
		rewardInfo.Position = UDim2.fromOffset(56, 72)
		rewardInfo.BackgroundTransparency = 1
		rewardInfo.Text = ""
		rewardInfo.TextColor3 = THEME.SubText
		rewardInfo.TextSize = 11
		rewardInfo.Font = Enum.Font.Gotham
		rewardInfo.TextXAlignment = Enum.TextXAlignment.Left
		rewardInfo.Parent = card

		buyBondBtn = Instance.new("TextButton")
		buyBondBtn.Name = "BuyBondBtn"
		buyBondBtn.Text = "💸 Buy Bond"
		buyBondBtn.Size = UDim2.new(0, 90, 0, 28)
		buyBondBtn.Position = UDim2.new(1, -104, 0, 72)
		buyBondBtn.BackgroundColor3 = Color3.fromRGB(26, 80, 38)
		buyBondBtn.BorderSizePixel = 0
		buyBondBtn.TextSize = 11
		buyBondBtn.Font = Enum.Font.GothamBold
		buyBondBtn.TextColor3 = Color3.fromRGB(100, 255, 120)
		buyBondBtn.Parent = card
		Instance.new("UICorner", buyBondBtn).CornerRadius = UDim.new(0, 8)

		bindGuiButton(buyBondBtn, function()
			pcall(function()
				MarketplaceService:PromptProductPurchase(player, MONEY_BOND_PRODUCT_ID)
			end)
		end)

		-- Update reward display
		local function updateMoneyRewardUI()
			if cachedReward > 0 then
				descLabel.Text = string.format("Earn %s (%.1f%% of %s net worth)", formatMoney(cachedReward), cachedPct * 100, formatMoney(cachedNetWorth))
				buyBondBtn.Text = string.format("💸 %s", formatMoney(cachedReward))
			end
			local remaining = cachedResetTime - os.time()
			if remaining > 0 then
				rewardInfo.Text = string.format("Resets in %s • %d uses today • Each use −0.5%%", formatCountdown(remaining), cachedUseCount)
			else
				rewardInfo.Text = string.format("%d uses today • Each use −0.5%% • Resets daily", cachedUseCount)
			end
		end

		-- Periodically update while shop is open
		task.spawn(function()
			while card and card.Parent do
				if isOpen then updateMoneyRewardUI() end
				task.wait(1)
			end
		end)

		-- Also update when server sends fresh info
		if MoneyAdInfo then
			MoneyAdInfo.OnClientEvent:Connect(function()
				task.defer(updateMoneyRewardUI)
			end)
		end
	end

	-- Ad click handler
	local function getAdCooldown()
		return if isMoney then moneyAdCooldown else researchAdCooldown
	end
	local function setAdCooldown(v)
		if isMoney then moneyAdCooldown = v else researchAdCooldown = v end
	end

	bindGuiButton(watchBtn, function()
		if getAdCooldown() then return end
		setAdCooldown(true)
		watchBtn.Text = "CHECKING..."
		watchBtn.BackgroundTransparency = 0.4

		-- Pre-check ad availability
		local availOk, availResult = pcall(function()
			return AdService:GetAdAvailabilityNowAsync(Enum.AdFormat.RewardedVideo)
		end)
		if availOk and type(availResult) == "table" then
			local avail = availResult.AdAvailabilityResult
			if avail == Enum.AdAvailabilityResult.PlayerIneligible
				or avail == Enum.AdAvailabilityResult.DeviceIneligible
				or avail == Enum.AdAvailabilityResult.ExperienceIneligible
				or avail == Enum.AdAvailabilityResult.PublisherIneligible then
				card.Visible = false
				return
			end
			if avail == Enum.AdAvailabilityResult.NoFill then
				statusLabel.Text = "No ads available right now"
				watchBtn.Text = "▶ WATCH AD"
				watchBtn.BackgroundTransparency = 0
				setAdCooldown(false)
				task.delay(3, function()
					if statusLabel.Parent then statusLabel.Text = "" end
				end)
				return
			end
		end

		RequestAdBoost:FireServer(if isMoney then "Money" else "Research")

		-- Timeout
		task.delay(30, function()
			if getAdCooldown() and watchBtn.Parent then
				statusLabel.Text = "Ad request timed out"
				watchBtn.Text = "▶ WATCH AD"
				watchBtn.BackgroundTransparency = 0
				setAdCooldown(false)
				task.delay(2.5, function()
					if statusLabel.Parent and statusLabel.Text == "Ad request timed out" then
						statusLabel.Text = ""
					end
				end)
			end
		end)
	end)

	-- Listen for ad result
	AdBoostResult.OnClientEvent:Connect(function(boostType, success, endTime, failureMessage)
		local isMyType = (isMoney and boostType == "Money") or (not isMoney and boostType == "Research")
		if not isMyType then return end

		if success then
			if isMoney then
				-- Money reward is instant
				watchBtn.Text = "✓ DONE"
				watchBtn.BackgroundTransparency = 0
				statusLabel.Text = "Reward granted!"
				setAdCooldown(false)
				task.delay(2, function()
					if watchBtn.Parent then watchBtn.Text = "▶ WATCH AD" end
					if statusLabel.Parent then statusLabel.Text = "" end
				end)
			else
				-- Research boost has a timer
				watchBtn.Text = "ACTIVE ✓"
				watchBtn.BackgroundTransparency = 0.5
				local token = researchBoostUiToken + 1
				researchBoostUiToken = token
				task.spawn(function()
					while token == researchBoostUiToken do
						local remaining = (endTime or 0) - os.time()
						if remaining <= 0 then
							watchBtn.Text = "▶ WATCH AD"
							watchBtn.BackgroundTransparency = 0
							statusLabel.Text = ""
							setAdCooldown(false)
							break
						end
						local mins = math.floor(remaining / 60)
						local secs = remaining % 60
						statusLabel.Text = string.format("BOOST ACTIVE — %d:%02d", mins, secs)
						task.wait(1)
					end
				end)
			end
		else
			statusLabel.Text = failureMessage or "Ad failed"
			watchBtn.Text = "▶ WATCH AD"
			watchBtn.BackgroundTransparency = 0
			setAdCooldown(false)
			task.delay(2.5, function()
				if statusLabel.Parent and statusLabel.Text == (failureMessage or "Ad failed") then
					statusLabel.Text = ""
				end
			end)
		end
	end)

	return card
end

-- ── TAB RENDERING ─────────────────────────────────────────────────

local function clearContent()
	for _, child in ipairs(content:GetChildren()) do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
end

local function renderPasses()
	clearContent()
	for i, pass in ipairs(GAME_PASSES) do
		task.spawn(function()
			createCard(content, pass, i, "pass")
		end)
	end
end

local function renderSubscriptions()
	clearContent()
	for i, sub in ipairs(SUBSCRIPTIONS) do
		createCard(content, sub, i, "subscription")
	end
end

local function renderBoosts()
	clearContent()

	-- ─ Section: Free Ads ─
	local adHeader = Instance.new("Frame")
	adHeader.Name = "SectionAds"
	adHeader.Size = UDim2.new(1, 0, 0, 24)
	adHeader.BackgroundTransparency = 1
	adHeader.LayoutOrder = -100
	adHeader.Parent = content
	local adTitle = Instance.new("TextLabel")
	adTitle.Text = "📺  FREE — WATCH ADS"
	adTitle.Size = UDim2.fromScale(1, 1)
	adTitle.BackgroundTransparency = 1
	adTitle.TextColor3 = Color3.fromRGB(80, 200, 80)
	adTitle.TextSize = 13
	adTitle.Font = Enum.Font.GothamBold
	adTitle.TextXAlignment = Enum.TextXAlignment.Left
	adTitle.Parent = adHeader

	createAdCard(content, -99, "Money")
	createAdCard(content, -98, "Research")

	-- ─ Section: Money ─
	local moneyHeader = Instance.new("Frame")
	moneyHeader.Name = "SectionMoney"
	moneyHeader.Size = UDim2.new(1, 0, 0, 28)
	moneyHeader.BackgroundTransparency = 1
	moneyHeader.LayoutOrder = 0
	moneyHeader.Parent = content
	local moneyTitle = Instance.new("TextLabel")
	moneyTitle.Text = "💰  MONEY"
	moneyTitle.Size = UDim2.fromScale(1, 1)
	moneyTitle.BackgroundTransparency = 1
	moneyTitle.TextColor3 = Color3.fromRGB(255, 200, 50)
	moneyTitle.TextSize = 13
	moneyTitle.Font = Enum.Font.GothamBold
	moneyTitle.TextXAlignment = Enum.TextXAlignment.Left
	moneyTitle.Parent = moneyHeader

	local order = 1
	for _, prod in ipairs(DEV_PRODUCTS) do
		if prod.category == "Money" then
			createCard(content, prod, order, "product")
			order += 1
		end
	end

	-- ─ Section: Research ─
	local rpHeader = Instance.new("Frame")
	rpHeader.Name = "SectionResearch"
	rpHeader.Size = UDim2.new(1, 0, 0, 28)
	rpHeader.BackgroundTransparency = 1
	rpHeader.LayoutOrder = 100
	rpHeader.Parent = content
	local rpTitle = Instance.new("TextLabel")
	rpTitle.Text = "🧪  RESEARCH POINTS"
	rpTitle.Size = UDim2.fromScale(1, 1)
	rpTitle.BackgroundTransparency = 1
	rpTitle.TextColor3 = Color3.fromRGB(160, 100, 255)
	rpTitle.TextSize = 13
	rpTitle.Font = Enum.Font.GothamBold
	rpTitle.TextXAlignment = Enum.TextXAlignment.Left
	rpTitle.Parent = rpHeader

	for _, prod in ipairs(DEV_PRODUCTS) do
		if prod.category == "Research" then
			createCard(content, prod, 100 + order, "product")
			order += 1
		end
	end

	-- ─ Section: Slots ─
	local slotHeader = Instance.new("Frame")
	slotHeader.Name = "SectionSlots"
	slotHeader.Size = UDim2.new(1, 0, 0, 28)
	slotHeader.BackgroundTransparency = 1
	slotHeader.LayoutOrder = 200
	slotHeader.Parent = content
	local slotTitle = Instance.new("TextLabel")
	slotTitle.Text = "💾  SAVE SLOTS"
	slotTitle.Size = UDim2.fromScale(1, 1)
	slotTitle.BackgroundTransparency = 1
	slotTitle.TextColor3 = Color3.fromRGB(100, 180, 255)
	slotTitle.TextSize = 13
	slotTitle.Font = Enum.Font.GothamBold
	slotTitle.TextXAlignment = Enum.TextXAlignment.Left
	slotTitle.Parent = slotHeader

	for _, prod in ipairs(DEV_PRODUCTS) do
		if prod.category == "Slots" then
			createCard(content, prod, 200 + order, "product")
			order += 1
		end
	end
end

-- ── TAB SWITCHING ─────────────────────────────────────────────────

setActiveTab = function(tabName: string)
	activeTab = tabName
	for name, btn in pairs(tabButtons) do
		if name == tabName then
			btn.BackgroundColor3 = THEME.TabActive
			btn.TextColor3 = THEME.Text
		else
			btn.BackgroundColor3 = THEME.TabInactive
			btn.TextColor3 = THEME.SubText
		end
	end
	if tabName == "Passes" then
		renderPasses()
	elseif tabName == "Subscriptions" then
		renderSubscriptions()
	elseif tabName == "Boosts" then
		renderBoosts()
	end
end

for i, tabName in ipairs(TABS) do
	local btn = Instance.new("TextButton")
	btn.Name = "Tab_" .. tabName
	btn.Text = tabName
	btn.Size = UDim2.new(0, 110, 1, 0)
	btn.BackgroundColor3 = THEME.TabInactive
	btn.BorderSizePixel = 0
	btn.TextColor3 = THEME.SubText
	btn.TextSize = 12
	btn.Font = Enum.Font.GothamBold
	btn.LayoutOrder = i
	btn.Parent = tabBar
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)
	tabButtons[tabName] = btn
	bindGuiButton(btn, function()
		setActiveTab(tabName)
	end)
end

-- ── HOOK: TopBar + Old Buttons ────────────────────────────────────

local function hookButton(instance, callback)
	if not instance then return end
	if instance:IsA("GuiButton") then
		bindGuiButton(instance, callback)
	else
		instance.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				callback()
			end
		end)
	end
end

task.spawn(function()
	local MainHUD = PlayerGui:WaitForChild("MainHUD", 15)
	if not MainHUD then return end
	local Top = MainHUD:WaitForChild("Top", 10)
	if not Top then return end
	local TopBar = Top:WaitForChild("TopBar", 10)
	if not TopBar then return end

	-- ShopButton (🛒 icon in top bar)
	local shopBtn = TopBar:WaitForChild("ShopButton", 10)
	if shopBtn then
		hookButton(shopBtn, toggleShop)
	end

	-- Money > More → open to Boosts tab
	local Money = TopBar:FindFirstChild("Money")
	if Money then
		local moreBtn = Money:FindFirstChild("More")
		if moreBtn then
			hookButton(moreBtn, function()
				openShop("Boosts")
			end)
		end
	end

	-- Guests > More → open to Passes tab
	local Guests = TopBar:FindFirstChild("Guests")
	if Guests then
		local guestsMore = Guests:FindFirstChild("More")
		if guestsMore then
			hookButton(guestsMore, function()
				openShop("Passes")
			end)
		end
	end
end)

-- Research "Buy RP" button in ResearchFrame header
task.spawn(function()
	local MainHUD = PlayerGui:WaitForChild("MainHUD", 15)
	if not MainHUD then return end
	local ResearchFrame = MainHUD:WaitForChild("ResearchFrame", 10)
	if not ResearchFrame then return end
	local ResearchHeader = ResearchFrame:WaitForChild("Header", 10)
	if not ResearchHeader then return end
	local rpLabel = ResearchHeader:FindFirstChild("RPLabel")
	if rpLabel then
		hookButton(rpLabel, function()
			openShop("Boosts")
		end)
	end
end)

-- ── AUTO-OPEN ON INSUFFICIENT FUNDS ──────────────────────────────

task.spawn(function()
	local lastAutoOpen = 0

	local function checkAndOpen(category, titleText)
		if titleText == "Not Enough Money" or titleText == "NOT ENOUGH MONEY" then
			local now = os.clock()
			if now - lastAutoOpen > 3 then
				lastAutoOpen = now
				openShop("Boosts")
			end
		end
	end

	local NotificationEvent = Events:FindFirstChild("NotificationEvent")
	if NotificationEvent and NotificationEvent:IsA("RemoteEvent") then
		NotificationEvent.OnClientEvent:Connect(checkAndOpen)
	end

	local ClientNotification = ReplicatedStorage:FindFirstChild("ClientNotification")
		or ReplicatedStorage:WaitForChild("ClientNotification", 10)
	if ClientNotification and ClientNotification:IsA("BindableEvent") then
		ClientNotification.Event:Connect(checkAndOpen)
	end

	player:GetAttributeChangedSignal("ShopAutoOpen"):Connect(function()
		local val = player:GetAttribute("ShopAutoOpen")
		if val == true then
			player:SetAttribute("ShopAutoOpen", nil)
			openShop("Boosts")
		end
	end)
end)

-- ── INIT ──────────────────────────────────────────────────────────

gui.Enabled = false
panel.Visible = false
setActiveTab("Passes")

-- Refresh ownership when a gamepass is purchased
MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(_, passId, purchased)
	if purchased and activeTab == "Passes" then
		task.wait(0.5)
		renderPasses()
	end
end)

-- Refresh subscriptions when attributes change
player.AttributeChanged:Connect(function(attr)
	if string.sub(attr, 1, 4) == "Sub_" and activeTab == "Subscriptions" then
		task.wait(0.3)
		renderSubscriptions()
	end
end)
