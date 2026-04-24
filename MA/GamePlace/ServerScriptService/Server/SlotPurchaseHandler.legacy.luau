--[=[ PATH: ServerScriptService/Server/SlotPurchaseHandler | TYPE: Server Script ]=]--
-- ════════════════════════════════════════════════════════════════════
--  SLOT PURCHASE HANDLER
--  Processes "ExtraSlot" and "AddFriendSlot" dev product purchases
--  delegated by AdBoostServer.ProcessReceipt via a BindableEvent.
--
--  Persists purchase data in DataStore and sets player attributes:
--    ExtraSlotCount   – how many extra save slots purchased (max 4 extra = 12 total)
--    FriendSlotCount  – how many friend whitelist slots purchased
--
--  The Unlimited Slots subscription (Sub_UnlimitedSlots) overrides the
--  slot cap entirely — those players don't need to buy extra slots at all.
--
--  DataStore schema per userId ("SlotPurchases_v1"):
--    {
--      extraSlots   = N,   -- number of extra slots bought (0-4)
--      friendSlots  = M,   -- number of friend whitelist slots bought
--    }
--
--  Friend whitelist entries live in a separate DataStore ("FriendWhitelist_v1"):
--    userId → { [friendUserId] = true, ... }
-- ════════════════════════════════════════════════════════════════════

local DataStoreService   = game:GetService("DataStoreService")
local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CanonicalProfile = nil
do
	local serverFolder = ServerScriptService:FindFirstChild("Server")
	local profileModule = serverFolder and serverFolder:FindFirstChild("CanonicalPlayerProfile")
	if profileModule and profileModule:IsA("ModuleScript") then
		local ok, loaded = pcall(require, profileModule)
		if ok and type(loaded) == "table" then
			CanonicalProfile = loaded
		end
	end
end

-- ── CONFIGURATION ────────────────────────────────────────────────────
local BASE_SLOTS       = 8   -- matches SlotDataLoader.MAX_SAVE_SLOT_INDEX
local MAX_TOTAL_SLOTS  = 12  -- cap after extra slot purchases
local MAX_EXTRA_SLOTS  = MAX_TOTAL_SLOTS - BASE_SLOTS  -- 4 purchasable extras

local PURCHASE_DS_NAME  = "SlotPurchases_v1"
local WHITELIST_DS_NAME = "FriendWhitelist_v1"

local LegacyPurchaseStore = DataStoreService:GetDataStore(PURCHASE_DS_NAME)
local LegacyWhitelistStore = DataStoreService:GetDataStore(WHITELIST_DS_NAME)
local PurchaseStore = if CanonicalProfile
	then CanonicalProfile.CreateUserStoreProxy(LegacyPurchaseStore, PURCHASE_DS_NAME, "SlotPurchases")
	else LegacyPurchaseStore
local WhitelistStore = if CanonicalProfile
	then CanonicalProfile.CreateUserStoreProxy(LegacyWhitelistStore, WHITELIST_DS_NAME, "FriendWhitelist")
	else LegacyWhitelistStore

-- ── REMOTE SETUP ─────────────────────────────────────────────────────
local Events = ReplicatedStorage:WaitForChild("Events")

local function getOrCreate(className, name, parent)
	local obj = parent:FindFirstChild(name)
	if obj and obj:IsA(className) then return obj end
	if obj then obj:Destroy() end
	obj = Instance.new(className)
	obj.Name = name
	obj.Parent = parent
	return obj
end

-- BindableEvent fired by AdBoostServer.ProcessReceipt
local ProcessSlotPurchase = getOrCreate("BindableEvent", "ProcessSlotPurchase",
	script.Parent or ServerScriptService)

-- RemoteEvent: server → client, sends updated slot/friend counts
local SlotPurchaseUpdate = getOrCreate("RemoteEvent", "SlotPurchaseUpdate", Events)
-- RemoteEvent: client → server (request whitelist management UI data)
local RequestFriendWhitelist = getOrCreate("RemoteEvent", "RequestFriendWhitelist", Events)
-- RemoteEvent: client → server (add/remove a friend from whitelist)
local UpdateFriendWhitelist  = getOrCreate("RemoteEvent", "UpdateFriendWhitelist",  Events)

local NotificationEvent = Events:FindFirstChild("NotificationEvent")

-- ── HELPERS ─────────────────────────────────────────────────────────

local function notify(player, category, title, message, duration)
	if NotificationEvent then
		NotificationEvent:FireClient(player, category, title, message, duration or 4)
	end
end

local function loadPurchaseData(userId: number): {extraSlots: number, friendSlots: number}
	local ok, data = pcall(function()
		return PurchaseStore:GetAsync(tostring(userId))
	end)
	if ok and type(data) == "table" then
		return {
			extraSlots  = math.max(0, tonumber(data.extraSlots)  or 0),
			friendSlots = math.max(0, tonumber(data.friendSlots) or 0),
		}
	end
	return { extraSlots = 0, friendSlots = 0 }
end

local function savePurchaseData(userId: number, data: {extraSlots: number, friendSlots: number})
	pcall(function()
		PurchaseStore:SetAsync(tostring(userId), data)
	end)
end

local function getEffectiveMaxSlots(player: Player): number
	-- Unlimited Slots subscription removes the cap entirely
	if player:GetAttribute("Sub_UnlimitedSlots") == true then
		return MAX_TOTAL_SLOTS  -- or you could return math.huge; UI caps at 12
	end
	-- Resort Pass also includes Unlimited Slots
	if player:GetAttribute("Sub_ResortPass") == true then
		return MAX_TOTAL_SLOTS
	end
	local extra = tonumber(player:GetAttribute("ExtraSlotCount")) or 0
	return math.min(BASE_SLOTS + extra, MAX_TOTAL_SLOTS)
end

local function applySlotAttributes(player: Player, data: {extraSlots: number, friendSlots: number})
	player:SetAttribute("ExtraSlotCount", data.extraSlots)
	player:SetAttribute("FriendSlotCount", data.friendSlots)
	player:SetAttribute("EffectiveMaxSlots", getEffectiveMaxSlots(player))
	SlotPurchaseUpdate:FireClient(player, {
		extraSlots      = data.extraSlots,
		friendSlots     = data.friendSlots,
		effectiveMax    = getEffectiveMaxSlots(player),
	})
end

-- ── PLAYER LIFECYCLE ─────────────────────────────────────────────────

Players.PlayerAdded:Connect(function(player: Player)
	task.delay(4, function()
		if not player:IsDescendantOf(game) then return end
		local data = loadPurchaseData(player.UserId)
		applySlotAttributes(player, data)
	end)
end)

-- ── PURCHASE HANDLER ─────────────────────────────────────────────────

ProcessSlotPurchase.Event:Connect(function(player: Player, productType: string, _purchaseId: string)
	if not player or not player:IsDescendantOf(game) then return end

	local userId = player.UserId
	local data   = loadPurchaseData(userId)

	if productType == "ExtraSlot" then
		if data.extraSlots >= MAX_EXTRA_SLOTS then
			notify(player, "Negative", "SLOT CAP REACHED",
				string.format("You already have the maximum of %d save slots.", MAX_TOTAL_SLOTS), 5)
			-- Note: ProcessReceipt already returned PurchaseGranted optimistically.
			-- Roblox won't charge twice for the same PurchaseId, so this is safe.
			return
		end
		data.extraSlots += 1
		savePurchaseData(userId, data)
		applySlotAttributes(player, data)
		notify(player, "Positive", "SLOT UNLOCKED",
			string.format("You now have %d save slots available! (Max %d)",
				BASE_SLOTS + data.extraSlots, MAX_TOTAL_SLOTS), 5)

	elseif productType == "AddFriendSlot" then
		data.friendSlots += 1
		savePurchaseData(userId, data)
		applySlotAttributes(player, data)
		notify(player, "Positive", "FRIEND SLOT ADDED",
			string.format("You now have %d friend whitelist slots. Use /friends in chat to manage.", data.friendSlots), 5)
	end
end)

-- ── FRIEND WHITELIST MANAGEMENT ──────────────────────────────────────

-- Load the friend whitelist for a user
local function loadWhitelist(userId: number): {[string]: boolean}
	local ok, data = pcall(function()
		return WhitelistStore:GetAsync(tostring(userId))
	end)
	if ok and type(data) == "table" then
		return data
	end
	return {}
end

-- Friend whitelist is only available in private servers
local IS_PRIVATE_SERVER = game.PrivateServerId ~= "" and game.PrivateServerOwnerId > 0

-- Client requests their whitelist to display
RequestFriendWhitelist.OnServerEvent:Connect(function(player: Player)
	if not IS_PRIVATE_SERVER then return end
	local whitelist  = loadWhitelist(player.UserId)
	local slotCount  = tonumber(player:GetAttribute("FriendSlotCount")) or 0
	local friends    = {}
	for friendId, enabled in pairs(whitelist) do
		if enabled == true then
			table.insert(friends, tonumber(friendId))
		end
	end
	SlotPurchaseUpdate:FireClient(player, {
		slots   = slotCount,
		friends = friends,
	})
end)

-- Client requests to add/remove a friend
UpdateFriendWhitelist.OnServerEvent:Connect(function(player: Player, action: string, targetUserId: number)
	if not IS_PRIVATE_SERVER then return end
	if type(action) ~= "string" then return end
	if type(targetUserId) ~= "number" or targetUserId <= 0 then
		notify(player, "Negative", "INVALID USER", "That user ID is not valid.", 4)
		return
	end
	if targetUserId == player.UserId then
		notify(player, "Negative", "INVALID", "You cannot add yourself to your own whitelist.", 4)
		return
	end

	local userId    = player.UserId
	local slotCount = tonumber(player:GetAttribute("FriendSlotCount")) or 0
	local whitelist = loadWhitelist(userId)

	-- Count current active whitelist entries
	local currentCount = 0
	for _, v in pairs(whitelist) do if v == true then currentCount += 1 end end

	if action == "add" then
		if whitelist[tostring(targetUserId)] == true then
			notify(player, "Negative", "ALREADY ADDED", "That player is already on your whitelist.", 4)
			return
		end
		if currentCount >= slotCount then
			notify(player, "Negative", "NO SLOTS",
				string.format("You have %d/%d friend slots used. Purchase more to add additional friends.", currentCount, slotCount), 5)
			return
		end
		whitelist[tostring(targetUserId)] = true
		pcall(function() WhitelistStore:SetAsync(tostring(userId), whitelist) end)
		notify(player, "Positive", "FRIEND ADDED", "Player " .. tostring(targetUserId) .. " added to your resort whitelist.", 4)

	elseif action == "remove" then
		whitelist[tostring(targetUserId)] = nil
		pcall(function() WhitelistStore:SetAsync(tostring(userId), whitelist) end)
		notify(player, "Positive", "FRIEND REMOVED", "Player removed from your whitelist.", 4)
	end
end)

-- ── GLOBAL HELPER (for JoinCodeSystem etc.) ──────────────────────────
-- Other scripts can call _G.IsOnFriendWhitelist(ownerId, visitorId) synchronously.
-- (Uses cached or re-fetched whitelist.)
local whitelistCache: {[number]: {[string]: boolean}} = {}

_G.IsOnFriendWhitelist = function(ownerId: number, visitorId: number): boolean
	if not IS_PRIVATE_SERVER then return false end
	local cache = whitelistCache[ownerId]
	if not cache then
		local ok, data = pcall(function() return WhitelistStore:GetAsync(tostring(ownerId)) end)
		cache = (ok and type(data) == "table") and data or {}
		whitelistCache[ownerId] = cache
		-- Expire cache after 60s
		task.delay(60, function() whitelistCache[ownerId] = nil end)
	end
	return cache[tostring(visitorId)] == true
end
