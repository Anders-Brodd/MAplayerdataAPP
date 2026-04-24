--[=[ PATH: ReplicatedStorage/Shop/SlopeMath | TYPE: ModuleScript ]=]--

--[[
	SLOPE MATH V11

	- Terrain-following Catmull-Rom splines
	- Stronger anti-bump smoothing pass
	- Variable-width interpolation support
	- Optional auto path generation for steep two-point runs
	- Reduced cost rates
	- Backward compatibility aliases (generatePath)
]]

local Workspace = game:GetService("Workspace")

local SlopeMath = {}

local CONFIG = {
	MIN_POINTS_PER_SEGMENT = 12,
	MAX_POINTS_PER_SEGMENT = 40,
	POINT_SPACING = 2,

	SMOOTHING_ITERATIONS = 9,
	SMOOTHING_WEIGHT = 0.4,

	MAX_SLOPE_ANGLE = 55,
	CURVE_INSERTION_THRESHOLD = 35,

	DEFAULT_WIDTH = 90,
	MIN_WIDTH = 30,
	MAX_WIDTH = 160,
	WIDTH_CURVE_FACTOR = 0.3,
	WIDTH_INTERPOLATION = "smoothstep",

	CLIFF_ANGLE_THRESHOLD = 50,
	CLIFF_MIN_DROP = 15,
	JUMP_ZONE_LENGTH = 12,
	LANDING_ZONE_LENGTH = 20,

	MOGUL_SPACING = 20,
	MOGUL_HEIGHT = 1.2,
	MOGUL_WIDTH = 7,
	MOGUL_RANDOMNESS = 0.18,

	DIFFICULTY = {
		Green = { maxAngle = 12, minAngle = 0 },
		Blue = { maxAngle = 25, minAngle = 12 },
		Black = { maxAngle = 40, minAngle = 25 },
		["Double Black"] = { maxAngle = 90, minAngle = 40 },
	},

	DECORATION_RULES = {
		Green = {
			markers = true,
			signs = true,
			nets = true,
			moguls = false,
			markerSpacing = 30,
			netSpacing = 22,
		},
		Blue = {
			markers = true,
			signs = true,
			nets = true,
			moguls = false,
			markerSpacing = 34,
			netSpacing = 24,
		},
		Black = {
			markers = true,
			signs = true,
			nets = false,
			moguls = false,
			markerSpacing = 38,
		},
		["Double Black"] = {
			markers = false,
			signs = true,
			nets = false,
			moguls = false,
			markerSpacing = 0,
		},
	},

	COST_PER_STUD = {
		Green = 2,
		Blue = 4,
		Black = 7,
		["Double Black"] = 11,
	},
}

SlopeMath.CONFIG = CONFIG

local TERRAIN_PARAMS = RaycastParams.new()
TERRAIN_PARAMS.FilterType = Enum.RaycastFilterType.Include
TERRAIN_PARAMS.FilterDescendantsInstances = { Workspace.Terrain }
TERRAIN_PARAMS.IgnoreWater = true

function SlopeMath.catmullRomStandard(t, p0, p1, p2, p3)
	local t2 = t * t
	local t3 = t2 * t
	return 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
end

function SlopeMath.getTerrainHeight(terrain, x, z, searchHeight)
	searchHeight = searchHeight or 5000
	local params = TERRAIN_PARAMS
	if terrain and terrain ~= Workspace.Terrain then
		params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { terrain }
		params.IgnoreWater = true
	end

	local origin = Vector3.new(x, searchHeight, z)
	local result = Workspace:Raycast(origin, Vector3.new(0, -(searchHeight + 500), 0), params)
	if result then
		return result.Position.Y
	end
	return 0
end

function SlopeMath.sampleTerrainLine(terrain, startPos, endPos, numSamples)
	local samples = {}
	numSamples = numSamples or 20
	for i = 0, numSamples do
		local t = i / numSamples
		local pos = startPos:Lerp(endPos, t)
		local height = SlopeMath.getTerrainHeight(terrain, pos.X, pos.Z)
		table.insert(samples, Vector3.new(pos.X, height, pos.Z))
	end
	return samples
end

function SlopeMath.calculateSlopeAngle(p1, p2)
	local horizontal = Vector3.new(p2.X - p1.X, 0, p2.Z - p1.Z).Magnitude
	local vertical = p1.Y - p2.Y
	if horizontal < 0.1 then
		return vertical > 0 and 90 or -90
	end
	return math.deg(math.atan(vertical / horizontal))
end

local function SmoothScalarSeries(values, iterations)
	local out = table.clone(values)
	for _ = 1, iterations do
		if #out < 3 then break end
		local temp = table.clone(out)
		for i = 2, #out - 1 do
			temp[i] = (out[i - 1] + out[i] * 2 + out[i + 1]) / 4
		end
		out = temp
	end
	return out
end

local function DedupeControlPoints(controlPoints)
	if #controlPoints <= 1 then return controlPoints end
	local out = { controlPoints[1] }
	for i = 2, #controlPoints do
		if (controlPoints[i] - out[#out]).Magnitude >= 2 then
			table.insert(out, controlPoints[i])
		end
	end
	if #out == 1 then
		table.insert(out, controlPoints[#controlPoints])
	end
	return out
end

function SlopeMath.generateAutoPath(startPos, endPos, terrain, difficulty)
	local totalDrop = startPos.Y - endPos.Y
	if totalDrop <= 0 then
		return { startPos, endPos }
	end
	local horizontalDist = Vector3.new(endPos.X - startPos.X, 0, endPos.Z - startPos.Z).Magnitude
	local directAngle = math.abs(SlopeMath.calculateSlopeAngle(startPos, endPos))

	if directAngle < CONFIG.CURVE_INSERTION_THRESHOLD then
		local wantsWiggle = (difficulty == "Black" or difficulty == "Double Black" or difficulty == "Triple Black")
		if not wantsWiggle then
			return { startPos, endPos }
		end
	end

	local targetAngle = CONFIG.DIFFICULTY[difficulty] and CONFIG.DIFFICULTY[difficulty].maxAngle or 25
	targetAngle = math.max(targetAngle * 0.7, 15)

	local requiredHorizontal = totalDrop / math.tan(math.rad(targetAngle))
	local extraHorizontal = math.max(0, requiredHorizontal - horizontalDist)

	local mainDir = Vector3.new(endPos.X - startPos.X, 0, endPos.Z - startPos.Z)
	if mainDir.Magnitude < 1 then
		mainDir = Vector3.new(1, 0, 0)
	end
	mainDir = mainDir.Unit

	local perpDir = mainDir:Cross(Vector3.yAxis).Unit
	local numSegments = math.clamp(math.ceil(extraHorizontal / 80), 2, 12)

	local controlPoints = { startPos }
	local switchDirection = 1

	for i = 1, numSegments - 1 do
		local t = i / numSegments
		local easeT = t * t * (3 - 2 * t)
		local y = startPos.Y + (endPos.Y - startPos.Y) * easeT
		local mainProgress = startPos:Lerp(endPos, t)
		local switchAmplitude = math.clamp(extraHorizontal / (numSegments * 1.5), 10, 60)
		local lateralOffset = perpDir * switchAmplitude * switchDirection

		local pointPos = Vector3.new(mainProgress.X + lateralOffset.X, y, mainProgress.Z + lateralOffset.Z)
		local terrainY = SlopeMath.getTerrainHeight(terrain, pointPos.X, pointPos.Z)
		pointPos = Vector3.new(pointPos.X, math.min(y, terrainY), pointPos.Z)

		table.insert(controlPoints, pointPos)
		switchDirection = -switchDirection
	end

	table.insert(controlPoints, endPos)
	return controlPoints
end

function SlopeMath.interpolateWidth(widthData, index)
	if not widthData or #widthData == 0 then
		return CONFIG.DEFAULT_WIDTH
	end
	if #widthData == 1 then
		return widthData[1].width
	end

	local prevCP, nextCP
	for _, cp in ipairs(widthData) do
		if cp.index <= index then prevCP = cp end
		if cp.index >= index and not nextCP then nextCP = cp end
	end

	if not prevCP then return widthData[1].width end
	if not nextCP then return widthData[#widthData].width end
	if prevCP.index == nextCP.index then return prevCP.width end

	local t = (index - prevCP.index) / (nextCP.index - prevCP.index)
	if CONFIG.WIDTH_INTERPOLATION == "smoothstep" then
		t = t * t * (3 - 2 * t)
	end
	return prevCP.width + (nextCP.width - prevCP.width) * t
end

function SlopeMath.getWidthAtPoint(pathPoints, index, widthData)
	if widthData and #widthData > 0 then
		return math.clamp(SlopeMath.interpolateWidth(widthData, index), CONFIG.MIN_WIDTH, CONFIG.MAX_WIDTH)
	end

	if not pathPoints or #pathPoints < 2 then
		return CONFIG.DEFAULT_WIDTH
	end

	local curvature = 0
	if index > 1 and index < #pathPoints then
		local prev = pathPoints[index - 1]
		local curr = pathPoints[index]
		local nxt = pathPoints[index + 1]
		local dir1 = (curr - prev)
		local dir2 = (nxt - curr)
		if dir1.Magnitude > 0.01 and dir2.Magnitude > 0.01 then
			local dot = dir1.Unit:Dot(dir2.Unit)
			curvature = 1 - math.clamp(dot, -1, 1)
		end
	end

	local angle = 0
	if index < #pathPoints then
		angle = math.abs(SlopeMath.calculateSlopeAngle(pathPoints[index], pathPoints[index + 1]))
	end

	local curveFactor = 1 - (curvature * CONFIG.WIDTH_CURVE_FACTOR)
	local slopeFactor = 1 - (math.clamp(angle - 20, 0, 40) / 100)

	local width = CONFIG.DEFAULT_WIDTH * curveFactor * slopeFactor
	return math.clamp(width, CONFIG.MIN_WIDTH, CONFIG.DEFAULT_WIDTH)
end

function SlopeMath.detectCliffZones(pathPoints)
	if not pathPoints or #pathPoints < 10 then return {} end

	local zones = {}
	local step = math.max(1, math.floor(#pathPoints / 60))
	local i = 1
	while i <= #pathPoints - step do
		local p1 = pathPoints[i]
		local p2 = pathPoints[math.min(i + step, #pathPoints)]
		local angle = math.abs(SlopeMath.calculateSlopeAngle(p1, p2))
		local drop = p1.Y - p2.Y

		if angle >= CONFIG.CLIFF_ANGLE_THRESHOLD and drop >= CONFIG.CLIFF_MIN_DROP then
			local cliffBottom = i + step
			while cliffBottom < #pathPoints - step do
				local a = math.abs(SlopeMath.calculateSlopeAngle(pathPoints[cliffBottom], pathPoints[math.min(cliffBottom + step, #pathPoints)]))
				if a < CONFIG.CLIFF_ANGLE_THRESHOLD * 0.7 then break end
				cliffBottom = cliffBottom + step
			end

			table.insert(zones, {
				type = "cliff",
				startIndex = i,
				endIndex = cliffBottom,
				jumpZoneStart = math.max(1, i - math.floor(CONFIG.JUMP_ZONE_LENGTH / step)),
				jumpZoneEnd = i,
				landingZoneStart = cliffBottom,
				landingZoneEnd = math.min(#pathPoints, cliffBottom + math.floor(CONFIG.LANDING_ZONE_LENGTH / step)),
				position = p1,
				landingPosition = pathPoints[math.min(cliffBottom, #pathPoints)],
			})
			i = cliffBottom + 1
		else
			i = i + 1
		end
	end

	return zones
end

function SlopeMath.generateMogulPositions(pathPoints, widthData)
	if not pathPoints or #pathPoints < 20 then return {} end

	local moguls = {}
	local distAccum = 0
	local rng = Random.new(42)
	for i = 2, #pathPoints do
		local dist = (pathPoints[i] - pathPoints[i - 1]).Magnitude
		distAccum = distAccum + dist
		if distAccum < CONFIG.MOGUL_SPACING then continue end
		distAccum = 0

		local dir = SlopeMath.getDirectionAtIndex(pathPoints, i)
		local right = SlopeMath.getRightVector(dir)
		local width = SlopeMath.getWidthAtPoint(pathPoints, i, widthData)
		local halfWidth = width / 2
		local numMogulsAcross = math.max(3, math.floor(width / CONFIG.MOGUL_WIDTH))

		for m = 0, numMogulsAcross do
			local lateralT = (m / numMogulsAcross) * 2 - 1
			local lateralOffset = lateralT * (halfWidth * 0.85)
			local randOffset = rng:NextNumber(-1, 1) * CONFIG.MOGUL_RANDOMNESS * CONFIG.MOGUL_SPACING
			local randLateral = rng:NextNumber(-1, 1) * CONFIG.MOGUL_RANDOMNESS * CONFIG.MOGUL_WIDTH
			if math.abs(lateralOffset + randLateral) < halfWidth * 0.9 then
				table.insert(moguls, {
					position = pathPoints[i] + right * (lateralOffset + randLateral) + Vector3.new(0, randOffset * 0.1, 0),
					height = CONFIG.MOGUL_HEIGHT * rng:NextNumber(0.6, 1.0),
					radius = CONFIG.MOGUL_WIDTH / 2 * rng:NextNumber(0.7, 1.2),
					pathIndex = i,
				})
			end
		end
	end

	return moguls
end

function SlopeMath.insertCurvePoints(controlPoints, terrain)
	if #controlPoints < 2 then return controlPoints end

	local enhanced = { controlPoints[1] }
	for i = 1, #controlPoints - 1 do
		local p1 = controlPoints[i]
		local p2 = controlPoints[i + 1]
		local angle = math.abs(SlopeMath.calculateSlopeAngle(p1, p2))

		if angle > CONFIG.CURVE_INSERTION_THRESHOLD then
			local segments = math.clamp(math.ceil(angle / 20), 2, 8)
			for s = 1, segments - 1 do
				local t = s / segments
				local hPos = p1:Lerp(p2, t)
				local easeT = t * t * (3 - 2 * t)
				local targetY = p1.Y + (p2.Y - p1.Y) * easeT
				local terrainY = SlopeMath.getTerrainHeight(terrain, hPos.X, hPos.Z)
				table.insert(enhanced, Vector3.new(hPos.X, math.min(targetY, terrainY), hPos.Z))
			end
		end

		table.insert(enhanced, p2)
	end

	return enhanced
end

function SlopeMath.generateTerrainPath(controlPoints, terrain)
	if not controlPoints or #controlPoints < 2 then return {} end

	local deduped = DedupeControlPoints(controlPoints)
	local enhanced = SlopeMath.insertCurvePoints(deduped, terrain)

	local grounded = {}
	for _, cp in ipairs(enhanced) do
		local terrainY = SlopeMath.getTerrainHeight(terrain, cp.X, cp.Z)
		table.insert(grounded, Vector3.new(cp.X, terrainY - 0.5, cp.Z))
	end

	local path = {}
	if #grounded == 2 then
		local dist = (grounded[2] - grounded[1]).Magnitude
		local steps = math.max(CONFIG.MIN_POINTS_PER_SEGMENT, math.ceil(dist / CONFIG.POINT_SPACING))
		for i = 0, steps do
			local t = i / steps
			local pos = grounded[1]:Lerp(grounded[2], t)
			local terrainY = SlopeMath.getTerrainHeight(terrain, pos.X, pos.Z)
			table.insert(path, Vector3.new(pos.X, terrainY - 0.5, pos.Z))
		end
	else
		for i = 1, #grounded - 1 do
			local p0 = grounded[math.max(1, i - 1)]
			local p1 = grounded[i]
			local p2 = grounded[i + 1]
			local p3 = grounded[math.min(#grounded, i + 2)]
			local segDist = (p2 - p1).Magnitude
			local steps = math.clamp(math.ceil(segDist / CONFIG.POINT_SPACING), CONFIG.MIN_POINTS_PER_SEGMENT, CONFIG.MAX_POINTS_PER_SEGMENT)

			for step = 0, steps - 1 do
				local t = step / steps
				local pos = SlopeMath.catmullRomStandard(t, p0, p1, p2, p3)
				local terrainY = SlopeMath.getTerrainHeight(terrain, pos.X, pos.Z)
				table.insert(path, Vector3.new(pos.X, terrainY - 0.5, pos.Z))
			end
		end

		local last = grounded[#grounded]
		local terrainY = SlopeMath.getTerrainHeight(terrain, last.X, last.Z)
		table.insert(path, Vector3.new(last.X, terrainY - 0.5, last.Z))
	end

	path = SlopeMath.smoothPath(path, CONFIG.SMOOTHING_ITERATIONS)

	local heights = {}
	for i, pos in ipairs(path) do
		heights[i] = SlopeMath.getTerrainHeight(terrain, pos.X, pos.Z)
	end
	heights = SmoothScalarSeries(heights, 4)

	local finalPath = {}
	for i, pos in ipairs(path) do
		local y = heights[i] - 0.25
		if i > 1 then
			local prev = finalPath[i - 1]
			local horizontal = Vector3.new(pos.X - prev.X, 0, pos.Z - prev.Z).Magnitude
			if horizontal > 0 then
				local maxDy = horizontal * 1.2
				y = math.clamp(y, prev.Y - maxDy, prev.Y + maxDy)
			end
		end
		table.insert(finalPath, Vector3.new(pos.X, y, pos.Z))
	end

	return finalPath
end

function SlopeMath.smoothPath(pathPoints, iterations)
	if not pathPoints or #pathPoints < 3 then return pathPoints end
	iterations = iterations or CONFIG.SMOOTHING_ITERATIONS

	local smoothed = {}
	for _, p in ipairs(pathPoints) do
		table.insert(smoothed, p)
	end

	local weight = CONFIG.SMOOTHING_WEIGHT
	for _ = 1, iterations do
		local temp = {}
		temp[1] = smoothed[1]
		for i = 2, #smoothed - 1 do
			local prev = smoothed[i - 1]
			local curr = smoothed[i]
			local nxt = smoothed[i + 1]
			local avgX = (prev.X + nxt.X) / 2
			local avgY = (prev.Y + nxt.Y) / 2
			local avgZ = (prev.Z + nxt.Z) / 2
			temp[i] = Vector3.new(curr.X * (1 - weight) + avgX * weight, curr.Y * (1 - weight) + avgY * weight, curr.Z * (1 - weight) + avgZ * weight)
		end
		temp[#smoothed] = smoothed[#smoothed]
		smoothed = temp
	end

	return smoothed
end

function SlopeMath.getDifficulty(startPos, endPos)
	local angle = math.abs(SlopeMath.calculateSlopeAngle(startPos, endPos))
	if angle < 12 then return "Green" end
	if angle < 25 then return "Blue" end
	if angle < 40 then return "Black" end
	return "Double Black"
end

function SlopeMath.getDifficultyFromPath(pathPoints)
	if not pathPoints or #pathPoints < 2 then return "Green" end

	local maxAngle = 0
	local totalAngle = 0
	local count = 0
	local step = math.max(1, math.floor(#pathPoints / 30))
	for i = 1, #pathPoints - step, step do
		local angle = math.abs(SlopeMath.calculateSlopeAngle(pathPoints[i], pathPoints[i + step]))
		maxAngle = math.max(maxAngle, angle)
		totalAngle = totalAngle + angle
		count = count + 1
	end

	local avgAngle = count > 0 and (totalAngle / count) or 0
	local finalAngle = (maxAngle * 0.7) + (avgAngle * 0.3)

	if finalAngle < 12 then return "Green" end
	if finalAngle < 25 then return "Blue" end
	if finalAngle < 40 then return "Black" end
	return "Double Black"
end

function SlopeMath.getDecorationRules(difficulty)
	return CONFIG.DECORATION_RULES[difficulty] or CONFIG.DECORATION_RULES.Green
end

function SlopeMath.getElevationProfile(pathPoints, numSamples)
	if not pathPoints or #pathPoints < 2 then return {} end
	numSamples = numSamples or 20

	local profile = {}
	local totalLength = SlopeMath.getPathLength(pathPoints)
	local cumDist = { 0 }
	for i = 2, #pathPoints do
		cumDist[i] = cumDist[i - 1] + (pathPoints[i] - pathPoints[i - 1]).Magnitude
	end

	for s = 0, numSamples do
		local targetDist = (s / numSamples) * totalLength
		local idx = 1
		for i = 2, #cumDist do
			if cumDist[i] >= targetDist then
				idx = i - 1
				break
			end
		end

		local segLen = cumDist[idx + 1] and (cumDist[idx + 1] - cumDist[idx]) or 1
		local segT = segLen > 0 and ((targetDist - cumDist[idx]) / segLen) or 0
		segT = math.clamp(segT, 0, 1)

		local p1 = pathPoints[idx]
		local p2 = pathPoints[math.min(idx + 1, #pathPoints)]
		local pos = p1:Lerp(p2, segT)

		local angle = 0
		if idx < #pathPoints then
			angle = SlopeMath.calculateSlopeAngle(p1, p2)
		end

		table.insert(profile, {
			distance = targetDist,
			elevation = pos.Y,
			angle = angle,
			position = pos,
		})
	end

	return profile
end

function SlopeMath.getPathLength(pathPoints)
	if not pathPoints or #pathPoints < 2 then return 0 end
	local total = 0
	for i = 1, #pathPoints - 1 do
		total = total + (pathPoints[i + 1] - pathPoints[i]).Magnitude
	end
	return total
end

function SlopeMath.getDirectionAtIndex(pathPoints, index)
	if not pathPoints or #pathPoints < 2 then return Vector3.zAxis end
	index = math.clamp(index, 1, #pathPoints)
	if index >= #pathPoints then
		return (pathPoints[#pathPoints] - pathPoints[#pathPoints - 1]).Unit
	elseif index <= 1 then
		return (pathPoints[2] - pathPoints[1]).Unit
	else
		local dir = pathPoints[index + 1] - pathPoints[index - 1]
		return dir.Magnitude > 0.01 and dir.Unit or Vector3.zAxis
	end
end

function SlopeMath.getRightVector(direction)
	local right = direction:Cross(Vector3.yAxis)
	if right.Magnitude < 0.01 then return Vector3.xAxis end
	return right.Unit
end

function SlopeMath.calculateCost(pathPoints, difficulty, widthData)
	local rate = CONFIG.COST_PER_STUD[difficulty] or CONFIG.COST_PER_STUD.Green
	local length = SlopeMath.getPathLength(pathPoints)
	local avgWidth = CONFIG.DEFAULT_WIDTH

	if widthData and #widthData > 0 then
		local sum = 0
		for _, wd in ipairs(widthData) do
			sum = sum + wd.width
		end
		avgWidth = sum / #widthData
	end

	local widthFactor = avgWidth / CONFIG.DEFAULT_WIDTH
	return math.floor(length * rate * widthFactor)
end

SlopeMath.COLORS = {
	Green = Color3.fromRGB(76, 209, 55),
	Blue = Color3.fromRGB(52, 152, 219),
	Black = Color3.fromRGB(44, 62, 80),
	["Double Black"] = Color3.fromRGB(255, 215, 0),
	Edge = Color3.fromRGB(255, 255, 255),
}

function SlopeMath.getDifficultyColor(difficulty)
	return SlopeMath.COLORS[difficulty] or SlopeMath.COLORS.Green
end

function SlopeMath.generatePath(controlPoints, terrain)
	terrain = terrain or Workspace.Terrain
	return SlopeMath.generateTerrainPath(controlPoints, terrain)
end
SlopeMath.GeneratePath = SlopeMath.generatePath

return SlopeMath
