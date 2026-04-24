--[[
DESCRIPTION:
This script acts as the primary configuration module for placeable items in the game. It stores dictionaries for different categories (Lifts, Buildings, Decor, Slopes) and contains specific data for each item.

CHANGES (ADDED/REMOVED):
- NOTE: Lifts no longer define or enforce any maximum length. Only minimum length and angle rules still apply during placement.
- ADDED: `MaxAngle` to lift types to work with the new PlacementClient restriction system.
]]--

local Config = {
	Categories = {
		"Lifts", "Buildings", "Decor", "Slopes"
	},
	Items = {
		-- // ⛷️ LIFTS //
		-- Dynamic Pricing: Price = BasePrice + (Length * PricePerStud)

		["Chairlift"] = { --depricated
			ID = 100000000001,
			ShowInMenu = false,
			Loadable = true,
			Category = nil,
			Price = 100,
			PricePerStud = 1500,
			Type = "TwoPoint",
			Speed = 9,
			Capacity = 2,
			ChairSpacing = 50,
			PoleSpacing = 120,
			Detachable = false,
			HasDoors = false, 
			DoorOpenWidth = 0,
			PoleBodyRotationY = 90,
			SheaveRotationY = 0,
			StationRotation = 0,
			ChairRotationX = 0, ChairRotationY = -90, ChairRotationZ = 0,
			SurfaceTow = false,
			GripHeight = 0,
			RideAnimation = nil,
			MaxAngle = 45
		},
		["Surface Tow"] = {
			ID = 100000000002,
			ShowInMenu = true,
			Loadable = true,
			Category = "Lifts",
			Price = 12000,
			PricePerStud = 45,
			Type = "TwoPoint",
			Speed = 6,
			Capacity = 2,
			ChairSpacing = 40,
			PoleSpacing = 100,
			Detachable = false,
			HasDoors = false,
			DoorOpenWidth = 0,
			PoleBodyRotationY = 0,
			SheaveRotationY = 90,
			StationRotation = 180,
			ChairRotationX = 0, ChairRotationY = -90, ChairRotationZ = 0,
			SurfaceTow = true,
			RideAnimation = "rbxassetid://180435571",
			MaxAngle = 35
		},
		["Double Vintage Chairlift"] = {
			ID = 100000000003,
			ShowInMenu = true,
			Loadable = true,
			Category = "Lifts",
			Price = 32000,
			PricePerStud = 75,
			Type = "TwoPoint",
			Speed = 8,
			Capacity = 2,
			ChairSpacing = 100,
			PoleSpacing = 90,
			Detachable = false,
			HasDoors = false,
			DoorOpenWidth = 0,
			PoleBodyRotationY = -180,
			SheaveRotationY = -90,
			StationRotation = 180,
			ChairRotationX = 0, ChairRotationY = 90, ChairRotationZ = 0,
			SurfaceTow = false,
			RideAnimation = "rbxassetid://180435571",
			MaxAngle = 45
		},
		["Single Vintage Chairlift"] = {
			ID = 100000000004,
			ShowInMenu = false,
			Loadable = true,
			Category = "Lifts",
			Price = 24000,
			PricePerStud = 95,
			Type = "TwoPoint",
			Speed = 6.5,
			Capacity = 1,
			ChairSpacing = 100,
			PoleSpacing = 90,
			Detachable = false,
			HasDoors = false,
			DoorOpenWidth = 0,
			PoleBodyRotationY = 0,
			SheaveRotationY = 180,
			StationRotation = 180,
			ChairRotationX = -90, ChairRotationY = 0, ChairRotationZ = 90,
			SurfaceTow = false,
			RideAnimation = "rbxassetid://180435571",
			MaxAngle = 45
		},
		["Advanced Chairlift"] = {
			ID = 100000000005,
			ShowInMenu = false,
			Loadable = true,
			Category = nil,
			Price = 1200000,
			PricePerStud = 4500,
			Type = "TwoPoint",
			Speed = 8.5,
			Capacity = 2,
			ChairSpacing = 60,
			PoleSpacing = 200,
			Detachable = false,
			HasDoors = false,
			DoorOpenWidth = 0,
			PoleBodyRotationY = 180,
			SheaveRotationY = 0,
			StationRotation = 180,
			ChairRotationX = 0, ChairRotationY = -90, ChairRotationZ = 0,
			SeatTriggerYawOffsetDeg = 180,
			GuestSeatYawOffsetDeg = 180,
			NormalizeGuestSeatFacing = true,
			GuestSeatHeightOffsetAdd = 1.35,
			SurfaceTow = false,
			RideAnimation = "rbxassetid://180435571",
			MaxAngle = 50
		},
		["Fixed Grip Double"] = { 
			ID = 100000000006,
			ShowInMenu = true,
			Loadable = true,
			Category = "Lifts",
			Price = 125000,
			PricePerStud = 180,
			Type = "TwoPoint",
			Speed = 8.5,
			Capacity = 2,
			ChairSpacing = 45,
			PoleSpacing = 135,
			Detachable = false,
			HasDoors = false,
			DoorOpenWidth = 0,
			PoleBodyRotationY = 180,
			SheaveRotationY = -180,
			StationRotation = 180,
			ChairRotationX = 0, ChairRotationY = -90, ChairRotationZ = 0,
			SurfaceTow = false,
			RideAnimation = "rbxassetid://180435571",
			MaxAngle = 45
		},
		["Gondola"] = {
			ID = 100000000007,
			ShowInMenu = true,
			Loadable = true,
			Category = "Lifts",
			Price = 1650000,
			PricePerStud = 850,
			Type = "TwoPoint",
			UseLODChair = true,
			Speed = 20,
			StationSpeed = 0.095,
			Capacity = 6,
			ChairSpacing = 115,
			PoleSpacing = 425,
			Detachable = true,

			-- Dynamic Node Triggers & Smoothing
			DecelNode = "A1", DecelDelay = 0, DecelRate = 13,
			AccelNode = "A2", AccelDelay = 0, AccelRate = 11.5,

			HasDoors = true,
			DoorOpenWidth = 1.25,
			DoorOpenAxis = "Z",
			DoorLeftDirection = 1,
			DoorRightDirection = -1,
			DoorOutwardAmount = 0.45,
			DoorOutwardAxis = "X",
			DoorOutwardDirection = 1,
			DoorOpenNode = "A1", DoorOpenDelay = 19,
			DoorCloseNode = "B2", DoorCloseDelay = 25,

			PoleBodyRotationY = 0,
			SheaveRotationY = -90,
			StationRotation = 0,
			ChairRotationX = 0, ChairRotationY = 0, ChairRotationZ = 0,
			SurfaceTow = false,
			RideAnimation = "rbxassetid://180435571",
			MaxAngle = 55
		},
		["6 Person Bubble Lift"] = {
			ID = 2500000,
			ShowInMenu = true,
			Loadable = true,
			Category = "Lifts",
			Price = 1750000,
			PricePerStud = 720,
			Type = "TwoPoint",
			Speed = 18.375,
			StationSpeed = 0.275,
			Capacity = 6,
			ChairSpacing = 105,
			PoleSpacing = 350,
			Detachable = true,

			-- Dynamic Node Triggers & Smoothing
			DecelNode = "F1", DecelDelay = 46, DecelRate = 16.5,
			AccelNode = "G2", AccelDelay = 17, AccelRate = 15,

			HasDoors = false,
			DoorOpenWidth = 1.8,
			HasBubbleBar = true,
			EnableBarClosing = false,
			EnableBubbleClosing = false,
			SeatHeightOffset = 0,
			SeatTriggerYawOffsetDeg = 180,
			GuestSeatYawOffsetDeg = 180,
			GuestSeatHeightOffsetAdd = 2,
			NormalizeGuestSeatFacing = true,
			BarOpenInStation = true,
			BarRotateAxis = "Z",
			BarCloseAngle = 52,
			BarHingeOffset = Vector3.new(-0.6, 1.2, -0.2),
			BarUsePivotAsHinge = false,
			BarCloseOffset = Vector3.new(0, -0.1, 0.4),
			BubbleRotateAxis = "X",
			BubbleCloseAngle = 45,
			BubbleHingeOffset = Vector3.new(0, 1.5, -3.5),
			BubbleCloseOffset = Vector3.new(0, -0.4, 2.1),
			BubbleBarLerpSpeed = 1.2,
			PoleBodyRotationY = 180,
			SheaveRotationY = -90,
			StationRotation = -180,
			ChairRotationX = 180, ChairRotationY = 0, ChairRotationZ = 0,
			GripHeight = 0,
			SurfaceTow = false,
			RideAnimation = "rbxassetid://180435571",
			MaxAngle = 55
		},
		["HS4"] = {
			ID = 100000000008,
			ShowInMenu = true,
			Loadable = true,
			Category = "Lifts",
			Price = 780000,
			PricePerStud = 600,
			Type = "TwoPoint",
			Speed = 18.375,
			StationSpeed = 0.275,
			Capacity = 4,
			ChairSpacing = 85,
			PoleSpacing = 350,
			Detachable = true,

			-- Dynamic Node Triggers & Smoothing
			DecelNode = "G1", DecelDelay = 0, DecelRate = 13,
			AccelNode = "G2", AccelDelay = 0, AccelRate = 12,

			HasDoors = false,
			DoorOpenWidth = 1.8,
			PoleBodyRotationY = 180,
			SheaveRotationY = -180,
			StationRotation = -180,
			ChairRotationX = 0, ChairRotationY = 180, ChairRotationZ = 0,
			SurfaceTow = false,
			RideAnimation = "rbxassetid://180435571",
			MaxAngle = 55
		},
		["Fixed Grip Quad"] = {
			ID = 100000000009,
			ShowInMenu = true,
			Loadable = true,
			Category = "Lifts",
			Price = 285000,
			PricePerStud = 300,
			Type = "TwoPoint",
			Speed = 8.5,
			Capacity = 4,
			ChairSpacing = 45,
			PoleSpacing = 120,
			Detachable = false,
			HasDoors = false,
			DoorOpenWidth = 1.8,
			PoleBodyRotationY = -180,
			SheaveRotationY =-180,
			StationRotation = 180,
			ChairRotationX = 0, ChairRotationY = -90, ChairRotationZ = 90,
			SurfaceTow = false,
			RideAnimation = "rbxassetid://180435571",
			MaxAngle = 45
		},
		["Magic Carpet"] = {
			ID = 100000000040,
			ShowInMenu = true,
			Loadable = true,
			Category = "Lifts",
			Price = 8000,
			PricePerStud = 18,
			Type = "Carpet",
			Speed = 3.5,
			Capacity = 1,
			ChairSpacing = 8,
			StationRotation = 0,
			ChairRotationX = 0, ChairRotationY = 90, ChairRotationZ = 0,
			SurfaceTow = false,
			TerrainBlend = true,
			RideAnimation = "rbxassetid://180435571",
			MaxAngle = 12,
			-- Carpet terrain placement rules: only smooth/flat ground allowed.
			-- MaxTerrainRoughness: max height jump (studs) between adjacent samples before rejection.
			-- SmoothBumpThreshold: bumps smaller than this (studs) get auto-flattened by the server.
			MaxTerrainRoughness = 8,
			SmoothBumpThreshold = 3,
		},

		-- // 🏠 BUILDINGS // START NEW ONES WITH 11
		["Small Cabin (Dark)"] = { ID = 100000000010, ShowInMenu = true, Loadable = true, Category = "Buildings", Price = 5000, Type = "House", Capacity = 4 },
		["Medium Cabin (Dark)"] = { ID = 100000000011, ShowInMenu = true, Loadable = true, Category = "Buildings", Price = 15000, Type = "House", Capacity = 6, NightWindowMaterial = "Neon" },
		["Medium Cabin (Light)"] = { ID = 110000000000, ShowInMenu = true, Loadable = true, Category = "Buildings", Price = 15000, Type = "House", Capacity = 6, NightWindowMaterial = "Neon" },--11...00 ALREADY EXISTS HERE: START FROM 11...01
		["Large Cabin (Dark)"] = { ID = 100000000012, ShowInMenu = true, Loadable = true, Category = "Buildings", Price = 65000, Type = "House", Capacity = 10 },
		["Small Cabin (Light)"] = { ID = 100000000013, ShowInMenu = true, Loadable = true, Category = "Buildings", Price = 5000, Type = "House", Capacity = 4 },
		["Large Cabin (Light)"] = { ID = 100000000014, ShowInMenu = true, Loadable = true, Category = "Buildings", Price = 65000, Type = "House", Capacity = 12 },
		["Large Hotel (Dark)"] = { ID = 100000000090, ShowInMenu = true, Loadable = true, Category = "Buildings", Price = 78000, Type = "House", Capacity = 30 },

		-- // 🛠️ CUSTOM BLOCKS // START NEW ONES WITH 16
		["Builder Block"] = { ID = 160000000000, ShowInMenu = false, Loadable = true, Category = "Buildings", Price = 120, Type = "CustomBlock" },
		["Builder Cylinder"] = { ID = 160000000001, ShowInMenu = false, Loadable = true, Category = "Buildings", Price = 120, Type = "CustomBlock" },
		["Builder Sphere"] = { ID = 160000000002, ShowInMenu = false, Loadable = true, Category = "Buildings", Price = 120, Type = "CustomBlock" },
		["Builder Wedge"] = { ID = 160000000003, ShowInMenu = false, Loadable = true, Category = "Buildings", Price = 120, Type = "CustomBlock" },
		["Builder Corner Wedge"] = { ID = 160000000004, ShowInMenu = false, Loadable = true, Category = "Buildings", Price = 120, Type = "CustomBlock" },

		-- // 🍔 FOOD & RENTAL //START NEW ONES WITH 12
		["Small Restaurant"] = { ID = 100000000015, ShowInMenu = true, Loadable = true, Category = "Buildings", Price = 11500, Type = "Food" },
		["Medium Restaurant (Light)"] = { ID = 100000000016, ShowInMenu = true, Loadable = true, Category = "Buildings", Price = 56000, Type = "Food" },
		["Rental Shop"] = { ID = 100000000017, ShowInMenu = true, Loadable = true, Category = "Buildings", Price = 9000, Type = "Rental", NightWindows = true, NightWindowMaterial = "Neon" },
		["Medium Restaurant (Dark)"] = { ID = 120000000000, ShowInMenu = true, Loadable = true, Category = "Buildings", Price = 56000, Type = "Food" },
		["Prinoth Bison"] = { ID = 120000000001, ShowInMenu = false, Loadable = false, Category = "Buildings", Price = 72000, Type = "Vehicle" },
		["Large Restaurant"] = { ID = 120000000002, ShowInMenu = true, Loadable = true, Category = "Buildings", Price = 62000, Type = "Food" },
		["Snack Bar"] = { ID = 120000000003, ShowInMenu = true, Loadable = true, Category = "Buildings", Price = 6500, Type = "Food" },
		["Big Ticket Office"] = { ID = 120000000004, ShowInMenu = true, Loadable = true, Category = "Buildings", Price = 9500, Type = "TicketOffice" },
		["Snowcat Garage"] = { ID = 120000000005, ShowInMenu = true, Loadable = true, Category = "Buildings", Price = 16500, Type = "SnowcatGarage" },
		["Med Center"] = { ID = 120000000006, ShowInMenu = true, Loadable = true, Category = "Buildings", Price = 11250, Type = "MedCenter" },
		["Ski Patrol Hut"] = { ID = 120000000007, ShowInMenu = true, Loadable = true, Category = "Buildings", Price = 7800, Type = "PatrolHut" },

		-- // 🎄 DECOR //START NEW ONES WITH 13
		["Tree 1"] = { ID = 100000000018, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 350, Type = "Static" },
		["Small Floodlight"] = { ID = 100000000029, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 350, Type = "Static" },
		["360 Floodlight"] = { ID = 100000000030, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 350, Type = "Static" },
		["Net"] = { ID = 100000000031, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 50, Type = "Static" },
		["Tree 2"] = { ID = 100000000019, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 350, Type = "Static" },
		["Snowy Tree 1"] = { ID = 100000000020, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 350, Type = "Static" },
		["Snowy Tree 2"] = { ID = 100000000021, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 350, Type = "Static" },
		["Slow Sign"] = { ID = 100000000023, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 450, Type = "Static" },
		["Load Sign"] = { ID = 100000000024, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 450, Type = "Static" },
		["Unload Sign"] = { ID = 100000000025, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 450, Type = "Static" },
		["Avalanche Danger"] = { ID = 100000000026, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 450, Type = "Static" },
		["Boundary Sign"] = { ID = 100000000027, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 450, Type = "Static" },
		["Conveyor"] = { ID = 100000000028, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 6000, Type = "Static" },
		--["Raise Bar Here"] = { ID = 130000000005, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 250, Type = "Static" },
		["Lift Closed"] = { ID = 130000000006, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 250, Type = "Static" },
		--["Must Unload"] = { ID = 130000000007, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 250, Type = "Static" },
		--["Arrow"] = { ID = 130000000008, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 250, Type = "Static" },
		--["Family Zone"] = { ID = 130000000009, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 250, Type = "Static" },
		 ["10ft Swine Tower"] = { ID = 130000000011, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 12000, Type = "Static", PlacementYawOffset = 180 },
		["15ft Swine Tower"] = { ID = 130000000015, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 17000, Type = "Static", PlacementYawOffset = 180 },
		--["Skua-30"] = { ID = 130000000016, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 10500, Type = "Static" },

		["SnowGun"] = { ID = 130000000018, ShowInMenu = false, Loadable = true, Category = "Decor", Price = 25000, Type = "Static" },
		["Bench 1"] = { ID = 130000000019, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 750, Type = "Static" },
		["Picnic Table"] = { ID = 130000000020, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 1250, Type = "Static" },
		["Dev Statue"] = { ID = 130000000222, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 10000000000, Type = "Static" },
		["Beta Chair 1"] = { ID = 130000000021, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 5000, Type = "Static" },
		["Beta Chair 2"] = { ID = 130000000022, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 5000, Type = "Static" },
		["Trash Bin"] = { ID = 130000000023, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 1000, Type = "Static" },
		["Double Trash Bin"] = { ID = 130000000024, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 1500, Type = "Static" },
		["Ski Rack"] = { ID = 130000000025, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 1750, Type = "Static" },
		["Control Gate Blue"] = { ID = 130000000026, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 50, Type = "Static" },
		["Control Gate Red"] = { ID = 130000000027, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 50, Type = "Static" },
		["Bench 2"] = { ID = 130000000028, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 750, Type = "Static" },
		["Bench 3"] = { ID = 130000000029, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 750, Type = "Static" },
		["Bench 4"] = { ID = 130000000030, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 750, Type = "Static" },
		["Bench 5"] = { ID = 130000000031, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 750, Type = "Static" },
		--["Stoat-6"] = { ID = 130000000032, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 9000, Type = "Static" },
		--["Stoat-10"] = { ID = 130000000033, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 12500, Type = "Static" },
		["SnowCannon"] = { ID = 130000000034, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 11500, Type = "Static" },
		["Mogul"] = { ID = 130000000035, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 75, Type = "Static", PlacementMode = "SlopeDownhill" },
		["Campfire"] = { ID = 130000000036, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 175, Type = "Static" },
		["Quad Light Pole"] = { ID = 130000000037, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 500, Type = "Static" },
		["Flagged Light Pole"] = { ID = 130000000052, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 600, Type = "Static", ForceUprightBase = true },
		["aXess Gate"] = { ID = 130000000041, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 3500, Type = "Static", TerrainBlend = true },
		["aXess Quad Gate"] = { ID = 130000000042, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 6200, Type = "Static", TerrainBlend = true },
		["Ramp"] = { ID = 130000000038, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 350, Type = "Static", PlacementMode = "SlopeDownhill", UprightOnSlope = true, TerrainBlend = false },
		["Ski Rail"] = { ID = 130000000039, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 500, Type = "Static", PlacementMode = "SlopeDownhill", TerrainBlend = false },
		["Tall Pole"] = { ID = 130000000045, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 125, Type = "Static", PlacementMode = "SlopeDownhill", UprightOnSlope = true, TerrainBlend = false },
		["Short Pole"] = { ID = 130000000046, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 85, Type = "Static", PlacementMode = "SlopeDownhill", UprightOnSlope = true, TerrainBlend = false },
		["Short Rail"] = { ID = 130000000047, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 250, Type = "Static", PlacementMode = "SlopeDownhill", UprightOnSlope = true, TerrainBlend = false },
		["Simple Box"] = { ID = 130000000048, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 175, Type = "Static", PlacementMode = "SlopeDownhill", UprightOnSlope = true, TerrainBlend = false },
		["Box /w Hump"] = { ID = 130000000049, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 225, Type = "Static", PlacementMode = "SlopeDownhill", UprightOnSlope = true, TerrainBlend = false },
		["Tent"] = { ID = 130000000050, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 450, Type = "Static", ForceUprightBase = true },
		["Long Rail"] = { ID = 130000000051, ShowInMenu = false, Loadable = true, Category = "Decor", Price = 350, Type = "Static", PlacementMode = "SlopeDownhill", UprightOnSlope = true, TerrainBlend = false },
		["Rock 1"] = { ID = 130000000040, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 50, Type = "Static", PlacementMode = "SlopeDownhill" },
		["Metal Fence"] = { ID = 130000000043, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 400, Type = "Static" },
		["GL1TCHT3CK"] = { ID = 130000000044, ShowInMenu = true, Loadable = true, Category = "Decor", Price = 400000, Type = "Static", AllowedUsers = {"GL1TCHT3CK", "AndersBrodd"} },

		["Concrete Path"] = {
			ID = 130000000003,
			ShowInMenu = true,
			Loadable = true,
			Category = "Decor",
			Price = 700,
			PricePerStud = 20,
			Type = "Slope",
			IsPath = true
		},
		["Queue Path"] = {
			ID = 130000000099,
			ShowInMenu = true,
			Loadable = true,
			Category = "Slopes",
			Price = 500,
			PricePerStud = 15,
			Type = "Slope",
			IsQueue = true
		},
		-- // ⛷️ SLOPES //START NEW ONES WITH 14
		["Green Slope"] = { ID = 140000000000, ShowInMenu = true, Loadable = true, Category = "Slopes", Price = 1100, PricePerStud = 22, Type = "Slope", Difficulty = 1 },
		["Blue Slope"] = { ID = 140000000001, ShowInMenu = true, Loadable = true, Category = "Slopes", Price = 3200, PricePerStud = 42, Type = "Slope", Difficulty = 2 },
		["Black Slope"] = { ID = 140000000002, ShowInMenu = true, Loadable = true, Category = "Slopes", Price = 9500, PricePerStud = 85, Type = "Slope", Difficulty = 3 },
		["Double Black Slope"] = { ID = 140000000003, ShowInMenu = true, Loadable = true, Category = "Slopes", Price = 19000, PricePerStud = 145, Type = "Slope", Difficulty = 4 },
		["Triple Black Slope"] = { ID = 140000000004, ShowInMenu = true, Loadable = true, Category = "Slopes", Price = 32000, PricePerStud = 210, Type = "Slope", Difficulty = 5 },
		["Glade"] = { ID = 140000000005, ShowInMenu = true, Loadable = true, Category = "Slopes", Price = 6000, PricePerStud = 62, Type = "Slope", Difficulty = 2 },
	}
}

Config.DiscountAttributeByBucket = {
	Lifts = "ResearchDiscount_Lifts",
	Slopes = "ResearchDiscount_Slopes",
	Buildings = "ResearchDiscount_Buildings",
	Snow = "ResearchDiscount_Snow",
}
Config.IncomeBonusAttribute = "ResearchIncomeBonus"
Config.GlobalBuildCostScalar = 0.92 -- Economy tuning knob: lowers global placement/build costs to keep progression moving

local SNOW_ITEM_NAMES = {
	["10ft Swine Tower"] = true,
	["15ft Swine Tower"] = true,
	["Skua-30"] = true,
	["Stoat-6"] = true,
	["Stoat-10"] = true,
	["SnowCannon"] = true,
	["SnowGun"] = true,
	["10ft Narwhal Tower"] = true,
	["15ft Narwhal Tower"] = true,
	["20ft Narwhal Tower"] = true,
}

local EXCLUDED_SLOPE_ITEMS = {
	["Concrete Path"] = true,
	["Queue Path"] = true,
}

function Config.GetDiscountBucket(itemName, itemConfig)
	itemConfig = itemConfig or Config.Items[itemName]
	if not itemConfig then return nil end

	if tostring(itemConfig.Category or "") == "Lifts" then
		return "Lifts"
	end

	if SNOW_ITEM_NAMES[itemName] then
		return "Snow"
	end

	if itemConfig.Type == "Slope" and not EXCLUDED_SLOPE_ITEMS[itemName] then
		return "Slopes"
	end

	if tostring(itemConfig.Category or "") == "Buildings" and itemConfig.Type ~= "CustomBlock" and itemConfig.Type ~= "Vehicle" then
		return "Buildings"
	end

	return nil
end

function Config.GetResearchDiscountForPlayer(player, itemName, itemConfig)
	local bucket = Config.GetDiscountBucket(itemName, itemConfig)
	if not bucket or typeof(player) ~= "Instance" then
		return 0
	end
	local attrName = Config.DiscountAttributeByBucket[bucket]
	local value = tonumber(player:GetAttribute(attrName)) or 0
	return math.clamp(value, 0, 0.45)
end

function Config.ApplyDiscount(amount, discount)
	local numericAmount = tonumber(amount) or 0
	local numericDiscount = math.clamp(tonumber(discount) or 0, 0, 0.45)
	return math.max(0, math.floor((numericAmount * (1 - numericDiscount)) + 0.5))
end

function Config.GetPlacementCost(itemName, player, distanceStuds)
	local itemConfig = Config.Items[itemName]
	if not itemConfig then
		return 0
	end
	local basePrice = math.max(0, tonumber(itemConfig.Price) or 0)
	local perStud = math.max(0, tonumber(itemConfig.PricePerStud) or 0)
	local variableDistance = math.max(0, tonumber(distanceStuds) or 0)
	local scalar = math.max(0.1, tonumber(Config.GlobalBuildCostScalar) or 1)
	local scaledBasePrice = basePrice * scalar
	local scaledPerStud = perStud * scalar
	local grossCost = scaledBasePrice + (variableDistance * scaledPerStud)
	local discount = Config.GetResearchDiscountForPlayer(player, itemName, itemConfig)
	
	if itemName == "Tester Statues" and typeof(player) == "Instance" and player:IsA("Player") then
		if player:GetAttribute("IsTester") then
			return 0
		end
	end
	
	return Config.ApplyDiscount(grossCost, discount)
end

function Config.GetPlacementPriceDetails(itemName, player, distanceStuds)
	local itemConfig = Config.Items[itemName]
	if not itemConfig then
		return {
			BasePrice = 0,
			PricePerStud = 0,
			DistanceStuds = 0,
			GrossCost = 0,
			Discount = 0,
			DiscountPercent = 0,
			DiscountedBasePrice = 0,
			DiscountedPricePerStud = 0,
			FinalCost = 0,
			Bucket = nil,
		}
	end

	local basePrice = math.max(0, tonumber(itemConfig.Price) or 0)
	local perStud = math.max(0, tonumber(itemConfig.PricePerStud) or 0)
	local variableDistance = math.max(0, tonumber(distanceStuds) or 0)
	local scalar = math.max(0.1, tonumber(Config.GlobalBuildCostScalar) or 1)
	local scaledBasePrice = basePrice * scalar
	local scaledPerStud = perStud * scalar
	local grossCost = scaledBasePrice + (variableDistance * scaledPerStud)
	local discount = Config.GetResearchDiscountForPlayer(player, itemName, itemConfig)
	local finalCost = Config.ApplyDiscount(grossCost, discount)

	local isFreeTester = false
	if itemName == "Tester Statues" and typeof(player) == "Instance" and player:IsA("Player") then
		if player:GetAttribute("IsTester") then
			finalCost = 0
			isFreeTester = true
		end
	end

	return {
		BasePrice = scaledBasePrice,
		PricePerStud = scaledPerStud,
		DistanceStuds = variableDistance,
		GrossCost = grossCost,
		Discount = discount,
		DiscountPercent = math.floor((discount * 100) + 0.5),
		DiscountedBasePrice = isFreeTester and 0 or Config.ApplyDiscount(scaledBasePrice, discount),
		DiscountedPricePerStud = Config.ApplyDiscount(scaledPerStud, discount),
		FinalCost = finalCost,
		Bucket = Config.GetDiscountBucket(itemName, itemConfig),
	}
end

function Config.ShouldTerrainBlend(itemName, itemConfig)
	itemConfig = itemConfig or Config.Items[itemName]
	if type(itemConfig) ~= "table" then
		return true
	end
	if itemConfig.TerrainBlend == nil then
		return true
	end
	return itemConfig.TerrainBlend == true
end

function Config.ShouldUseNightWindows(itemName, itemConfig)
	itemConfig = itemConfig or Config.Items[itemName]
	if type(itemConfig) ~= "table" then
		return false
	end
	if itemConfig.NightWindows ~= nil then
		return itemConfig.NightWindows == true
	end
	return tostring(itemConfig.Type or "") == "House"
end

function Config.GetNightWindowMaterial(itemName, itemConfig)
	itemConfig = itemConfig or Config.Items[itemName]
	if type(itemConfig) ~= "table" then
		return nil
	end
	local materialName = itemConfig.NightWindowMaterial
	if type(materialName) ~= "string" or materialName == "" then
		return nil
	end
	return materialName
end

Config.ItemsById = {}
Config.ItemNameById = {}
Config.DuplicateItemIds = {}
Config.LegacyIdToSaveId = {}

local CATEGORY_ID_PREFIX = {
	Lifts = "LIFT",
	Buildings = "BLDG",
	Decor = "DECO",
	Slopes = "SLOPE",
}

local function normalizeItemIdKey(rawId)
	if rawId == nil then
		return nil
	end

	local valueType = typeof(rawId)
	if valueType == "number" then
		return tostring(math.floor(rawId + 0.5))
	end

	local text = tostring(rawId)
	text = text:gsub("^%s+", ""):gsub("%s+$", "")
	if text == "" then
		return nil
	end
	return text
end

function Config.GetSaveId(itemName, itemConfig)
	itemConfig = itemConfig or Config.Items[itemName]
	if type(itemConfig) ~= "table" then
		return nil
	end

	local explicitSaveId = normalizeItemIdKey(itemConfig.SaveID)
	if explicitSaveId then
		return explicitSaveId
	end

	local legacyId = normalizeItemIdKey(itemConfig.ID)
	if not legacyId then
		return nil
	end

	local prefix = CATEGORY_ID_PREFIX[tostring(itemConfig.Category or "")] or "ITEM"
	return string.format("%s-%s", prefix, legacyId)
end

function Config.GetItemById(rawId)
	local idKey = normalizeItemIdKey(rawId)
	if not idKey then
		return nil, nil
	end

	local entry = Config.ItemsById[idKey]
	if type(entry) == "table" then
		return entry.Name, entry.Config
	end

	return nil, nil
end

function Config.ResolveItem(itemName, rawId)
	local directConfig = nil
	if type(itemName) == "string" then
		directConfig = Config.Items[itemName]
	end

	local resolvedName, resolvedConfig = Config.GetItemById(rawId)
	if directConfig and resolvedConfig and directConfig ~= resolvedConfig then
		return itemName, directConfig, "name_conflict"
	end
	if resolvedConfig then
		return resolvedName, resolvedConfig, "id"
	end
	if directConfig then
		return itemName, directConfig, "name"
	end

	return nil, nil, nil
end

function Config.ValidateUniqueItemIds()
	Config.ItemsById = {}
	Config.ItemNameById = {}
	Config.DuplicateItemIds = {}
	Config.LegacyIdToSaveId = {}

	local duplicatesFound = false

	local function registerId(idKey, itemName, itemConfig)
		if not idKey then
			return
		end
		local existing = Config.ItemsById[idKey]
		if existing == nil then
			Config.ItemsById[idKey] = {
				Name = itemName,
				Config = itemConfig,
			}
			Config.ItemNameById[idKey] = itemName
		elseif type(existing) == "table" then
			duplicatesFound = true
			Config.DuplicateItemIds[idKey] = { existing.Name, itemName }
			Config.ItemsById[idKey] = false
			Config.ItemNameById[idKey] = nil
		else
			duplicatesFound = true
			local names = Config.DuplicateItemIds[idKey] or {}
			table.insert(names, itemName)
			Config.DuplicateItemIds[idKey] = names
		end
	end

	for itemName, itemConfig in pairs(Config.Items) do
		local legacyId = normalizeItemIdKey(itemConfig.ID)
		local saveId = Config.GetSaveId(itemName, itemConfig)
		if legacyId then
			registerId(legacyId, itemName, itemConfig)
			itemConfig.LegacyID = legacyId
		end
		local extraLegacyIds = {}
		if type(itemConfig.LegacyIDs) == "table" then
			for _, rawLegacyId in ipairs(itemConfig.LegacyIDs) do
				local normalizedLegacyId = normalizeItemIdKey(rawLegacyId)
				if normalizedLegacyId and normalizedLegacyId ~= legacyId then
					table.insert(extraLegacyIds, normalizedLegacyId)
					registerId(normalizedLegacyId, itemName, itemConfig)
				end
			end
		end
		itemConfig.LegacyIDs = extraLegacyIds
		if saveId then
			registerId(saveId, itemName, itemConfig)
			itemConfig.SaveID = saveId
			if legacyId then
				Config.LegacyIdToSaveId[legacyId] = saveId
			end
			for _, normalizedLegacyId in ipairs(extraLegacyIds) do
				Config.LegacyIdToSaveId[normalizedLegacyId] = saveId
			end
		end
	end

	if duplicatesFound then
	end

	return not duplicatesFound
end

local itemCount = 0
for key, value in pairs(Config.Items) do
	itemCount = itemCount + 1
end
Config.ValidateUniqueItemIds()

return Config