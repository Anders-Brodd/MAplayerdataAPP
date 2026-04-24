--[=[ PATH: ReplicatedStorage/Research/ResearchConfig | TYPE: ModuleScript ]=]--
-- Progression retuned Apr 4, 2026: research is quicker overall while decor milestones carry more long-term grind.

local Config = {}

Config.SchemaVersion = 2
Config.DataStoreName = "TycoonResearchData"

Config.StartRP = 320
Config.PassiveRPPerTick = 10
Config.PassiveTickSeconds = 10
Config.OfflineProgressCapSeconds = 3600
Config.AutoSaveSeconds = 45
Config.MaxRP = 250000

Config.ResearchPacing = {
	CostMultiplier = 0.72,
	TimeMultiplier = 0.58,
	MinimumResearchTime = 8,
}

Config.RootNodes = { "Basics" }

Config.Layout = {
	Lanes = {
		{ Id = "Transport", Label = "TRANSPORT", StartRow = 1, EndRow = 2, Color = Color3.fromRGB(93, 146, 255) },
		{ Id = "SnowOps", Label = "SNOW OPS", StartRow = 3, EndRow = 4, Color = Color3.fromRGB(86, 211, 255) },
		{ Id = "Terrain", Label = "TERRAIN", StartRow = 5, EndRow = 5, Color = Color3.fromRGB(115, 226, 124) },
		{ Id = "GuestServices", Label = "GUEST SERVICES", StartRow = 6, EndRow = 7, Color = Color3.fromRGB(255, 186, 92) },
	},
	NodeLayout = {
		Basics = { Column = 0, Row = 4, Lane = "Foundation" },
		Lift_Mechanics_I = { Column = 1, Row = 1, Lane = "Transport" },
		Safety_Signage = { Column = 1, Row = 5, Lane = "Terrain" },
		Guest_Services = { Column = 1, Row = 6, Lane = "GuestServices" },
		Lift_Mechanics_II = { Column = 2, Row = 1, Lane = "Transport" },
		Transit_Infrastructure = { Column = 2, Row = 2, Lane = "Transport" },
		Snowmaking_I = { Column = 2, Row = 3, Lane = "SnowOps" },
		Terrain_Engineering = { Column = 2, Row = 5, Lane = "Terrain" },
		Lodge_Expansion = { Column = 2, Row = 6, Lane = "GuestServices" },
		Dining_I = { Column = 2, Row = 7, Lane = "GuestServices" },
		Advanced_Detachables = { Column = 3, Row = 1, Lane = "Transport" },
		Snowmaking_II = { Column = 3, Row = 3, Lane = "SnowOps" },
		Slope_Grooming = { Column = 3, Row = 4, Lane = "SnowOps" },
		Extreme_Terrain = { Column = 3, Row = 5, Lane = "Terrain" },
		Lodge_Expansion_II = { Column = 3, Row = 6, Lane = "GuestServices" },
		Gondola_Systems = { Column = 4, Row = 1, Lane = "Transport" },
		Snowmaking_III = { Column = 4, Row = 3, Lane = "SnowOps" },
		Dining_II = { Column = 3, Row = 7, Lane = "GuestServices" },
		Dining_III = { Column = 4, Row = 7, Lane = "GuestServices" },

	},
}

Config.TechTree = {
	Basics = {
		Name = "Resort Foundations",
		Desc = "Open basic transport and beginner construction.",
		Cost = 0,
		Time = 0,
		Reqs = {},
		Branch = "Core",
		Sort = 0,
		Unlocks = {
			"Surface Tow",
			"Small Cabin (Light)",
			"Small Cabin (Dark)",
			"Rental Shop",
			"Small Restaurant",
		},
	},

	Guest_Services = {
		Name = "Guest Services",
		Desc = "Food and rentals for first-time visitors.",
		Cost = 115,
		Time = 14,
		Reqs = { "Basics" },
		Branch = "Services",
		Sort = 1,
		Unlocks = {
			"Snack Bar",
			"Big Ticket Office",
			"Ski Patrol Hut",
		},
	},

	Safety_Signage = {
		Name = "Slope Safety",
		Desc = "Operational signage and beginner route control.",
		Cost = 100,
		Time = 12,
		Reqs = { "Basics" },
		Branch = "Terrain",
		Sort = 1,
		Unlocks = {
			"Flagged Light Pole",
		},
	},

	Lift_Mechanics_I = {
		Name = "Lift Mechanics I",
		Desc = "Entry engineering for low-capacity lift systems.",
		Cost = 185,
		Time = 32,
		Reqs = { "Basics" },
		Branch = "Lifts",
		Sort = 1,
		Unlocks = {
			"Double Vintage Chairlift",
			"Fixed Grip Double",
		},
	},


	Lodge_Expansion = {
		Name = "Lodging Expansion I",
		Desc = "Scale capacity for longer guest stays.",
		Cost = 360,
		Time = 36,
		Reqs = { "Guest_Services" },
		Branch = "Services",
		Sort = 2,
		Unlocks = {
			"Medium Cabin (Dark)",
			"Medium Cabin (Light)",
		},
	},

	Lodge_Expansion_II = {
		Name = "Lodging Expansion II",
		Desc = "Scale capacity for longer guest stays.",
		Cost = 1250,
		Time = 180,
		Reqs = { "Lodge_Expansion" },
		Branch = "Services",
		Sort = 3,
		Unlocks = {
			"Large Cabin (Dark)",
			"Large Cabin (Light)",
			"Large Hotel (Dark)",
		},
	},

	Dining_I = {
		Name = "Dining I",
		Desc = "Improve guest retention with better dining options.",
		Cost = 420,
		Time = 48,
		Reqs = { "Guest_Services" },
		Branch = "Services",
		Sort = 3,
		Unlocks = {},
	},

	Dining_II = {
		Name = "Dining II",
		Desc = "Further improve guest retention and capacity with larger dining options.",
		Cost = 900,
		Time = 150,
		Reqs = { "Dining_I" },
		Branch = "Services",
		Sort = 4,
		Unlocks = {
			"Medium Restaurant (Light)",
			"Medium Restaurant (Dark)",
		},
	},

	Dining_III = {
		Name = "Dining III",
		Desc = "Further improve guest retention and capacity with larger dining options.",
		Cost = 1400,
		Time = 240,
		Reqs = { "Dining_II","Lodge_Expansion_II" },
		Branch = "Services",
		Sort = 5,
		Unlocks = {
			"Large Restaurant",
		},
	},

	Lift_Mechanics_II = {
		Name = "Lift Mechanics II",
		Desc = "Higher capacity fixed-grip lift systems.",
		Cost = 650,
		Time = 120,
		Reqs = { "Lift_Mechanics_I" },
		Branch = "Lifts",
		Sort = 2,
		Unlocks = {
			"Fixed Grip Quad",
		},
	},

	Transit_Infrastructure = {
		Name = "Transport Infrastructure",
		Desc = "Improve guest movement in high-traffic zones.",
		Cost = 310,
		Time = 40,
		Reqs = { "Lift_Mechanics_I" },
		Branch = "Lifts",
		Sort = 3,
		Unlocks = {
			"Magic Carpet",
		},
	},

	Terrain_Engineering = {
		Name = "Terrain Engineering",
		Desc = "Steeper run shaping for advanced riders.",
		Cost = 700,
		Time = 75,
		Reqs = { "Safety_Signage" },
		Branch = "Terrain",
		Sort = 2,
		Unlocks = {
			"Med Center",
		},
	},

	Extreme_Terrain = {
		Name = "Extreme Terrain",
		Desc = "Unlock expert-only terrain products.",
		Cost = 1800,
		Time = 150,
		Reqs = { "Terrain_Engineering" },
		Branch = "Terrain",
		Sort = 3,
		Unlocks = {},
	},

	Snowmaking_I = {
		Name = "Snowmaking I",
		Desc = "Baseline snowmaking coverage.",
		Cost = 900,
		Time = 85,
		Reqs = { "Safety_Signage" },
		Branch = "Snow",
		Sort = 2,
		Unlocks = {
			"10ft Swine Tower",
			"Skua-30",
		},
	},

	Snowmaking_II = {
		Name = "Snowmaking II",
		Desc = "Expand output and reliability.",
		Cost = 1900,
		Time = 180,
		Reqs = { "Snowmaking_I" },
		Branch = "Snow",
		Sort = 3,
		Unlocks = {
			"15ft Swine Tower",
		},
	},

	Snowmaking_III = {
		Name = "Snowmaking III",
		Desc = "High-throughput endgame coverage.",
		Cost = 3200,
		Time = 240,
		Reqs = { "Snowmaking_II" },
		Branch = "Snow",
		Sort = 4,
		Unlocks = {},
	},

	Advanced_Detachables = {
		Name = "Advanced Detachable Systems",
		Desc = "Speedy high-capacity transport.",
		Cost = 5200,
		Time = 300,
		Reqs = { "Lift_Mechanics_II", "Transit_Infrastructure" },
		Branch = "Lifts",
		Sort = 4,
		Unlocks = {
			"HS4",
			"6 Person Bubble Lift",
		},
	},

	Gondola_Systems = {
		Name = "Gondola Systems",
		Desc = "Flagship high-capacity transport.",
		Cost = 6000,
		Time = 450,
		Reqs = { "Advanced_Detachables" },
		Branch = "Lifts",
		Sort = 5,
		Unlocks = {
			"Gondola",
		},
	},

	Slope_Grooming = {
		Name = "Slope Grooming",
		Desc = "Coming soon. This research path does not unlock a placeable item yet while grooming is being reworked.",
		Cost = 1100,
		Time = 90,
		Reqs = { "Snowmaking_I" },
		Branch = "Snow",
		Sort = 3,
		Unlocks = {
			"Snowcat Garage",
		},
	},
}

local function applyResearchPacing()
	local pacing = Config.ResearchPacing or {}
	local costMultiplier = tonumber(pacing.CostMultiplier) or 1
	local timeMultiplier = tonumber(pacing.TimeMultiplier) or 1
	local minimumTime = math.max(0, math.floor(tonumber(pacing.MinimumResearchTime) or 0))

	for _, tech in pairs(Config.TechTree) do
		local rawCost = tonumber(tech.Cost) or 0
		if rawCost > 0 then
			tech.Cost = math.max(1, math.floor((rawCost * costMultiplier) + 0.5))
		else
			tech.Cost = 0
		end

		local rawTime = tonumber(tech.Time) or 0
		if rawTime > 0 then
			tech.Time = math.max(minimumTime, math.floor((rawTime * timeMultiplier) + 0.5))
		else
			tech.Time = 0
		end
	end
end

applyResearchPacing()

Config.ResearchBonuses = {
	Basics = {
		IncomeBonus = 0.05,
	},
	Guest_Services = {
		Discounts = { Buildings = 0.05 },
		IncomeBonus = 0.04,
	},
	Safety_Signage = {
		Discounts = { Slopes = 0.05 },
	},
	Lift_Mechanics_I = {
		Discounts = { Lifts = 0.06 },
	},
	Lodge_Expansion = {
		Discounts = { Buildings = 0.07 },
		IncomeBonus = 0.03,
	},
	Lodge_Expansion_II = {
		Discounts = { Buildings = 0.08 },
		IncomeBonus = 0.04,
	},
	Dining_I = {
		Discounts = { Buildings = 0.06 },
		IncomeBonus = 0.06,
	},
	Dining_II = {
		Discounts = { Buildings = 0.08 },
		IncomeBonus = 0.08,
	},
	Lift_Mechanics_II = {
		Discounts = { Lifts = 0.08 },
	},
	Transit_Infrastructure = {
		Discounts = { Lifts = 0.06 },
	},
	Terrain_Engineering = {
		Discounts = { Slopes = 0.08 },
	},
	Extreme_Terrain = {
		Discounts = { Slopes = 0.10 },
	},
	Snowmaking_I = {
		Discounts = { Snow = 0.06 },
	},
	Snowmaking_II = {
		Discounts = { Snow = 0.08 },
	},
	Snowmaking_III = {
		Discounts = { Snow = 0.10 },
	},
	Advanced_Detachables = {
		Discounts = { Lifts = 0.10 },
	},
	Gondola_Systems = {
		Discounts = { Lifts = 0.10 },
	},
	Slope_Grooming = {
		Discounts = { Snow = 0.06 },
	},
}

return Config
