--[=[ PATH: ServerScriptService/Server/SubscriptionManager | TYPE: Server Script ]=]--
-- ════════════════════════════════════════════════════════════════════
--  SUBSCRIPTION MANAGER
--  Checks and caches Roblox subscription status for each player.
--  Sets player attributes used by all other systems:
--    Sub_ResortPass       – bundles all pass benefits (old + new)
--    Sub_UnlimitedSlots   – removes per-extra-slot cost
--    Sub_PremiumRewards   – 2x daily rewards
--    Sub_VIP              – cosmetic commands, chat tag, featured lobby
--
--  Other scripts should read the attribute, not call this module directly.
-- ════════════════════════════════════════════════════════════════════

local MarketplaceService = game:GetService("MarketplaceService")
local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")

-- ── SUBSCRIPTION IDS ────────────────────────────────────────────────
local SUBSCRIPTION_IDS = {
	ResortPass     = "EXP-250027655716536898",
	UnlimitedSlots = "EXP-4763590370263171569",
	PremiumRewards = "EXP-7331536610573550159",
	VIP            = "EXP-7351729691373470262",
}

-- Attribute names written to the Player instance (read by other scripts)
local ATTR = {
	ResortPass     = "Sub_ResortPass",
	UnlimitedSlots = "Sub_UnlimitedSlots",
	PremiumRewards = "Sub_PremiumRewards",
	VIP            = "Sub_VIP",
}

-- Passes automatically granted by Resort Pass (all old + all new)
local RESORT_PASS_GAMEPASS_IDS = {
	1683937935, -- Pre-Order / Founder
	1704778044, -- Controller+
	1705274438, -- Freecam+
	1705719197, -- Time Setter
	1707796502, -- Weather Controller
	1708162428, -- 2x Guests
	1708924275, -- 2x Money
	1708600326, -- More Employees
	1753340250, -- 2x Research Points
	1792834210, -- Slot Data Limit Bypass
	1793522272, -- Always Active Resort
}

-- ── HELPERS ─────────────────────────────────────────────────────────

local function checkSubscription(player: Player, subscriptionId: string): boolean
	local ok, result = pcall(function()
		return MarketplaceService:GetUserSubscriptionStatusAsync(player, subscriptionId)
	end)
	if not ok then
		warn("[SubscriptionManager] GetUserSubscriptionStatusAsync failed for",
			player.Name, "/", subscriptionId, ":", tostring(result))
		return false
	end
	-- result is a SubscriptionStatus enum instance; subscribed if IsSubscribed == true
	return result ~= nil and result.IsSubscribed == true
end

local function applySubscriptionAttributes(player: Player)
	local hasResortPass     = checkSubscription(player, SUBSCRIPTION_IDS.ResortPass)
	local hasUnlimitedSlots = checkSubscription(player, SUBSCRIPTION_IDS.UnlimitedSlots)
	local hasPremiumRewards = checkSubscription(player, SUBSCRIPTION_IDS.PremiumRewards)
	local hasVIP            = checkSubscription(player, SUBSCRIPTION_IDS.VIP)

	player:SetAttribute(ATTR.ResortPass,     hasResortPass)
	player:SetAttribute(ATTR.UnlimitedSlots, hasUnlimitedSlots)
	player:SetAttribute(ATTR.PremiumRewards, hasPremiumRewards)
	player:SetAttribute(ATTR.VIP,            hasVIP)

	-- Resort Pass grants all bundled game-pass benefits. We mark these via
	-- a synthetic "ManualPass" list on the player attribute so other scripts
	-- (PlacementServer, GuestServer, etc.) see the full grant without calling
	-- EntitlementManager again. EntitlementManager.HasAccess is still
	-- authoritative; here we just warm the fast-attribute path.
	if hasResortPass then
		for _, passId in ipairs(RESORT_PASS_GAMEPASS_IDS) do
			player:SetAttribute("ResortPassGrant_" .. tostring(passId), true)
		end
	else
		-- Remove stale grants on re-check (e.g. subscription lapsed)
		for _, passId in ipairs(RESORT_PASS_GAMEPASS_IDS) do
			player:SetAttribute("ResortPassGrant_" .. tostring(passId), nil)
		end
	end

	if hasVIP then
		-- Give VIP tag / chat color (read by ChatTagsClient or similar)
		player:SetAttribute("VIPTag", true)
		player:SetAttribute("ChatColor", Color3.fromRGB(255, 215, 0)) -- gold
	else
		player:SetAttribute("VIPTag", nil)
		player:SetAttribute("ChatColor", nil)
	end
end

-- ── PLAYER LIFECYCLE ────────────────────────────────────────────────

Players.PlayerAdded:Connect(function(player: Player)
	-- Check subscriptions async after a short delay (avoids join-time DS pressure)
	task.delay(3, function()
		if not player:IsDescendantOf(game) then return end
		applySubscriptionAttributes(player)
	end)
end)

-- Periodic re-check every 5 minutes to catch subscription state changes mid-session
task.spawn(function()
	while true do
		task.wait(300)
		for _, player in ipairs(Players:GetPlayers()) do
			task.spawn(applySubscriptionAttributes, player)
		end
	end
end)

-- Handle players already in-game (Studio test or race with script load)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(applySubscriptionAttributes, player)
end
