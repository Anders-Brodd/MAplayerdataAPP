--[[
	ENTITLEMENT MANAGER (Founder Support)

	Goal:
	- Permanently record legacy supporter buyers as founders.
	- Founder status grants access to all supporter gamepass checks forever.
	- Keep one entitlement path so future perks do not require manual backfills.
]]

local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local EntitlementManager = {}

local IS_SERVER = RunService:IsServer()

-- Legacy pass ownership promotes to permanent founder.
local LEGACY_FOUNDER_PASS_IDS = {
	1683937935,
}

-- Founder status only maps to supporter-tier passes.
-- Intentionally excludes privileged slot/sandbox passes.
local FOUNDER_ACCESS_PASS_IDS = {
	[1683937935] = true, -- Pre-Order
	[1704778044] = true, -- Controller+
	[1705274438] = true, -- Freecam+
	[1705719197] = true, -- Time Setter
	[1707796502] = true, -- Weather Controller
	[1708162428] = true, -- 2x Guests
	-- NOTE: More Employees (1708600326) is intentionally excluded so employee caps
	-- follow explicit ownership/admin grants only.
	[1708924275] = true, -- 2x Money
}

-- All known game-pass IDs (for reference and pass-validity checks)
local ALL_KNOWN_PASS_IDS = {
	[1683937935] = "Pre-Order",
	[1704778044] = "Controller+",
	[1705274438] = "Freecam+",
	[1705719197] = "Time Setter",
	[1707796502] = "Weather Controller",
	[1708162428] = "2x Guests",
	[1708600326] = "More Employees",
	[1708924275] = "2x Money",
	[1753340250] = "2x Research Points",
	[1792834210] = "Slot Data Limit Bypass",
	[1793522272] = "Always Active Resort",
}

-- Subscription IDs (stored here for reference; checked by SubscriptionManager server script)
-- Client-side subscription gating should read player attributes set by SubscriptionManager:
--   Sub_ResortPass, Sub_UnlimitedSlots, Sub_PremiumRewards, Sub_VIP
local SUBSCRIPTION_IDS = {
	ResortPass     = "EXP-250027655716536898",
	UnlimitedSlots = "EXP-4763590370263171569",
	PremiumRewards = "EXP-7331536610573550159",
	VIP            = "EXP-7351729691373470262",
}

local FOUNDER_DATASTORE_NAME = "PreOrderAccessData"
local MANUAL_PASS_DATASTORE_NAME = "DevPanelGamepassGrants"
local REMOTE_FOLDER_NAME = "EntitlementEvents"
local REMOTE_ACCESS_NAME = "CheckAccess"
local REMOTE_FOUNDER_NAME = "CheckFounderStatus"
local REMOTE_CHANGE_NAME = "EntitlementChanged"
local BINDABLE_CHANGE_NAME = "ServerEntitlementChanged"

type UserCache = {
	Founder: boolean?,
	Passes: {[number]: boolean},
	ManualPassesLoaded: boolean,
	ManualPasses: {[number]: boolean},
}

local UserCaches: {[number]: UserCache} = {}
local FounderStore = if IS_SERVER then DataStoreService:GetDataStore(FOUNDER_DATASTORE_NAME) else nil
local ManualPassStore = if IS_SERVER then DataStoreService:GetDataStore(MANUAL_PASS_DATASTORE_NAME) else nil
local RemoteCheckAccess: RemoteFunction? = nil
local RemoteCheckFounder: RemoteFunction? = nil
local RemoteEntitlementChanged: RemoteEvent? = nil
local ServerEntitlementChanged: BindableEvent? = nil
local ClientEntitlementConnection: RBXScriptConnection? = nil

local function getUserCache(userId: number): UserCache
	local cache = UserCaches[userId]
	if cache then
		return cache
	end

	cache = {
		Founder = nil,
		Passes = {},
		ManualPassesLoaded = false,
		ManualPasses = {},
	}
	UserCaches[userId] = cache
	return cache
end

local function resolveUserId(playerOrUserId: any): (number?, Player?)
	if typeof(playerOrUserId) == "Instance" and playerOrUserId:IsA("Player") then
		return playerOrUserId.UserId, playerOrUserId
	end
	if type(playerOrUserId) == "number" then
		return playerOrUserId, Players:GetPlayerByUserId(playerOrUserId)
	end
	return nil, nil
end

local function fireEntitlementChanged(userId: number, payload: {[string]: any}?)
	if not IS_SERVER then
		return
	end

	local finalPayload = payload or {}
	finalPayload.userId = userId
	finalPayload.at = os.time()

	if ServerEntitlementChanged then
		ServerEntitlementChanged:Fire(finalPayload)
	end

	if RemoteEntitlementChanged then
		local player = Players:GetPlayerByUserId(userId)
		if player then
			RemoteEntitlementChanged:FireClient(player, finalPayload)
		end
	end
end

local function applyClientEntitlementChange(payload: {[string]: any})
	if type(payload) ~= "table" then
		return
	end

	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end

	local userId = tonumber(payload.userId)
	if userId ~= localPlayer.UserId then
		return
	end

	local cache = getUserCache(userId)
	local passId = tonumber(payload.passId)
	if payload.invalidateAll == true then
		cache.Passes = {}
		cache.ManualPassesLoaded = false
		cache.ManualPasses = {}
	end

	if passId then
		if payload.enabled == true then
			cache.Passes[passId] = true
		elseif payload.enabled == false then
			cache.Passes[passId] = nil
			cache.ManualPasses[passId] = nil
		else
			cache.Passes[passId] = nil
		end
	end

	if payload.founder == true then
		cache.Founder = true
	elseif payload.founder == false then
		cache.Founder = false
	end
end

local function ownsPassRaw(userId: number, passId: number): boolean
	local cache = getUserCache(userId)
	if cache.Passes[passId] ~= nil then
		return cache.Passes[passId]
	end

	local success, ownsPass = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(userId, passId)
	end)

	if success then
		cache.Passes[passId] = ownsPass
		return ownsPass
	end

	return false
end

local function loadFounderFromStore(userId: number): boolean
	if not IS_SERVER or not FounderStore then
		return false
	end

	local cache = getUserCache(userId)
	if cache.Founder ~= nil then
		return cache.Founder
	end

	local success, data = pcall(function()
		return FounderStore:GetAsync(tostring(userId))
	end)

	if not success then
		return false
	end

	local isFounder = false
	if data == true then
		isFounder = true
	elseif type(data) == "table" then
		isFounder = data.isFounder == true or data.founder == true
	elseif data ~= nil and data ~= false then
		-- Backward-compatible: any non-empty legacy value counts as founder.
		isFounder = true
	end

	cache.Founder = isFounder
	return isFounder
end

local function grantFounder(userId: number, sourcePassId: number?)
	local cache = getUserCache(userId)
	cache.Founder = true

	if not IS_SERVER or not FounderStore then
		return
	end

	local payload = {
		isFounder = true,
		sourcePassId = sourcePassId,
		grantedAt = os.time(),
	}

	local success, err = pcall(function()
		FounderStore:UpdateAsync(tostring(userId), function(existing)
			if existing == true then
				return existing
			end
			if type(existing) == "table" and (existing.isFounder == true or existing.founder == true) then
				return existing
			end
			if existing ~= nil and existing ~= false then
				return existing
			end
			return payload
		end)
	end)

	if not success then
		return
	end

	fireEntitlementChanged(userId, {
		founder = true,
		sourcePassId = sourcePassId,
		source = "founder_grant",
	})
end

local function loadManualPassesFromStore(userId: number): {[number]: boolean}
	local cache = getUserCache(userId)
	if cache.ManualPassesLoaded then
		return cache.ManualPasses
	end

	cache.ManualPassesLoaded = true

	if not IS_SERVER or not ManualPassStore then
		return cache.ManualPasses
	end

	local success, data = pcall(function()
		return ManualPassStore:GetAsync(tostring(userId))
	end)

	if not success then
		return cache.ManualPasses
	end

	if type(data) == "table" then
		for rawPassId, enabled in pairs(data) do
			local passId = tonumber(rawPassId)
			if passId and enabled == true then
				cache.ManualPasses[passId] = true
			end
		end
	end

	return cache.ManualPasses
end

local function hasManualPass(userId: number, passId: number): boolean
	if not IS_SERVER then
		return false
	end
	local manualPasses = loadManualPassesFromStore(userId)
	return manualPasses[passId] == true
end

local function setManualPass(userId: number, passId: number, isEnabled: boolean): (boolean, string?)
	local cache = getUserCache(userId)
	loadManualPassesFromStore(userId)

	local previousManual = cache.ManualPasses[passId]
	local previousPass = cache.Passes[passId]
	cache.ManualPasses[passId] = if isEnabled then true else nil
	cache.Passes[passId] = if isEnabled then true else nil

	if not IS_SERVER or not ManualPassStore then
		cache.ManualPasses[passId] = previousManual
		cache.Passes[passId] = previousPass
		return false, "server_only"
	end

	local success, err = pcall(function()
		ManualPassStore:UpdateAsync(tostring(userId), function(existing)
			local nextData = {}
			if type(existing) == "table" then
				for rawPassId, enabled in pairs(existing) do
					if enabled == true then
						nextData[tostring(rawPassId)] = true
					end
				end
			end

			if isEnabled then
				nextData[tostring(passId)] = true
			else
				nextData[tostring(passId)] = nil
			end

			if next(nextData) == nil then
				return nil
			end
			return nextData
		end)
	end)

	if not success then
		cache.ManualPasses[passId] = previousManual
		cache.Passes[passId] = previousPass
		return false, tostring(err)
	end

	fireEntitlementChanged(userId, {
		passId = passId,
		enabled = isEnabled,
		source = "manual_grant",
	})
	return true, nil
end

local function checkAndPromoteLegacyFounder(userId: number): boolean
	for _, passId in ipairs(LEGACY_FOUNDER_PASS_IDS) do
		if ownsPassRaw(userId, passId) then
			grantFounder(userId, passId)
			return true
		end
	end
	return false
end

local function founderCoversPass(passId: number): boolean
	return FOUNDER_ACCESS_PASS_IDS[passId] == true
end

local function hasFounderStatusServer(userId: number): boolean
	local cache = getUserCache(userId)
	if cache.Founder == true then
		return true
	end

	if loadFounderFromStore(userId) then
		return true
	end

	if checkAndPromoteLegacyFounder(userId) then
		return true
	end

	cache.Founder = false
	return false
end

local function ensureClientRemotes()
	if RemoteCheckAccess and RemoteCheckFounder and RemoteEntitlementChanged and ClientEntitlementConnection then
		return
	end

	local folder = ReplicatedStorage:FindFirstChild(REMOTE_FOLDER_NAME)
	if not folder then
		return
	end

	local access = folder:FindFirstChild(REMOTE_ACCESS_NAME)
	local founder = folder:FindFirstChild(REMOTE_FOUNDER_NAME)
	local changed = folder:FindFirstChild(REMOTE_CHANGE_NAME)
	if access and access:IsA("RemoteFunction") then
		RemoteCheckAccess = access
	end
	if founder and founder:IsA("RemoteFunction") then
		RemoteCheckFounder = founder
	end
	if changed and changed:IsA("RemoteEvent") then
		RemoteEntitlementChanged = changed
		if not ClientEntitlementConnection then
			ClientEntitlementConnection = changed.OnClientEvent:Connect(applyClientEntitlementChange)
		end
	end
end

function EntitlementManager.HasFounderStatus(playerOrUserId: any): boolean
	local userId = resolveUserId(playerOrUserId)
	if not userId then
		return false
	end

	local cache = getUserCache(userId)
	if cache.Founder == true then
		return true
	end

	if IS_SERVER then
		return hasFounderStatusServer(userId)
	end

	-- Client path: always prefer server-authoritative founder status.
	local localPlayer = Players.LocalPlayer
	if not localPlayer or localPlayer.UserId ~= userId then
		return false
	end

	ensureClientRemotes()
	if RemoteCheckFounder then
		local success, result = pcall(function()
			return RemoteCheckFounder:InvokeServer()
		end)
		if success then
			cache.Founder = result == true
			return cache.Founder == true
		end
	end

	-- Fallback if remotes are unavailable.
	for _, passId in ipairs(LEGACY_FOUNDER_PASS_IDS) do
		if ownsPassRaw(userId, passId) then
			cache.Founder = true
			return true
		end
	end

	cache.Founder = false
	return false
end

function EntitlementManager.HasAccess(playerOrUserId: any, specificPassId: number): boolean
	local userId = resolveUserId(playerOrUserId)
	if not userId then
		return false
	end

	if type(specificPassId) ~= "number" or specificPassId <= 0 then
		return false
	end

	if EntitlementManager.HasFounderStatus(userId) and founderCoversPass(specificPassId) then
		return true
	end

	if IS_SERVER and hasManualPass(userId, specificPassId) then
		return true
	end

	if IS_SERVER then
		return ownsPassRaw(userId, specificPassId)
	end

	local localPlayer = Players.LocalPlayer
	if not localPlayer or localPlayer.UserId ~= userId then
		return false
	end

	ensureClientRemotes()
	if RemoteCheckAccess then
		local success, result = pcall(function()
			return RemoteCheckAccess:InvokeServer(specificPassId)
		end)
		if success then
			local cache = getUserCache(userId)
			if result == true then
				cache.Passes[specificPassId] = true
				return true
			end
			cache.Passes[specificPassId] = nil
			return false
		end
	end

	local cache = getUserCache(userId)
	if cache.Passes[specificPassId] == true then
		return true
	end

	-- Fallback if remotes are unavailable. Do not cache false on client.
	local success, ownsPass = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(userId, specificPassId)
	end)
	if success and ownsPass then
		cache.Passes[specificPassId] = true
		return true
	end
	if not success then
	end
	return false
end

function EntitlementManager.GrantPass(playerOrUserId: any, passId: number): (boolean, string?)
	if not IS_SERVER then
		return false, "server_only"
	end

	local userId = resolveUserId(playerOrUserId)
	if not userId then
		return false, "invalid_user"
	end

	if type(passId) ~= "number" or passId <= 0 then
		return false, "invalid_pass"
	end

	local ok, err = setManualPass(userId, passId, true)
	if not ok then
		return false, err
	end

	for _, legacyPassId in ipairs(LEGACY_FOUNDER_PASS_IDS) do
		if passId == legacyPassId then
			grantFounder(userId, passId)
			break
		end
	end

	return true, nil
end

function EntitlementManager.RevokePass(playerOrUserId: any, passId: number): (boolean, string?)
	if not IS_SERVER then
		return false, "server_only"
	end

	local userId = resolveUserId(playerOrUserId)
	if not userId then
		return false, "invalid_user"
	end

	if type(passId) ~= "number" or passId <= 0 then
		return false, "invalid_pass"
	end

	return setManualPass(userId, passId, false)
end

function EntitlementManager.GrantFounder(playerOrUserId: any, sourcePassId: number?): (boolean, string?)
	if not IS_SERVER then
		return false, "server_only"
	end

	local userId = resolveUserId(playerOrUserId)
	if not userId then
		return false, "invalid_user"
	end

	grantFounder(userId, sourcePassId)
	return true, nil
end

if IS_SERVER then
	local folder = ReplicatedStorage:FindFirstChild(REMOTE_FOLDER_NAME)
	if folder and not folder:IsA("Folder") then
		folder:Destroy()
		folder = nil
	end
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = REMOTE_FOLDER_NAME
		folder.Parent = ReplicatedStorage
	end

	local access = folder:FindFirstChild(REMOTE_ACCESS_NAME)
	if access and not access:IsA("RemoteFunction") then
		access:Destroy()
		access = nil
	end
	if not access then
		access = Instance.new("RemoteFunction")
		access.Name = REMOTE_ACCESS_NAME
		access.Parent = folder
	end

	local founder = folder:FindFirstChild(REMOTE_FOUNDER_NAME)
	if founder and not founder:IsA("RemoteFunction") then
		founder:Destroy()
		founder = nil
	end
	if not founder then
		founder = Instance.new("RemoteFunction")
		founder.Name = REMOTE_FOUNDER_NAME
		founder.Parent = folder
	end

	local changed = folder:FindFirstChild(REMOTE_CHANGE_NAME)
	if changed and not changed:IsA("RemoteEvent") then
		changed:Destroy()
		changed = nil
	end
	if not changed then
		changed = Instance.new("RemoteEvent")
		changed.Name = REMOTE_CHANGE_NAME
		changed.Parent = folder
	end

	local serverChanged = folder:FindFirstChild(BINDABLE_CHANGE_NAME)
	if serverChanged and not serverChanged:IsA("BindableEvent") then
		serverChanged:Destroy()
		serverChanged = nil
	end
	if not serverChanged then
		serverChanged = Instance.new("BindableEvent")
		serverChanged.Name = BINDABLE_CHANGE_NAME
		serverChanged.Parent = folder
	end

	RemoteEntitlementChanged = changed
	ServerEntitlementChanged = serverChanged

	local accessRemote = access :: RemoteFunction
	local founderRemote = founder :: RemoteFunction
	accessRemote.OnServerInvoke = function(player: Player, specificPassId: number)
		return EntitlementManager.HasAccess(player, specificPassId)
	end

	founderRemote.OnServerInvoke = function(player: Player)
		return EntitlementManager.HasFounderStatus(player)
	end

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, wasPurchased)
		if not wasPurchased then
			return
		end

		local userId = player.UserId
		local cache = getUserCache(userId)
		cache.Passes[passId] = true
		fireEntitlementChanged(userId, {
			passId = passId,
			enabled = true,
			source = "purchase",
		})

		for _, legacyPassId in ipairs(LEGACY_FOUNDER_PASS_IDS) do
			if passId == legacyPassId then
				grantFounder(userId, passId)
				break
			end
		end
	end)
end

-- Returns true if the player has the given subscription active.
-- On client: reads the String attribute set by SubscriptionManager.
-- On server: reads the same attribute (SubscriptionManager sets it on join).
-- Attribute key format: "Sub_<Name>" e.g. "Sub_ResortPass".
function EntitlementManager.HasSubscription(playerOrUserId: any, subscriptionKey: string): boolean
	local userId, player = resolveUserId(playerOrUserId)
	if not userId or type(subscriptionKey) ~= "string" then
		return false
	end

	local attrName = "Sub_" .. subscriptionKey
	local target = player or (IS_SERVER and Players:GetPlayerByUserId(userId))
	if target then
		return target:GetAttribute(attrName) == true
	end

	-- Client path without direct player ref: check LocalPlayer
	local localPlayer = Players.LocalPlayer
	if localPlayer and localPlayer.UserId == userId then
		return localPlayer:GetAttribute(attrName) == true
	end

	return false
end

-- Convenience: true if player has the game pass OR owns it via Resort Pass subscription
-- or has founder status that covers the pass.
function EntitlementManager.HasAccessOrSub(playerOrUserId: any, passId: number): boolean
	if EntitlementManager.HasAccess(playerOrUserId, passId) then
		return true
	end
	-- Resort Pass grants all bundled passes
	return EntitlementManager.HasSubscription(playerOrUserId, "ResortPass")
end

Players.PlayerRemoving:Connect(function(player)
	UserCaches[player.UserId] = nil
end)

EntitlementManager.LegacyFounderPassIds = LEGACY_FOUNDER_PASS_IDS
EntitlementManager.AllKnownPassIds = ALL_KNOWN_PASS_IDS
EntitlementManager.SubscriptionIds = SUBSCRIPTION_IDS

return EntitlementManager
