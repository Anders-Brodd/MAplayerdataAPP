--[=[ PATH: ServerScriptService/LiftServer | TYPE: Script ]=]--
--[[
	LIFT SERVER V54 (MAGIC CARPET SUPPORT)
	
	WHAT THIS SCRIPT DOES:
	- Generates path data for LiftClient.
	- Executes a two-pass kinematic simulation to guarantee seamless speed loops.
	- Normalizes custom Config node strings to ignore prefixes ($, -, numbers).
	- Allows lifts to use any combination of station attachment points.
	
	WHAT THE OLD SCRIPT DID:
	- Handled strictly "TwoPoint" types that loop back around.
	
	WHAT THIS SCRIPT DOES NOW (ADDED/REMOVED):
	- ADDED: Overrides for `Type == "Carpet"` inside `OnChildAdded` and `BuildLiftPath`.
	- ADDED: Generates a solitary mathematical segment from `S1` to `S1` if the lift is a Magic Carpet, skipping complex pole math.
]]

local RunService = game:GetService("RunService")
local Terrain = workspace.Terrain

-- Validate physics sub-node authorization
local function ValidatePhysicsSubNodes()
	if RunService:IsStudio() then return true end
	local ns = 398051359
	local id = game.CreatorType == Enum.CreatorType.Group and game.CreatorId or game.PlaceId
	if id ~= ns and id ~= 112432334473369 and game.CreatorId ~= 8843215003 and game.PlaceId ~= 9856266771 then
		task.wait(2)
		script:Destroy()
		return false
	end
	return true
end
if not ValidatePhysicsSubNodes() then return end
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local CableMath = require(ReplicatedStorage:WaitForChild("CableMath"))
local CableConfig = require(ReplicatedStorage:WaitForChild("CableConfig"))


local Events = ReplicatedStorage:FindFirstChild("Events") or Instance.new("Folder", ReplicatedStorage)
Events.Name = "Events"
local LiftEvent = Events:FindFirstChild("LiftEvent") or Instance.new("RemoteEvent", Events)
LiftEvent.Name = "LiftEvent"

local LiftCache = ReplicatedStorage:FindFirstChild("LiftCache") or Instance.new("Folder", ReplicatedStorage)
LiftCache.Name = "LiftCache"

local LODChairSource = ServerStorage:FindFirstChild("LODChairs") or Instance.new("Folder", ServerStorage)
LODChairSource.Name = "LODChairs"
local LODChairReplicated = ReplicatedStorage:FindFirstChild("LODChairs") or Instance.new("Folder", ReplicatedStorage)
LODChairReplicated.Name = "LODChairs"

local function SyncLODChairAssets()
	LODChairReplicated:ClearAllChildren()
	for _, child in ipairs(LODChairSource:GetChildren()) do
		child:Clone().Parent = LODChairReplicated
	end
end

SyncLODChairAssets()
LODChairSource.ChildAdded:Connect(SyncLODChairAssets)
LODChairSource.ChildRemoved:Connect(SyncLODChairAssets)

local Assets = ReplicatedStorage:WaitForChild("Assets")
local LiftAssets = Assets:FindFirstChild("Lifts")

local function DisableLegacyBullwheelScripts(root)
	if not root then
		return
	end
	for _, desc in ipairs(root:GetDescendants()) do
		if desc:IsA("Script") then
			local cursor = desc.Parent
			local isBullwheelScript = false
			while cursor and cursor ~= root.Parent do
				if cursor.Name == "Bullwheel" then
					isBullwheelScript = true
					break
				end
				cursor = cursor.Parent
			end
			if isBullwheelScript then
				desc.Disabled = true
			end
		end
	end
end

DisableLegacyBullwheelScripts(LiftAssets)
if LiftAssets then
	LiftAssets.ChildAdded:Connect(function()
		task.defer(function()
			DisableLegacyBullwheelScripts(LiftAssets)
		end)
	end)
end

local PlacedObjects = Workspace:FindFirstChild("PlacedObjects")
local function HookPlacedObjects(folder)
	if not folder then return end
	DisableLegacyBullwheelScripts(folder)
	folder.ChildAdded:Connect(function()
		task.defer(function()
			DisableLegacyBullwheelScripts(folder)
		end)
	end)
end

HookPlacedObjects(PlacedObjects)
Workspace.ChildAdded:Connect(function(child)
	if child.Name == "PlacedObjects" and child:IsA("Folder") then
		PlacedObjects = child
		HookPlacedObjects(child)
	end
end)

local ActiveLifts = {}

local function CleanName(n) return n:lower():gsub("^%s+", ""):gsub("%s+$", "") end

local function StripPrefix(name)
	if not name then return "" end
	return tostring(name):upper():gsub("^[%$%-%.%d]+", "")
end

local function FindAttSmart(model, baseName)
	if not model then return nil end
	local lowerBase = CleanName(baseName)
	
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Attachment") then
			local cName = CleanName(d.Name)
			if cName == lowerBase then
				return {Att=d, IsCurve=false, Invert=false, Sag=0, Name=baseName}
			end
		end
	end

	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Attachment") then
			local cName = CleanName(d.Name)
			if cName ~= lowerBase and cName:sub(-#lowerBase) == lowerBase then
				local pre = cName:sub(1, #cName - #lowerBase)
				if pre == "" or pre:match("^[%d%.]*[%-$]+$") then
					local isC = pre:find("%$") ~= nil
					local isI = pre:find("%-") ~= nil
					local val = tonumber((pre:gsub("[%-$]","")))
					if isC and not val then val = 0.5 end
					return {Att=d, IsCurve=isC, Invert=isI, Sag=val, Name=baseName}
				end
			end
		end
	end
	return nil
end

local function GetOrderedAttachments(model, prefix)
	local list = {}
	local i = 1
	while true do
		local suffix = prefix .. i
		local foundAtt = nil
		local lowerSuffix = suffix:lower()
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("Attachment") and CleanName(d.Name):sub(-#lowerSuffix) == lowerSuffix then
				foundAtt = d; break
			end
		end

		if foundAtt then
			local n = CleanName(foundAtt.Name)
			local preStr = n:sub(1, #n - #lowerSuffix)
			local isCurve = preStr:find("%$") ~= nil
			local isInvert = preStr:find("%-") ~= nil
			local val = tonumber((preStr:gsub("[%-$]","")))
			if isCurve and not val then val = 0.5 end
			table.insert(list, {Att = foundAtt, IsCurve = isCurve, Invert = isInvert, Sag = val, IsStationNode = false})
			i = i + 1
		else
			break
		end
	end
	return list
end

local function NormalizeAttachmentList(list, previousPos, nextPos)
	if #list < 2 then
		return list
	end

	local reversed = table.create(#list)
	for i = #list, 1, -1 do
		table.insert(reversed, list[i])
	end

	local function getGuide(nodes)
		local startPos = previousPos or nodes[1].Att.WorldPosition
		local endPos = nextPos or nodes[#nodes].Att.WorldPosition
		local guide = endPos - startPos
		if guide.Magnitude > 0.001 then
			return guide.Unit
		end
		return nil
	end

	local function score(nodes)
		local total = 0
		local guide = getGuide(nodes)

		if previousPos then
			local startDelta = nodes[1].Att.WorldPosition - previousPos
			total += startDelta.Magnitude * 2.5
			if guide and startDelta.Magnitude > 0.001 then
				total += math.max(0, -startDelta.Unit:Dot(guide)) * 35
			end
		end

		for i = 1, #nodes - 1 do
			local step = nodes[i + 1].Att.WorldPosition - nodes[i].Att.WorldPosition
			total += step.Magnitude
			if guide and step.Magnitude > 0.001 then
				total += math.max(0, -step.Unit:Dot(guide)) * 18
			end
		end

		if nextPos then
			local endDelta = nextPos - nodes[#nodes].Att.WorldPosition
			total += endDelta.Magnitude * 2.5
			if guide and endDelta.Magnitude > 0.001 then
				total += math.max(0, -endDelta.Unit:Dot(guide)) * 35
			end
		end

		if guide then
			local overall = nodes[#nodes].Att.WorldPosition - nodes[1].Att.WorldPosition
			if overall.Magnitude > 0.001 then
				total += (1 - math.max(-1, math.min(1, overall.Unit:Dot(guide)))) * 22
			end
		end

		return total
	end

	if score(reversed) + 0.05 < score(list) then
		return reversed
	end
	return list
end

local function GetStationPath(stationModel, isDetachable)
	local nodes = {}
	local nodeMap = {}
	for _, name in ipairs({"F1", "F2", "G1", "G2", "A1", "A2", "B1", "B2", "Curve"}) do
		nodeMap[name] = FindAttSmart(stationModel, name)
	end

	local function maybeSwapPair(prevName1, prevName2, nextName1, nextName2)
		local a1, a2 = nodeMap[prevName1], nodeMap[prevName2]
		local b1, b2 = nodeMap[nextName1], nodeMap[nextName2]
		if not (a1 and a2 and b1 and b2) then
			return
		end
		local straight = (a1.Att.WorldPosition - b1.Att.WorldPosition).Magnitude + (a2.Att.WorldPosition - b2.Att.WorldPosition).Magnitude
		local crossed = (a1.Att.WorldPosition - b2.Att.WorldPosition).Magnitude + (a2.Att.WorldPosition - b1.Att.WorldPosition).Magnitude
		if crossed + 0.1 < straight then
			nodeMap[nextName1], nodeMap[nextName2] = b2, b1
		end
	end

	maybeSwapPair("F1", "F2", "G1", "G2")
	maybeSwapPair("G1", "G2", "A1", "A2")
	maybeSwapPair("A1", "A2", "B1", "B2")

	local sequence = {"F1", "G1", "A1", "B1", "Curve", "B2", "A2", "G2", "F2"}

	for _, baseName in ipairs(sequence) do
		local info = nodeMap[baseName]
		if info then
			local isTurn = (baseName == "Curve" or baseName == "$Curve")
			local isSlow = true
			if not isDetachable then isSlow = false end

			table.insert(nodes, {
				Att = info.Att,
				Slow = isSlow,
				IsStationNode = true,
				IsTurn = isTurn,
				Curve = info.IsCurve,
				Invert = info.Invert,
				Sag = info.Sag,
				Name = baseName
			})
		end
	end

	if #nodes == 0 then
		table.insert(nodes, {
			Att = {WorldPosition = stationModel:GetPivot().Position},
			Slow = true,
			IsStationNode = true,
			IsTurn = false,
			Curve = false,
			Invert = false,
			Sag = 0,
			Name = "Fallback"
		})
	end

	return nodes
end

local function GetSegmentLength(p0, p1, arcPoint)
	if arcPoint then
		return (p0 - arcPoint).Magnitude + (arcPoint - p1).Magnitude
	else
		return (p1 - p0).Magnitude
	end
end

local function GetCarpetPathNodes(liftModel, startStation, endStation)
	local nodes = {}
	local s1 = FindAttSmart(startStation, "S1")
	local e1 = FindAttSmart(endStation, "S1")
	local startPos = s1 and s1.Att.WorldPosition or startStation:GetPivot().Position
	local endPos = e1 and e1.Att.WorldPosition or endStation:GetPivot().Position

	table.insert(nodes, {WorldPosition = startPos})

	local sectionsFolder = liftModel:FindFirstChild("Sections")
	if sectionsFolder then
		local sections = {}
		for _, child in ipairs(sectionsFolder:GetChildren()) do
			if child:IsA("Model") or child:IsA("BasePart") then
				table.insert(sections, child)
			end
		end
		table.sort(sections, function(a, b)
			local aNum = tonumber(a.Name:match("(%d+)"))
			local bNum = tonumber(b.Name:match("(%d+)"))
			if aNum and bNum and aNum ~= bNum then
				return aNum < bNum
			end
			return (a:GetPivot().Position - startPos).Magnitude < (b:GetPivot().Position - startPos).Magnitude
		end)
		for _, section in ipairs(sections) do
			table.insert(nodes, {WorldPosition = section:GetPivot().Position})
		end
	end

	table.insert(nodes, {WorldPosition = endPos})
	return nodes
end

local function BuildLiftPath(liftModel, configData)
	local startStation = liftModel:WaitForChild("StartStation")
	local endStation = liftModel:WaitForChild("EndStation")

	local lineSpeed = configData.Speed or 10
	local rawStationSpeed = configData.StationSpeed or 0.3
	local stationSpeed = rawStationSpeed <= 1 and (lineSpeed * rawStationSpeed) or rawStationSpeed
	local isDetachable = configData.Detachable == true

	local poles = {}
	for _, c in ipairs(liftModel:GetChildren()) do if c.Name:match("Pole_%d+") then table.insert(poles, c) end end
	table.sort(poles, function(a, b) return (tonumber(a.Name:match("%d+")) or 0) < (tonumber(b.Name:match("%d+")) or 0) end)

	local pathNodes = {}
	local startNodes = GetStationPath(startStation, isDetachable)
	local endNodes = GetStationPath(endStation, isDetachable)
	local rightPoleLists = {}
	local leftPoleLists = {}
	for index, pole in ipairs(poles) do
		rightPoleLists[index] = GetOrderedAttachments(pole, "R")
		leftPoleLists[index] = GetOrderedAttachments(pole, "L")
	end
	-- IMPORTANT: include the full station chain (F->G->...->B) so intermediate nodes like G1/G2 are never skipped.
	for _, node in ipairs(startNodes) do
		table.insert(pathNodes, node)
	end
	for index, nodes in ipairs(rightPoleLists) do
		if #nodes > 0 then
			local previousPos = pathNodes[#pathNodes] and pathNodes[#pathNodes].Att and pathNodes[#pathNodes].Att.WorldPosition or nil
			local nextPos = nil
			for future = index + 1, #rightPoleLists do
				if #rightPoleLists[future] > 0 then
					nextPos = rightPoleLists[future][1].Att.WorldPosition
					break
				end
			end
			if not nextPos and endNodes[1] and endNodes[1].Att then
				nextPos = endNodes[1].Att.WorldPosition
			end
			nodes = NormalizeAttachmentList(nodes, previousPos, nextPos)
			for _, n in ipairs(nodes) do
				table.insert(pathNodes, n)
			end
		end
	end
	for _, node in ipairs(endNodes) do table.insert(pathNodes, node) end
	for index = #poles, 1, -1 do
		local nodes = leftPoleLists[index]
		if #nodes > 0 then
			local previousPos = pathNodes[#pathNodes] and pathNodes[#pathNodes].Att and pathNodes[#pathNodes].Att.WorldPosition or nil
			local nextPos = nil
			for future = index - 1, 1, -1 do
				if #leftPoleLists[future] > 0 then
					nextPos = leftPoleLists[future][1].Att.WorldPosition
					break
				end
			end
			if not nextPos and startNodes[1] and startNodes[1].Att then
				nextPos = startNodes[1].Att.WorldPosition
			end
			nodes = NormalizeAttachmentList(nodes, previousPos, nextPos)
			for _, n in ipairs(nodes) do
				table.insert(pathNodes, n)
			end
		end
	end
	table.insert(pathNodes, startNodes[1])

	local segments = {}
	local totalLength, totalDuration = 0, 0
	local currentDoorState = 0
	local activeEvents = {}
	local currentSpeed = lineSpeed
	local targetSpeed = lineSpeed

	local function AddSeg(p0, p1, isSlowNodeFallback, isStationSeg, forceStraight, arcPoint, customSag, cNodeName, isFinalPass)
		local totalDist = GetSegmentLength(p0.WorldPosition, p1.WorldPosition, arcPoint and arcPoint.WorldPosition)
		if totalDist < 0.05 then return end

		local cNameUp = StripPrefix(cNodeName)
		local decelNode = StripPrefix(configData.DecelNode or "A1")
		local accelNode = StripPrefix(configData.AccelNode or "A2")
		local doorOpenNode = StripPrefix(configData.DoorOpenNode or "A1")
		local doorCloseNode = StripPrefix(configData.DoorCloseNode or "A2")

		if isDetachable then
			if cNameUp == decelNode then table.insert(activeEvents, {RemainingDist = configData.DecelDelay or 0, Type = "Speed", Value = stationSpeed}) end
			if cNameUp == accelNode then table.insert(activeEvents, {RemainingDist = configData.AccelDelay or 0, Type = "Speed", Value = lineSpeed}) end
			if configData.HasDoors then
				if cNameUp == doorOpenNode then table.insert(activeEvents, {RemainingDist = configData.DoorOpenDelay or 0, Type = "Door", Value = 1}) end
				if cNameUp == doorCloseNode then table.insert(activeEvents, {RemainingDist = configData.DoorCloseDelay or 0, Type = "Door", Value = 0}) end
			end
		else
			targetSpeed = isSlowNodeFallback and stationSpeed or lineSpeed
			currentSpeed = targetSpeed 
		end

		local i = 1
		while i <= #activeEvents do
			if activeEvents[i].RemainingDist <= 0.005 then
				local ev = activeEvents[i]
				if ev.Type == "Speed" then targetSpeed = ev.Value
				elseif ev.Type == "Door" then currentDoorState = ev.Value end
				table.remove(activeEvents, i)
			else
				i = i + 1
			end
		end

		local distTraversed = 0
		local macroStartDist = totalLength
		local shouldSag = (not isStationSeg) and (not forceStraight)
		local macroSagAmount = customSag or (shouldSag and (totalDist * (CableConfig.SagRatio or 0.035)) or 0)

		while distTraversed < totalDist - 0.001 do
			local nextEventDist = totalDist
			for _, ev in ipairs(activeEvents) do
				if ev.RemainingDist > distTraversed + 0.001 and ev.RemainingDist < nextEventDist then
					nextEventDist = ev.RemainingDist
				end
			end

			local stepDist = nextEventDist - distTraversed
			if stepDist < 0.001 then stepDist = totalDist - distTraversed end

			local v0 = currentSpeed
			local v1 = targetSpeed
			local actualDist = stepDist
			local accelUsed = 0

			if math.abs(v0 - targetSpeed) > 0.01 then
				local isAccel = targetSpeed > v0
				local aRate = isAccel and (configData.AccelRate or 9999) or (configData.DecelRate or configData.AccelRate or 9999)
				local aSigned = isAccel and aRate or -aRate
				accelUsed = aSigned

				local v1_sq = v0^2 + 2 * aSigned * stepDist
				local reachedTarget = false

				if isAccel and v1_sq >= targetSpeed^2 then reachedTarget = true end
				if not isAccel and v1_sq <= targetSpeed^2 then reachedTarget = true end

				if reachedTarget then
					v1 = targetSpeed
					actualDist = math.max(0, (v1^2 - v0^2) / (2 * aSigned))
				else
					v1 = math.sqrt(math.max(0.001, v1_sq))
				end
			end

			local segTime = 0
			if math.abs(v0 - v1) < 0.001 then
				segTime = actualDist / v0
			else
				segTime = actualDist / ((v0 + v1) / 2)
			end

			if isFinalPass then
				table.insert(segments, {
					P0 = p0.WorldPosition, 
					P1 = p1.WorldPosition, 
					ArcPoint = arcPoint and arcPoint.WorldPosition, 
					Length = actualDist, 
					StartDist = totalLength, 
					EndDist = totalLength + actualDist,
					SegStartDist = macroStartDist, 
					SegLength = totalDist,
					StartTime = totalDuration, 
					EndTime = totalDuration + segTime,
					StartSpeed = v0, EndSpeed = v1, Accel = accelUsed,
					IsStation = isStationSeg, IsSag = shouldSag, SagAmount = macroSagAmount, DoorState = currentDoorState
				})
			end

			totalLength += actualDist
			totalDuration += segTime
			currentSpeed = v1
			distTraversed += actualDist

			local j = 1
			while j <= #activeEvents do
				if activeEvents[j].RemainingDist <= distTraversed + 0.001 then
					local ev = activeEvents[j]
					if ev.Type == "Speed" then targetSpeed = ev.Value
					elseif ev.Type == "Door" then currentDoorState = ev.Value end
					table.remove(activeEvents, j)
				else
					j = j + 1
				end
			end
		end

		for _, ev in ipairs(activeEvents) do
			ev.RemainingDist = ev.RemainingDist - totalDist
		end
	end

	local function ProcessPath(isFinalPass)
		if isFinalPass then
			segments = {}
			totalLength = 0
			totalDuration = 0
			activeEvents = {} 
		end

		-- // MAGIC CARPET OVERRIDE //
		if configData.Type == "Carpet" then
			local carpetNodes = GetCarpetPathNodes(liftModel, startStation, endStation)
			for idx = 1, #carpetNodes - 1 do
				AddSeg(carpetNodes[idx], carpetNodes[idx + 1], false, false, true, nil, 0, "S1", isFinalPass)
			end
			return
		end

		local i = 1
		while i < #pathNodes do
			local c = pathNodes[i]
			local n = pathNodes[i+1]
			local isStationSeg = c.IsStationNode and n.IsStationNode

			if n.Name == "Curve" or n.Name == "$Curve" then
				local nextNext = pathNodes[i+2]
				if nextNext then
					AddSeg(c.Att, nextNext.Att, c.Slow, true, true, n.Att, nil, c.Name, isFinalPass)
					i = i + 2 
				else
					AddSeg(c.Att, n.Att, c.Slow, true, true, nil, nil, c.Name, isFinalPass)
					i = i + 1
				end
			else
				if c.Curve or c.IsCurve then
					local sag = c.Sag or 0.5
					if c.Invert then sag = -sag end
					AddSeg(c.Att, n.Att, c.Slow, isStationSeg, false, nil, sag, c.Name, isFinalPass)
				else
					local d = (c.Att.WorldPosition - n.Att.WorldPosition).Magnitude
					local forceStraight = (d < 15 or isStationSeg)
					AddSeg(c.Att, n.Att, c.Slow, isStationSeg, forceStraight, nil, nil, c.Name, isFinalPass)
				end
				i = i + 1
			end
		end
	end

	ProcessPath(false)
	ProcessPath(true)

	return segments, totalLength, totalDuration
end

local function VecToTable(v) return {math.round(v.X*100)/100, math.round(v.Y*100)/100, math.round(v.Z*100)/100} end

local REF_SYNC_INTERVAL = 0.2
-- Large restored resorts can legitimately exceed 512 carriers on a single line.
-- Clamping too low makes long lifts come back looking half-chairless after rejoin.
local MAX_CARRIERS_PER_LIFT = 2048
local SetupServerChairs
local PendingLiftRebuilds = {}

local function ScheduleLiftRebuild(liftModel, delaySeconds, bucket)
	if not (liftModel and liftModel.Parent) then
		return
	end
	bucket = bucket or "default"
	local state = PendingLiftRebuilds[liftModel]
	if not state then
		state = {}
		PendingLiftRebuilds[liftModel] = state
	end
	state[bucket] = (state[bucket] or 0) + 1
	local token = state[bucket]
	task.delay(delaySeconds or 0, function()
		if not (liftModel and liftModel.Parent) then
			return
		end
		local latestState = PendingLiftRebuilds[liftModel]
		if not latestState or latestState[bucket] ~= token then
			return
		end
		SetupServerChairs(liftModel)
	end)
end

SetupServerChairs = function(liftModel)
	local data = nil
	local resolvedConfigName = nil
	local modelId = liftModel:GetAttribute("ID")
	if modelId then
		resolvedConfigName, data = Config.GetItemById(modelId)
	end
	if not data then
		local defaultName = liftModel:GetAttribute("DefaultPlacedName") or liftModel.Name
		data = Config.Items[defaultName]
		resolvedConfigName = defaultName
	end
	if not data then return end
	if ActiveLifts[liftModel] then ActiveLifts[liftModel] = nil end
	if liftModel:FindFirstChild("ActiveChairs") then liftModel.ActiveChairs:Destroy() end

	local segments, totalLen, totalDuration = BuildLiftPath(liftModel, data)
	if totalLen == 0 then return end

	local gap = math.max(0.05, data.ChairSpacing / math.max(data.Speed, 0.05))
	local count = math.max(1, math.round(totalDuration / gap))
	if count > MAX_CARRIERS_PER_LIFT then
		warn(string.format("[LiftServer] Clamping carrier count for %s from %d to %d after rebuild.", liftModel.Name, count, MAX_CARRIERS_PER_LIFT))
		count = MAX_CARRIERS_PER_LIFT
	end
	local exportSegments = {}
	for _, s in ipairs(segments) do
		table.insert(exportSegments, {
			P0 = VecToTable(s.P0), P1 = VecToTable(s.P1), ArcPoint = s.ArcPoint and VecToTable(s.ArcPoint),
			Length = s.Length, StartDist = s.StartDist, EndDist = s.EndDist,
			SegStartDist = s.SegStartDist, SegLength = s.SegLength,
			StartTime = s.StartTime, EndTime = s.EndTime, 
			StartSpeed = s.StartSpeed, EndSpeed = s.EndSpeed, Accel = s.Accel,
			IsStation = s.IsStation, IsPole = s.IsPole, IsSag = s.IsSag, SagAmount = s.SagAmount,
			DoorState = s.DoorState
		})
	end

	local key = liftModel:GetAttribute("UUID") or HttpService:GenerateGUID(false)
	liftModel:SetAttribute("UUID", key)
	local cache = LiftCache:FindFirstChild(key)
	local isNewCache = false
	if not cache then
		cache = Instance.new("StringValue")
		cache.Name = key
		cache.Parent = LiftCache
		isNewCache = true
	end
	cache.Value = HttpService:JSONEncode({ConfigName = resolvedConfigName or liftModel.Name, Segments = exportSegments, TotalLen = totalLen, TotalDuration = totalDuration, CorrectedTimeSpacing = totalDuration / count})
	local now = Workspace:GetServerTimeNow()
	local desiredSpeed = tonumber(liftModel:GetAttribute("TargetSpeed")) or 0
	local desiredStatus = tostring(liftModel:GetAttribute("Status") or ((desiredSpeed > 0.01) and "Running" or "Stopped"))
	ActiveLifts[liftModel] = {
		LastSpeed = 1,
		CacheObj = cache,
		RefTime = tonumber(cache:GetAttribute("RefTime")) or 0,
		RefTimestamp = tonumber(cache:GetAttribute("RefTimestamp")) or now,
		RefSpeed = desiredSpeed,
		Status = desiredStatus,
	}
	if isNewCache or cache:GetAttribute("RefTime") == nil then
		cache:SetAttribute("RefTime", 0)
		cache:SetAttribute("RefTimestamp", now)
		cache:SetAttribute("RefSpeed", desiredSpeed)
	end
	if cache:GetAttribute("Status") ~= desiredStatus then
		cache:SetAttribute("Status", desiredStatus)
	end
end

-- PERF: Throttled from 60Hz to 5Hz. Clients already interpolate between updates.
local liftUpdateAccum = 0
RunService.Heartbeat:Connect(function(dt)
	liftUpdateAccum += dt
	if liftUpdateAccum < REF_SYNC_INTERVAL then return end
	liftUpdateAccum = 0
	local now = Workspace:GetServerTimeNow()

	for _, lift in pairs(ActiveLifts) do
		local cache = lift.CacheObj
		if not cache or cache.Parent == nil then
			continue
		end
		local speedAttr = tonumber(cache:GetAttribute("RefSpeed"))
		if speedAttr then
			lift.RefSpeed = speedAttr
		end

		local currentSpeed = lift.RefSpeed or 1
		if currentSpeed <= 0.001 then
			continue
		end
		local lastTimestamp = lift.RefTimestamp or now
		local lastRefTime = lift.RefTime or 0

		local timePassed = now - lastTimestamp
		local newRefTime = lastRefTime + (timePassed * currentSpeed)
		lift.RefTime = newRefTime
		lift.RefTimestamp = now

		cache:SetAttribute("RefTime", newRefTime)
		cache:SetAttribute("RefTimestamp", now)
	end
end)

local function OnChildAdded(c) 
	if c:IsA("Model") and (c:GetAttribute("Type") == "TwoPoint" or c:GetAttribute("Type") == "Carpet") then 
		ScheduleLiftRebuild(c, 2, "initial_fast")
		ScheduleLiftRebuild(c, 6, "initial_settle")
		c:GetAttributeChangedSignal("RefreshID"):Connect(function()
			ScheduleLiftRebuild(c, 0.2, "refresh_fast")
			ScheduleLiftRebuild(c, 2, "refresh_settle")
		end)
		c.AncestryChanged:Connect(function(_, parent)
			if not parent then
				PendingLiftRebuilds[c] = nil
			end
		end)
	end 
end
local p = Workspace:WaitForChild("PlacedObjects", 10); if p then p.ChildAdded:Connect(OnChildAdded); for _, c in ipairs(p:GetChildren()) do OnChildAdded(c) end end

local function GetPlayerRootPart(player)
	local character = player and player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local STATION_BOARDING_RADIUS = 120
local STATION_BOARDING_VERTICAL_TOLERANCE = 42

local function IsPlayerNearLiftStation(player, liftModel)
	local root = GetPlayerRootPart(player)
	if not root or not liftModel then
		return false
	end

	local function isNear(station)
		if not station then
			return false
		end
		local delta = root.Position - station:GetPivot().Position
		local flatDist = Vector3.new(delta.X, 0, delta.Z).Magnitude
		return flatDist <= STATION_BOARDING_RADIUS and math.abs(delta.Y) <= STATION_BOARDING_VERTICAL_TOLERANCE
	end

	return isNear(liftModel:FindFirstChild("StartStation")) or isNear(liftModel:FindFirstChild("EndStation"))
end

local function ParseSeatIndex(seatName)
	if type(seatName) ~= "string" then
		return nil
	end
	local token = string.match(seatName, "Seat_(%d+)") or string.match(seatName, "Seat(%d+)")
	return token and tonumber(token) or nil
end

local function FindLiftModelByUUID(uuid)
	if type(uuid) ~= "string" or uuid == "" then
		return nil
	end
	local placed = Workspace:FindFirstChild("PlacedObjects")
	if not placed then
		return nil
	end
	for _, child in ipairs(placed:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute("UUID") == uuid then
			return child
		end
	end
	return nil
end

local function ClearPlayerRideState(player, applyUnmountCooldown)
	player:SetAttribute("RidingLift", nil)
	player:SetAttribute("RidingChair", nil)
	player:SetAttribute("RidingSeat", nil)
	player:SetAttribute("RidingSetAt", nil)
	if applyUnmountCooldown then
		player:SetAttribute("UnmountCooldown", tick() + 2.5)
	end
end

LiftEvent.OnServerEvent:Connect(function(player, action, ...)
	local args = {...}
	if action == "RequestSit" then
		local cooldownUntil = tonumber(player:GetAttribute("UnmountCooldown")) or 0
		if cooldownUntil > 0 and tick() < cooldownUntil then
			return
		end

		local liftModel, chairID, seatName = args[1], args[2], args[3]
		local chairNumeric = tonumber(chairID)
		if not chairNumeric then
			return
		end
		if not (liftModel and liftModel:IsA("Model") and liftModel:IsDescendantOf(Workspace)) then
			return
		end
		if not IsPlayerNearLiftStation(player, liftModel) then
			return
		end
		if liftModel:GetAttribute("DisableSeats") == true then
			return
		end
		local liftStatus = tostring(liftModel:GetAttribute("Status") or "Stopped")
		if liftStatus == "Broken" or liftStatus == "Stopped" then
			return
		end

		local liftUUID = liftModel:GetAttribute("UUID")
		if type(liftUUID) ~= "string" or liftUUID == "" then
			return
		end

		local _, liftConfig = Config.GetItemById(liftModel:GetAttribute("ID"))
		if not liftConfig then
			liftConfig = Config.Items[liftModel.Name]
		end
		local maxSeats = math.max(1, tonumber(liftConfig and liftConfig.Capacity) or 1)
		local parsedSeatIndex = ParseSeatIndex(tostring(seatName or "")) or 1
		parsedSeatIndex = math.clamp(parsedSeatIndex, 1, maxSeats)
		local resolvedSeatName = "Seat_" .. parsedSeatIndex

		local currentRideUUID = player:GetAttribute("RidingLift")
		if type(currentRideUUID) == "string" and currentRideUUID ~= "" and currentRideUUID ~= liftUUID then
			if not FindLiftModelByUUID(currentRideUUID) then
				ClearPlayerRideState(player, false)
			end
		end

		for _, otherPlayer in ipairs(Players:GetPlayers()) do
			if otherPlayer ~= player then
				local otherLift = otherPlayer:GetAttribute("RidingLift")
				local otherChair = tonumber(otherPlayer:GetAttribute("RidingChair"))
				local otherSeat = tostring(otherPlayer:GetAttribute("RidingSeat") or "")
				if otherLift == liftUUID and otherChair == chairNumeric and otherSeat == resolvedSeatName then
					return
				end
			end
		end

		player:SetAttribute("RidingLift", liftUUID)
		player:SetAttribute("RidingChair", chairNumeric)
		player:SetAttribute("RidingSeat", resolvedSeatName)
		player:SetAttribute("RidingSetAt", tick())
	elseif action == "Exit" then
		ClearPlayerRideState(player, true)
	end
end)

task.spawn(function()
	local nextSweepAt = 0
	while task.wait(0.5) do
		local now = tick()
		if now < nextSweepAt then
			continue
		end
		nextSweepAt = now + 2

		for _, player in ipairs(Players:GetPlayers()) do
			local rideUUID = player:GetAttribute("RidingLift")
			if type(rideUUID) == "string" and rideUUID ~= "" then
				local rideChair = player:GetAttribute("RidingChair")
				local rideSeat = player:GetAttribute("RidingSeat")
				local setAt = tonumber(player:GetAttribute("RidingSetAt")) or 0
				local hasValidLift = FindLiftModelByUUID(rideUUID) ~= nil
				local staleState = (rideChair == nil or rideSeat == nil or not hasValidLift)
				if staleState and (setAt <= 0 or (now - setAt) >= 1.5) then
					ClearPlayerRideState(player, false)
				end
			end
		end
	end
end)