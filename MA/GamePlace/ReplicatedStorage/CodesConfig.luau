--[=[ PATH: ReplicatedStorage/CodesConfig | TYPE: ModuleScript ]=]--
-- Add/modify codes here. Keys are case-insensitive.
-- Optional per-code override fields: MaxClaimsPerPlayer or UsesPerPlayer (default: 1).

local CodesConfig = {}

CodesConfig.DefaultMoneyBoostMultiplier = 2
CodesConfig.DefaultResearchBoostMultiplier = 2
CodesConfig.DefaultGuestBoostMultiplier = 1.6

CodesConfig.Codes = {
	COMP2026 = {
		Enabled = true,
		Rewards = {
			{ Type = "Money", Amount = 175000 },
			{ Type = "ResearchPoints", Amount = 350 },
			{ Type = "GuestBoost", DurationMinutes = 15, Multiplier = 1.6 },
			{ Type = "MoneyBoost", DurationMinutes = 15, Multiplier = 2 },
		},
	},

	MONEY15 = {
		Enabled = true,
		Rewards = {
			{ Type = "MoneyBoost", DurationMinutes = 15, Multiplier = 2 },
		},
	},

	GUEST15 = {
		Enabled = true,
		Rewards = {
			{ Type = "GuestBoost", DurationMinutes = 15, Multiplier = 1.6 },
		},
	},

	RESEARCH15 = {
		Enabled = true,
		Rewards = {
			{ Type = "ResearchBoost", DurationMinutes = 15, Multiplier = 2 },
		},
	},
}

return CodesConfig
