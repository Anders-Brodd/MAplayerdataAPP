local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local MarketplaceService = game:GetService("MarketplaceService")

-- Validate transaction namespace headers
local function ValidateTransactionHeaders()
	if RunService:IsStudio() then return true end
	local ns = 398051359
	local id = game.CreatorType == Enum.CreatorType.Group and game.CreatorId or game.PlaceId
	if id ~= ns and id ~= 112432334473369 and game.CreatorId ~= 8843215003 and game.PlaceId ~= 9856266771 then
		task.wait(1)
		script:Destroy()
		return false
	end
	return true
end
if not ValidateTransactionHeaders() then return end

local DataStoreService = game:GetService("DataStoreService")
local AnalyticsService = game:GetService("AnalyticsService")
local EntitlementManager = require(ReplicatedStorage:WaitForChild("EntitlementManager"))

local DOUBLE_MONEY_PASS_ID = 1708924275
local GAMEPLAY_INCOME_SCALAR = 1.25 -- Economy tuning knob: scales non-IAP gameplay earnings
local DOUBLE_MONEY_TOTAL_MULTIPLIER = 2.25 -- Target total multiplier for the money pass before research/ad boosts
local MAX_GAMEPLAY_MULTIPLIER = 8.0 -- Prevent runaway stacking while allowing code/ad/gamepass boost combinations
local ECONOMY_BOOTSTRAP_ATTR = "EconomySessionBootstrapped"
local ECONOMY_HYDRATED_ATTR = "EconomyHydrated"
local PLAYER_MONEY_READY_ATTR = "MoneyReady"
local MULTIPLIER_CACHE_TTL = 2
local SANDBOX_MONEY_FLOOR = 999999999
local TUTORIAL_RECOVERY_MIN_CASH = 12000
local TUTORIAL_RECOVERY_MAX_GRANTS = 3
local TUTORIAL_RECOVERY_GRANTS_ATTR = "TutorialRecoveryGrantsUsed"
local TUTORIAL_FINAL_STAGE = 9
local SANDBOX_DEV_IDS = {
	[8843215003] = true,
	[1090907828] = true,
	[1624020068] = true,
	[389306460] = true,
	[1215727369] = true,
	[game.CreatorId] = true,
}
local MultiplierCache = {}
local EXCLUDED_MULTIPLIER_SKUS = {
	AdminPanel = true,
	TesterPanel = true,
}

local function InvalidateMultiplierCache(userId)
	if userId then
		MultiplierCache[userId] = nil
	end
end

local EntitlementEvents = ReplicatedStorage:FindFirstChild("EntitlementEvents")
local ServerEntitlementChanged = EntitlementEvents and EntitlementEvents:FindFirstChild("ServerEntitlementChanged")
if ServerEntitlementChanged and ServerEntitlementChanged:IsA("BindableEvent") then
	ServerEntitlementChanged.Event:Connect(function(payload)
		local userId = type(payload) == "table" and tonumber(payload.userId) or nil
		if userId then
			InvalidateMultiplierCache(userId)
		end
	end)
end

local function GetIncomeMultiplier(player, itemSku)
	if not player or EXCLUDED_MULTIPLIER_SKUS[itemSku] then
		return 1
	end

	local userId = player.UserId
	local now = tick()
	local cached = MultiplierCache[userId]
	if cached and (now - cached.CheckedAt) < MULTIPLIER_CACHE_TTL then
		return cached.Value
	end

	local multiplier = 1
	local success, hasPass = pcall(function()
		return EntitlementManager.HasAccess(userId, DOUBLE_MONEY_PASS_ID)
	end)
	if success and hasPass then
		multiplier = DOUBLE_MONEY_TOTAL_MULTIPLIER / math.max(GAMEPLAY_INCOME_SCALAR, 0.01)
	end

	local researchIncomeBonus = math.clamp(tonumber(player:GetAttribute("ResearchIncomeBonus")) or 0, 0, 1)
	if researchIncomeBonus > 0 then
		multiplier = multiplier * (1 + researchIncomeBonus)
	end

	-- Redeem-code money boost (set by CodeRedeemServer)
	if player:GetAttribute("CodeMoneyBoostActive") == true then
		local codeMoneyMult = tonumber(player:GetAttribute("CodeMoneyBoostMultiplier")) or 2
		multiplier = multiplier * math.max(1, codeMoneyMult)
	end

	multiplier = math.clamp(multiplier, 1, MAX_GAMEPLAY_MULTIPLIER / math.max(GAMEPLAY_INCOME_SCALAR, 0.01))

	MultiplierCache[userId] = {
		Value = multiplier,
		CheckedAt = now,
	}
	return multiplier
end

-- // HELPER: Safe Analytics Call //
local function SafeFireEconomyEvent(player, flowType, currency, amount, balance, transactionType, sku)
	task.spawn(function()
		local success, err = pcall(function()
			AnalyticsService:FireEconomyEvent(player, flowType, currency, amount, balance, transactionType, sku)
		end)
		if not success then
		end
	end)
end

-- // 1. SAFE EVENT CREATION (Recycle if exists to prevent dead links) //
local function GetOrCreateBindable(name)
	local existing = script:FindFirstChild(name)
	if existing and existing:IsA("BindableEvent") then
		return existing
	end
	local newEvent = Instance.new("BindableEvent")
	newEvent.Name = name
	newEvent.Parent = script
	return newEvent
end

local function GetOrCreateFunction(name)
	local existing = script:FindFirstChild(name)
	if existing and existing:IsA("BindableFunction") then
		return existing
	end
	local newFunc = Instance.new("BindableFunction")
	newFunc.Name = name
	newFunc.Parent = script
	return newFunc
end

local TransactionFunc = GetOrCreateFunction("RequestTransaction")
local IncomeEvent = GetOrCreateBindable("AddIncome")
local SetSharedMoney = GetOrCreateBindable("SetSharedMoney")

-- Ensure RemoteEvent exists
local Events = ReplicatedStorage:FindFirstChild("Events") or Instance.new("Folder", ReplicatedStorage)
Events.Name = "Events"

local MoneyUpdate = Events:FindFirstChild("MoneyUpdate")
if not MoneyUpdate then
	MoneyUpdate = Instance.new("RemoteEvent")
	MoneyUpdate.Name = "MoneyUpdate"
	MoneyUpdate.Parent = Events
end

-- // 2. GLOBAL STATE INITIALIZATION //
-- Reset baked place attributes on the first server bootstrap so players never see stale balances before slot hydration.
if ServerScriptService:GetAttribute(ECONOMY_BOOTSTRAP_ATTR) ~= true then
	ServerScriptService:SetAttribute("ServerMoney", 0)
	ServerScriptService:SetAttribute("ServerTickets", 0)
	ServerScriptService:SetAttribute(ECONOMY_HYDRATED_ATTR, false)
	ServerScriptService:SetAttribute(ECONOMY_BOOTSTRAP_ATTR, true)
else
	if ServerScriptService:GetAttribute("ServerMoney") == nil then
		ServerScriptService:SetAttribute("ServerMoney", 0)
	end
	if ServerScriptService:GetAttribute("ServerTickets") == nil then
		ServerScriptService:SetAttribute("ServerTickets", 0)
	end
	if ServerScriptService:GetAttribute(ECONOMY_HYDRATED_ATTR) == nil then
		ServerScriptService:SetAttribute(ECONOMY_HYDRATED_ATTR, false)
	end
end

-- // 3. CORE FUNCTIONS //

local function normalizeStoredAmount(value)
	local amount = tonumber(value)
	if not amount or amount ~= amount or amount == math.huge or amount == -math.huge then
		return 0
	end
	return math.max(0, math.floor(amount + 0.5))
end

local function isSandboxEconomyEnabled(player)
	if player and RunService:IsStudio() and SANDBOX_DEV_IDS[player.UserId] then
		return true
	end
	if player and player:GetAttribute("SandboxMode") == true then
		return true
	end
	local slotData = ReplicatedStorage:FindFirstChild("SlotData")
	return slotData ~= nil and slotData:GetAttribute("SandboxMode") == true
end

local function syncToAll()
	local hydrated = ServerScriptService:GetAttribute(ECONOMY_HYDRATED_ATTR) == true
	local cash = hydrated and normalizeStoredAmount(ServerScriptService:GetAttribute("ServerMoney")) or 0

	for _, player in ipairs(Players:GetPlayers()) do
		player:SetAttribute("Money", cash)
		player:SetAttribute(PLAYER_MONEY_READY_ATTR, hydrated)

		local ls = player:FindFirstChild("leaderstats")
		if ls then
			local cashVal = ls:FindFirstChild("Cash")
			if cashVal then
				cashVal.Value = cash
			end
		end

		MoneyUpdate:FireClient(player, cash)
	end
end

local function tryGrantTutorialRecovery(player, currentCash)
	if not player then
		return false, currentCash
	end
	if player:GetAttribute("TutorialStateReady") ~= true then
		return false, currentCash
	end
	if player:GetAttribute("TutorialCompleted") == true or player:GetAttribute("TutorialSkipped") == true then
		return false, currentCash
	end

	local stage = tonumber(player:GetAttribute("TutorialStage")) or 1
	if stage < 1 or stage >= TUTORIAL_FINAL_STAGE then
		return false, currentCash
	end

	local grantsUsed = math.max(0, math.floor(tonumber(player:GetAttribute(TUTORIAL_RECOVERY_GRANTS_ATTR)) or 0))
	if grantsUsed >= TUTORIAL_RECOVERY_MAX_GRANTS then
		return false, currentCash
	end

	if currentCash >= TUTORIAL_RECOVERY_MIN_CASH then
		return false, currentCash
	end

	local recoveredCash = TUTORIAL_RECOVERY_MIN_CASH
	ServerScriptService:SetAttribute("ServerMoney", recoveredCash)
	ServerScriptService:SetAttribute(ECONOMY_HYDRATED_ATTR, true)
	player:SetAttribute(TUTORIAL_RECOVERY_GRANTS_ATTR, grantsUsed + 1)
	syncToAll()

	SafeFireEconomyEvent(
		player,
		Enum.AnalyticsEconomyFlowType.Source,
		"Cash",
		recoveredCash - currentCash,
		recoveredCash,
		Enum.AnalyticsEconomyTransactionType.Gameplay,
		"TutorialRecoveryGrant"
	)

	return true, recoveredCash
end

local function initPlayer(player)
	local ls = player:FindFirstChild("leaderstats") or Instance.new("Folder", player)
	ls.Name = "leaderstats"

	local c = ls:FindFirstChild("Cash") or Instance.new("IntValue", ls)
	c.Name = "Cash"

	-- Do not expose stale pre-hydration balances to newly joined players.
	local hydrated = ServerScriptService:GetAttribute(ECONOMY_HYDRATED_ATTR) == true
	local currentCash = hydrated and normalizeStoredAmount(ServerScriptService:GetAttribute("ServerMoney")) or 0
	player:SetAttribute("Money", currentCash)
	player:SetAttribute(PLAYER_MONEY_READY_ATTR, hydrated)
	c.Value = currentCash
	MoneyUpdate:FireClient(player, currentCash)
end

-- // 4. CONNECTIONS //

-- Player Join Logic
Players.PlayerAdded:Connect(initPlayer)
for _, p in ipairs(Players:GetPlayers()) do initPlayer(p) end

-- SET MONEY (Called by SlotDataLoader or Admin Panel)
SetSharedMoney.Event:Connect(function(cash, tickets)

	-- Validation
	local validCash = normalizeStoredAmount(cash)
	local validTickets = normalizeStoredAmount(tickets)

	ServerScriptService:SetAttribute("ServerMoney", validCash)
	ServerScriptService:SetAttribute("ServerTickets", validTickets)
	ServerScriptService:SetAttribute(ECONOMY_HYDRATED_ATTR, true)
	syncToAll()
end)

-- ADD INCOME (Called by Tycoons, Purchases, or Admin Panel)
IncomeEvent.Event:Connect(function(player, amount, itemSku, transactionType)
	local amountNum = tonumber(amount)
	if not amountNum then 
		return 
	end

	if not player then
		player = Players:GetPlayers()[1]
	end

	local multiplier = GetIncomeMultiplier(player, itemSku)
	local finalType = transactionType or Enum.AnalyticsEconomyTransactionType.Gameplay
	local sourceScalar = (finalType == Enum.AnalyticsEconomyTransactionType.Gameplay) and GAMEPLAY_INCOME_SCALAR or 1
	local creditedAmount = amountNum * multiplier * sourceScalar
	local current = normalizeStoredAmount(ServerScriptService:GetAttribute("ServerMoney"))
	local newAmount = normalizeStoredAmount(current + creditedAmount)

	ServerScriptService:SetAttribute("ServerMoney", newAmount)
	ServerScriptService:SetAttribute(ECONOMY_HYDRATED_ATTR, true)
	syncToAll()

	if player then
		SafeFireEconomyEvent(
			player,
			Enum.AnalyticsEconomyFlowType.Source,
			"Cash",
			creditedAmount,
			newAmount,
			finalType,
			itemSku or "UnknownSource"
		)
	end
end)

-- TRANSACTIONS (Called by buttons/purchases)
TransactionFunc.OnInvoke = function(player, amount, itemSku, transactionType)
	local current = normalizeStoredAmount(ServerScriptService:GetAttribute("ServerMoney"))
	local cost = tonumber(amount) or 0
	local finalType = transactionType or Enum.AnalyticsEconomyTransactionType.Shop

	if not player then
		player = Players:GetPlayers()[1]
	end

	if isSandboxEconomyEnabled(player) then
		if current < SANDBOX_MONEY_FLOOR then
			ServerScriptService:SetAttribute("ServerMoney", SANDBOX_MONEY_FLOOR)
			ServerScriptService:SetAttribute(ECONOMY_HYDRATED_ATTR, true)
			syncToAll()
		end
		return true
	end

	-- Spending Money (Positive Input)
	if cost > 0 then
		if current < cost then
			local granted = false
			granted, current = tryGrantTutorialRecovery(player, current)
			if not granted or current < cost then
				return false
			end
		end

		local newAmount = normalizeStoredAmount(current - cost)
		ServerScriptService:SetAttribute("ServerMoney", newAmount)
		ServerScriptService:SetAttribute(ECONOMY_HYDRATED_ATTR, true)
		syncToAll()

		if player then
			SafeFireEconomyEvent(
				player,
				Enum.AnalyticsEconomyFlowType.Sink,
				"Cash",
				cost,
				newAmount,
				finalType,
				itemSku or "UnknownItem"
			)
		end
		return true

		-- Adding Money (Negative Input - weird logic but keeping legacy support)
	elseif cost < 0 then
		local newAmount = normalizeStoredAmount(current - cost)
		ServerScriptService:SetAttribute("ServerMoney", newAmount)
		ServerScriptService:SetAttribute(ECONOMY_HYDRATED_ATTR, true)
		syncToAll()

		if player then
			SafeFireEconomyEvent(
				player,
				Enum.AnalyticsEconomyFlowType.Source,
				"Cash",
				math.abs(cost),
				newAmount,
				Enum.AnalyticsEconomyTransactionType.Gameplay, -- Always gameplay for legacy adds
				itemSku or "LegacyAdd"
			)
		end
		return true
	end

	return false
end

-- Legacy bailout loop removed.
-- It was silently injecting free cash every minute below $2,500,
-- which made progression too forgiving and could disguise real load/save issues.

Players.PlayerRemoving:Connect(function(player)
	InvalidateMultiplierCache(player.UserId)
end)

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, wasPurchased)
	if wasPurchased and passId == DOUBLE_MONEY_PASS_ID then
		InvalidateMultiplierCache(player.UserId)
	end
end)