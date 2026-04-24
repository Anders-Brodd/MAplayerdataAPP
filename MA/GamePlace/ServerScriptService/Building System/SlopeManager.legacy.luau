--[=[ PATH: ServerScriptService/Building System/SlopeManager_Terrain | TYPE: Script ]=]--
--[[
	TERRAIN SLOPE SYSTEM V15
	DOES: Handles server-side generation, placement, merging, and modification of slopes, paths, and glades directly onto existing terrain. Connects to the economy system for purchases and tracks terrain/tree alterations for undo functions. 
	OLD SCRIPT DID:
	- ZERO terrain generation: the mountain IS the slope
	- NO air clearing: eliminates bumps/holes from terrain cuts
	- Only cleared trees along the path corridor
	- Nets followed terrain slope angle (not flat/horizontal)
	- Markers, nets, signs placed on terrain surface
	- Continuous safety nets with overlap
	- Per-slope decor options (markers, nets, marker lights)
	ADDED/REMOVED:
	- Updated version string in logs and comments to V15.
	- Added `GetSlopeData` function definition before it is exported globally to prevent script errors.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Config = require(ReplicatedStorage:WaitForChild("Config"))
local SlopeMath = require(ReplicatedStorage:WaitForChild("Shop"):WaitForChild("SlopeMath"))

local Events = ReplicatedStorage:WaitForChild("Events")
local TrackDeletedTree = Events:FindFirstChild("TrackDeletedTree")
local NotificationEvent = Events:FindFirstChild("NotificationEvent")
local RequestBuildingSave = Events:FindFirstChild("RequestBuildingSave")
if RequestBuildingSave and not RequestBuildingSave:IsA("BindableEvent") then
	RequestBuildingSave:Destroy()
	RequestBuildingSave = nil
end
if not RequestBuildingSave then
	RequestBuildingSave = Instance.new("BindableEvent")
	RequestBuildingSave.Name = "RequestBuildingSave"
	RequestBuildingSave.Parent = Events
end

local RemoveItemInternal = nil

task.spawn(function()
	local removalScript = ServerScriptService:FindFirstChild("RemovalServer", true)
	if removalScript then
		RemoveItemInternal = removalScript:WaitForChild("RemoveItemInternal", 10)
	end
end)

local MoneySystem, TransactionFunc
task.spawn(function()
	while not MoneySystem do
		MoneySystem = ServerScriptService:FindFirstChild("Server") and ServerScriptService.Server:FindFirstChild("MoneyServer") or ServerScriptService:FindFirstChild("MoneyServer", true)
		task.wait(1)
	end
	TransactionFunc = MoneySystem:WaitForChild("RequestTransaction")
end)

local terrain = Workspace.Terrain

local function isUnlockedByResearch(player, itemName)
	local checker = ServerStorage:FindFirstChild("Research_CheckUnlock")
	if not checker or not checker:IsA("BindableFunction") then
		return true
	end

	local ok, allowed = pcall(function()
		return checker:Invoke(player, itemName)
	end)
	if not ok then
		return false
	end
	return allowed == true
end

local CONFIG = {
	DEFAULT_WIDTH = 90,
	MIN_WIDTH = 30,
	MAX_WIDTH = 160,

	POINT_DENSITY = 4,
	SMOOTHING_ITERATIONS = 4,          -- reduced from 6; less smoothing = fewer bumps
	RESAMPLE_SPACING = 4,
	VERTICAL_SMOOTHING_ITERATIONS = 4, -- reduced from 10; was over-smoothing and creating oscillations
	MAX_VERTICAL_STEP = 1.2,           -- slightly more permissive so it doesn't fight terrain
	MAX_VERTICAL_RATIO = 0.85,         -- reduced from 1.2; prevents big Y jumps between points
	SURFACE_OFFSET = 0.0,              -- ZERO offset; sit directly on terrain

	-- ═══════════════════════════════════════════════════════
	-- FLUSH MODE: minimal terrain generation
	-- The slope is just a thin snow skin on the existing mountain
	-- ═══════════════════════════════════════════════════════

	-- V13: NO terrain generation. The mountain IS the slope.
	-- We only clear air above the path to clean up bumps and remove trees.
	RIBBON_ENABLED = false,            -- no snow FillBlock at all
	RIBBON_OVERLAP = 1.5,
	EDGE_BLEND_ENABLED = false,        -- no edge fills
	SHOULDER_ENABLED = false,
	UNDERFILL_ENABLED = false,
	EDGE_LIP_ENABLED = false,
	EDGE_WALL_CLEAR_ENABLED = false,

	-- V14: Air clear DISABLED - was cutting holes/bumps into terrain
	-- The mountain surface is the slope; we only need tree clearing.
	AIR_CLEAR_ENABLED = false,
	AIR_CLEAR_HEIGHT = 2.0,
	AIR_CLEAR_MARGIN = 0.6,

	SEGMENT_SAMPLE_STUDS = 6,
	YIELD_EVERY_SEGMENTS = 12,
	MARKER_YIELD_EVERY = 12,
	NET_YIELD_EVERY = 10,
	HITBOX_YIELD_EVERY = 16,

	-- Path generation: tighter terrain following
	PATH_TERRAIN_SMOOTH_PASSES = 3,    -- reduced from 6
	PATH_TERRAIN_MICRO_PASSES = 1,     -- reduced from 2
	PATH_TERRAIN_FOLLOW_BLEND = 0.9,   -- higher = follows terrain more closely (was 0.72)
	PATH_FINAL_TERRAIN_PULL = 1.0,     -- full pull to terrain (was 0.9)
	PATH_MAX_HEIGHT_ABOVE_TERRAIN = 0.0, -- ZERO lift above terrain (was 0.12)

	NET_HEIGHT = 8,
	NET_THICKNESS = 0.32,
	NET_OVERLAP = 3.2,
	NET_STRIDE = 1,
	NET_SAMPLE_DISTANCE = 12,
	NET_MIN_SEGMENT = 6,
	NET_MAX_SEGMENT_FACTOR = 1.9,
	NET_MIN_TANGENT_DOT = 0.2,
	NET_POLE_GRID = 3.0,
	NET_SEGMENT_GRID = 6.0,
	NET_SNOW_EMBED_DEPTH = 0.2,

	AUTO_PATH_MIN_DIRECT_ANGLE = 30,
	AUTO_PATH_MAX_SWITCH_AMPLITUDE = 70,

	MARKER_LIGHT_COLOR = Color3.fromRGB(255, 205, 145),
	MARKER_LIGHT_BRIGHTNESS = 1.25,
	MARKER_LIGHT_RANGE = 13,

	MAX_SAVED_PATH_POINTS = 1400,
	MAX_SAVED_CONTROL_POINTS = 240,
	MAX_ATTR_JSON_CHARS = 180000,
	MAX_INPUT_CONTROL_POINTS = 2200,
	MAX_INPUT_WIDTH_POINTS = 512,
	MAX_ABS_COORD = 200000,
	PLACE_RATE_LIMIT_SECONDS = 0.9,

	SURFACE_MATERIAL = Enum.Material.Snow,

	COLORS = {
		Green = Color3.fromRGB(76, 209, 55),
		Blue = Color3.fromRGB(52, 152, 219),
		Black = Color3.fromRGB(44, 62, 80),
		DoubleBlack = Color3.fromRGB(255, 215, 0),
		TripleBlack = Color3.fromRGB(44, 62, 80),
		Glade = Color3.fromRGB(80, 160, 60),
	},

	MARKER_SPACING = {
		Green = 28,
		Blue = 32,
		Black = 38,
		["Double Black"] = 42,
		["Triple Black"] = 48,
		["Glade"] = 30,
	},

	DECOR_DEFAULTS = {
		Green = { markers = false, nets = true, markerLights = false },
		Blue = { markers = false, nets = true, markerLights = false },
		Black = { markers = true, nets = false, markerLights = true },
		["Double Black"] = { markers = true, nets = false, markerLights = true },
		["Triple Black"] = { markers = true, nets = false, markerLights = true },
		["Glade"] = { markers = true, nets = false, markerLights = false },
	},
}

local SlopeRegistry = {}
_G.SlopeRegistry = SlopeRegistry
local slopePlaceCooldownByUserId = {}
local SlopePathCache = setmetatable({}, { __mode = "k" })
local SlopeWidthDataCache = setmetatable({}, { __mode = "k" })

local function ForgetSlopeModel(model)
	if not model then
		return
	end
	for i = #SlopeRegistry, 1, -1 do
		if SlopeRegistry[i].Model == model then
			table.remove(SlopeRegistry, i)
		end
	end
	SlopePathCache[model] = nil
	SlopeWidthDataCache[model] = nil
end

local function IsFiniteNumber(value)
	return type(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
end

local function ToFiniteNumber(value)
	local n = tonumber(value)
	if not IsFiniteNumber(n) then
		return nil
	end
	return n
end

local function IsCoordInBounds(x, y, z)
	local maxAbs = CONFIG.MAX_ABS_COORD
	return math.abs(x) <= maxAbs and math.abs(y) <= maxAbs and math.abs(z) <= maxAbs
end

local function DecimatePoints(points, maxPoints)
	if not points then return {} end
	if #points <= maxPoints then return points end
	local out = {}
	for i = 1, maxPoints do
		local t = (i - 1) / (maxPoints - 1)
		local idx = math.floor(t * (#points - 1)) + 1
		table.insert(out, points[idx])
	end
	return out
end

local function SerializePoints(points)
	local packed = {}
	for _, v in ipairs(points) do
		table.insert(packed, {v.X, v.Y, v.Z})
	end
	return packed
end

local function FlatDistance(a, b)
	return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end

local function GetPathDirectionFlat(pathPoints, index)
	if not pathPoints or #pathPoints < 2 then
		return Vector3.zAxis
	end
	index = math.clamp(index, 1, #pathPoints)
	local prev = pathPoints[math.max(1, index - 1)]
	local nxt = pathPoints[math.min(#pathPoints, index + 1)]
	local d = nxt - prev
	local flat = Vector3.new(d.X, 0, d.Z)
	if flat.Magnitude < 0.001 then
		return Vector3.zAxis
	end
	return flat.Unit
end

local function EncodeArrayWithBudget(entries, maxChars)
	if not entries or #entries == 0 then
		return "[]", 0
	end

	local budget = math.max(8000, tonumber(maxChars) or CONFIG.MAX_ATTR_JSON_CHARS)
	local arr = entries
	local json = HttpService:JSONEncode(arr)
	if #json <= budget then
		return json, #arr
	end

	local keep = #arr
	while keep > 128 do
		keep = math.floor(keep * 0.75)
		local sampled = {}
		local step = math.max(1, math.ceil(#arr / keep))
		for i = 1, #arr, step do
			table.insert(sampled, arr[i])
		end
		arr = sampled
		json = HttpService:JSONEncode(arr)
		if #json <= budget then
			return json, #arr
		end
	end
	return json, #arr
end

local function EncodeArrayToChunks(entries, maxChars)
	if not entries or #entries == 0 then
		return {"[]"}
	end

	local budget = math.max(8000, tonumber(maxChars) or CONFIG.MAX_ATTR_JSON_CHARS)
	local chunks = {}
	local currentPieces = {}
	local currentLen = 2

	local function flushChunk()
		if #currentPieces == 0 then
			return
		end
		table.insert(chunks, "[" .. table.concat(currentPieces, ",") .. "]")
		currentPieces = {}
		currentLen = 2
	end

	for _, entry in ipairs(entries) do
		local piece = HttpService:JSONEncode(entry)
		local extra = #piece
		if #currentPieces > 0 then
			extra += 1
		end
		if (currentLen + extra) > budget and #currentPieces > 0 then
			flushChunk()
		end
		table.insert(currentPieces, piece)
		currentLen += extra
	end

	flushChunk()
	if #chunks == 0 then
		table.insert(chunks, "[]")
	end
	return chunks
end

local TERRAIN_PARAMS = RaycastParams.new()
TERRAIN_PARAMS.FilterType = Enum.RaycastFilterType.Include
TERRAIN_PARAMS.FilterDescendantsInstances = {Workspace.Terrain}
TERRAIN_PARAMS.IgnoreWater = true

local function GetTerrainSample(x, z)
	local hit = Workspace:Raycast(Vector3.new(x, 5000, z), Vector3.new(0, -10000, 0), TERRAIN_PARAMS)
	if hit then
		return hit.Position, hit.Normal
	end
	return Vector3.new(x, 0, z), Vector3.yAxis
end

local function GetTerrainHeight(x, z)
	local hitPos = GetTerrainSample(x, z)
	return hitPos.Y
end

local function SafeUnit(v, fallback)
	if v.Magnitude > 1e-4 then
		return v.Unit
	end
	return fallback or Vector3.yAxis
end

local function ProjectOnPlane(v, normal)
	return v - normal * v:Dot(normal)
end

local function GenerateAutoControlPoints(startPos, endPos, difficulty)
	if not startPos or not endPos then
		return {startPos, endPos}
	end

	local horizontalDist = Vector3.new(endPos.X - startPos.X, 0, endPos.Z - startPos.Z).Magnitude
	if horizontalDist < 1 then
		return {startPos, endPos}
	end

	local drop = startPos.Y - endPos.Y
	if drop <= 0 then
		return {startPos, endPos}
	end
	local directAngle = math.deg(math.atan(math.abs(drop) / horizontalDist))
	local wantsWiggle = (difficulty == "Black" or difficulty == "Double Black" or difficulty == "Triple Black")
	if directAngle < CONFIG.AUTO_PATH_MIN_DIRECT_ANGLE and not wantsWiggle then
		return {startPos, endPos}
	end

	local targetAngles = {
		Green = 12,
		Blue = 20,
		Black = 30,
		["Double Black"] = 40,
	}
	local targetAngle = targetAngles[difficulty] or 25
	local safeTan = math.max(0.2, math.tan(math.rad(targetAngle)))
	local requiredHorizontal = math.abs(drop) / safeTan
	local extraHorizontal = math.max(0, requiredHorizontal - horizontalDist)
	if extraHorizontal < 10 and not wantsWiggle then
		return {startPos, endPos}
	end
	if extraHorizontal < 10 and wantsWiggle then
		extraHorizontal = 10
	end

	local mainDir = Vector3.new(endPos.X - startPos.X, 0, endPos.Z - startPos.Z).Unit
	local perpDir = mainDir:Cross(Vector3.yAxis)
	if perpDir.Magnitude < 0.001 then
		perpDir = Vector3.xAxis
	else
		perpDir = perpDir.Unit
	end

	local numSegments = math.clamp(math.ceil(extraHorizontal / 85), 2, 12)
	local switchAmplitude = math.clamp(extraHorizontal / (numSegments * 1.35), 12, CONFIG.AUTO_PATH_MAX_SWITCH_AMPLITUDE)
	local side = 1
	local out = {startPos}

	for i = 1, numSegments - 1 do
		local t = i / numSegments
		local smoothT = t * t * (3 - 2 * t)
		local base = startPos:Lerp(endPos, t)
		local y = startPos.Y + (endPos.Y - startPos.Y) * smoothT
		local lateral = perpDir * switchAmplitude * side * math.sin(t * math.pi)
		local px = base.X + lateral.X
		local pz = base.Z + lateral.Z
		local py = math.min(y, GetTerrainHeight(px, pz))
		table.insert(out, Vector3.new(px, py, pz))
		side = -side
	end

	table.insert(out, endPos)
	return out
end

local function InterpolateWidth(widthData, index, totalPoints, minWidth)
	minWidth = minWidth or CONFIG.MIN_WIDTH
	if not widthData or #widthData == 0 then
		return CONFIG.DEFAULT_WIDTH
	end
	if #widthData == 1 then
		return math.clamp(widthData[1].width, minWidth, CONFIG.MAX_WIDTH)
	end

	local prev, nxt
	for _, wd in ipairs(widthData) do
		if wd.index <= index then prev = wd end
		if wd.index >= index and not nxt then nxt = wd end
	end
	if not prev then return widthData[1].width end
	if not nxt then return widthData[#widthData].width end
	if prev.index == nxt.index then return prev.width end

	local t = (index - prev.index) / (nxt.index - prev.index)
	t = t * t * (3 - 2 * t)
	local w = prev.width + (nxt.width - prev.width) * t
	return math.clamp(w, minWidth, CONFIG.MAX_WIDTH)
end

local function AverageWidth(widthData, minWidth)
	minWidth = minWidth or CONFIG.MIN_WIDTH
	if not widthData or #widthData == 0 then return CONFIG.DEFAULT_WIDTH end
	local sum = 0
	for _, wd in ipairs(widthData) do
		sum += wd.width
	end
	return math.clamp(sum / #widthData, minWidth, CONFIG.MAX_WIDTH)
end

local function CatmullRom(t, p0, p1, p2, p3)
	local t2 = t * t
	local t3 = t2 * t
	return 0.5 * (
		(2 * p1) +
			(-p0 + p2) * t +
			(2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
			(-p0 + 3 * p1 - 3 * p2 + p3) * t3
	)
end

local function GaussianSmooth(points)
	if #points < 3 then return points end
	local out = { points[1] }
	for i = 2, #points - 1 do
		out[i] = points[i - 1] * 0.25 + points[i] * 0.5 + points[i + 1] * 0.25
	end
	out[#points] = points[#points]
	return out
end

local function SmoothScalarSeries(values, passes)
	if not values or #values < 3 then
		return values
	end
	local out = table.clone(values)
	for _ = 1, math.max(1, passes or 1) do
		local nextValues = table.clone(out)
		for i = 2, #out - 1 do
			nextValues[i] = (out[i - 1] + out[i] * 2 + out[i + 1]) * 0.25
		end
		out = nextValues
	end
	return out
end

local function ResamplePath(points, spacing)
	if #points < 2 then return points end
	spacing = math.max(2, spacing or CONFIG.RESAMPLE_SPACING)

	local out = { points[1] }
	local anchor = points[1]
	local accumulated = 0

	for i = 2, #points do
		local current = points[i]
		local segment = current - anchor
		local segLen = segment.Magnitude
		if segLen < 0.001 then
			continue
		end

		local dir = segment.Unit
		while accumulated + segLen >= spacing do
			local need = spacing - accumulated
			local sample = anchor + dir * need
			table.insert(out, sample)
			anchor = sample
			segment = current - anchor
			segLen = segment.Magnitude
			if segLen < 0.001 then
				break
			end
			dir = segment.Unit
			accumulated = 0
		end

		accumulated += segLen
		anchor = current
	end

	if (out[#out] - points[#points]).Magnitude > 0.5 then
		table.insert(out, points[#points])
	end

	return out
end

local function SmoothVertical(path)
	if #path < 3 then return path end
	local current = path
	for _ = 1, CONFIG.VERTICAL_SMOOTHING_ITERATIONS do
		local nextPath = { current[1] }
		for i = 2, #current - 1 do
			local prev = current[i - 1]
			local p = current[i]
			local nxt = current[i + 1]
			local avgY = (prev.Y + p.Y * 2 + nxt.Y) * 0.25
			local y = p.Y + (avgY - p.Y) * 0.45  -- reduced blend factor from 0.55
			local horizontal = Vector3.new(p.X - nextPath[i - 1].X, 0, p.Z - nextPath[i - 1].Z).Magnitude
			local maxStep = math.max(CONFIG.MAX_VERTICAL_STEP, horizontal * CONFIG.MAX_VERTICAL_RATIO)
			local clampedY = nextPath[i - 1].Y + math.clamp(y - nextPath[i - 1].Y, -maxStep, maxStep)
			nextPath[i] = Vector3.new(p.X, clampedY, p.Z)
		end
		nextPath[#current] = current[#current]
		current = nextPath
	end
	return current
end

-- ═══════════════════════════════════════════════════════
-- V12 PATH GENERATION: Direct terrain following
-- The path hugs the terrain surface exactly. No lifting.
-- ═══════════════════════════════════════════════════════
local function GenerateSmoothPath(controlPoints)
	if #controlPoints < 2 then return controlPoints end

	-- Keep authored control polyline: pre-smoothing corners used to collapse sharp turns into near-straight chords.
	local clean = controlPoints

	-- Ground every control point to terrain
	local grounded = {}
	for _, cp in ipairs(clean) do
		local y = GetTerrainHeight(cp.X, cp.Z)
		table.insert(grounded, Vector3.new(cp.X, y, cp.Z))
	end

	-- Interpolate between control points
	local path = {}
	if #grounded == 2 then
		local dist = (grounded[2] - grounded[1]).Magnitude
		local steps = math.max(1, math.ceil(dist / CONFIG.POINT_DENSITY))
		for i = 0, steps do
			table.insert(path, grounded[1]:Lerp(grounded[2], i / steps))
		end
	else
		for i = 1, #grounded - 1 do
			local p0 = grounded[math.max(1, i - 1)]
			local p1 = grounded[i]
			local p2 = grounded[i + 1]
			local p3 = grounded[math.min(#grounded, i + 2)]
			local segDist = (p2 - p1).Magnitude
			local steps = math.max(1, math.ceil(segDist / CONFIG.POINT_DENSITY))
			for step = 0, steps - 1 do
				local pos = CatmullRom(step / steps, p0, p1, p2, p3)
				table.insert(path, Vector3.new(pos.X, GetTerrainHeight(pos.X, pos.Z), pos.Z))
			end
		end
		table.insert(path, grounded[#grounded])
	end

	-- Light smoothing (fewer passes when the polyline has tight corners)
	local maxTurn = 0
	if #grounded >= 3 then
		for i = 2, #grounded - 1 do
			local a, b, c = grounded[i - 1], grounded[i], grounded[i + 1]
			local v1 = Vector3.new(a.X - b.X, 0, a.Z - b.Z)
			local v2 = Vector3.new(c.X - b.X, 0, c.Z - b.Z)
			if v1.Magnitude > 0.05 and v2.Magnitude > 0.05 then
				local dot = math.clamp(v1.Unit:Dot(v2.Unit), -1, 1)
				maxTurn = math.max(maxTurn, math.deg(math.acos(dot)))
			end
		end
	end
	local smoothPasses = CONFIG.SMOOTHING_ITERATIONS
	if maxTurn >= 55 then
		smoothPasses = math.min(smoothPasses, 1)
	elseif maxTurn >= 35 then
		smoothPasses = math.min(smoothPasses, 2)
	end
	for _ = 1, smoothPasses do
		path = GaussianSmooth(path)
	end

	-- Resample to even spacing
	path = ResamplePath(path, CONFIG.RESAMPLE_SPACING)

	-- Smooth vertical profile (fewer passes now)
	path = SmoothVertical(path)

	-- Get smoothed terrain heights for reference
	local terrainHeights = {}
	for i, p in ipairs(path) do
		terrainHeights[i] = GetTerrainHeight(p.X, p.Z)
	end
	terrainHeights = SmoothScalarSeries(terrainHeights, CONFIG.PATH_TERRAIN_SMOOTH_PASSES)

	-- FINAL PASS: Snap every point directly onto terrain
	-- No offset, no lifting. The path IS the terrain surface.
	local final = {}
	local prevY = nil
	for i, p in ipairs(path) do
		local terrainY = terrainHeights[i] or GetTerrainHeight(p.X, p.Z)
		local targetY = terrainY  -- no offset added

		-- Gentle vertical rate limiting to prevent micro-bumps
		if prevY then
			local horizontal = Vector3.new(
				p.X - final[i - 1].X,
				0,
				p.Z - final[i - 1].Z
			).Magnitude
			local maxStep = math.max(CONFIG.MAX_VERTICAL_STEP, horizontal * CONFIG.MAX_VERTICAL_RATIO)
			targetY = prevY + math.clamp(targetY - prevY, -maxStep, maxStep)
		end

		final[i] = Vector3.new(p.X, targetY, p.Z)
		prevY = targetY
	end

	-- One more light vertical smooth
	final = SmoothVertical(final)

	-- Final terrain snap: ensure nothing floats
	for i, p in ipairs(final) do
		local rawTerrainY = GetTerrainHeight(p.X, p.Z)
		-- Allow the path to be at terrain or very slightly below (for the snow ribbon)
		-- but NEVER above terrain
		local maxY = rawTerrainY
		if p.Y > maxY then
			final[i] = Vector3.new(p.X, maxY, p.Z)
		end
	end

	return final
end

local function ClearTreesInBox(cframe, regionSize, treeSnapshot)
	local treeFolder = Workspace:FindFirstChild("TreeFolder")
	if not treeFolder then return end

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.FilterDescendantsInstances = {treeFolder}

	local parts = Workspace:GetPartBoundsInBox(cframe, regionSize, overlapParams)
	local cleared = {}
	for _, part in ipairs(parts) do
		local current = part
		while current and current.Parent and current.Parent ~= treeFolder do
			current = current.Parent
		end
		if current and current.Parent == treeFolder and not cleared[current] then
			cleared[current] = true
			local pivot = current:GetPivot()
			table.insert(treeSnapshot, {
				Name = current.Name,
				CF = {pivot:GetComponents()},
			})
			if TrackDeletedTree then
				TrackDeletedTree:Fire(nil, pivot.Position.X, pivot.Position.Z)
			end
			current:Destroy()
		end
	end
end

-- ═══════════════════════════════════════════════════════
-- V13 CARVE: NO terrain generation at all
-- The mountain is already the slope. We just:
-- 1. Clear trees along the path
-- 2. Optionally clear air above the path to remove bumps
-- That's it. No snow ribbons, no fills, no blocks.
-- ═══════════════════════════════════════════════════════
local function CarveSlope(pathPoints, widthData, isPath, skipTreeClear)

	local terrainLog = {}
	local treeSnapshot = {}
	local previousRight = nil
	local doAirClear = CONFIG.AIR_CLEAR_ENABLED ~= false

	for i = 1, #pathPoints - 1 do
		local p1 = pathPoints[i]
		local p2 = pathPoints[i + 1]
		local segment = p2 - p1
		local segmentDist = segment.Magnitude
		local flatSegment = Vector3.new(segment.X, 0, segment.Z)
		local flatDist = flatSegment.Magnitude
		if flatDist < 0.001 or segmentDist < 0.001 then
			continue
		end

		local segmentDir = segment.Unit
		local flatDir = flatSegment.Unit
		if flatDir.Magnitude < 0.001 then
			flatDir = Vector3.zAxis
		else
			flatDir = flatDir.Unit
		end
		local right = flatDir:Cross(Vector3.yAxis)
		if right.Magnitude < 0.001 then
			right = Vector3.xAxis
		else
			right = right.Unit
		end
		if previousRight and right:Dot(previousRight) < 0 then
			right = -right
		end
		previousRight = right

		local width = InterpolateWidth(widthData, i, #pathPoints)
		local mid = (p1 + p2) * 0.5
		local surfaceY = (p1.Y + p2.Y) * 0.5
		local lookPos = Vector3.new(mid.X, surfaceY, mid.Z)
		local lookAt = lookPos + segmentDir

		-- Clear trees along the corridor (skip for Glades — they preserve world trees)
		if not skipTreeClear then
			local treeRegionCF = CFrame.lookAt(lookPos, lookAt)
			ClearTreesInBox(treeRegionCF, Vector3.new(width + 12, 36, segmentDist + 8), treeSnapshot)
		end

		if isPath then
			-- Paint the ground Concrete without changing geometry by stepping along the segment
			local steps = math.ceil(segmentDist / 4)
			for j = 0, steps do
				local pt = p1:Lerp(p2, j/steps)
				-- We need the ground Y at this exact point to center the replacement brush
				local ptY = GetTerrainHeight(pt.X, pt.Z) or pt.Y

				local rMin = Vector3.new(pt.X - (width/2), ptY - 4, pt.Z - (width/2))
				local rMax = Vector3.new(pt.X + (width/2), ptY + 4, pt.Z + (width/2))
				local region = Region3.new(
					Vector3.new(math.min(rMin.X, rMax.X), math.min(rMin.Y, rMax.Y), math.min(rMin.Z, rMax.Z)),
					Vector3.new(math.max(rMin.X, rMax.X), math.max(rMin.Y, rMax.Y), math.max(rMin.Z, rMax.Z))
				):ExpandToGrid(4)

				terrain:ReplaceMaterial(region, 4, Enum.Material.Snow, Enum.Material.Concrete)
				if j % 12 == 0 then
					task.wait()
				end
			end

			table.insert(terrainLog, {
				P1 = {p1.X, p1.Y, p1.Z},
				P2 = {p2.X, p2.Y, p2.Z},
				Width = width,
				Type = "ConcretePaint",
			})
		elseif doAirClear then
			local clearHeight = CONFIG.AIR_CLEAR_HEIGHT or 2.0
			local clearMargin = CONFIG.AIR_CLEAR_MARGIN or 0.6
			local clearCF = CFrame.lookAt(
				Vector3.new(mid.X, surfaceY + clearHeight * 0.5, mid.Z),
				Vector3.new(mid.X, surfaceY + clearHeight * 0.5, mid.Z) + segmentDir
			)
			local clearSize = Vector3.new(
				width + clearMargin,
				clearHeight,
				segmentDist + (CONFIG.RIBBON_OVERLAP or 1.5)
			)
			terrain:FillBlock(clearCF, clearSize, Enum.Material.Air)
			table.insert(terrainLog, {
				CF = {clearCF:GetComponents()},
				Size = {clearSize.X, clearSize.Y, clearSize.Z},
				Type = "AirClear",
			})
		end

		if CONFIG.YIELD_EVERY_SEGMENTS > 0 and i % CONFIG.YIELD_EVERY_SEGMENTS == 0 then
			task.wait()
		end
	end

	return terrainLog, treeSnapshot
end

local function FindDecorAsset(name)
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if assets then
		local decor = assets:FindFirstChild("Decor")
		if decor then
			local exact = decor:FindFirstChild(name)
			if exact then return exact end
		end
		local deep = assets:FindFirstChild(name, true)
		if deep then return deep end
	end

	local decorRoot = ReplicatedStorage:FindFirstChild("Decor")
	if decorRoot then
		local exact = decorRoot:FindFirstChild(name)
		if exact then return exact end
	end

	return nil
end

local function GetFirstPart(obj)
	if not obj then return nil end
	if obj:IsA("BasePart") then return obj end
	if obj:IsA("Model") then
		if obj.PrimaryPart then return obj.PrimaryPart end
		return obj:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function MakeStatic(obj, canCollide)
	if not obj then return end
	if obj:IsA("BasePart") then
		obj.Anchored = true
		obj.CanCollide = canCollide == true
		obj.CanQuery = false
		obj.CanTouch = false
		obj.Massless = true
		return
	end

	for _, d in ipairs(obj:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = canCollide == true
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
		end
	end
end

local function AddMarkerLight(part)
	if not part then return end
	if part:FindFirstChild("MarkerLight") then return end
	local light = Instance.new("PointLight")
	light.Name = "MarkerLight"
	light.Color = CONFIG.MARKER_LIGHT_COLOR
	light.Range = CONFIG.MARKER_LIGHT_RANGE
	light.Brightness = CONFIG.MARKER_LIGHT_BRIGHTNESS
	light.Shadows = false
	light.Parent = part
end

local function NormalizeDifficultyKey(difficultyName)
	if difficultyName == "Double Black" then
		return "DoubleBlack"
	end
	if difficultyName == "Triple Black" then
		return "TripleBlack"
	end
	return difficultyName
end

local function PlaceMarkers(pathPoints, difficultyName, container, widthData, decorOptions)
	if not decorOptions.markers then return end

	local diffKey = NormalizeDifficultyKey(difficultyName)
	local color = CONFIG.COLORS[diffKey] or CONFIG.COLORS.Green
	local spacing = CONFIG.MARKER_SPACING[difficultyName] or 30

	local markerNames = {
		Green = "GreenMarker",
		Blue = "BlueMarker",
		Black = "BlackMarker",
		["Double Black"] = "DoubleBlackMarker",
		["Triple Black"] = "BlackMarker",
		["Glade"] = "GreenMarker",
	}
	local markerTemplate = FindDecorAsset(markerNames[difficultyName] or "GreenMarker")
	local placedMarkers = 0

	for i = 1, #pathPoints, spacing do
		local pos = pathPoints[i]
		local nextIndex = math.min(i + 5, #pathPoints)
		local dir = (pathPoints[nextIndex] - pos)
		if dir.Magnitude < 0.001 then
			dir = Vector3.zAxis
		else
			dir = dir.Unit
		end
		local right = dir:Cross(Vector3.yAxis)
		if right.Magnitude < 0.01 then continue end
		right = right.Unit

		local halfWidth = InterpolateWidth(widthData, i, #pathPoints) * 0.5
		for side = -1, 1, 2 do
			local markerPos = pos + right * (halfWidth + 2) * side
			local y = GetTerrainHeight(markerPos.X, markerPos.Z)
			markerPos = Vector3.new(markerPos.X, y, markerPos.Z)

			if markerTemplate then
				local marker = markerTemplate:Clone()
				marker.Name = "SlopeMarker"
				local markerCF = CFrame.lookAt(markerPos, markerPos + dir)
				if marker:IsA("Model") then
					marker:PivotTo(markerCF)
				else
					marker.CFrame = markerCF
				end
				MakeStatic(marker, false)
				marker.Parent = container
				if decorOptions.markerLights then
					AddMarkerLight(GetFirstPart(marker))
				end
			else
				local pole = Instance.new("Part")
				pole.Name = "Marker"
				pole.Size = Vector3.new(0.5, 6, 0.5)
				pole.Position = markerPos + Vector3.new(0, 3, 0)
				pole.Anchored = true
				pole.CanCollide = false
				pole.Material = Enum.Material.SmoothPlastic
				pole.Color = color
				pole.Parent = container
				if decorOptions.markerLights then
					AddMarkerLight(pole)
				end
			end
			placedMarkers += 1
			if CONFIG.MARKER_YIELD_EVERY > 0 and placedMarkers % CONFIG.MARKER_YIELD_EVERY == 0 then
				task.wait()
			end
		end
	end
end

local function FindSlopeByUUID(uuid)
	local placed = Workspace:FindFirstChild("PlacedObjects")
	if not placed then return nil end
	for _, child in ipairs(placed:GetChildren()) do
		if child:GetAttribute("UUID") == uuid then return child end
	end
	return nil
end

local function QuickParsePath(model)
	local raw = model:GetAttribute("RawPoints")
	if not raw then return nil end
	local ok, data = pcall(function() return HttpService:JSONDecode(raw) end)
	if not ok or type(data) ~= "table" then return nil end
	local pts = {}
	for _, p in ipairs(data) do
		local x = p[1] or p.X or 0
		local y = p[2] or p.Y or 0
		local z = p[3] or p.Z or 0
		table.insert(pts, Vector3.new(x, y, z))
	end
	return pts
end

local function FindClosestPathPoint(path, pos)
	local bestIdx = 1
	local bestDist = math.huge
	for i, point in ipairs(path) do
		local dist = (point - pos).Magnitude
		if dist < bestDist then
			bestIdx = i
			bestDist = dist
		end
	end
	return bestIdx, bestDist
end

local function IsEndpoint(model, pos)
	local path = QuickParsePath(model)
	if not path or #path < 2 then return false end
	local _, dist = FindClosestPathPoint(path, pos)
	return dist < 8 or (path[1] - pos).Magnitude < 8 or (path[#path] - pos).Magnitude < 8
end

local function PlaceNets(pathPoints, difficultyName, container, widthData, decorOptions, connections)
	if not decorOptions.nets then return end
	if #pathPoints < 2 then return end
	
	local NET_TEXTURE_ID = "rbxassetid://112244699465288"
	local POLE_HEIGHT = 7
	local POLE_DIAMETER = 0.125
	local NET_HEIGHT = 5.5
	local NET_THICKNESS = 0.2
	local SPACING = 14 -- Spacing between poles
	local POLE_COLOR = Color3.fromRGB(255, 80, 0) -- Safety Orange

	-- Calculate trim for intersections
	local trimStart = 0
	local trimEnd = 0
	if connections then
		-- Always trim nets at connection points to prevent fence overlap.
		-- For T-junctions: trim by 60% of width to open the junction.
		-- For endpoint-to-endpoint merges: trim by 40% to avoid overlapping nets.
		if connections.Start then 
			local target = FindSlopeByUUID(connections.Start.UUID)
			if target and IsEndpoint(target, connections.Start.Position) then
				-- Endpoint merge: smaller trim to reduce overlap without leaving a gap
				trimStart = InterpolateWidth(widthData, 1, #pathPoints) * 0.4
			else
				-- T-junction: full trim to open the junction
				trimStart = InterpolateWidth(widthData, 1, #pathPoints) * 0.6 
			end
		end
		if connections.End then 
			local target = FindSlopeByUUID(connections.End.UUID)
			if target and IsEndpoint(target, connections.End.Position) then
				trimEnd = InterpolateWidth(widthData, #pathPoints, #pathPoints) * 0.4
			else
				trimEnd = InterpolateWidth(widthData, #pathPoints, #pathPoints) * 0.6 
			end
		end
	end

	local samplePath = ResamplePath(pathPoints, SPACING)
	if #samplePath < 2 then
		samplePath = table.clone(pathPoints)
	end

	
	local function getWidth(idx)
		return InterpolateWidth(widthData, idx, #pathPoints)
	end
	
	-- Calculate total length for end trimming
	local pathLen = 0
	local dists = {0}
	for i = 1, #samplePath-1 do
		pathLen = pathLen + (samplePath[i+1] - samplePath[i]).Magnitude
		dists[i+1] = pathLen
	end

	local polesL, polesR = {}, {}
	local prevRight = nil
	
	for i, pt in ipairs(samplePath) do
		-- Skip points in the trim zones
		if dists[i] < trimStart or dists[i] > (pathLen - trimEnd) then continue end

		local alpha = (i - 1) / math.max(1, #samplePath - 1)
		local idx = 1 + math.floor(alpha * (#pathPoints - 1))
		local pNext = samplePath[i+1]
		local pPrev = samplePath[i-1]
		local tan
		if pNext and pPrev then tan = (pNext - pPrev).Unit
		elseif pNext then tan = (pNext - pt).Unit
		elseif pPrev then tan = (pt - pPrev).Unit
		else tan = Vector3.zAxis end
		
		local right = tan:Cross(Vector3.yAxis).Unit
		if prevRight and right:Dot(prevRight) < 0 then right = -right end
		prevRight = right
		
		local hw = getWidth(idx) * 0.5 + 2
		local center = Vector3.new(pt.X, GetTerrainHeight(pt.X, pt.Z), pt.Z)
		local lPos = center - right * hw
		local rPos = center + right * hw
		
		if lPos then lPos = Vector3.new(lPos.X, GetTerrainHeight(lPos.X, lPos.Z), lPos.Z) end
		if rPos then rPos = Vector3.new(rPos.X, GetTerrainHeight(rPos.X, rPos.Z), rPos.Z) end
		
		table.insert(polesL, lPos or false)
		table.insert(polesR, rPos or false)
	end
	
	local function buildSide(points)
		local builtSegments = 0
		for i, pos in ipairs(points) do
			if not pos then continue end
			
			local pole = Instance.new("Part")
			pole.Name = "NetPole"
			pole.Shape = Enum.PartType.Cylinder
			pole.Size = Vector3.new(POLE_HEIGHT, POLE_DIAMETER, POLE_DIAMETER)
			pole.CFrame = CFrame.new(pos + Vector3.new(0, POLE_HEIGHT/2 - 1, 0)) * CFrame.Angles(0, 0, math.pi/2)
			pole.Anchored = true; pole.CanCollide = false; pole.Material = Enum.Material.Metal; pole.Color = POLE_COLOR
			pole.Parent = container
			
			if i > 1 and points[i-1] then
				local prev = points[i-1]
				local p1 = prev + Vector3.new(0, POLE_HEIGHT/2 - 1, 0)
				local p2 = pos + Vector3.new(0, POLE_HEIGHT/2 - 1, 0)
				local dist = (p2 - p1).Magnitude
				local mid = (p1 + p2) / 2
				
				local net = Instance.new("Part")
				net.Name = "SafetyNet"
				-- Rotated dimensions for correct texture mapping (90 degree fix)
				net.Size = Vector3.new(NET_HEIGHT, NET_THICKNESS, dist)
				net.CFrame = CFrame.lookAt(mid, p2) * CFrame.Angles(0, 0, math.pi/2)
				net.Anchored = true; net.CanCollide = true; net.Transparency = 1
				net.Parent = container
				
				for _, face in ipairs({Enum.NormalId.Top, Enum.NormalId.Bottom}) do
					local t = Instance.new("Texture")
					t.Texture = NET_TEXTURE_ID; t.Face = face; t.StudsPerTileU = 3; t.StudsPerTileV = 3; t.Transparency = 0.1; t.Parent = net
				end
				builtSegments += 1
				if CONFIG.NET_YIELD_EVERY > 0 and builtSegments % CONFIG.NET_YIELD_EVERY == 0 then
					task.wait()
				end
			end
		end
	end
	
	buildSide(polesL)
	buildSide(polesR)
end

local function PlaceSign(pathPoints, difficultyName, container, widthData)
	if #pathPoints < 2 then return end
	local diffKey = NormalizeDifficultyKey(difficultyName)
	local color = CONFIG.COLORS[diffKey] or CONFIG.COLORS.Green

	local startPos = pathPoints[1]
	local dir = (pathPoints[math.min(10, #pathPoints)] - startPos)
	if dir.Magnitude < 0.001 then dir = Vector3.zAxis else dir = dir.Unit end
	local right = dir:Cross(Vector3.yAxis)
	if right.Magnitude < 0.001 then return end
	right = right.Unit

	local width = InterpolateWidth(widthData, 1, #pathPoints)
	local signPos = startPos - right * (width * 0.5 + 8)
	local y = GetTerrainHeight(signPos.X, signPos.Z)
	signPos = Vector3.new(signPos.X, y, signPos.Z)

	local signNames = {
		Green = "Green Sign",
		Blue = "Blue Sign",
		Black = "Black Sign",
		["Double Black"] = "Double Black Sign",
		["Triple Black"] = "Double Black Sign",
		["Glade"] = "Green Sign",
	}
	local signAsset = FindDecorAsset(signNames[difficultyName] or "Green Sign")

	if signAsset then
		local sign = signAsset:Clone()
		sign.Name = "SlopeSign"

		-- Keep the sign upright and facing back up the hill toward incoming skiers.
		local flatDir = Vector3.new(dir.X, 0, dir.Z)
		if flatDir.Magnitude < 0.001 then
			flatDir = Vector3.zAxis
		else
			flatDir = flatDir.Unit
		end
		local facingDir = -flatDir
		local yaw = math.atan2(facingDir.X, facingDir.Z)

		-- Compute upright correction from Base part
		local uprightCorrection = CFrame.new()
		if sign:IsA("Model") then
			local basePart = sign:FindFirstChild("Base", true) or sign.PrimaryPart
			if basePart and basePart:IsA("BasePart") then
				local pivotCF = sign:GetPivot()
				local relRot = pivotCF.Rotation:Inverse() * basePart.CFrame.Rotation
				local currentUp = relRot.UpVector
				local dotVal = currentUp:Dot(Vector3.yAxis)
				if dotVal < 0.99 then
					local axis = currentUp:Cross(Vector3.yAxis)
					if axis.Magnitude > 0.001 then
						uprightCorrection = CFrame.fromAxisAngle(axis.Unit, math.acos(math.clamp(dotVal, -1, 1)))
					end
				end
			end
		end

		-- Calculate ground offset from bounding box AFTER applying correction
		local bottomOffset = 0
		if sign:IsA("Model") then
			local tempCF = CFrame.new(0, 500, 0) * CFrame.Angles(0, yaw, 0) * uprightCorrection
			sign:PivotTo(tempCF)
			local bbCF, bbSize = sign:GetBoundingBox()
			local pivotPos = sign:GetPivot().Position
			bottomOffset = pivotPos.Y - (bbCF.Position.Y - bbSize.Y/2)
		end

		local groundedPos = Vector3.new(signPos.X, signPos.Y + bottomOffset, signPos.Z)
		local signCF = CFrame.new(groundedPos, groundedPos + facingDir) * uprightCorrection
		if sign:IsA("Model") then sign:PivotTo(signCF) else sign.CFrame = signCF end
		MakeStatic(sign, false)
		sign.Parent = container

		-- Adding Hitbox for Deletion Tool
		local hitbox = Instance.new("Part")
		hitbox.Name = "Hitbox"
		hitbox.Size = Vector3.new(6, 10, 6)
		if sign:IsA("Model") then
			hitbox.CFrame = sign:GetPivot()
		else
			hitbox.CFrame = sign.CFrame
		end
		hitbox.Transparency = 1
		hitbox.CanCollide = false
		hitbox.CanQuery = true -- Allow raycasts to hit this sign
		hitbox.Anchored = true
		hitbox.Parent = sign
	else
		local post = Instance.new("Part")
		post.Name = "Post"
		post.Size = Vector3.new(0.8, 8, 0.8)
		post.Position = signPos + Vector3.new(0, 4, 0)
		post.Anchored = true
		post.CanCollide = false
		post.Material = Enum.Material.SmoothPlastic
		post.Color = Color3.fromRGB(100, 60, 30)
		post.Parent = container

		local board = Instance.new("Part")
		board.Name = "Board"
		board.Size = Vector3.new(4, 3, 0.4)
		board.CFrame = CFrame.lookAt(signPos + Vector3.new(0, 7, 0), signPos + Vector3.new(0, 7, 0) + dir)
		board.Anchored = true
		board.CanCollide = false
		board.Material = Enum.Material.SmoothPlastic
		board.Color = color
		board.Parent = container
	end
end

local function GetDifficulty(pathPoints)
	return SlopeMath.getDifficultyFromPath(pathPoints)
end

local function NormalizeDifficulty(rawDifficulty, pathPoints)
	local map = {
		[1] = "Green",
		[2] = "Blue",
		[3] = "Black",
		[4] = "Double Black",
		[5] = "Triple Black",
	}

	local difficulty = rawDifficulty
	if type(difficulty) == "number" then
		difficulty = map[difficulty] or "Green"
	end
	if difficulty == "Red" then difficulty = "Double Black" end
	if difficulty == "Glade" then return "Glade" end -- preserve Glade identity
	if not difficulty or difficulty == "Slope" or difficulty == "" then
		difficulty = GetDifficulty(pathPoints)
	end
	return difficulty
end

local function FlatDistance(a, b)
	return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end

local function BuildDecorOptions(difficulty, raw)
	local defaults = CONFIG.DECOR_DEFAULTS[difficulty] or CONFIG.DECOR_DEFAULTS.Green
	local opts = {
		markers = defaults.markers,
		nets = defaults.nets,
		markerLights = defaults.markerLights,
	}

	if type(raw) == "table" then
		local mode = raw.Mode or raw.mode
		if type(mode) == "string" then
			mode = string.lower(mode)
			if mode == "both" then
				opts.markers = true
				opts.nets = true
			elseif mode == "markers" then
				opts.markers = true
				opts.nets = false
			elseif mode == "nets" then
				opts.markers = false
				opts.nets = true
			elseif mode == "none" then
				opts.markers = false
				opts.nets = false
			end
		end
		if raw.markers ~= nil then opts.markers = raw.markers == true end
		if raw.nets ~= nil then opts.nets = raw.nets == true end
		if raw.markerLights ~= nil then opts.markerLights = raw.markerLights == true end
		if raw.MarkerLights ~= nil then opts.markerLights = raw.MarkerLights == true end
	end

	if opts.nets then
		opts.markers = false
		opts.markerLights = false
	end
	if not opts.markers then
		opts.markerLights = false
	end
	return opts
end

local function ParseControlPoints(points)
	local out = {}
	local maxPoints = math.max(2, CONFIG.MAX_INPUT_CONTROL_POINTS)
	for _, pt in ipairs(points) do
		if typeof(pt) == "Vector3" then
			local x, y, z = pt.X, pt.Y, pt.Z
			if IsFiniteNumber(x) and IsFiniteNumber(y) and IsFiniteNumber(z) and IsCoordInBounds(x, y, z) then
				table.insert(out, pt)
			end
		elseif type(pt) == "table" then
			local x = ToFiniteNumber(pt.X or pt[1])
			local y = ToFiniteNumber(pt.Y or pt[2])
			local z = ToFiniteNumber(pt.Z or pt[3])
			if x and y and z and IsCoordInBounds(x, y, z) then
				table.insert(out, Vector3.new(x, y, z))
			end
		end
	end
	if #out > maxPoints then
		out = DecimatePoints(out, maxPoints)
	end
	return out
end

local function ParseWidthData(rawWidthData, controlCount, pathCount, isPath)
	local parsed = {}
	local defWidth = isPath and 4 or CONFIG.DEFAULT_WIDTH
	local minWidth = isPath and 1 or CONFIG.MIN_WIDTH

	if type(rawWidthData) == "table" then
		for _, wd in ipairs(rawWidthData) do
			if #parsed >= CONFIG.MAX_INPUT_WIDTH_POINTS then
				break
			end
			if type(wd) == "table" then
				local srcIndex = ToFiniteNumber(wd.index or wd[1]) or 1
				local width = ToFiniteNumber(wd.width or wd[2]) or defWidth
				srcIndex = math.clamp(math.floor(srcIndex), 1, math.max(1, controlCount))
				width = math.clamp(width, minWidth, CONFIG.MAX_WIDTH)
				local t = (controlCount > 1) and ((srcIndex - 1) / (controlCount - 1)) or 0
				local dstIndex = math.floor(t * math.max(1, pathCount - 1) + 1)
				table.insert(parsed, { index = dstIndex, width = width })
			end
		end
	end

	if #parsed == 0 then
		parsed = {
			{ index = 1, width = defWidth },
			{ index = math.max(1, pathCount), width = defWidth },
		}
	end

	table.sort(parsed, function(a, b)
		return a.index < b.index
	end)

	return parsed
end

local function DecodePointsFromJson(rawPointsJson)
	if type(rawPointsJson) ~= "string" or rawPointsJson == "" then
		return nil
	end
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(rawPointsJson)
	end)
	if not ok or type(decoded) ~= "table" then
		return nil
	end
	local out = {}
	for _, pt in ipairs(decoded) do
		if type(pt) == "table" then
			local x = ToFiniteNumber(pt.X or pt[1])
			local y = ToFiniteNumber(pt.Y or pt[2])
			local z = ToFiniteNumber(pt.Z or pt[3])
			if x and y and z and IsCoordInBounds(x, y, z) then
				table.insert(out, Vector3.new(x, y, z))
			end
		end
	end
	if #out < 2 then
		return nil
	end
	return out
end

local function DecodeWidthDataFromJson(rawWidthJson, pathCount, isPath)
	if type(rawWidthJson) ~= "string" or rawWidthJson == "" then
		return nil
	end
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(rawWidthJson)
	end)
	if not ok or type(decoded) ~= "table" then
		return nil
	end

	local defWidth = isPath and 4 or CONFIG.DEFAULT_WIDTH
	local minWidth = isPath and 1 or CONFIG.MIN_WIDTH

	local parsed = {}
	for _, wd in ipairs(decoded) do
		if type(wd) == "table" then
			local idx = ToFiniteNumber(wd.index or wd[1]) or 1
			local width = ToFiniteNumber(wd.width or wd[2]) or defWidth
			idx = math.clamp(math.floor(idx), 1, math.max(1, pathCount))
			width = math.clamp(width, minWidth, CONFIG.MAX_WIDTH)
			table.insert(parsed, { index = idx, width = width })
		end
	end
	if #parsed == 0 then
		return nil
	end
	table.sort(parsed, function(a, b)
		return a.index < b.index
	end)
	return parsed
end

local function GetSlopePathFromModel(model)
	if not model or not model.Parent then
		return nil
	end
	if SlopePathCache[model] then
		return SlopePathCache[model]
	end
	for _, entry in ipairs(SlopeRegistry) do
		if entry.Model == model and type(entry.Path) == "table" and #entry.Path >= 2 then
			SlopePathCache[model] = entry.Path
			return entry.Path
		end
	end
	local parsed = DecodePointsFromJson(model:GetAttribute("RawPoints"))
	if parsed and #parsed >= 2 then
		SlopePathCache[model] = parsed
		return parsed
	end
	return nil
end

local function GetSlopeWidthDataFromModel(model, pathCount)
	local isPath = model and model:GetAttribute("IsPath") == true
	local defWidth = isPath and 4 or CONFIG.DEFAULT_WIDTH
	local minWidth = isPath and 1 or CONFIG.MIN_WIDTH

	if not model then
		return {
			{ index = 1, width = defWidth },
			{ index = math.max(1, pathCount), width = defWidth },
		}
	end
	if SlopeWidthDataCache[model] then
		return SlopeWidthDataCache[model]
	end
	for _, entry in ipairs(SlopeRegistry) do
		if entry.Model == model and type(entry.WidthData) == "table" and #entry.WidthData > 0 then
			SlopeWidthDataCache[model] = entry.WidthData
			return entry.WidthData
		end
	end
	local decoded = DecodeWidthDataFromJson(model:GetAttribute("WidthData"), pathCount, isPath)
	if decoded and #decoded > 0 then
		SlopeWidthDataCache[model] = decoded
		return decoded
	end
	local avgWidth = math.clamp(tonumber(model:GetAttribute("SlopeWidth")) or defWidth, minWidth, CONFIG.MAX_WIDTH)
	local fallback = {
		{ index = 1, width = avgWidth },
		{ index = math.max(1, pathCount), width = avgWidth },
	}
	SlopeWidthDataCache[model] = fallback
	return fallback
end

-- =============================================================================
-- GET SLOPE DATA
-- =============================================================================
local function GetSlopeData(model)
	if not model or not model:IsA("Model") then return nil end
	local path = GetSlopePathFromModel(model)
	if not path or #path < 2 then return nil end

	return {
		Path = path,
		WidthData = GetSlopeWidthDataFromModel(model, #path),
		Difficulty = model:GetAttribute("Difficulty") or "Green",
		IsPath = model:GetAttribute("IsPath") == true,
		IsQueue = model:GetAttribute("IsQueue") == true,
	}
end
_G.GetSlopeData = GetSlopeData

local function GetTargetSlopeInfo(model, junctionPos)
	if not model then return nil, nil end
	local path = GetSlopePathFromModel(model)
	if not path or #path < 2 then return nil, nil end

	local bestIdx = 1
	local bestDist = math.huge
	for i, p in ipairs(path) do
		local d = (p - junctionPos).Magnitude
		if d < bestDist then bestDist = d; bestIdx = i end
	end

	local pA = path[math.max(1, bestIdx - 1)]
	local pB = path[math.min(#path, bestIdx + 1)]
	local dir = (pB - pA).Unit
	local right = dir:Cross(Vector3.yAxis).Unit

	return right, path
end

local function HandleNetIntersections(newSlopeModel, newSlopePath, connections)
	if not connections then return end

	local function CreateNetBetweenPoles(pole1, pole2, container)
		if not pole1 or not pole2 or not container then return nil end

		local p1 = pole1.Position + Vector3.new(0, pole1.Size.X/2 - 1, 0)
		local p2 = pole2.Position + Vector3.new(0, pole2.Size.X/2 - 1, 0)

		local dist = (p2 - p1).Magnitude
		if dist < 1 or dist > 60 then return nil end

		local mid = (p1 + p2) / 2

		local net = Instance.new("Part")
		net.Name = "SafetyNet"
		net.Size = Vector3.new(5.5, 0.2, dist)
		net.CFrame = CFrame.lookAt(mid, p2) * CFrame.Angles(0, 0, math.pi/2)
		net.Anchored = true; net.CanCollide = true; net.Transparency = 1
		net.CollisionGroup = "SlopeNet"
		net.Parent = container

		local NET_TEXTURE_ID = "rbxassetid://112244699465288"
		for _, face in ipairs({Enum.NormalId.Top, Enum.NormalId.Bottom}) do
			local t = Instance.new("Texture")
			t.Texture = NET_TEXTURE_ID; t.Face = face; t.StudsPerTileU = 3; t.StudsPerTileV = 3; t.Transparency = 0.1; t.Parent = net
		end
		return net
	end

	local function IsMergeDecor(child)
		return child.Name == "NetPole"
			or child.Name == "SafetyNet"
			or child.Name == "Net"
			or child.Name == "SlopeMarker"
			or child.Name == "MarkerLight"
			or child.Name == "Post"
			or child.Name == "SlopeSign"
			or child.Name == "Marker"
			or child.Name == "Board"
	end

	local function ClearJunctionDecor(model, junctionPos, keepSet, clearRadius)
		if not model or not junctionPos then return end
		local radius = clearRadius or 16
		for _, child in ipairs(model:GetChildren()) do
			if keepSet and keepSet[child] then
				continue
			end
			if IsMergeDecor(child) then
				local childPos = child:IsA("BasePart") and child.Position or (child:IsA("Model") and child:GetPivot().Position or nil)
				if childPos and (childPos - junctionPos).Magnitude <= radius then
					child:Destroy()
				end
			end
		end
	end

	local function ClearMergeMouthDecor(model, junctionPos, alongDir, rightDir, halfWidth, keepSet, forwardDepth, sidePadding)
		if not model or not junctionPos or not alongDir or not rightDir then return end
		local depth = forwardDepth or 24
		local width = math.max(halfWidth or 0, 8)
		local padding = sidePadding or 6
		for _, child in ipairs(model:GetChildren()) do
			if keepSet and keepSet[child] then
				continue
			end
			if IsMergeDecor(child) then
				local childPos = child:IsA("BasePart") and child.Position or (child:IsA("Model") and child:GetPivot().Position or nil)
				if childPos then
					local offset = childPos - junctionPos
					local along = offset:Dot(alongDir)
					local side = math.abs(offset:Dot(rightDir))
					if along >= -18 and along <= depth and side <= (width + padding) then
						child:Destroy()
					end
				end
			end
		end
	end

	for connType, conn in pairs(connections) do
		if type(conn) ~= "table" or not conn.UUID or not conn.Position then continue end
		local targetModel = FindSlopeByUUID(conn.UUID)
		if targetModel then
			local isEndpointMerge = IsEndpoint(targetModel, conn.Position)
			local targetRight, targetPath = GetTargetSlopeInfo(targetModel, conn.Position)
			if not targetRight then continue end

			local backIdx = (connType == "Start") and math.min(#newSlopePath, 6) or math.max(1, #newSlopePath - 5)
			local approachVec = (conn.Position - newSlopePath[backIdx]).Unit
			local dot = approachVec:Dot(targetRight)
			local isRightSide = (dot < 0) -- Approaching from Right side (opposing Right vector)

			-- Find the target's width at the connector point using nearest-point tolerance so load-time drift doesn't break merges.
			local targetWidth = 30
			local targetWidthData = GetSlopeWidthDataFromModel(targetModel, #targetPath)
			if targetWidthData then
				local closestIdx, closestDist = FindClosestPathPoint(targetPath, conn.Position)
				if closestDist <= 14 then
					targetWidth = InterpolateWidth(targetWidthData, closestIdx, #targetPath)
				end
			end
			local targetHalfWidth = targetWidth * 0.5

			-- T-Junction logic
			local newJunctionPos = (connType == "Start") and newSlopePath[1] or newSlopePath[#newSlopePath]
			local newDir = (connType == "Start") and (newSlopePath[2] - newSlopePath[1]).Unit or (newSlopePath[#newSlopePath] - newSlopePath[#newSlopePath-1]).Unit
			local newRight = newDir:Cross(Vector3.yAxis)
			
			local newWidth = 30
			local newWidthData = GetSlopeWidthDataFromModel(newSlopeModel, #newSlopePath)
			if newWidthData then
				local wIdx = (connType == "Start") and 1 or #newSlopePath
				newWidth = InterpolateWidth(newWidthData, wIdx, #newSlopePath)
			end
			local newHalfWidth = newWidth * 0.5

			-- Compute ideal geometric corners at the junction for accurate target pole targeting
			local idealLeftJunction = newJunctionPos - newRight * newHalfWidth
			local idealRightJunction = newJunctionPos + newRight * newHalfWidth

			local newPoleL, newPoleR
			local closestL_distSq, closestR_distSq = math.huge, math.huge

			for _, p in ipairs(newSlopeModel:GetChildren()) do
				if p.Name == "NetPole" then
					local distSq = (p.Position - newJunctionPos).Magnitude^2
					if (p.Position - newJunctionPos):Dot(newRight) < 0 then -- Left side
						if distSq < closestL_distSq then newPoleL = p; closestL_distSq = distSq end
					else -- Right side
						if distSq < closestR_distSq then newPoleR = p; closestR_distSq = distSq end
					end
				end
			end

			if newPoleL and newPoleR then
				local targetPoleL, targetPoleR
				local closestTargetL_distSq, closestTargetR_distSq = math.huge, math.huge

				for _, p in ipairs(targetModel:GetChildren()) do
					if p.Name == "NetPole" then
						-- Filter poles to correct side to prevent crossing the slope
						local vecToPole = p.Position - conn.Position
						local sideDist = vecToPole:Dot(targetRight)
						local validSide = false
						if isEndpointMerge then
							validSide = true
						elseif isRightSide then
							validSide = sideDist > targetHalfWidth * 0.5
						else
							validSide = sideDist < -targetHalfWidth * 0.5
						end

						if validSide then
							local distL = (p.Position - idealLeftJunction).Magnitude^2
							local distR = (p.Position - idealRightJunction).Magnitude^2
							if distL < closestTargetL_distSq then targetPoleL = p; closestTargetL_distSq = distL end
							if distR < closestTargetR_distSq then targetPoleR = p; closestTargetR_distSq = distR end
						end
					end
				end

				if targetPoleL and targetPoleR then
					if targetPoleL == targetPoleR then
						-- The new slope is perfectly aligned such that its ideal width resolves to a single target pole
						-- We must clear it to open the gap.
						-- Keep the shared endpoint pole in place and only clear the overlapping approach decor.
						local keepSet = {}
						if newPoleL then keepSet[newPoleL] = true end
						if newPoleR then keepSet[newPoleR] = true end
						do
							local junctionClearRadius = math.max(14, math.min(26, newWidth * 0.65))
							local mergeHalfWidth = math.max(newHalfWidth, targetHalfWidth)
							ClearJunctionDecor(newSlopeModel, newJunctionPos, keepSet, junctionClearRadius)
							ClearJunctionDecor(targetModel, conn.Position, keepSet, junctionClearRadius)
							ClearMergeMouthDecor(newSlopeModel, newJunctionPos, newDir, newRight, mergeHalfWidth, keepSet, 40, 14)
							ClearMergeMouthDecor(targetModel, conn.Position, targetDir, targetRight, mergeHalfWidth, keepSet, 44, 14)
						end
					else
						local bridgeLeft = CreateNetBetweenPoles(newPoleL, targetPoleL, newSlopeModel)
						local bridgeRight = CreateNetBetweenPoles(newPoleR, targetPoleR, newSlopeModel)
						local keepSet = {}
						if newPoleL then keepSet[newPoleL] = true end
						if newPoleR then keepSet[newPoleR] = true end
						if targetPoleL then keepSet[targetPoleL] = true end
						if targetPoleR then keepSet[targetPoleR] = true end
						if bridgeLeft then keepSet[bridgeLeft] = true end
						if bridgeRight then keepSet[bridgeRight] = true end

						local clearCenter = (targetPoleL.Position + targetPoleR.Position) / 2
						local clearVector = targetPoleR.Position - targetPoleL.Position
						local clearHalfDist = clearVector.Magnitude / 2
						local clearDir = clearVector.Unit
						for _, p in ipairs(targetModel:GetChildren()) do
							if IsMergeDecor(p) and p ~= targetPoleL and p ~= targetPoleR then
								local pp = p:IsA("Model") and p:GetPivot().Position or p.Position
								local alongVec = pp - clearCenter
								local dotProj = alongVec:Dot(clearDir)
								local perpDist = (alongVec - clearDir * dotProj).Magnitude
								if math.abs(dotProj) < clearHalfDist + 4 and perpDist < 20 then
									p:Destroy()
								end
							end
						end

						do
							local jctClearRadius = math.max(14, math.min(26, (newPoleL.Position - newPoleR.Position).Magnitude * 0.65))
							local mergeHalfWidth = math.max(newHalfWidth, targetHalfWidth)
							ClearJunctionDecor(newSlopeModel, newJunctionPos, keepSet, jctClearRadius)
							ClearJunctionDecor(targetModel, conn.Position, keepSet, jctClearRadius)
							ClearMergeMouthDecor(newSlopeModel, newJunctionPos, newDir, newRight, mergeHalfWidth, keepSet, 40, 14)
							ClearMergeMouthDecor(targetModel, conn.Position, targetDir, targetRight, mergeHalfWidth, keepSet, 44, 14)
						end
					end
				end
			end
		end
	end
end

local function FindPlacedSlopeByUUID(uuid)
	if type(uuid) ~= "string" or uuid == "" then return nil end
	local placedFolder = workspace:FindFirstChild("PlacedObjects")
	if not placedFolder then return nil end
	for _, child in ipairs(placedFolder:GetChildren()) do
		if child:IsA("Model")
			and child:GetAttribute("UUID") == uuid
			and (child:GetAttribute("Type") == "Slope" or child:GetAttribute("RawPoints") ~= nil)
		then
			return child
		end
	end
	return nil
end

local function PlaceSlope(player, data)
	if not data then return false end
	local points = data.Points or data.pathPoints
	if not points or #points < 2 then return false end

	local restoringUuid = type(data.UUID) == "string" and data.UUID or nil
	if data.IsRestoring == true and restoringUuid then
		local existing = FindPlacedSlopeByUUID(restoringUuid)
		if existing then
			if #existing:GetDescendants() == 0 then
				existing:Destroy()
			else
				return true
			end
		end
	end

	local controlPoints = ParseControlPoints(points)
	if #controlPoints < 2 then return false end

	local requestedDifficulty = NormalizeDifficulty(data.Difficulty, controlPoints)
	local drawMode = tostring(data.DrawMode or ""):lower()
	local wantsAutoPath = data.AutoPath ~= false
	local widthControlCount = #controlPoints
	if drawMode == "point" and wantsAutoPath and #controlPoints == 2 then
		controlPoints = GenerateAutoControlPoints(controlPoints[1], controlPoints[2], requestedDifficulty)
	end

	local isPresmoothed = data.Presmoothed == true
	local path = isPresmoothed and controlPoints or GenerateSmoothPath(controlPoints)
	if #path < 2 then return false end

	local difficulty = NormalizeDifficulty(data.Difficulty, path)
	local isPath = false
	local isQueue = data.IsQueue == true
	local itemConfig = Config.Items[data.ItemName]
	if itemConfig then
		if itemConfig.IsPath then isPath = true end
		if itemConfig.IsQueue then isQueue = true end
	end

	local widthData = ParseWidthData(data.WidthData, widthControlCount, #path, isPath or isQueue)
	local isRestoring = data.IsRestoring == true

	-- =========================================================================
	-- 💰 ECONOMY TRANSACTION 💰
	-- Perform the charge before heavy math or terrain generation
	-- =========================================================================
	if not isRestoring then
		local itemConfig = Config.Items[data.ItemName]
		if itemConfig and itemConfig.PricePerStud and TransactionFunc then
			local totalLen = 0
			for i = 2, #path do
				totalLen += (path[i] - path[i - 1]).Magnitude
			end

			-- Usually we do base price + (len * perStud), but for paths base Price is typically 0
			local finalCost = Config.GetPlacementCost(data.ItemName, player, totalLen)

			local transactionType = Enum.AnalyticsEconomyTransactionType.Shop
			local success = TransactionFunc:Invoke(player, finalCost, data.ItemName, transactionType)

			if not success then
				if NotificationEvent and NotificationEvent:IsA("RemoteEvent") then
					NotificationEvent:FireClient(
						player, 
						"Negative", 
						"Insufficient Funds", 
						"You don't have enough money for this path!", 
						4
					)
				end
				return false
			end
		end
	end
	-- =========================================================================

	local mergedDecorRaw = {}
	if type(data.DecorOptions) == "table" then
		for k, v in pairs(data.DecorOptions) do
			mergedDecorRaw[k] = v
		end
	end
	if data.UseNets ~= nil then mergedDecorRaw.nets = data.UseNets end
	if data.UseMarkers ~= nil then mergedDecorRaw.markers = data.UseMarkers end
	if data.MarkerLights ~= nil then mergedDecorRaw.markerLights = data.MarkerLights end

	local decorOptions = BuildDecorOptions(difficulty, mergedDecorRaw)

	local terrainLog, treeSnapshot
	local isGlade = type(difficulty) == "string" and difficulty:lower():find("glade") ~= nil
	terrainLog, treeSnapshot = CarveSlope(path, widthData, isPath, isGlade)
	task.wait()

	local model = Instance.new("Model")
	if isPath then
		model.Name = "Concrete Path"
		model:SetAttribute("Type", "Slope")
		model:SetAttribute("IsPath", true)
	elseif isQueue then
		model.Name = "Queue Path"
		model:SetAttribute("Type", "Slope")
		model:SetAttribute("IsQueue", true)
		if data.TargetUUID then model:SetAttribute("TargetUUID", data.TargetUUID) end
	else
		local nameMap = {
			["Green"] = "Green Slope",
			["Blue"] = "Blue Slope",
			["Black"] = "Black Slope",
			["Double Black"] = "Double Black Slope",
			["Triple Black"] = "Triple Black Slope",
			["Glade"] = "Glade"
		}
		model.Name = nameMap[difficulty] or ("Slope_" .. difficulty:gsub(" ", ""))
		model:SetAttribute("Type", "Slope")
		model:SetAttribute("Difficulty", difficulty)
	end

	model:SetAttribute("SlopeVersion", 15)
	model:SetAttribute("SlopeWidth", AverageWidth(widthData))
	model:SetAttribute("MarkersEnabled", decorOptions.markers)
	model:SetAttribute("NetsEnabled", decorOptions.nets)
	model:SetAttribute("MarkerLightsEnabled", decorOptions.markerLights)
	if data.CustomName and data.CustomName ~= "" then
		model:SetAttribute("CustomName", data.CustomName)
	end

	local ownerId = 0
	if typeof(player) == "Instance" and player:IsA("Player") then
		ownerId = player.UserId
	elseif type(player) == "number" then
		ownerId = player
	elseif type(player) == "table" and player.UserId then
		ownerId = player.UserId
	end
	model:SetAttribute("Owner", ownerId)
	model:SetAttribute("UUID", data.UUID or HttpService:GenerateGUID(false))

	local finalItemConfig = Config.Items[data.ItemName] or Config.Items[model.Name]
	if finalItemConfig and finalItemConfig.ID then
		model:SetAttribute("ID", tostring(finalItemConfig.ID))
	end
	
	local paid = tonumber(data.Price)
	if not paid then
		local totalLen = 0
		for i = 2, #path do
			totalLen += (path[i] - path[i - 1]).Magnitude
		end
		paid = Config.GetPlacementCost(data.ItemName or model.Name, ownerId, totalLen)
	end
	if paid then
		model:SetAttribute("Price", paid)
		model:SetAttribute("PaidPrice", paid)
	end
	local ptime = tonumber(data.PlacementTime)
	if not ptime then ptime = os.time() end
	model:SetAttribute("PlacementTime", ptime)

	local savedPath = DecimatePoints(path, CONFIG.MAX_SAVED_PATH_POINTS)
	local savedControl = DecimatePoints(controlPoints, CONFIG.MAX_SAVED_CONTROL_POINTS)
	model:SetAttribute("RawPoints", HttpService:JSONEncode(SerializePoints(savedPath)))
	model:SetAttribute("ControlPoints", HttpService:JSONEncode(SerializePoints(savedControl)))
	model:SetAttribute("PathPointCount", #path)

	local serializedWidths = {}
	for _, wd in ipairs(widthData) do
		table.insert(serializedWidths, { wd.index, wd.width })
	end
	model:SetAttribute("WidthData", HttpService:JSONEncode(serializedWidths))

	if terrainLog and #terrainLog > 0 then
		local terrainChunks = EncodeArrayToChunks(terrainLog, CONFIG.MAX_ATTR_JSON_CHARS)
		model:SetAttribute("TerrainSnapshot", terrainChunks[1] or "[]")
		model:SetAttribute("TerrainSnapshotChunkCount", #terrainChunks)
		for chunkIndex = 2, #terrainChunks do
			model:SetAttribute("TerrainSnapshot_" .. chunkIndex, terrainChunks[chunkIndex])
		end
		model:SetAttribute("TerrainSnapshotTotal", #terrainLog)
		model:SetAttribute("TerrainSnapshotKept", #terrainLog)
		model:SetAttribute("TerrainSnapshotTruncated", false)
	end

	if treeSnapshot and #treeSnapshot > 0 then
		local treeJson, keptTrees = EncodeArrayWithBudget(treeSnapshot, CONFIG.MAX_ATTR_JSON_CHARS)
		model:SetAttribute("TreeSnapshot", treeJson)
	end

	if not isPath then
		PlaceSign(path, difficulty, model, widthData)
		PlaceMarkers(path, difficulty, model, widthData, decorOptions)
	end

	-- Concrete Path: Generate invisible hitbox strips so the delete tool can detect the path
	if isPath and #path >= 2 then
		local hitboxSpacing = 20
		local carried = 0
		local createdPathHitboxes = 0
		for i = 1, #path - 1 do
			local p1, p2 = path[i], path[i + 1]
			local seg = p2 - p1
			local dist = seg.Magnitude
			carried += dist
			if carried >= hitboxSpacing or i == 1 then
				local mid = (p1 + p2) * 0.5
				local width = InterpolateWidth(widthData, i, #path)
				local groundY = GetTerrainHeight(mid.X, mid.Z) or mid.Y
				local dir = seg.Magnitude > 0.001 and seg.Unit or Vector3.zAxis

				local hitbox = Instance.new("Part")
				hitbox.Name = "PathHitbox"
				hitbox.Size = Vector3.new(width, 0.5, math.min(dist + 2, hitboxSpacing))
				hitbox.Transparency = 1
				hitbox.CanCollide = false
				hitbox.Anchored = true
				hitbox.CFrame = CFrame.lookAt(
					Vector3.new(mid.X, groundY + 0.15, mid.Z),
					Vector3.new(mid.X, groundY + 0.15, mid.Z) + dir
				)
				hitbox.Parent = model
				carried = 0
				createdPathHitboxes += 1
				if CONFIG.HITBOX_YIELD_EVERY > 0 and createdPathHitboxes % CONFIG.HITBOX_YIELD_EVERY == 0 then
					task.wait()
				end
			end
		end
	end

	-- Slopes: Generate invisible hitbox strips so the delete tool can detect slopes easily
	if not isPath and not isQueue and #path >= 2 then
		local hitboxSpacing = 40
		local carried = 0
		local createdSlopeHitboxes = 0
		for i = 1, #path - 1 do
			local p1, p2 = path[i], path[i + 1]
			local seg = p2 - p1
			local dist = seg.Magnitude
			carried += dist
			if carried >= hitboxSpacing or i == 1 then
				local mid = (p1 + p2) * 0.5
				local width = InterpolateWidth(widthData, i, #path)
				local groundY = GetTerrainHeight(mid.X, mid.Z) or mid.Y
				local dir = seg.Magnitude > 0.001 and seg.Unit or Vector3.zAxis

				local hitbox = Instance.new("Part")
				hitbox.Name = "SlopeHitbox"
				hitbox.Size = Vector3.new(width * 0.6, 6, math.min(dist + 4, hitboxSpacing))
				hitbox.Transparency = 1
				hitbox.CanCollide = false
				hitbox.Anchored = true
				hitbox.CFrame = CFrame.lookAt(
					Vector3.new(mid.X, groundY + 3, mid.Z),
					Vector3.new(mid.X, groundY + 3, mid.Z) + dir
				)
				hitbox.Parent = model
				carried = 0
				createdSlopeHitboxes += 1
				if CONFIG.HITBOX_YIELD_EVERY > 0 and createdSlopeHitboxes % CONFIG.HITBOX_YIELD_EVERY == 0 then
					task.wait()
				end
			end
		end
	end

	local placedFolder = Workspace:FindFirstChild("PlacedObjects") or Instance.new("Folder")
	placedFolder.Name = "PlacedObjects"
	placedFolder.Parent = Workspace
	model.Parent = placedFolder
	task.wait()

	if not isPath then
		PlaceNets(path, difficulty, model, widthData, decorOptions, data.Connections)
		-- After placing the new slope's nets, handle creating the connections to existing slopes.
		HandleNetIntersections(model, path, data.Connections)
	end

	table.insert(SlopeRegistry, {
		Model = model,
		Path = path,
		Difficulty = difficulty,
		WidthData = widthData,
		DecorOptions = decorOptions,
	})


	-- ── Slope stat toast ─────────────────────────────────────────────────
	-- Fire a notification to the player showing length + vertical drop.
	if typeof(player) == "Instance" and player:IsA("Player") and #path >= 2 then
		task.spawn(function()
			local totalLen = 0
			for i = 2, #path do
				totalLen = totalLen + (path[i] - path[i-1]).Magnitude
			end
			local vertDrop = math.abs(path[1].Y - path[#path].Y)
			local msg = string.format(
				"%s Run — %dm long, %dm vert ↓",
				difficulty,
				math.round(totalLen),
				math.round(vertDrop)
			)
			if NotificationEvent and NotificationEvent:IsA("RemoteEvent") then
				NotificationEvent:FireClient(player, "Positive", "Trail Placed", msg, 5)
			end
		end)
	end

	return true
end

local function IsSlopePlaceRequest(itemName, data)
	local function IsSlopeCatalogItem(name)
		if type(name) ~= "string" then
			return false
		end
		local items = Config and Config.Items
		if type(items) ~= "table" then
			return false
		end
		local item = items[name]
		if type(item) ~= "table" then
			return false
		end
		if item.Type == "Slope" then
			return true
		end
		local category = string.lower(tostring(item.Category or ""))
		return category == "slope" or category == "slopes"
	end

	local isSlopeItemName = (type(itemName) == "string")
		and (string.find(string.lower(itemName), "slope", 1, true) ~= nil)
	local isSlopeType = (type(data) == "table") and (data.Type == "Slope")
	local isSlopeCatalogItem = IsSlopeCatalogItem(itemName)

	if isSlopeCatalogItem then
		return true
	end

	return isSlopeType and isSlopeItemName
end

local function IsRateLimited(player)
	local now = os.clock()
	local userId = player.UserId
	local last = slopePlaceCooldownByUserId[userId]
	if last and (now - last) < CONFIG.PLACE_RATE_LIMIT_SECONDS then
		return true
	end
	slopePlaceCooldownByUserId[userId] = now
	return false
end

Players.PlayerRemoving:Connect(function(player)
	if player then
		slopePlaceCooldownByUserId[player.UserId] = nil
	end
end)

task.spawn(function()
	local placeEvent = Events:WaitForChild("PlaceItem")
	placeEvent.OnServerEvent:Connect(function(player, itemName, data)
		if not (typeof(player) == "Instance" and player:IsA("Player")) then
			return
		end
		if player:GetAttribute("WorldLoadLocked") == true then
			if NotificationEvent and NotificationEvent:IsA("RemoteEvent") then
				NotificationEvent:FireClient(player, "Warning", "LOADING", "World is still loading, please wait.", 3)
			end
			return
		end
		if type(itemName) ~= "string" then
			return
		end
		if type(data) ~= "table" then
			return
		end
		if not IsSlopePlaceRequest(itemName, data) then
			return
		end
		if not isUnlockedByResearch(player, itemName) then
			if NotificationEvent and NotificationEvent:IsA("RemoteEvent") then
				NotificationEvent:FireClient(
					player,
					"Negative",
					"RESEARCH LOCKED",
					"Unlock this item in the Research tree first.",
					4
				)
			end
			return
		end
		if IsRateLimited(player) then
			if NotificationEvent and NotificationEvent:IsA("RemoteEvent") then
				NotificationEvent:FireClient(player, "Warning", "TOO FAST", "Please wait before placing another slope.", 3)
			end
			return
		end
		task.defer(function()
			local placed = PlaceSlope(player, data)
			if placed and RequestBuildingSave then
				RequestBuildingSave:Fire()
			end
		end)
	end)
end)

_G.PlaceSlope = PlaceSlope

-- =============================================================================
-- GLADE TREES
-- =============================================================================
local function PlaceGladeTrees(pathPoints, widthData, density, container)
	-- density: 0 to 100 (percent)
	if not pathPoints or #pathPoints < 2 then return end
	density = math.clamp(density or 50, 0, 100)
	if density == 0 then return end

	-- Find tree templates
	local treeFolder = ReplicatedStorage:FindFirstChild("Assets")
	local treeFolderTrees = treeFolder and treeFolder:FindFirstChild("Trees")
	local templates = {}
	if treeFolderTrees then
		for _, t in ipairs(treeFolderTrees:GetChildren()) do
			if t:IsA("Model") or t:IsA("BasePart") then
				table.insert(templates, t)
			end
		end
	end
	if #templates == 0 then return end

	-- Create container for glade trees
	local gladeFolder = container:FindFirstChild("GladeTrees")
	if gladeFolder then gladeFolder:Destroy() end
	gladeFolder = Instance.new("Folder")
	gladeFolder.Name = "GladeTrees"
	gladeFolder.Parent = container

	-- Spacing inversely proportional to density
	local spacing = math.clamp(math.floor(40 - (density * 0.32)), 6, 40)
	local rng = Random.new(container:GetAttribute("UUID") and string.len(container:GetAttribute("UUID")) or 42)

	local terrainParams = RaycastParams.new()
	terrainParams.FilterType = Enum.RaycastFilterType.Include
	terrainParams.FilterDescendantsInstances = {workspace.Terrain}

	local placedCount = 0
	local step = math.max(1, math.floor(#pathPoints / 80))

	for i = 1, #pathPoints - step, step do
		local pos = pathPoints[i]
		local nextIdx = math.min(i + step, #pathPoints)
		local dir = (pathPoints[nextIdx] - pos)
		if dir.Magnitude < 0.1 then continue end
		dir = dir.Unit
		local right = dir:Cross(Vector3.yAxis)
		if right.Magnitude < 0.01 then continue end
		right = right.Unit

		local halfWidth = InterpolateWidth(widthData, i, #pathPoints) * 0.5

		-- Place trees along edges and within (but avoid dead center to leave skiing room)
		for offset = -halfWidth + 4, halfWidth - 4, spacing do
			if math.abs(offset) < halfWidth * 0.25 then continue end -- leave center clear
			if rng:NextNumber() > (density / 100) then continue end

			local treePos = pos + right * offset
			local rayResult = workspace:Raycast(
				Vector3.new(treePos.X, treePos.Y + 100, treePos.Z),
				Vector3.new(0, -200, 0),
				terrainParams
			)
			if not rayResult then continue end

			local template = templates[rng:NextInteger(1, #templates)]
			local tree = template:Clone()
			local scale = 0.6 + rng:NextNumber() * 0.4
			if tree:IsA("Model") then tree:ScaleTo(scale) end

			local rotation = math.rad(rng:NextInteger(0, 360))
			local cf = CFrame.new(rayResult.Position) * CFrame.Angles(0, rotation, 0)
			if tree:IsA("Model") then tree:PivotTo(cf) else tree.CFrame = cf end

			tree.Parent = gladeFolder
			placedCount += 1
		end
	end

	container:SetAttribute("GladeDensity", density)
end

-- =============================================================================
-- EDIT SLOPE DECOR (POST-PLACEMENT)
-- =============================================================================
local function ClearDecorFromModel(model)
	-- Collect first, then destroy (destroying while iterating skips entries)
	local toDestroy = {}
	for _, child in ipairs(model:GetChildren()) do
		local name = child.Name:lower()
		if child:IsA("Model") or child:IsA("BasePart") then
			if name:match("^slopehitbox") or name:match("^pathhitbox") then
				-- Skip these
			elseif name:find("marker") or name:find("pole") or name:find("net")
				or name:find("sign") or name:find("post") or name:find("board")
				or name:find("hitbox") or name:find("safetynet") then
				table.insert(toDestroy, child)
			end
		end
		if child:IsA("Folder") and name == "gladetrees" then
			table.insert(toDestroy, child)
		end
	end
	for _, child in ipairs(toDestroy) do
		child:Destroy()
	end
	return #toDestroy
end

local function CloneWidthData(widthData)
	local out = {}
	for _, wd in ipairs(widthData or {}) do
		table.insert(out, {
			index = tonumber(wd.index or wd[1]) or 1,
			width = tonumber(wd.width or wd[2]) or CONFIG.DEFAULT_WIDTH,
		})
	end
	return out
end

local function GetEditableWidthBounds(model)
	local isPath = model and model:GetAttribute("IsPath") == true
	local minWidth = isPath and 1 or CONFIG.MIN_WIDTH
	return minWidth, CONFIG.MAX_WIDTH
end

local function ScaleWidthData(widthData, targetWidth, model, pathCount)
	local minWidth, maxWidth = GetEditableWidthBounds(model)
	local currentAvg = AverageWidth(widthData)
	if not currentAvg or currentAvg <= 0 then
		currentAvg = math.max(minWidth, tonumber(model:GetAttribute("SlopeWidth")) or CONFIG.DEFAULT_WIDTH)
	end
	local desiredWidth = math.clamp(tonumber(targetWidth) or currentAvg, minWidth, maxWidth)

	if not widthData or #widthData == 0 then
		return {
			{ index = 1, width = desiredWidth },
			{ index = math.max(1, pathCount), width = desiredWidth },
		}, desiredWidth
	end

	local ratio = currentAvg > 0 and (desiredWidth / currentAvg) or 1
	local scaled = {}
	for _, wd in ipairs(widthData) do
		local idx = math.clamp(math.floor(tonumber(wd.index or wd[1]) or 1), 1, math.max(1, pathCount))
		local width = math.clamp((tonumber(wd.width or wd[2]) or currentAvg) * ratio, minWidth, maxWidth)
		table.insert(scaled, { index = idx, width = width })
	end

	if #scaled == 1 then
		table.insert(scaled, { index = math.max(1, pathCount), width = scaled[1].width })
	end

	table.sort(scaled, function(a, b)
		return a.index < b.index
	end)
	return scaled, desiredWidth
end

local function GetSlopeCatalogItemName(model, difficulty)
	if model:GetAttribute("IsPath") == true then
		return "Concrete Path"
	end
	if difficulty == "Glade" then
		return "Glade"
	end
	return tostring(difficulty or "Green") .. " Slope"
end

local function BuildSlopeEditPayload(model, options, widthDataOverride)
	local path = DecodePointsFromJson(model:GetAttribute("RawPoints"))
	if not path or #path < 2 then
		return nil, "No stored path"
	end

	local difficulty = model:GetAttribute("Difficulty") or "Green"
	local isPath = model:GetAttribute("IsPath") == true
	local widthData = widthDataOverride or DecodeWidthDataFromJson(model:GetAttribute("WidthData"), #path, false, isPath)
	if not widthData then
		local minWidth = isPath and 1 or CONFIG.MIN_WIDTH
		local fallbackWidth = math.clamp(tonumber(model:GetAttribute("SlopeWidth")) or (isPath and 4 or CONFIG.DEFAULT_WIDTH), minWidth, CONFIG.MAX_WIDTH)
		widthData = {
			{ index = 1, width = fallbackWidth },
			{ index = #path, width = fallbackWidth },
		}
	end

	local decorOptions = {}
	if options.markers ~= nil then
		decorOptions.markers = options.markers == true
	else
		decorOptions.markers = model:GetAttribute("MarkersEnabled") ~= false
	end
	if options.nets ~= nil then
		decorOptions.nets = options.nets == true
	else
		decorOptions.nets = model:GetAttribute("NetsEnabled") == true
	end
	if options.markerLights ~= nil then
		decorOptions.markerLights = options.markerLights == true
	else
		decorOptions.markerLights = model:GetAttribute("MarkerLightsEnabled") ~= false
	end

	if model.Name:lower():find("glade") or difficulty == "Glade" then
		decorOptions.gladeDensity = math.clamp(tonumber(options.gladeDensity or model:GetAttribute("GladeDensity") or 50) or 50, 0, 100)
	end

	return {
		Points = path,
		pathPoints = path,
		Difficulty = difficulty,
		Type = "Slope",
		ItemName = GetSlopeCatalogItemName(model, difficulty),
		UUID = model:GetAttribute("UUID") or HttpService:GenerateGUID(false),
		CustomName = model:GetAttribute("CustomName"),
		WidthData = widthData,
		DecorOptions = decorOptions,
		Presmoothed = true,
		IsRestoring = true,
	}, path
end

local function RebuildSlopeFromEdit(player, model, options)
	if not RemoveItemInternal or not RemoveItemInternal:IsA("BindableFunction") then
		return false, "Slope rebuild helper unavailable"
	end

	local payload, pathOrError = BuildSlopeEditPayload(model, options)
	if not payload then
		return false, pathOrError
	end

	local path = pathOrError
	local originalWidthData = CloneWidthData(payload.WidthData)
	local scaledWidthData = ScaleWidthData(originalWidthData, options.width, model, #path)
	payload.WidthData = scaledWidthData

	local removed = RemoveItemInternal:Invoke(player, model, {
		SkipRefund = true,
		SkipSave = true,
		YieldUntilRestored = true,
	})
	if not removed then
		return false, "Failed to remove old slope"
	end
	ForgetSlopeModel(model)

	local rebuilt = PlaceSlope(player, payload)
	if not rebuilt then
		payload.WidthData = originalWidthData
		local rollbackOk = PlaceSlope(player, payload)
		if rollbackOk and RequestBuildingSave then
			RequestBuildingSave:Fire()
		end
		return false, "Failed to rebuild slope"
	end

	if RequestBuildingSave then
		RequestBuildingSave:Fire()
	end
	return true
end

local function EditSlopeDecor(model, options)
	if not model or not model.Parent then return false, "Invalid model" end

	local difficulty = model:GetAttribute("Difficulty")
	if not difficulty then return false, "Not a slope" end

	-- Decode stored path
	local path = DecodePointsFromJson(model:GetAttribute("RawPoints"))
	if not path or #path < 2 then return false, "No stored path" end

	local widthData = DecodeWidthDataFromJson(
		model:GetAttribute("WidthData"),
		#path,
		model:GetAttribute("IsPath") == true
	)
	if not widthData then
		local avgW = tonumber(model:GetAttribute("SlopeWidth")) or CONFIG.DEFAULT_WIDTH
		widthData = {
			{ index = 1, width = avgW },
			{ index = #path, width = avgW },
		}
	end

	-- Clear existing decor
	local removed = ClearDecorFromModel(model)

	-- Build new decor options (can't use and/or ternary for booleans - false fails)
	local decorOptions = {}
	if options.markers ~= nil then
		decorOptions.markers = options.markers
	else
		decorOptions.markers = model:GetAttribute("MarkersEnabled") ~= false
	end
	if options.nets ~= nil then
		decorOptions.nets = options.nets
	else
		decorOptions.nets = model:GetAttribute("NetsEnabled") == true
	end
	if options.markerLights ~= nil then
		decorOptions.markerLights = options.markerLights
	else
		decorOptions.markerLights = model:GetAttribute("MarkerLightsEnabled") ~= false
	end

	-- Update attributes
	if decorOptions.nets then
		decorOptions.markers = false
		decorOptions.markerLights = false
	end
	if decorOptions.markerLights and not decorOptions.markers then
		decorOptions.markers = true
	end

	-- Only write attributes when value actually changes to avoid spurious repair triggers
	if model:GetAttribute("MarkersEnabled") ~= decorOptions.markers then
		model:SetAttribute("MarkersEnabled", decorOptions.markers)
	end
	if model:GetAttribute("NetsEnabled") ~= decorOptions.nets then
		model:SetAttribute("NetsEnabled", decorOptions.nets)
	end
	if model:GetAttribute("MarkerLightsEnabled") ~= decorOptions.markerLights then
		model:SetAttribute("MarkerLightsEnabled", decorOptions.markerLights)
	end

	-- Re-place decor
	PlaceSign(path, difficulty, model, widthData)
	PlaceMarkers(path, difficulty, model, widthData, decorOptions)
	
	-- Reconstruct connections from neighboring slopes so nets trim correctly at junctions
	local editConnections = nil
	local placedFolder = Workspace:FindFirstChild("PlacedObjects")
	if placedFolder and #path >= 2 then
		local function findSnapForEdit(pt)
			local bestDist = 8
			local bestSnap = nil
			for _, m in ipairs(placedFolder:GetChildren()) do
				if m:GetAttribute("Type") == "Slope" and m ~= model then
					local r = m:GetAttribute("RawPoints")
					if r then
						local ok2, pts2 = pcall(function() return HttpService:JSONDecode(r) end)
						if ok2 and type(pts2) == "table" then
							for _, p in ipairs(pts2) do
								if type(p) == "table" then
									local pVec = Vector3.new(p[1], p[2], p[3])
									local d = (Vector3.new(pVec.X, 0, pVec.Z) - Vector3.new(pt.X, 0, pt.Z)).Magnitude
									if d < bestDist then
										bestDist = d
										bestSnap = { UUID = m:GetAttribute("UUID"), Position = pVec }
									end
								end
							end
						end
					end
				end
			end
			return bestSnap
		end
		local snapStart = findSnapForEdit(path[1])
		local snapEnd = findSnapForEdit(path[#path])
		if snapStart or snapEnd then
			editConnections = {}
			if snapStart then editConnections.Start = snapStart end
			if snapEnd then editConnections.End = snapEnd end
		end
	end
	PlaceNets(path, difficulty, model, widthData, decorOptions, editConnections)
	if editConnections then
		HandleNetIntersections(model, path, editConnections)
	end

	-- Handle glade trees
	local isGlade = model.Name:lower():find("glade") or difficulty == "Glade"
	if isGlade then
		local gladeDensity = options.gladeDensity or model:GetAttribute("GladeDensity") or 50
		PlaceGladeTrees(path, widthData, gladeDensity, model)
	end

	return true
end

_G.EditSlopeDecor = EditSlopeDecor

-- =============================================================================
-- RECALCULATE INTERSECTIONS ON RESTORE
-- =============================================================================
local function RecalculateAllSlopeIntersections()
	local placedFolder = Workspace:FindFirstChild("PlacedObjects")
	if not placedFolder then return end

	local function findSnap(pt, excludeModel)
		local bestDist = 8
		local bestSnap = nil
		for _, m in ipairs(placedFolder:GetChildren()) do
			if m:GetAttribute("Type") == "Slope" and m ~= excludeModel then
				local r = m:GetAttribute("RawPoints")
				if r then
					local ok, pts = pcall(function() return HttpService:JSONDecode(r) end)
					if ok and type(pts) == "table" then
						for _, p in ipairs(pts) do
							if type(p) == "table" then
								local pVec = Vector3.new(p[1], p[2], p[3])
								local d = (Vector3.new(pVec.X, 0, pVec.Z) - Vector3.new(pt.X, 0, pt.Z)).Magnitude
								if d < bestDist then
									bestDist = d
									bestSnap = {
										UUID = m:GetAttribute("UUID"),
										Position = pVec
									}
								end
							end
						end
					end
				end
			end
		end
		return bestSnap
	end

	for _, model in ipairs(placedFolder:GetChildren()) do
		if model:GetAttribute("Type") == "Slope" then
			local r = model:GetAttribute("RawPoints")
			if r then
				local ok, decoded = pcall(function() return HttpService:JSONDecode(r) end)
				if ok and type(decoded) == "table" and #decoded >= 2 then
					local path = {}
					for _, p in ipairs(decoded) do
						if type(p) == "table" then
							table.insert(path, Vector3.new(p[1], p[2], p[3]))
						end
					end
					
					if #path >= 2 then
						local connections = {}
						local snapStart = findSnap(path[1], model)
						if snapStart then connections.Start = snapStart end
						
						local snapEnd = findSnap(path[#path], model)
						if snapEnd then connections.End = snapEnd end
						
						if connections.Start or connections.End then
							HandleNetIntersections(model, path, connections)
						end
					end
				end
			end
		end
	end
end

local BuildingRestoreReady = Events:WaitForChild("BuildingRestoreReady", 5)
if BuildingRestoreReady then
	BuildingRestoreReady.Event:Connect(function()
		RecalculateAllSlopeIntersections()
		task.delay(5, RecalculateAllSlopeIntersections)
		task.delay(10, RecalculateAllSlopeIntersections)
	end)
end

-- =============================================================================
-- EDIT SLOPE REMOTE EVENT
-- =============================================================================
task.spawn(function()
	local editEvent = Events:FindFirstChild("EditSlopeRemote")
	if not editEvent then
		editEvent = Instance.new("RemoteEvent")
		editEvent.Name = "EditSlopeRemote"
		editEvent.Parent = Events
	end

	editEvent.OnServerEvent:Connect(function(player, slopeModel, options)
		if not (typeof(player) == "Instance" and player:IsA("Player")) then return end
		if not slopeModel or not slopeModel:IsA("Model") then return end
		if type(options) ~= "table" then return end

		-- Verify ownership
		local ownerId = slopeModel:GetAttribute("Owner")
		if ownerId and ownerId ~= player.UserId then
			if NotificationEvent then
				NotificationEvent:FireClient(player, "Negative", "NOT YOUR SLOPE", "You can only edit slopes you placed.", 3)
			end
			return
		end

		local requestedWidth = tonumber(options.width)
		local currentWidth = tonumber(slopeModel:GetAttribute("SlopeWidth")) or CONFIG.DEFAULT_WIDTH
		local shouldRebuildWidth = (requestedWidth ~= nil) and (math.abs(requestedWidth - currentWidth) >= 0.5)

		local success, err
		if shouldRebuildWidth then
			success, err = RebuildSlopeFromEdit(player, slopeModel, options)
			if success and NotificationEvent then
				NotificationEvent:FireClient(player, "Positive", "Trail Updated", ("Width updated to %d studs."):format(math.round(requestedWidth)), 3)
			end
		else
			success, err = EditSlopeDecor(slopeModel, options)
		end

		if not success then
			if NotificationEvent then
				NotificationEvent:FireClient(player, "Negative", "Trail Edit Failed", tostring(err), 3)
			end
		end
	end)
end)