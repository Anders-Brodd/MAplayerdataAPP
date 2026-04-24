-- DEPRECATED: Remove Ads pass removed
if true then
	return
end

--[=[ PATH: StarterPlayer/StarterPlayerScripts/RemoveAdsClient | TYPE: LocalScript ]=]--
-- ════════════════════════════════════════════════════════════════════
--  REMOVE ADS CLIENT
--  When the local player has the "Remove Ads" pass (1792930148) or the
--  Resort Pass subscription, all Roblox native AdPortal and AdGui
--  instances in the game world are hidden / disabled.
--
--  Also hides any custom Surface GUI tagged "ImmersiveAd" (for future
--  custom ad GUIs you place in Studio — just tag them "ImmersiveAd").
--
--  Runs once on join; also watches for new AdPortal instances inserted
--  at runtime (e.g. loaded by a module or via DataModel streaming).
-- ════════════════════════════════════════════════════════════════════

local Players           = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player    = Players.LocalPlayer
local PASS_ID   = 1792930148
local AD_TAG    = "ImmersiveAd"  -- custom tag for Surface GUIs you place in Studio

-- ── HELPERS ──────────────────────────────────────────────────────────

local function hasRemoveAds(): boolean
	-- Fast-path: attribute set by SubscriptionManager / EntitlementManager
	if player:GetAttribute("Sub_ResortPass") == true then return true end
	if player:GetAttribute("ResortPassGrant_" .. tostring(PASS_ID)) == true then return true end

	-- Game-pass check via MarketplaceService (async, runs once on join)
	local MarketplaceService = game:GetService("MarketplaceService")
	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, PASS_ID)
	end)
	return ok and owns == true
end

local function hideAdInstance(inst)
	-- AdPortal / AdGui: disable entirely
	if inst:IsA("AdPortal") or inst:IsA("AdGui") then
		inst.Enabled = false
		return
	end
	-- Custom Surface GUI tagged "ImmersiveAd"
	if inst:IsA("SurfaceGui") and CollectionService:HasTag(inst, AD_TAG) then
		inst.Enabled = false
	end
end

-- ── MAIN LOGIC ────────────────────────────────────────────────────────

-- Check once, then apply
local function applyIfEligible()
	if not hasRemoveAds() then return end

	-- Hide all existing AdPortal / AdGui instances in the workspace
	for _, inst in ipairs(workspace:GetDescendants()) do
		hideAdInstance(inst)
	end

	-- Hide tagged custom ad GUIs (SurfaceGuis, PlayerGuis, etc.)
	for _, inst in ipairs(CollectionService:GetTagged(AD_TAG)) do
		hideAdInstance(inst)
	end

	-- Watch for new instances added at runtime (streaming, runtime placement, etc.)
	workspace.DescendantAdded:Connect(function(inst)
		if inst:IsA("AdPortal") or inst:IsA("AdGui") then
			inst.Enabled = false
		end
	end)

	-- Watch for newly tagged custom ad GUIs
	CollectionService:GetInstanceAddedSignal(AD_TAG):Connect(hideAdInstance)
end

-- Run after slight delay to allow SubscriptionManager attributes to propagate
task.delay(6, applyIfEligible)

-- Also re-check when Sub_ResortPass attribute changes mid-session (subscription lapse/grant)
player:GetAttributeChangedSignal("Sub_ResortPass"):Connect(function()
	applyIfEligible()
end)
