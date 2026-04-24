-- CableConfig
-- ReplicatedStorage
-- Settings for the 3D Cable System

local CableConfig = {
	-- // VISUALS //
	Thickness = 0.2,            -- How thick the wire is (studs)
	Color = Color3.fromRGB(30, 30, 30), -- Dark Grey/Black
	Material = Enum.Material.Metal,

	-- // PHYSICS / SAG //
	-- NEW: "Natural" sag scales with distance.
	-- 0.035 = 3.5% of length. (100 stud span = 3.5 studs sag)
	SagRatio = 0.035,           

	-- Fallback for fixed curve segments (if not specified)
	SagAmount = 1.5,            

	SegmentsPerSpan = 20,       -- Visual quality

	-- // OPTIMIZATION //
	MinDistanceForSag = 15,     -- Spans shorter than this are forced straight
}

return CableConfig