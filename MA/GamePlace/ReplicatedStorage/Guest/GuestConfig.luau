--[=[ PATH: ReplicatedStorage/Guest/GuestConfig | TYPE: ModuleScript ]=]--
--[[
	🎿 GUEST CONFIG V3.0 — COMPLETE SYSTEM CONFIGURATION
	
	Used by GuestServer V10.0 for all guest behavior.
	Everything here is referenced by the server — no unused fields.
	
	SYSTEMS:
	• Satisfaction (decay, recovery, events, thresholds)
	• Personalities (4 types with weighted random selection)
	• Crash system (speed-based with difficulty modifiers)
	• Ski ownership (per personality)
	• Rest/Break system (energy management)
	• Slope difficulty mapping (allowed + preferred per personality)
	• Employee effects (per type with level scaling)
	• Economy (budgets, spending, tips)
	• Complaints & speech (per satisfaction level + specific triggers)
	• Spawn settings
]]

local GuestConfig = {}

-- ============================================================
-- SPAWN SETTINGS
-- ============================================================
GuestConfig.Spawn = {
	BaseSpawnRate = 12,
	MaxGuestsPerHotelBed = 1.15,
	-- 0 = no static per-player cap; demand/capacity is driven by hotels + systems.
	MaxGlobalGuests = 0,
	SpawnCooldown = 0.04,
	SpawnRadius = 8,
	PopulationAdjustInterval = 3,
	MaxSpawnPerAdjust = 12,
	MaxSpawnPerHotelPerAdjust = 4,
	MaxTrimPerAdjust = 30,
	AvatarCache = {
		FriendFetchCap = 200,
		DescriptionCacheTTLSeconds = 900,
		DescriptionPrefetchPerCycle = 8,
		MaxAvatarRequestsPerSecond = 5,
		FallbackGenericChanceWhenBacklogged = 0.8,
		PreferGenericThreshold = 220,
		ForceGenericThreshold = 360,
	},
	Director = {
		TargetFillAggressiveness = 0.58,
		MaxSpawnWorkers = 4,
		SpawnBacklogHardCap = 1200,
	},
	QueueBehavior = {
		MinCommitWaitSeconds = 10,
		RerouteCheckStartSeconds = 16,
		RerouteIfPredictedWaitAbove = 45,
		MinImprovementToRerouteSeconds = 10,
		RerouteCooldownSeconds = 8,
		EmergencyPressure = 2.35,
		BoardingDistance = 14,
		BoardingExtendedDistance = 18,
		BoardingExtendedDelaySeconds = 1.2,
	},
	LiftRouting = {
		-- Queue pressure thresholds used by GuestServer for diversification.
		OvercrowdedPressure = 1.7,
		HardOvercrowdedPressure = 2.4,
		MismatchMinPressure = 1.0,
		RerouteWaitSeconds = 6,
		AvoidLiftSeconds = 10,
		AllowMismatchWhenCrowded = true,
		SameLiftRepeatPenalty = 0.9,
		CrowdPenaltyTickSeconds = 4,
		MinChairSpacingSeconds = 2.2,
		MaxChairScan = 120,
		-- Connected-lift discovery tolerances used by GuestServer when building
		-- downstream route graphs from each lift end station.
		ConnectedLiftMaxFlatDistance = 520,
		ConnectedLiftMaxRise = 90,
		ConnectedLiftMaxDrop = 220,
		SlopeEntryMaxFlatDistance = 840,
		SlopeEntryMaxRise = 160,
		SlopeEntryMinRemainingLength = 75,
	},
	SeasonDemandMultiplier = {
		Spring = 0.95,
		Summer = 0.90, -- PATCHED: was 0.75, guests now ski in summer so demand stays healthy
		Autumn = 1.0,
		Winter = 1.15,
	},
	-- Interpolated by hour (0-24). Lower at night, rises through morning, peaks evening.
	HourlyDemandCurve = {
		{Hour = 0,  Mult = 0.28},
		{Hour = 6,  Mult = 0.62},
		{Hour = 9,  Mult = 0.90},
		{Hour = 12, Mult = 1.02},
		{Hour = 16, Mult = 1.20},
		{Hour = 18, Mult = 1.35},
		{Hour = 21, Mult = 1.00},
		{Hour = 24, Mult = 0.28},
	},
	-- Minimum demand floor by hour so resorts stay lively even with low dynamic demand.
	MinimumDemandFloorByHour = {
		{Hour = 0,  Mult = 0.90},
		{Hour = 6,  Mult = 0.95},
		{Hour = 9,  Mult = 1.00},
		{Hour = 12, Mult = 1.05},
		{Hour = 16, Mult = 1.12},
		{Hour = 18, Mult = 1.20},
		{Hour = 21, Mult = 1.02},
		{Hour = 24, Mult = 0.90},
	},
}

-- Population trim / reconcile (GuestServer). Kept here to avoid Luau's ~200 top-level local register limit on the main GuestServer script.
GuestConfig.GuestTrimPriority = {
	["Sleeping"] = 1,
	["Idle"] = 2,
	["Deciding"] = 3,
	["Resting"] = 4,
	["Eating"] = 5,
	["Walking"] = 6,
	["TakingLesson"] = 7,
	["GoingToHotel"] = 8,
	["WalkingToLift"] = 9,
	["SkiingToSlope"] = 10,
	["Leaving"] = 11,
	["RentingGear"] = 12,
	["UnloadingLift"] = 13,
	["WaitingForLift"] = 14,
	["RidingLift"] = 15,
	["SkiingDown"] = 16,
	["Crashed"] = 17,
	["Recovering"] = 18,
}

GuestConfig.GuestNonTrimmableStates = {
	["TakingLesson"] = true,
	["RidingLift"] = true,
	["WaitingForLift"] = true,
	["SkiingDown"] = true,
	["Crashed"] = true,
	["Recovering"] = true,
}

-- Tuned for ~250 guests smooth; GuestServer adds automatic **mega-resort** scaling (1k–2.2k+).
GuestConfig.Performance = {
	MovementCommandRefreshSeconds = 0.18,
	MovementStuckCheckHz = 2,
	DecisionHzLowLoad = 6.0,
	DecisionHzHighLoad = 4.0,
	SkiServerHz = 6,
	MaxMovementGuestsPerTick = 36,
	MinMovementGuestsPerTick = 8,
	MaxMovementGuestsPerTickDynamic = 52,
	MaxSkiGuestsPerTick = 18,
	UseServerOwnedWalkers = true, -- Server ownership works fine now that collision is fixed
	TargetMovementRevisitSeconds = 0.9,
	DecisionTargetRevisitSeconds = 1.25,
	MinDecisionGuestsPerTick = 28,
	MaxDecisionGuestsPerTick = 72,
	MaxDecisionGuestsPerTickDynamic = 120,
	RuntimeCandidateRefreshSeconds = 1.6,
	MovementPressureSoftLimit = 0.85,
	MovementPressureHardLimit = 1.2,
	PathfindingDirectMoveDistance = 60,
	PathfindingFailureRepathLimit = 2,
	ClientWalkerSmoothingEnabled = false,
	ClientWalkerSmoothingDistance = 260,
}

-- Distance-based LOD vs **player characters** (nearest HumanoidRootPart / PrimaryPart).
-- When guest count < MinGuestsToActivate, LOD is off (everyone treated as tier 0).
GuestConfig.LOD = {
	Enabled = true,
	MinGuestsToActivate = 72,
	HighRadiusStuds = 260,
	MediumRadiusStuds = 620,
	-- How budgets are split each tick when LOD is active (should sum to ~1).
	MovementBudgetHigh = 0.66,
	MovementBudgetMedium = 0.24,
	MovementBudgetLow = 0.10,
	DecisionBudgetHigh = 0.60,
	DecisionBudgetMedium = 0.28,
	DecisionBudgetLow = 0.12,
	SkiBudgetHigh = 0.72,
	SkiBudgetMedium = 0.20,
	SkiBudgetLow = 0.08,
}

-- ============================================================
-- SATISFACTION SYSTEM
-- ============================================================
GuestConfig.Satisfaction = {
	BaseValue = 75, -- PATCHED: was 70, guests start happier

	Decay = {
		Hungry = 0.12, -- PATCHED: was 0.3, WAY too fast
		Waiting = 0.18, -- PATCHED: was 0.5, guests tanked rating just from normal queues
		WaitingLong = 0.35, -- PATCHED: was 1.0, long waits still hurt but not as brutally
		LostOrStuck = 0.08, -- PATCHED: was 0.2
		Cold = 0.04, -- PATCHED: was 0.1
	},

	Recovery = {
		Skiing = 0.5, -- PATCHED: was 0.2, skiing should BOOST satisfaction significantly
		Eating = 0.8, -- PATCHED: was 0.5, eating is a good experience now
		Resting = 0.5, -- PATCHED: was 0.3
	},

	Events = {
		-- POSITIVE (boosted to reward good resort management)
		SkiRunCompleted = 18, -- PATCHED: was 15
		AteFood = 15, -- PATCHED: was 12
		AteFoodWithChef = 22, -- PATCHED: was 20
		RentedGear = 12, -- PATCHED: was 10
		RentedGearWithTech = 18, -- PATCHED: was 15
		TookLesson = 28, -- PATCHED: was 25
		BoardedLift = 6, -- PATCHED: was 5
		BoardedLiftWithLifty = 14, -- PATCHED: was 12
		EmployeeHelped = 18, -- PATCHED: was 15
		FoundOpenRun = 10, -- PATCHED: was 8
		GoodWeather = 6, -- PATCHED: was 5
		RescuedByPatrol = 25, -- PATCHED: was 20
		GroomedSlope = 6, -- Bonus when skiing a well-groomed slope
		UngroomedSlope = -3, -- Penalty when skiing a poorly-groomed slope

		-- NEGATIVE (softened so rating doesn't tank instantly)
		WaitedTooLong = -8, -- PATCHED: was -15, way too harsh
		HungryTooLong = -5, -- PATCHED: was -10
		BrokenLift = -12, -- PATCHED: was -20
		NoSlopesAvailable = -6, -- PATCHED: was -12, not the guest's fault
		NoFoodAvailable = -8, -- PATCHED: was -15, way too harsh for early resorts
		NoRentalAvailable = -6, -- PATCHED: was -12
		GotLost = -4, -- PATCHED: was -8
		BadWeather = -3, -- PATCHED: was -5
		StuckInQueue = -5, -- PATCHED: was -10, queues are normal
		Crashed = -8, -- PATCHED: was -15, crashes happen naturally
	},

	Thresholds = {
		Ecstatic = 90,
		Happy = 70,
		Neutral = 45, -- PATCHED: was 50, wider neutral band
		Unhappy = 30, -- PATCHED: was 35
		Miserable = 15, -- PATCHED: was 20
		Leave = 8, -- PATCHED: was 15, guests should really struggle before leaving
	},

	BehaviorChances = {
		TipWhenHappy = 0.30, -- PATCHED: was 0.25, happier guests tip more
		ComplainWhenUnhappy = 0.12, -- PATCHED: was 0.15, less complaint spam
		LeaveWhenMiserable = 0.06, -- PATCHED: was 0.10, slower to leave
	},
}

-- ============================================================
-- CRASH SYSTEM
-- ============================================================
GuestConfig.Crash = {
	MinCrashSpeed = 55,
	CrashChancePerSecond = 0.0048, -- Reduced random crash frequency further to curb excessive accidents
	SteepSlopeMultiplier = 1.3, -- PATCHED: was 1.5
	BeginnerCrashMultiplier = 1.45, -- Beginners still crash more, but less punishingly
	ExpertCrashMultiplier = 0.3,
	RescueTimeout = 6, -- PATCHED: was 8, faster self-recovery
	SkiPatrolRescueBonus = 25, -- PATCHED: was 20, patrol rescue feels great
	CollisionCrashChance = 0.38, -- Reduce collision chain-crashes near lift unload zones
}

-- ============================================================
-- SKI OWNERSHIP
-- ============================================================
GuestConfig.SkiOwnership = {
	Beginner = 0.20,
	Intermediate = 0.50,
	Advanced = 0.70,
	Expert = 0.90,
}

-- ============================================================
-- REST & BREAK SYSTEM
-- ============================================================
GuestConfig.Rest = {
	BreakChanceAfterRun = 0.10,
	BreakChanceWhenTired = 0.30,
	RestDuration = { Min = 10, Max = 30 },
	RestLocations = {"House", "Food"},
	EnergyDrainPerRun = 15,
	EnergyRestorePerSecond = 2,
}

-- ============================================================
-- SLOPE DIFFICULTY MAPPING
-- ============================================================
GuestConfig.SlopeDifficulty = {
	[1] = "Green",
	[2] = "Blue",
	[3] = "Black",
	[4] = "DoubleBlack",
	[5] = "TripleBlack",
	[6] = "Glade",

	Allowed = {
		Beginner = {1},           -- Green ONLY
		Intermediate = {1, 2},    -- Green + Blue
		Advanced = {2, 3, 4, 6},  -- Blue + Black + Double Black + Glade (some)
		Expert = {3, 4, 5, 6},    -- Black + Double Black + Triple Black + Glade
	},

	Preferred = {
		Beginner = {1},
		Intermediate = {2},
		Advanced = {3},
		Expert = {4, 6},          -- Experts love Glades
	},
}

-- ============================================================
-- GUEST PERSONALITIES
-- ============================================================
GuestConfig.Personalities = {
	["Beginner"] = {
		Weight = 40,
		SkillLevel = 1,
		SkiSpeed = 0.75,
		Patience = 0.6,
		SatisfactionSensitivity = 1.3,
		TipMultiplier = 0.8,
		PreferredDifficulty = {"Green"},
	},
	["Intermediate"] = {
		Weight = 35,
		SkillLevel = 2,
		SkiSpeed = 1.3,
		Patience = 1.0,
		SatisfactionSensitivity = 1.0,
		TipMultiplier = 1.0,
		PreferredDifficulty = {"Green", "Blue"},
	},
	["Advanced"] = {
		Weight = 15,
		SkillLevel = 3,
		SkiSpeed = 1.85,
		Patience = 1.2,
		SatisfactionSensitivity = 0.8,
		TipMultiplier = 1.2,
		PreferredDifficulty = {"Blue", "Black", "Glade"},
	},
	["Expert"] = {
		Weight = 10,
		SkillLevel = 4,
		SkiSpeed = 2.4,
		Patience = 1.5,
		SatisfactionSensitivity = 0.6,
		TipMultiplier = 1.5,
		PreferredDifficulty = {"Black", "DoubleBlack", "Glade"},
	},
}

-- ============================================================
-- EMPLOYEE INTERACTION EFFECTS
-- ============================================================
GuestConfig.EmployeeEffects = {
	Lifty = {
		SatisfactionBonus = 7,
		WaitTimeReduction = 0.25,
		BreakdownPrevention = 0.10,
		PerLevel = { Satisfaction = 2, WaitReduction = 0.05 },
		InteractionRadius = 15,
		CooldownSeconds = 30,
	},
	Chef = {
		SatisfactionBonus = 8,
		FoodQualityMultiplier = 1.2,
		HungerRestoreBonus = 15,
		PerLevel = { Satisfaction = 3, FoodQuality = 0.1, HungerBonus = 5 },
		InteractionRadius = 20,
		CooldownSeconds = 60,
	},
	RentalTech = {
		SatisfactionBonus = 5,
		RentalSpeedMultiplier = 1.3,
		GearQualityBonus = 0.15,
		PerLevel = { Satisfaction = 2, Speed = 0.1, Quality = 0.05 },
		InteractionRadius = 12,
		CooldownSeconds = 120,
	},
	Instructor = {
		SatisfactionBonus = 20,
		SkillGainChance = 0.5,
		SkillGainAmount = 1,
		PerLevel = { Satisfaction = 5, SkillChance = 0.1 },
		InteractionRadius = 25,
		CooldownSeconds = 180,
	},
	SkiPatrol = {
		SatisfactionBonus = 10,
		SafetyConfidenceBonus = 0.1,
		PerLevel = { Satisfaction = 3 },
		InteractionRadius = 30,
		CooldownSeconds = 60,
	},
	Snowmaker = {
		SnowQualityBonus = 0.2,
		SatisfactionPerSnowQuality = 0.5,
		PerLevel = { SnowQuality = 0.05 },
	},
	Groomer = {
		SatisfactionBonus = 6,
		GroomQualityBonus = 0.15,
		PerLevel = { Satisfaction = 2, GroomQuality = 0.05 },
		InteractionRadius = 40,
		CooldownSeconds = 30,
	},
}

-- ============================================================
-- ECONOMY & SPENDING
-- ============================================================
GuestConfig.Economy = {
	BudgetRange = {
		Beginner = {Min = 3600, Max = 8400},
		Intermediate = {Min = 6400, Max = 14000},
		Advanced = {Min = 11200, Max = 24000},
		Expert = {Min = 20000, Max = 44000},
	},

	Spending = {
		LiftTicket = { BaseCost = 650, ChancePerVisit = 0.98, SatisfactionRequired = 0 },
		Food = { BaseCost = 425, ChanceWhenHungry = 1.0, SatisfactionRequired = 0 },
		Rental = { BaseCost = 550, ChanceIfNoGear = 0.95, SatisfactionRequired = 0 },
		Lesson = { BaseCost = 1100, ChanceForBeginner = 0.45, ChanceForOthers = 0.16, SatisfactionRequired = 25 },
		Souvenir = { BaseCost = 500, ChanceOnLeave = 0.38, SatisfactionRequired = 45 },
	},

	DynamicTicketPricing = {
		Enabled = true,
		DefaultBasePrice = 650,
		MinPrice = 400,
		MaxPrice = 1800,
		UpdateInterval = 12,
		Smoothing = 0.35,

		-- Signals used to push price up/down around the base price.
		TargetOccupancy = 0.78,
		QueueBaseline = 1.1,
		TargetSatisfaction = 70,
		ManualHoldSeconds = 300,

		OccupancyWeight = 0.65,
		QueueWeight = 0.30,
		SatisfactionWeight = 0.20,
		TimeDemandWeight = 0.25,

		MinDynamicMultiplier = 0.55,
		MaxDynamicMultiplier = 1.85,

		-- Demand reaction to ticket price (affects guest population targets).
		NeutralPriceForDemand = 650,
		DemandElasticity = 0.10,
		MinDemandMultiplier = 0.92,
		MaxDemandMultiplier = 1.45,
	},

	Tips = {
		BaseTip = 20,
		SatisfactionThreshold = 72,
		ChancePerInteraction = 0.30,
		MaxTipMultiplier = 3.5,
	},

	OutOfMoney = {
		LeaveChance = 0.22,
		SatisfactionPenalty = -6,
	},
}

-- ============================================================
-- COMPLAINTS & FEEDBACK
-- ============================================================
GuestConfig.Complaints = {
	Messages = {
		Miserable = {
			"This is awful!", "I want a refund!", "Never coming back!",
			"Worst resort ever!", "I'm leaving!",
		},
		Unhappy = {
			"The lines are too long...", "Where's the food?",
			"This is taking forever!", "Not impressed.", "Could be better...",
		},
		Neutral = {
			"It's okay I guess.", "Nothing special.", "Meh.",
		},
		Happy = {
			"Nice slopes!", "Having fun!", "Great snow!", "Love it here!",
		},
		Ecstatic = {
			"BEST DAY EVER!", "This is AMAZING!", "5 stars for sure!",
			"Coming back tomorrow!", "Take my money! 💰",
		},
	},

	Specific = {
		Hungry = {"I'm starving!", "Need food NOW!", "Where's the restaurant?"},
		Waiting = {"This line is ridiculous!", "How long is this going to take?", "*sigh*"},
		Lost = {"Where am I?", "I can't find anything!", "This place is confusing!"},
		Tired = {"I need a break...", "So tired...", "Is there a lodge nearby?"},
		BrokenLift = {"The lift is broken?!", "Seriously?!", "Fix this!"},
	},
}

-- ============================================================
-- PATHFINDING
-- ============================================================
GuestConfig.Pathfinding = {
	AgentRadius = 2.0,
	AgentHeight = 5.0,
	AgentCanJump = true,
	AgentCanClimb = false,
	WaypointSpacing = 4.0,
}

function GuestConfig.GetPathfindingProfile()
	local pathfinding = GuestConfig.Pathfinding or {}
	return {
		AgentRadius = math.max(0.5, tonumber(pathfinding.AgentRadius) or 2.0),
		AgentHeight = math.max(1, tonumber(pathfinding.AgentHeight) or 5.0),
		AgentCanJump = pathfinding.AgentCanJump ~= false,
		AgentCanClimb = pathfinding.AgentCanClimb == true,
		WaypointSpacing = math.max(1, tonumber(pathfinding.WaypointSpacing) or 4.0),
	}
end

-- ============================================================
-- HELPER FUNCTIONS
-- ============================================================
function GuestConfig.GetPersonality(name)
	return GuestConfig.Personalities[name]
end

function GuestConfig.GetRandomPersonality()
	local total = 0
	for _, p in pairs(GuestConfig.Personalities) do total = total + p.Weight end

	local roll = math.random() * total
	local current = 0
	for name, p in pairs(GuestConfig.Personalities) do
		current = current + p.Weight
		if roll <= current then return name, p end
	end
	return "Intermediate", GuestConfig.Personalities.Intermediate
end

function GuestConfig.GetEmployeeEffect(employeeType)
	return GuestConfig.EmployeeEffects[employeeType]
end

function GuestConfig.GetSatisfactionEvent(eventName)
	return GuestConfig.Satisfaction.Events[eventName] or 0
end

function GuestConfig.GetComplaintMessage(satisfactionLevel)
	local category
	if satisfactionLevel >= 90 then category = "Ecstatic"
	elseif satisfactionLevel >= 70 then category = "Happy"
	elseif satisfactionLevel >= 50 then category = "Neutral"
	elseif satisfactionLevel >= 35 then category = "Unhappy"
	else category = "Miserable" end

	local messages = GuestConfig.Complaints.Messages[category]
	return messages[math.random(#messages)]
end

function GuestConfig.GetSpecificComplaint(reason)
	local messages = GuestConfig.Complaints.Specific[reason]
	if messages then return messages[math.random(#messages)] end
	return nil
end

function GuestConfig.CalculateEmployeeBonus(employeeType, employeeLevel)
	local effect = GuestConfig.EmployeeEffects[employeeType]
	if not effect then return 0 end
	local base = effect.SatisfactionBonus or 0
	local perLevel = effect.PerLevel and effect.PerLevel.Satisfaction or 0
	return base + (perLevel * math.max(0, (employeeLevel or 1) - 1))
end

function GuestConfig.GetBudget(personality)
	local range = GuestConfig.Economy.BudgetRange[personality]
	if range then return math.random(range.Min, range.Max) end
	return math.random(50, 150)
end

return GuestConfig
