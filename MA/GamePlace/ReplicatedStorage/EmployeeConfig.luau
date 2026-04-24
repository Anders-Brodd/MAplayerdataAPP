--[[
	EMPLOYEE CONFIG V3.0 - FULL OVERHAUL
	ReplicatedStorage/EmployeeConfig
	
	CHANGES:
	- Gamepass integration (2x employees, unlimited employees)
	- Weather/slope awareness settings
	- Real economy: hiring costs deducted, wages deducted periodically
	- Meaningful stat multipliers per employee type
	- Difficulty-aware patrol behavior config
]]

local EmployeeConfig = {}

-- ============================================================
-- GAMEPASS IDS
-- ============================================================

EmployeeConfig.Gamepasses = {
	DoubleEmployees = 1708600326,       -- Legacy employee pass ID; now grants unlimited employees.
	UnlimitedEmployees = 1708600326,    -- Same live pass ID until/unless you split this into a separate product.
}

-- Backward compatibility for older employee server scripts.
EmployeeConfig.Passes = EmployeeConfig.Gamepasses

-- ============================================================
-- GLOBAL SETTINGS
-- ============================================================

EmployeeConfig.Settings = {
	-- Base caps (BEFORE gamepasses)
	MaxPerType = 5,
	MaxTotal = 35,

	-- Cap policy
	-- Base roster limits: 5 per type, up to 35 total.
	-- The live employee pass now unlocks unlimited employees.
	-- Keep these legacy doubled-cap numbers around for backward compatibility in case older scripts still read them.
	DoubleMaxPerType = 10,
	DoubleMaxTotal = 70,
	-- Unlimited = no cap at all

	PriceScalingExponent = 1.25,
	UpgradeBaseCost = 500,
	UpgradeCostMultiplier = 1.25,
	MaxLevel = 10,

	-- Wages (real economy)
	WageInterval = 90,       -- Deduct wages every 90 seconds
	WageEnabled = true,
	UnpaidEfficiencyMult = 0.65, -- Efficiency when owner can't pay wages

	-- Work timing
	WorkDurationMin = 45,
	WorkDurationMax = 90,
	BreakDurationMin = 8,
	BreakDurationMax = 15,
	BreakChance = 0.15,

	-- Employee lifecycle safety
	-- 0 disables auto-quitting when no assignment/slope/lift is available.
	JoblessQuitAfter = 0,

	-- Movement
	WanderRadius = 40,
	PathfindingTimeout = 5,
	StuckThreshold = 3,
	InteractionRadius = 50,

	-- Visuals
	NameTagDistance = 100,
	SpeechBubbleDuration = 4,
	HighlightThickness = 0.03,
}

-- ============================================================
-- WEATHER EFFECTS ON EMPLOYEES
-- ============================================================

EmployeeConfig.WeatherEffects = {
	Clear = {
		SpeedMult = 1.0,
		EfficiencyMult = 1.1,  -- Bonus in good weather
		IncomeMult = 1.1,
		LiftSpeedOverride = nil,  -- No override
		Speech = {"Beautiful day!", "Perfect conditions!", "What a day!"},
	},
	LightSnow = {
		SpeedMult = 0.95,
		EfficiencyMult = 1.0,
		IncomeMult = 1.0,
		LiftSpeedOverride = nil,
		Speech = {"Light flurries coming down.", "A little snow never hurt."},
	},
	HeavySnow = {
		SpeedMult = 0.8,
		EfficiencyMult = 0.85,
		IncomeMult = 0.9,
		LiftSpeedOverride = 0.7,  -- Slow lifts to 70%
		Speech = {"Heavy snow out there!", "Visibility is low.", "Careful on the slopes!"},
	},
	Blizzard = {
		SpeedMult = 0.5,
		EfficiencyMult = 0.6,
		IncomeMult = 0.7,
		LiftSpeedOverride = 0.3,  -- Near-stop in blizzard
		Speech = {"Blizzard conditions!", "Hold the lifts!", "Seek shelter!", "Dangerous out here!"},
	},
}

-- ============================================================
-- SLOPE DIFFICULTY SETTINGS
-- ============================================================

EmployeeConfig.DifficultySettings = {
	-- How employee types interact with slope difficulty
	PatrolIncome = {
		Green = 3,
		Blue = 5,
		Black = 8,
		["Double Black"] = 12,
	},
	-- Patrol frequency multiplier by difficulty
	PatrolFrequency = {
		Green = 1.0,
		Blue = 1.2,
		Black = 1.5,
		["Double Black"] = 2.0,
	},
	-- Crash rescue income by difficulty
	RescueIncome = {
		Green = 5,
		Blue = 8,
		Black = 12,
		["Double Black"] = 18,
	},
	-- Grooming effort multiplier by difficulty
	GroomingEffort = {
		Green = 1.0,
		Blue = 1.2,
		Black = 1.5,
		["Double Black"] = 2.0,
	},
	-- Instructor can only teach on these difficulties
	InstructorMaxDifficulty = {
		Green = true,
		Blue = true,
		Black = false,
		["Double Black"] = false,
	},
}

-- ============================================================
-- BUILDING NAME MAPPINGS
-- ============================================================

EmployeeConfig.BuildingTypes = {
	Lifts = {
		"Surface Tow", "Double Vintage Chairlift",
		"Fixed Grip Double", "Fixed Grip Quad",
		"6 Person Bubble Lift", "Gondola", "HS4", "Magic Carpet"
	},

	Restaurants = {
		"Restaurant (Small)", "Light Restaurant (Large)", "Dark Restaurant (Large)",
		"Restaurant", "Food Court", "Cafe", "Diner"
	},

	Rentals = {
		"Rental Shop", "Rental", "Equipment Rental"
	},

	Cleanable = {
		"Restaurant", "Food", "Cafe", "Rental", "Cabin", "Lodge", "Hotel", "House"
	},

	Hotels = {
		"Dark Cabin (Small)", "Dark Cabin (Medium)", "Dark Cabin (Large)",
		"Light Cabin (Small)", "Light Cabin (Large)"
	},

	Snowguns = {
		"10ft Swine Tower",
		"15ft Swine Tower",
		"Skua-30",
		"Stoat-6",
		"Stoat-10",
		"SnowGun",
		"SnowCannon",
		"10ft Narwhal Tower",
		"15ft Narwhal Tower",
		"20ft Narwhal Tower",
	}
}

-- ============================================================
-- EMPLOYEE TYPE DEFINITIONS
-- ============================================================

EmployeeConfig.Types = {

	LiftOperator = {
		Name = "Lift Operator",
		Emoji = "🚡",
		Description = "Operates lifts: auto-starts, controls speed, repairs breakdowns, slows in bad weather.",

		BaseCost = 125,
		BaseWage = 3,

		BaseWalkSpeed = 30,
		BaseEfficiency = 1.0,

		Color = Color3.fromRGB(0, 150, 255),
		UniformColor = Color3.fromRGB(30, 80, 150),

		UpgradeStats = {
			Efficiency = 0.15,
			WalkSpeed = 1,
		},
		UpgradeDesc = "Faster loading, quicker repairs",

		JobType = "Stationary",
		AssignmentType = "Lift",
		RequiresAssignment = false,

		Effects = {
			LiftLoadingSpeed = 0.10,
			LiftBreakdownReduction = 0.05,
			GuestSatisfaction = 0.02,
			MinorRepairBonus = 0.15,
		},

		-- Income per action cycle
		BaseIncome = 18,
		RepairIncome = 40,

		IdleLines = {
			"Watch your step!",
			"Keep your tips up!",
			"Have a great run!",
			"Bar coming down!",
		},
		WorkingLines = {
			"Loading passengers...",
			"Safety bar check!",
			"All clear, let's go!",
			"Lift running smooth.",
		},
		BreakLines = {
			"Quick coffee break.",
			"Stretching my legs.",
		},
		WeatherLines = {
			Blizzard = {"Holding the lift! Too dangerous.", "Slowing lift for safety!"},
			HeavySnow = {"Slowing the lift, visibility low.", "Careful boarding!"},
			Cold = {"Bundle up! It's freezing.", "Keep those hands warm!"},
		},
	},

	SkiPatrol = {
		Name = "Ski Patrol",
		Emoji = "⛑️",
		Description = "Rescues crashed guests, patrols slopes by difficulty, responds faster in bad weather.",

		BaseCost = 220,
		BaseWage = 5,

		BaseWalkSpeed = 34,
		BaseEfficiency = 1.0,

		Color = Color3.fromRGB(220, 50, 50),
		UniformColor = Color3.fromRGB(180, 30, 30),

		UpgradeStats = {
			Efficiency = 0.12,
			WalkSpeed = 1.5,
		},
		UpgradeDesc = "Faster rescues, wider patrol area",

		JobType = "Patrol",
		AssignmentType = "Slope",
		RequiresAssignment = false,

		Effects = {
			GuestInjuryRecovery = 0.25,
			SlopeSafetyRating = 0.05,
			GuestSatisfaction = 0.03,
			RescueRadius = 80,
		},

		BaseIncome = 8,
		RescueIncome = 24,

		IdleLines = {
			"All clear on the slopes.",
			"Scanning for trouble.",
			"Safety first!",
			"Ready to respond.",
		},
		WorkingLines = {
			"Rescue in progress!",
			"Help is on the way!",
			"Stay calm, I've got you.",
			"Heading to the crash site!",
		},
		BreakLines = {
			"Quick warm-up inside.",
			"Checking my gear.",
		},
		WeatherLines = {
			Blizzard = {"Blizzard patrol is critical!", "Extra vigilance in this storm."},
			HeavySnow = {"Watching for crashes in this snow.", "Low viz, eyes open."},
		},
	},

	Groomer = {
		Name = "Groomer",
		Emoji = "🚜",
		Description = "Maintains slope conditions - harder slopes need more grooming. Quality decays with use.",

		BaseCost = 320,
		BaseWage = 6,

		BaseWalkSpeed = 28,
		BaseEfficiency = 1.0,

		Color = Color3.fromRGB(255, 200, 50),
		UniformColor = Color3.fromRGB(200, 150, 30),

		UpgradeStats = {
			Efficiency = 0.15,
			WalkSpeed = 0.5,
		},
		UpgradeDesc = "Faster grooming, better snow quality",

		JobType = "Mobile",
		AssignmentType = "Slope",
		RequiresAssignment = false,

		Effects = {
			SlopeCondition = 0.15,
			SlopeConditionDecay = 0.10,
			GuestSatisfaction = 0.04,
			SkiSpeedBonus = 0.05,
		},

		BaseIncome = 14,
		GroomIncome = 16,

		IdleLines = {
			"Slopes looking good.",
			"Time for some corduroy.",
			"Fresh tracks incoming!",
		},
		WorkingLines = {
			"Grooming in progress...",
			"Making it smooth!",
			"Perfect lines!",
			"This slope needs work.",
		},
		BreakLines = {
			"Warming up the cat.",
			"Fuel break.",
		},
		WeatherLines = {
			Blizzard = {"Can't groom in a blizzard.", "Waiting for the storm to pass."},
			HeavySnow = {"Heavy snow means more grooming later.", "Snow is piling up."},
		},
	},

	Snowmaker = {
		Name = "Snowmaker",
		Emoji = "❄️",
		Description = "Operates snow guns. Only works below freezing. Adjusts intensity by temperature.",

		BaseCost = 260,
		BaseWage = 4,

		BaseWalkSpeed = 28,
		BaseEfficiency = 1.0,

		Color = Color3.fromRGB(150, 220, 255),
		UniformColor = Color3.fromRGB(100, 150, 200),

		UpgradeStats = {
			Efficiency = 0.12,
			WalkSpeed = 0.5,
		},
		UpgradeDesc = "More snow output, better coverage",

		JobType = "Stationary",
		AssignmentType = "Snowgun",
		RequiresAssignment = false,

		Effects = {
			SnowgunEfficiency = 0.20,
			SnowgunRange = 0.10,
			BaseDepthBonus = 0.05,
			OperatingCostReduction = 0.10,
		},

		BaseIncome = 10,

		-- Temperature thresholds
		FreezingTemp = 32,
		IdealTemp = 15,
		IntensityByTemp = {
			-- temp <= value => intensity
			{temp = 10, intensity = "Fast"},
			{temp = 20, intensity = "Medium"},
			{temp = 32, intensity = "Slow"},
		},

		IdleLines = {
			"Checking the guns.",
			"Good conditions tonight.",
			"Let it snow!",
		},
		WorkingLines = {
			"Guns are blowing!",
			"Making powder!",
			"Coverage looking good.",
			"Perfect snowmaking temps!",
		},
		BreakLines = {
			"Thawing out.",
			"Quick check on temps.",
		},
		WeatherLines = {
			TooWarm = {"Too warm for snowmaking.", "Need colder temps.", "Waiting for the freeze."},
			Freezing = {"Perfect snowmaking weather!", "Temps are ideal!"},
		},
	},

	Chef = {
		Name = "Chef",
		Emoji = "👨‍🍳",
		Description = "Serves food at restaurants. More guests nearby = more income. Hot cocoa bonus in cold weather.",

		BaseCost = 180,
		BaseWage = 4,

		BaseWalkSpeed = 28,
		BaseEfficiency = 1.0,

		Color = Color3.fromRGB(255, 255, 255),
		UniformColor = Color3.fromRGB(240, 240, 240),

		UpgradeStats = {
			Efficiency = 0.15,
			WalkSpeed = 0.5,
		},
		UpgradeDesc = "Faster service, tastier food",

		JobType = "Stationary",
		AssignmentType = "Restaurant",
		RequiresAssignment = false,

		Effects = {
			FoodServiceSpeed = 0.20,
			FoodRevenue = 0.18,
			GuestSatisfaction = 0.05,
			QueueReduction = 0.15,
		},

		BaseIncome = 16,
		GuestProximityRadius = 60,
		IncomePerNearbyGuest = 5,

		IdleLines = {
			"Order up!",
			"Kitchen's ready!",
			"Smells delicious!",
		},
		WorkingLines = {
			"Cooking up a storm!",
			"Hot and fresh!",
			"Coming right up!",
			"Busy kitchen today!",
		},
		BreakLines = {
			"Tasting the soup.",
			"Quick snack break.",
		},
		WeatherLines = {
			Cold = {"Hot cocoa is on!", "Warming up the kitchen.", "Extra soup today!"},
		},
	},

	RentalTech = {
		Name = "Rental Tech",
		Emoji = "🎿",
		Description = "Fits guests with gear. Finds guests who need rentals and speeds up the process.",

		BaseCost = 150,
		BaseWage = 3,

		BaseWalkSpeed = 28,
		BaseEfficiency = 1.0,

		Color = Color3.fromRGB(180, 100, 255),
		UniformColor = Color3.fromRGB(120, 60, 180),

		UpgradeStats = {
			Efficiency = 0.15,
			WalkSpeed = 0.5,
		},
		UpgradeDesc = "Faster fittings, better equipment",

		JobType = "Stationary",
		AssignmentType = "Rental",
		RequiresAssignment = false,

		Effects = {
			RentalSpeed = 0.25,
			RentalRevenue = 0.15,
			GuestSatisfaction = 0.03,
			EquipmentQuality = 0.10,
		},

		BaseIncome = 14,
		GuestProximityRadius = 50,
		IncomePerRental = 10,

		IdleLines = {
			"Perfect fit!",
			"Bindings are set.",
			"You're all set!",
		},
		WorkingLines = {
			"Let me check your DIN.",
			"Finding your size...",
			"Almost ready!",
			"Next customer please!",
		},
		BreakLines = {
			"Sharpening edges.",
			"Organizing inventory.",
		},
	},

	Janitor = {
		Name = "Janitor",
		Emoji = "🧹",
		Description = "Keeps base areas clean around cabins, restaurants, and rentals so guests feel the resort is well run.",

		BaseCost = 145,
		BaseWage = 3,

		BaseWalkSpeed = 21,
		BaseEfficiency = 1.0,

		Color = Color3.fromRGB(95, 210, 175),
		UniformColor = Color3.fromRGB(45, 125, 100),

		UpgradeStats = {
			Efficiency = 0.14,
			WalkSpeed = 0.5,
		},
		UpgradeDesc = "Cleans faster, handles busier guest areas",

		JobType = "Stationary",
		AssignmentType = "Cleaning",
		RequiresAssignment = false,

		Effects = {
			GuestSatisfaction = 0.04,
			ResortRating = 0.04,
			QueueReduction = 0.04,
		},

		BaseIncome = 11,
		GuestProximityRadius = 70,
		IncomePerNearbyGuest = 2,

		IdleLines = {
			"Keeping this place tidy.",
			"A clean base feels better.",
			"Sweeping up around the lodge.",
		},
		WorkingLines = {
			"Cleaning up the guest area.",
			"Freshening things up.",
			"Keeping the resort looking sharp.",
			"This base area is getting busy.",
		},
		BreakLines = {
			"Quick water break.",
			"Refilling supplies.",
		},
	},

	Instructor = {
		Name = "Instructor",
		Emoji = "🏂",
		Description = "Teaches on green/blue slopes. Boosts guest skill gain. Indoor lessons during storms.",

		BaseCost = 280,
		BaseWage = 5,

		BaseWalkSpeed = 32,
		BaseEfficiency = 1.0,

		Color = Color3.fromRGB(50, 200, 100),
		UniformColor = Color3.fromRGB(30, 150, 70),

		UpgradeStats = {
			Efficiency = 0.12,
			WalkSpeed = 1,
		},
		UpgradeDesc = "Better teaching, happier students",

		JobType = "Mobile",
		AssignmentType = "Slope",
		RequiresAssignment = false,

		Effects = {
			GuestSkillGain = 0.20,
			GuestSatisfaction = 0.08,
			ResortRating = 0.05,
			LessonRevenue = 0.15,
			GuestRetention = 0.10,
		},

		BaseIncome = 13,
		LessonIncome = 22,

		IdleLines = {
			"Pizza! French fries!",
			"Bend those knees!",
			"You're doing great!",
		},
		WorkingLines = {
			"Follow my tracks!",
			"Nice turn!",
			"Keep your weight forward!",
			"Great progress today!",
		},
		BreakLines = {
			"Let's take five.",
			"Hot cocoa break!",
		},
		WeatherLines = {
			Blizzard = {"Indoor lesson time!", "Theory class today.", "Too stormy to ski."},
			HeavySnow = {"Short lesson, then inside.", "We'll take it easy today."},
		},
	},

	Mechanic = {
		Name = "Mechanic",
		Emoji = "🔧",
		Description = "Patrols lifts and repairs damage. Rushes to broken lifts as priority.",

		BaseCost = 360,
		BaseWage = 7,

		BaseWalkSpeed = 31,
		BaseEfficiency = 1.0,

		Color = Color3.fromRGB(255, 165, 0),
		UniformColor = Color3.fromRGB(200, 120, 20),

		UpgradeStats = {
			Efficiency = 0.18,
			WalkSpeed = 1,
		},
		UpgradeDesc = "Faster repairs, better lift condition",

		JobType = "Patrol",
		AssignmentType = "Lift",
		RequiresAssignment = false,

		Effects = {
			LiftBreakdownReduction = 0.10,
			LiftConditionRestore = 0.20,
			GuestSatisfaction = 0.02,
		},

		BaseIncome = 10,
		RepairIncome = 38,

		IdleLines = {
			"Everything's running smooth.",
			"Checking the next lift.",
			"Tools ready.",
		},
		WorkingLines = {
			"Fixing this up.",
			"Almost got it.",
			"Tightening the bolts.",
			"Replacing the cable.",
		},
		BreakLines = {
			"Quick coffee.",
			"Wiping grease off.",
		},
		WeatherLines = {
			Blizzard = {"Lifts take a beating in this weather.", "Extra inspections needed."},
			HeavySnow = {"Snow piling on the cables.", "Checking for ice."},
		},
	},
}

-- ============================================================
-- HELPER FUNCTIONS
-- ============================================================

function EmployeeConfig.GetHireCost(baseCost, currentCount)
	if currentCount <= 0 then return baseCost end
	return math.floor(baseCost * (EmployeeConfig.Settings.PriceScalingExponent ^ currentCount))
end

function EmployeeConfig.GetUpgradeCost(currentLevel)
	return math.floor(
		EmployeeConfig.Settings.UpgradeBaseCost * 
			(EmployeeConfig.Settings.UpgradeCostMultiplier ^ (currentLevel - 1))
	)
end

function EmployeeConfig.GetWage(baseWage, level)
	return math.floor(baseWage * (1 + (level - 1) * 0.15))
end

function EmployeeConfig.GetStatAtLevel(baseValue, upgradePerLevel, level)
	return baseValue + (upgradePerLevel * (level - 1))
end

function EmployeeConfig.GetEffectsAtLevel(employeeType, level)
	local typeData = EmployeeConfig.Types[employeeType]
	if not typeData then return {} end

	local effects = {}
	for effectName, baseValue in pairs(typeData.Effects) do
		if type(baseValue) == "number" then
			effects[effectName] = baseValue * (1 + (level - 1) * 0.14)
		end
	end
	return effects
end

function EmployeeConfig.GetSpeechLine(employeeType, state)
	local typeData = EmployeeConfig.Types[employeeType]
	if not typeData then return nil end

	local lines
	if state == "Idle" then
		lines = typeData.IdleLines
	elseif state == "Working" then
		lines = typeData.WorkingLines
	elseif state == "Break" then
		lines = typeData.BreakLines
	end

	if lines and #lines > 0 then
		return lines[math.random(1, #lines)]
	end
	return nil
end

function EmployeeConfig.GetWeatherSpeech(employeeType, weatherKey)
	local typeData = EmployeeConfig.Types[employeeType]
	if not typeData or not typeData.WeatherLines then return nil end

	local lines = typeData.WeatherLines[weatherKey]
	if lines and #lines > 0 then
		return lines[math.random(1, #lines)]
	end
	return nil
end

function EmployeeConfig.GetTypeData(employeeType)
	return EmployeeConfig.Types[employeeType]
end

function EmployeeConfig.GetAllTypes()
	local types = {}
	for typeName, _ in pairs(EmployeeConfig.Types) do
		table.insert(types, typeName)
	end
	return types
end

function EmployeeConfig.GetWeatherMultipliers(weather)
	return EmployeeConfig.WeatherEffects[weather] or EmployeeConfig.WeatherEffects.Clear
end

function EmployeeConfig.GetDifficultyIncome(employeeType, difficulty)
	if employeeType == "SkiPatrol" then
		return EmployeeConfig.DifficultySettings.RescueIncome[difficulty] or 5
	elseif employeeType == "Groomer" then
		return EmployeeConfig.DifficultySettings.PatrolIncome[difficulty] or 3
	else
		return EmployeeConfig.DifficultySettings.PatrolIncome[difficulty] or 3
	end
end

function EmployeeConfig.CanInstructorTeachDifficulty(difficulty)
	return EmployeeConfig.DifficultySettings.InstructorMaxDifficulty[difficulty] or false
end

function EmployeeConfig.GetSnowmakerIntensity(temperature)
	local typeData = EmployeeConfig.Types.Snowmaker
	if temperature > typeData.FreezingTemp then
		return nil -- Too warm
	end
	for _, entry in ipairs(typeData.IntensityByTemp) do
		if temperature <= entry.temp then
			return entry.intensity
		end
	end
	return "Slow"
end

function EmployeeConfig.GetLevelProgress(level)
	local maxLevel = math.max(1, EmployeeConfig.Settings.MaxLevel or 10)
	if maxLevel <= 1 then return 1 end
	return math.clamp(((tonumber(level) or 1) - 1) / (maxLevel - 1), 0, 1)
end

function EmployeeConfig.GetBreakChance(level)
	local progress = EmployeeConfig.GetLevelProgress(level)
	return EmployeeConfig.Settings.BreakChance * (1.18 - (progress * 0.5))
end

function EmployeeConfig.GetBreakDuration(level)
	local progress = EmployeeConfig.GetLevelProgress(level)
	local minBreak = math.max(4, math.floor(EmployeeConfig.Settings.BreakDurationMin * (1.05 - (progress * 0.35))))
	local maxBreak = math.max(minBreak + 1, math.floor(EmployeeConfig.Settings.BreakDurationMax * (1.05 - (progress * 0.4))))
	return minBreak, maxBreak
end

function EmployeeConfig.GetRoleWorkStats(employeeType, level)
	local progress = EmployeeConfig.GetLevelProgress(level)
	local stats = {
		Progress = progress,
		QualityMult = 0.92 + (progress * 0.46),
		ActionInterval = 12 - (progress * 6),
		CrowdCapacity = 5 + math.floor(progress * 10),
		RepairPower = 1.3 + (progress * 0.9),
		RecoveryThresholdBonus = math.floor(progress * 12),
		SnowPower = 1 + (progress * 0.6),
		LessonDurationMult = 1 - (progress * 0.35),
	}

	if employeeType == "LiftOperator" then
		stats.CrowdCapacity = 8 + math.floor(progress * 18)
		stats.ActionInterval = 13 - (progress * 6)
		stats.RepairPower = 1.3 + (progress * 1.1)
		stats.QualityMult = 1 + (progress * 0.35)
	elseif employeeType == "Chef" then
		stats.CrowdCapacity = 5 + math.floor(progress * 15)
		stats.ActionInterval = 13 - (progress * 7)
		stats.QualityMult = 0.95 + (progress * 0.5)
	elseif employeeType == "RentalTech" then
		stats.CrowdCapacity = 4 + math.floor(progress * 13)
		stats.ActionInterval = 15 - (progress * 5.5)
		stats.QualityMult = 0.94 + (progress * 0.45)
	elseif employeeType == "Janitor" then
		stats.CrowdCapacity = 6 + math.floor(progress * 14)
		stats.ActionInterval = 11 - (progress * 5)
		stats.QualityMult = 0.96 + (progress * 0.5)
	elseif employeeType == "Mechanic" then
		stats.RepairPower = 1 + (progress * 1.0)
		stats.RecoveryThresholdBonus = 6 + math.floor(progress * 18)
		stats.ActionInterval = 14 - (progress * 4)
	elseif employeeType == "Snowmaker" then
		stats.SnowPower = 1 + (progress * 0.8)
		stats.ActionInterval = 20 - (progress * 6)
	elseif employeeType == "Groomer" then
		stats.SnowPower = 1 + (progress * 0.9)
		stats.QualityMult = 1 + (progress * 0.35)
	elseif employeeType == "SkiPatrol" then
		stats.QualityMult = 1 + (progress * 0.3)
	elseif employeeType == "Instructor" then
		stats.CrowdCapacity = 1
		stats.ActionInterval = 11 - (progress * 5)
		stats.QualityMult = 1 + (progress * 0.55)
		stats.LessonDurationMult = 1 - (progress * 0.45)
	end

	stats.ActionInterval = math.max(6, stats.ActionInterval)
	return stats
end

-- ============================================================
-- ASSIGNMENT HELPERS
-- ============================================================

local function IsPlacedObjectRootModel(obj, placedObjects)
	if not (obj and obj:IsA("Model") and placedObjects) then
		return false
	end

	local current = obj.Parent
	while current and current ~= placedObjects do
		if current:IsA("Model") then
			local currentType = current:GetAttribute("Type")
			local currentCategory = current:GetAttribute("Category")
			local currentUuid = current:GetAttribute("UUID")
			if currentType ~= nil or currentCategory ~= nil or currentUuid ~= nil then
				return false
			end
		end
		current = current.Parent
	end

	return current == placedObjects
end

function EmployeeConfig.GetValidAssignments(employeeType)
	local typeData = EmployeeConfig.Types[employeeType]
	if not typeData then return {} end

	local assignmentType = typeData.AssignmentType
	local validTargets = {}

	local placedObjects = workspace:FindFirstChild("PlacedObjects")
	if not placedObjects then return validTargets end

	for _, obj in ipairs(placedObjects:GetDescendants()) do
		if not IsPlacedObjectRootModel(obj, placedObjects) then
			continue
		end
		local objType = obj:GetAttribute("Type")
		local objName = obj.Name

		if assignmentType == "Lift" then
			if objType == "TwoPoint" then
				table.insert(validTargets, obj)
			else
				for _, liftName in ipairs(EmployeeConfig.BuildingTypes.Lifts) do
					if objName:find(liftName) then
						table.insert(validTargets, obj)
						break
					end
				end
			end

		elseif assignmentType == "Restaurant" then
			if objType == "Food" then
				table.insert(validTargets, obj)
			else
				for _, restName in ipairs(EmployeeConfig.BuildingTypes.Restaurants) do
					if objName:find(restName) then
						table.insert(validTargets, obj)
						break
					end
				end
			end

		elseif assignmentType == "Rental" then
			if objType == "Rental" then
				table.insert(validTargets, obj)
			else
				for _, rentalName in ipairs(EmployeeConfig.BuildingTypes.Rentals) do
					if objName:find(rentalName) then
						table.insert(validTargets, obj)
						break
					end
				end
			end

		elseif assignmentType == "Snowgun" then
			for _, gunName in ipairs(EmployeeConfig.BuildingTypes.Snowguns) do
				if objName:find(gunName) or objName:find("Narwhal") then
					table.insert(validTargets, obj)
					break
				end
			end

		elseif assignmentType == "Cleaning" then
			local cleanable = objType == "Food" or objType == "Rental" or objType == "House"
			if not cleanable then
				for _, cleanName in ipairs(EmployeeConfig.BuildingTypes.Cleanable) do
					if objName:find(cleanName) then
						cleanable = true
						break
					end
				end
			end
			if cleanable then
				table.insert(validTargets, obj)
			end

		elseif assignmentType == "Slope" then
			if objType == "Slope" or obj:GetAttribute("Difficulty") then
				table.insert(validTargets, obj)
			end
		end
	end

	return validTargets
end

function EmployeeConfig.FindFirstAvailableAssignment(employeeType)
	local assignments = EmployeeConfig.GetValidAssignments(employeeType)
	if #assignments > 0 then
		return assignments[1]
	end
	return nil
end

-- ============================================================
-- GUEST BONUS CALCULATOR (used by GuestServer)
-- ============================================================

function EmployeeConfig.CalculateEmployeeBonus(employeeType, staffLevel)
	staffLevel = staffLevel or 1
	local base = 2
	if employeeType == "Lifty" or employeeType == "LiftOperator" then
		base = 3
	elseif employeeType == "Chef" then
		base = 4
	elseif employeeType == "RentalTech" then
		base = 3
	end
	return math.floor(base * (1 + (staffLevel - 1) * 0.15))
end

return EmployeeConfig