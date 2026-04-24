--[[
    AdBoostServer: handles rewarded video ad rewards + dev product currency purchases.

    MONEY REWARD (ad or Robux "Resort Bond" purchase):
      - Grants a flat percentage of the resort's net worth (sum of all PaidPrice attributes).
      - Base reward: 5% of net worth. Each use within 24 h reduces it by 0.5% (min 0.5%).
      - Usage counter resets every 24 hours.
      - Both ad completion and the Robux dev product consume one "use" and respect diminishing returns.
      - Client receives: MoneyAdInfo(netWorth, useCount, resetTime, nextReward, nextPct)

    RESEARCH BOOST (unchanged):
      - Watching an ad gives 2× passive RP for 5 minutes via AdResearchBoostActive attribute.
      - "PendingRPGrant" consumed by ResearchServer tick loop for Robux purchases.

    PLAYER ATTRIBUTES set by this server:
      - "AdsEligible"         (bool)   — PolicyService result cached on join
      - "AdMoneyUseCount"     (number) — uses today
      - "AdMoneyResetTime"    (number) — unix timestamp of next daily reset
      - "AdResearchBoostActive" (bool) — 2x RP boost active
      - "AdResearchBoostEndTime" (number) — boost expiry
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")
local AdService = game:GetService("AdService")
local PolicyService = game:GetService("PolicyService")

local Events = ReplicatedStorage:WaitForChild("Events")
local RequestAdBoost = Events:WaitForChild("RequestAdBoost")
local AdBoostResult = Events:WaitForChild("AdBoostResult")
local NotificationEvent = Events:FindFirstChild("NotificationEvent")

-- ── CONFIGURATION ──
local BOOST_DURATION = 300 -- 5 minutes (Research RP boost only)

-- Money reward: flat percentage of resort net worth, diminishing per use, daily reset
local MONEY_REWARD_BASE_PCT   = 0.05    -- 5% of net worth on first daily use
local MONEY_REWARD_DECAY_PCT  = 0.005   -- each subsequent use in the same day: -0.5%
local MONEY_REWARD_MIN_PCT    = 0.005   -- floor: always at least 0.5%
local MONEY_REWARD_RESET_SECS = 86400   -- reset window (24 hours)
local MONEY_BOND_PRODUCT_ID   = 3557185185  -- Robux purchase for the same reward

-- Rewarded ad placement IDs (from Creator Hub > Monetization > Rewarded Video)
local AD_PLACEMENTS = {
	Money = {
		placementId     = 297325229327538,
		rewardProductId = 3557185185,
	},
	Research = {
		placementId     = 318737320373663,
		rewardProductId = 3557199251,
	},

}

-- Dev Product IDs → currency grants.
-- "MoneyBond" = dynamic reward equal to current net-worth percentage (same as ad).
local DEV_PRODUCT_MAP = {
	-- Fixed-amount money products
	[3557184373] = { Type = "Money", Amount = 10000 },
	[3557184641] = { Type = "Money", Amount = 50000 },
	[3557184919] = { Type = "Money", Amount = 250000 },
	-- Resort Bond: dynamic 5%-of-net-worth reward (diminishing returns per use)
	[3557185185] = { Type = "MoneyBond" },

	-- Research products
	[3557198648] = { Type = "Research", Amount = 100 },
	[3557198849] = { Type = "Research", Amount = 500 },
	[3557199096] = { Type = "Research", Amount = 2000 },
	[3557199251] = { Type = "Research", Amount = 8000 },

	-- Slot management (persistent; handled by SlotPurchaseHandler)
	[3575009101] = { Type = "ExtraSlot" },       -- permanently unlocks +1 save slot (max 12)
	[3575008862] = { Type = "AddFriendSlot" },   -- adds +1 friend to private server whitelist
}

-- Track active boosts (Research only — money is now an instant flat grant)
local ActiveBoosts = {} -- [userId] = { Research = endTime }

-- Money reward usage tracking (in-memory; resets after MONEY_REWARD_RESET_SECS)
-- [userId] = { count = N, resetTime = unix_ts }
local adMoneyUsage = {}

-- Track in-flight ad requests so a second request can't start while one is loading
local adsInFlight = {} -- [userId] = true
-- Post-completion cooldown timestamps (applied AFTER ad finishes, not before it starts)
local adCooldowns = {} -- [userId] = completionTime
-- ── HELPERS: NOTIFICATIONS ──
local function notify(player, category, title, message, duration)
	if NotificationEvent and NotificationEvent:IsA("RemoteEvent") then
		NotificationEvent:FireClient(player, category, title, message, duration or 4)
	end
end

local function failBoost(player, boostType, title, message, category)
	AdBoostResult:FireClient(player, boostType, false, nil, message)
	notify(player, category or "Negative", title, message, 4)
end

-- ── MONEY GRANT (via MoneyServer BindableEvent) ──
local function grantMoney(player, amount)
	local MoneyServer = ServerScriptService:FindFirstChild("Server")
		and ServerScriptService.Server:FindFirstChild("MoneyServer")
	if not MoneyServer then
		for _, child in ipairs(ServerScriptService:GetDescendants()) do
			if child.Name == "MoneyServer" and child:IsA("Script") then
				MoneyServer = child; break
			end
		end
	end
	if MoneyServer then
		local incomeEvent = MoneyServer:FindFirstChild("AddIncome")
		if incomeEvent and incomeEvent:IsA("BindableEvent") then
			incomeEvent:Fire(player, amount, "ShopPurchase", Enum.AnalyticsEconomyTransactionType.IAP)
			return true
		end
	end
	warn(string.format("[AdBoostServer] MoneyServer unavailable for %s — money not granted.", player.Name))
	return false
end

-- ── RESEARCH GRANT ──
local function grantResearch(player, amount)
	local current = tonumber(player:GetAttribute("PendingRPGrant")) or 0
	player:SetAttribute("PendingRPGrant", current + amount)
	notify(player, "Positive", "PURCHASE", string.format("+%d Research Points", amount), 4)
	return true
end

-- ── NET WORTH MONEY REWARD SYSTEM ──

-- Sum PaidPrice of every placed object in the resort.
local function calculateResortNetWorth()
	local total = 0
	local placedObjects = workspace:FindFirstChild("PlacedObjects")
	if placedObjects then
		for _, model in ipairs(placedObjects:GetChildren()) do
			if model:IsA("Model") then
				total += tonumber(model:GetAttribute("PaidPrice")) or 0
			end
		end
	end
	return total
end

-- Get or initialize the player's daily usage entry (auto-resets after 24 h).
local function getMoneyUsageState(userId)
	local state = adMoneyUsage[userId]
	if not state or os.time() >= state.resetTime then
		state = { count = 0, resetTime = os.time() + MONEY_REWARD_RESET_SECS }
		adMoneyUsage[userId] = state
	end
	return state
end

-- Reward percentage for the given use count.
local function getMoneyRewardPct(useCount)
	return math.max(MONEY_REWARD_MIN_PCT, MONEY_REWARD_BASE_PCT - useCount * MONEY_REWARD_DECAY_PCT)
end

-- Format money as $1.5K / $2.3M for notifications.
local function fmtMoney(amount)
	if amount >= 1e6 then
		return string.format("$%.1fM", amount / 1e6)
	elseif amount >= 1000 then
		return string.format("$%.1fK", amount / 1000)
	end
	return string.format("$%d", math.floor(amount))
end

-- Forward declaration; the actual RemoteEvent is wired up at end of file.
local MoneyAdInfo

local function sendMoneyAdInfo(player)
	if not MoneyAdInfo then return end
	local state    = getMoneyUsageState(player.UserId)
	local netWorth = calculateResortNetWorth()
	local nextPct  = getMoneyRewardPct(state.count)
	local reward   = math.floor(netWorth * nextPct)
	MoneyAdInfo:FireClient(player, netWorth, state.count, state.resetTime, reward, nextPct)
end

-- Grant the current net-worth percentage as money.  Called for both ad completions
-- and Robux "Resort Bond" product purchases. Returns the granted amount, or nil on failure.
local function applyMoneyReward(player)
	local userId   = player.UserId
	local state    = getMoneyUsageState(userId)
	local pct      = getMoneyRewardPct(state.count)
	local netWorth = calculateResortNetWorth()
	local reward   = math.max(1, math.floor(netWorth * pct))

	-- Increment use counter before granting.
	state.count += 1
	player:SetAttribute("AdMoneyUseCount",  state.count)
	player:SetAttribute("AdMoneyResetTime", state.resetTime)

	local granted = grantMoney(player, reward)
	if not granted then
		-- Roll back counter — nothing was delivered.
		state.count -= 1
		player:SetAttribute("AdMoneyUseCount", state.count)
		notify(player, "Negative", "REWARD FAILED", "Could not deliver money reward. Please try again.", 5)
		return nil
	end

	local pctDisplay  = string.format("%.1f%%", pct * 100)
	local nextReward  = math.floor(netWorth * getMoneyRewardPct(state.count))
	notify(player, "Money",
		"RESORT BOND PAID OUT",
		string.format("+%s (%s of %s resort value). Next reward: %s.",
			fmtMoney(reward), pctDisplay, fmtMoney(netWorth), fmtMoney(nextReward)),
		7)

	task.defer(function()
		local p = Players:GetPlayerByUserId(userId)
		if p then sendMoneyAdInfo(p) end
	end)
	return reward
end

-- ── RESEARCH BOOST MANAGEMENT (unchanged: 2x passive RP for 5 minutes) ──

local function applyResearchBoost(player)
	local userId  = player.UserId
	local endTime = os.time() + BOOST_DURATION
	if not ActiveBoosts[userId] then ActiveBoosts[userId] = {} end
	ActiveBoosts[userId].Research = endTime

	player:SetAttribute("AdResearchBoostActive", true)
	player:SetAttribute("AdResearchBoostEndTime", endTime)
	notify(player, "Positive", "2x RESEARCH BOOST ACTIVE",
		"Research Points doubled for 5 minutes! Check the boost icon for time remaining.", 6)

	task.delay(BOOST_DURATION, function()
		local p = Players:GetPlayerByUserId(userId)
		if p then
			p:SetAttribute("AdResearchBoostActive", nil)
			p:SetAttribute("AdResearchBoostEndTime", nil)
			notify(p, "Positive", "RESEARCH BOOST EXPIRED", "Your 2× Research Points boost has ended.", 4)
		end
		if ActiveBoosts[userId] then ActiveBoosts[userId].Research = nil end
	end)
	return endTime
end

local function hasActiveResearchBoost(player)
	local boosts = ActiveBoosts[player.UserId]
	return boosts and boosts.Research and os.time() < boosts.Research or false
end

-- ── AD BOOST REQUEST HANDLER ──
RequestAdBoost.OnServerEvent:Connect(function(player, boostType)
	if boostType ~= "Money" and boostType ~= "Research" and boostType ~= "AFK" then
		return
	end
	if player:GetAttribute("WorldLoadLocked") == true then
		failBoost(player, boostType, "WORLD LOADING", "Please wait for your resort to finish loading.")
		return
	end
	if RunService:IsStudio() then
		failBoost(player, boostType, "STUDIO", "Rewarded ads are only available in the live game.")
		return
	end

	local userId = player.UserId
	local now = os.time()

	-- Prevent concurrent ad for the same player (in-flight guard)
	if adsInFlight[userId] then
		failBoost(player, boostType, "AD IN PROGRESS", "An ad is already loading. Please wait.")
		return
	end
	-- Post-completion cooldown: applied AFTER the ad finishes, not before it starts
	if adCooldowns[userId] and (now - adCooldowns[userId]) < 10 then
		failBoost(player, boostType, "ADS COOLING DOWN", "Please wait a few seconds before trying again.")
		return
	end

	-- Research: only one active boost at a time. Money: always available (instant reward).
	if boostType == "Research" and hasActiveResearchBoost(player) then
		failBoost(player, boostType, "BOOST ACTIVE", "You already have an active Research boost!", "Positive")
		return
	end

	local adConfig = AD_PLACEMENTS[boostType]
	if not adConfig then
		failBoost(player, boostType, "ADS UNAVAILABLE", "This boost type is not configured.")
		return
	end

	-- Check ad eligibility via PolicyService
	local policyOk, policyResult = pcall(function()
		return PolicyService:GetPolicyInfoForPlayerAsync(player)
	end)
	if not policyOk then
		warn("[AdBoostServer] PolicyService error for " .. player.Name .. ": " .. tostring(policyResult))
		failBoost(player, boostType, "ADS UNAVAILABLE", "Could not verify ad eligibility. Try again later.")
		return
	end
	if not policyResult or not policyResult.AreAdsAllowed then
		warn("[AdBoostServer] Ads not allowed for " .. player.Name .. " (AreAdsAllowed=false)")
		failBoost(player, boostType, "ADS NOT AVAILABLE", "Rewarded ads are not available for your account (age restriction or region).")
		return
	end

	-- Mark in-flight BEFORE any yields to prevent race conditions
	adsInFlight[userId] = true

	-- Quick availability pre-check: avoids wasting a ShowRewardedVideoAdAsync call
	-- when the ad system has no fill for this experience right now.
	local availOk, availResult = pcall(function()
		return AdService:GetAdAvailabilityNowAsync(Enum.AdFormat.RewardedVideo)
	end)
	if availOk and type(availResult) == "table" then
		local avail = availResult.AdAvailabilityResult
		if avail == Enum.AdAvailabilityResult.NoFill then
			adsInFlight[userId] = nil
			adCooldowns[userId] = os.time()
			failBoost(player, boostType, "NO ADS AVAILABLE", "No ads available right now. Try again in a moment.")
			return
		elseif avail ~= Enum.AdAvailabilityResult.IsAvailable and avail ~= Enum.AdAvailabilityResult.InternalError then
			-- InternalError: still attempt (may succeed); any other non-available state: bail
			adsInFlight[userId] = nil
			adCooldowns[userId] = os.time()
			failBoost(player, boostType, "ADS UNAVAILABLE", "Ads not available right now. Try again later.")
			return
		end
	end

	-- Create the ad reward object for this boost type
	local rewardOk, adReward = pcall(function()
		return AdService:CreateAdRewardFromDevProductId(adConfig.rewardProductId)
	end)
	if not rewardOk or not adReward then
		local errMsg = tostring(adReward)
		warn("[AdBoostServer] CreateAdRewardFromDevProductId failed for " .. player.Name .. " (productId=" .. tostring(adConfig.rewardProductId) .. "): " .. errMsg)
		adsInFlight[userId] = nil
		adCooldowns[userId] = os.time()
		failBoost(player, boostType, "ADS UNAVAILABLE", "Could not prepare ad reward: " .. errMsg)
		return
	end

	-- Show the rewarded video ad (yields until ad is dismissed or errors)
	warn("[AdBoostServer] Showing rewarded ad to " .. player.Name .. " (type=" .. boostType .. ", placement=" .. tostring(adConfig.placementId) .. ")")

	local adOk, adResult = pcall(function()
		return AdService:ShowRewardedVideoAdAsync(player, adReward, adConfig.placementId)
	end)

	-- Always clear in-flight and set post-completion cooldown, regardless of result
	adsInFlight[userId] = nil
	adCooldowns[userId] = os.time()

	if not adOk then
		local errMsg = tostring(adResult)
		warn("[AdBoostServer] ShowRewardedVideoAdAsync error for " .. player.Name .. ": " .. errMsg)
		failBoost(player, boostType, "ADS UNAVAILABLE", "Ad request failed: " .. errMsg)
		return
	end

	local resultStr = tostring(adResult)
	warn("[AdBoostServer] Ad result for " .. player.Name .. ": " .. resultStr)

	if adResult == Enum.ShowAdResult.ShowCompleted then
		if boostType == "Money" then
			local reward = applyMoneyReward(player)
			AdBoostResult:FireClient(player, boostType, reward ~= nil, nil, nil, reward)
		else
			local endTime = applyResearchBoost(player)
			AdBoostResult:FireClient(player, boostType, true, endTime)
		end
		return
	end

	local failureMessage
	if adResult == Enum.ShowAdResult.AdNotReady then
		failureMessage = "No ads available right now. Try again later."
	elseif adResult == Enum.ShowAdResult.ShowInterrupted then
		failureMessage = "You closed the ad before it finished."
	elseif adResult == Enum.ShowAdResult.InternalError then
		failureMessage = "Ad failed to load. Please try again."
	else
		failureMessage = "Ad did not complete (" .. resultStr .. ")."
	end

	failBoost(player, boostType, "AD NOT COMPLETED", failureMessage)
end)

-- ── DEV PRODUCT PURCHASE HANDLER ──
MarketplaceService.ProcessReceipt = function(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local productInfo = DEV_PRODUCT_MAP[receiptInfo.ProductId]
	if not productInfo then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local granted = false
	if productInfo.Type == "MoneyBond" then
		-- Dynamic reward: 5% of resort net worth (same diminishing-returns system as the ad)
		local reward = applyMoneyReward(player)
		granted = reward ~= nil
	elseif productInfo.Type == "Money" then
		granted = grantMoney(player, productInfo.Amount)
		if granted then
			notify(player, "Positive", "PURCHASE COMPLETE", string.format("+%s", fmtMoney(productInfo.Amount)), 5)
		end
	elseif productInfo.Type == "Research" then
		granted = grantResearch(player, productInfo.Amount)
	elseif productInfo.Type == "ExtraSlot" or productInfo.Type == "AddFriendSlot" then
		-- Deferred to SlotPurchaseHandler — fire a BindableEvent for it to process.
		-- This keeps ProcessReceipt non-blocking; SlotPurchaseHandler returns the real result.
		local handler = ServerScriptService:FindFirstChild("Server")
			and ServerScriptService.Server:FindFirstChild("SlotPurchaseHandler")
		if handler then
			local processEvent = handler:FindFirstChild("ProcessSlotPurchase")
			if processEvent and processEvent:IsA("BindableEvent") then
				processEvent:Fire(player, productInfo.Type, receiptInfo.PurchaseId)
				granted = true  -- optimistically grant; SlotPurchaseHandler validates
			end
		else
			warn("[AdBoostServer] SlotPurchaseHandler not found — cannot process", productInfo.Type)
		end
	end

	return granted and Enum.ProductPurchaseDecision.PurchaseGranted or Enum.ProductPurchaseDecision.NotProcessedYet
end

-- ── REMOTE EVENTS FOR CLIENT UI ──
local function getOrCreateRemote(name)
	local existing = Events:FindFirstChild(name)
	if existing then return existing end
	local re = Instance.new("RemoteEvent")
	re.Name  = name
	re.Parent = Events
	return re
end

MoneyAdInfo              = getOrCreateRemote("MoneyAdInfo")
local RequestMoneyAdInfo = getOrCreateRemote("RequestMoneyAdInfo")

-- Client requests fresh reward info (e.g., when the money shop opens).
RequestMoneyAdInfo.OnServerEvent:Connect(function(player)
	sendMoneyAdInfo(player)
end)

-- ── SEND AD ELIGIBILITY + INITIAL REWARD INFO ON JOIN ──
Players.PlayerAdded:Connect(function(player)
	task.spawn(function()
		local ok, policyInfo = pcall(function()
			return PolicyService:GetPolicyInfoForPlayerAsync(player)
		end)
		local eligible = ok and policyInfo ~= nil and policyInfo.AreAdsAllowed == true
		player:SetAttribute("AdsEligible", eligible)

		-- Initialise usage attributes so client UI shows correctly before first shop open.
		local state = getMoneyUsageState(player.UserId)
		player:SetAttribute("AdMoneyUseCount",  state.count)
		player:SetAttribute("AdMoneyResetTime", state.resetTime)

		-- Small delay so placed objects load and net worth is meaningful.
		task.wait(4)
		sendMoneyAdInfo(player)
	end)
end)

-- ── CLEANUP ──
Players.PlayerRemoving:Connect(function(player)
	ActiveBoosts[player.UserId]  = nil
	adCooldowns[player.UserId]   = nil
	adsInFlight[player.UserId]   = nil
	adMoneyUsage[player.UserId]  = nil
end)

print("[AdBoostServer] Loaded — Resort Bond ad rewards + Research boost ready.")
