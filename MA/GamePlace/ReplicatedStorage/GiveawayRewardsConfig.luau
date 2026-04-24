--[[
	Discord Giveaway Rewards Config

	Reward keys here must match the keys used by the Discord bot.
	The game grants equivalent perks using internal entitlement/admin flags.
]]

local GiveawayRewardsConfig = {}

GiveawayRewardsConfig.RewardMap = {
	vip = {
		kind = "pass",
		passId = 1683937935, -- Pre-Order / VIP-style supporter access
		label = "VIP",
	},
	admin = {
		kind = "admin",
		label = "Admin Access",
	},
	double_cash = {
		kind = "pass",
		passId = 1708924275,
		label = "2x Cash",
	},
	double_guests = {
		kind = "pass",
		passId = 1708162428,
		label = "2x Guests",
	},
	double_employees = {
		kind = "pass",
		passId = 1708600326,
		label = "Unlimited Employees",
	},
	weather_controller = {
		kind = "pass",
		passId = 1707796502,
		label = "Weather Controller",
	},
	time_setter = {
		kind = "pass",
		passId = 1705719197,
		label = "Time Setter",
	},
	controller_plus = {
		kind = "pass",
		passId = 1704778044,
		label = "Controller+",
	},
	freecam_plus = {
		kind = "pass",
		passId = 1705274438,
		label = "Freecam+",
	},
	sandbox_mode = {
		kind = "pass",
		passId = 1733258476,
		label = "Sandbox Mode",
	},
	founder = {
		kind = "founder",
		label = "Founder",
	},
}

function GiveawayRewardsConfig.NormalizeRewardKey(rawKey)
	local key = string.lower(tostring(rawKey or ""))
	key = string.gsub(key, "[%s%-]+", "_")
	key = string.gsub(key, "[^%w_]", "")
	return key
end

function GiveawayRewardsConfig.Resolve(rawKey)
	local key = GiveawayRewardsConfig.NormalizeRewardKey(rawKey)
	return key, GiveawayRewardsConfig.RewardMap[key]
end

return GiveawayRewardsConfig