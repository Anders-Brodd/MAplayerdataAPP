--[=[ PATH: ServerScriptService/CableServer | TYPE: Script ]=]--
--[[
	CABLE SERVER V23 (DYNAMIC VISUAL SAG)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CableConfig = require(ReplicatedStorage:WaitForChild("CableConfig"))

local function CreateCylinder(p0, p1, parent)
	local distance = (p1 - p0).Magnitude
	if distance < 0.05 then return end 
	local part = Instance.new("Part")
	part.Name = "CableSeg"
	part.Anchored = true
	part.CanCollide = false
	part.CastShadow = true
	part.Material = CableConfig.Material
	part.Color = CableConfig.Color
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(distance, CableConfig.Thickness, CableConfig.Thickness)
	local center = (p0 + p1) / 2
	part.CFrame = CFrame.lookAt(center, p1) * CFrame.Angles(0, math.pi/2, 0)
	part.Parent = parent
end

local function DrawCable(att0, att1, parent, forceStraight, customSag)
	if not att0 or not att1 then return end
	local p0 = att0.WorldPosition
	local p1 = att1.WorldPosition
	local distance = (p1 - p0).Magnitude

	if forceStraight and not customSag then
		if distance < CableConfig.MinDistanceForSag then CreateCylinder(p0, p1, parent); return end
	end

	local segments = CableConfig.SegmentsPerSpan

	-- [NATURAL SAG FIX]
	local sag = customSag
	if not sag then
		if forceStraight then 
			sag = 0 
		else
			-- Dynamic sag based on distance
			local ratio = CableConfig.SagRatio or 0.035
			sag = distance * ratio
		end
	end

	local midPoint = (p0 + p1) / 2
	local controlPoint = midPoint - Vector3.new(0, sag * 2, 0) 
	local lastPos = p0
	for i = 1, segments do
		local t = i / segments
		local l1 = p0:Lerp(controlPoint, t)
		local l2 = controlPoint:Lerp(p1, t)
		local currentPos = l1:Lerp(l2, t)
		CreateCylinder(lastPos, currentPos, parent)
		lastPos = currentPos
	end
end

local function DrawCircleThrough3Points(p1, p2, p3, parent)
	-- Standard circle drawing logic (unchanged)
	local v1, v2, v3 = p1.WorldPosition, p2.WorldPosition, p3.WorldPosition
	if (v2-v1):Cross(v3-v2).Magnitude < 0.001 then CreateCylinder(v1, v2, parent); CreateCylinder(v2, v3, parent); return end
	local a, b, c = v1, v2, v3
	local ac, ab = c - a, b - a
	local abXac = ab:Cross(ac)
	local toCenter = (abXac:Cross(ab)*ac.Magnitude^2 + ac:Cross(abXac)*ab.Magnitude^2) / (2 * abXac.Magnitude^2)
	local center = a + toCenter
	local function DrawArc(startP, endP)
		local startVec = (startP - center)
		local endVec = (endP - center)
		local angle = math.acos(math.clamp(startVec.Unit:Dot(endVec.Unit), -1, 1))
		local axis = startVec:Cross(endVec).Unit
		local lastP = startP
		for i = 1, 5 do
			local alpha = angle * (i / 5)
			local currP = center + CFrame.fromAxisAngle(axis, alpha):VectorToWorldSpace(startVec)
			CreateCylinder(lastP, currP, parent)
			lastP = currP
		end
	end
	DrawArc(v1, v2); DrawArc(v2, v3)
end

local function CleanName(n) return n:lower():gsub("^%s+", ""):gsub("%s+$", "") end

local function FindAttSmart(model, baseName)
	if not model then return nil end
	local lowerBase = CleanName(baseName)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Attachment") then
			local cName = CleanName(d.Name)
			if cName:sub(-#lowerBase) == lowerBase then
				local pre = cName:sub(1, #cName - #lowerBase)
				if pre == "" or pre:match("[%d%.]*[%-$]+") then
					local isC = pre:find("%$")~=nil
					local isI = pre:find("%-")~=nil
					local val = tonumber((pre:gsub("[%-$]","")))
					if isC and not val then val = 0.5 end
					return {Att=d, IsCurve=isC, Invert=isI, Sag=val}
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
			table.insert(list, {Att = foundAtt, IsCurve = isCurve, Invert = isInvert, Sag = val})
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

local function WireStation(stationModel, folder)
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

	local curve = nodeMap.Curve
	if curve then
		local b1 = nodeMap.B1
		local b2 = nodeMap.B2

		local function ConnectSequence(seqNames)
			local nodes = {}
			for _, n in ipairs(seqNames) do
				local info = nodeMap[n]
				if info then table.insert(nodes, info) end
			end
			for k=1, #nodes-1 do
				local c = nodes[k]
				local n = nodes[k+1]
				local s = nil
				if c.IsCurve then s = c.Invert and -(c.Sag or 0.5) or (c.Sag or 0.5) end
				DrawCable(c.Att, n.Att, folder, true, s)
			end
			return nodes[#nodes]
		end

		local entryNames = b1 and {"F1", "G1", "A1", "B1"} or {"F1"}
		local lastEntry = ConnectSequence(entryNames)
		if lastEntry then
			local arcExit = b2 or nodeMap.F2
			if arcExit then
				DrawCircleThrough3Points(lastEntry.Att, curve.Att, arcExit.Att, folder)
			end
		end

		local exitNames = b2 and {"B2", "A2", "G2", "F2"} or {"F2"}
		ConnectSequence(exitNames)
	else
		local f1 = nodeMap.F1
		local f2 = nodeMap.F2
		if f1 and f2 then DrawCable(f1.Att, f2.Att, folder, true) end
	end
end

local function BuildCable(liftModel)
	if not liftModel:FindFirstChild("StartStation") then task.wait(1.5) end
	local startStation = liftModel:WaitForChild("StartStation", 5)
	local endStation = liftModel:WaitForChild("EndStation", 5)
	if not startStation or not endStation then return end

	local old = liftModel:FindFirstChild("CableSystem")
	if old then old:Destroy() end
	local cf = Instance.new("Folder", liftModel); cf.Name = "CableSystem"

	WireStation(startStation, cf)
	task.wait()
	WireStation(endStation, cf)
	task.wait()

	local poles = {}
	for _, c in ipairs(liftModel:GetChildren()) do if c.Name:match("Pole_%d+") then table.insert(poles, c) end end
	table.sort(poles, function(a,b) return (tonumber(a.Name:match("%d+")) or 0) < (tonumber(b.Name:match("%d+")) or 0) end)

	local function ConnectLine(fromStation, toStation, attStartName, attEndName, side)
		local startInfo = FindAttSmart(fromStation, attStartName)
		local endInfo = FindAttSmart(toStation, attEndName)
		if not startInfo then return end
		local last = startInfo.Att
		local list = poles
		if side == "L" then
			local r = {}
			for i=#poles,1,-1 do table.insert(r, poles[i]) end
			list = r
		end
		for poleIndex, p in ipairs(list) do
			local nodes = GetOrderedAttachments(p, side)
			if #nodes > 0 then
				local nextPos = endInfo and endInfo.Att.WorldPosition or nil
				for futureIndex = poleIndex + 1, #list do
					local futureNodes = GetOrderedAttachments(list[futureIndex], side)
					if #futureNodes > 0 then
						nextPos = futureNodes[1].Att.WorldPosition
						break
					end
				end
				nodes = NormalizeAttachmentList(nodes, last and last.WorldPosition or nil, nextPos)
				DrawCable(last, nodes[1].Att, cf, false) 
				for k=1, #nodes-1 do
					local c, n = nodes[k], nodes[k+1]
					local s = nil
					if c.IsCurve then s = c.Invert and -(c.Sag or 0.5) or (c.Sag or 0.5) end
					DrawCable(c.Att, n.Att, cf, true, s)
				end
				last = nodes[#nodes].Att
				task.wait()
			end
		end
		if endInfo then
			DrawCable(last, endInfo.Att, cf, false)
			task.wait()
		end
	end

	ConnectLine(startStation, endStation, "F2", "F1", "R")
	task.wait()
	ConnectLine(endStation, startStation, "F2", "F1", "L")
end

local function OnChildAdded(c)
	if c:IsA("Model") and c:GetAttribute("Type") == "TwoPoint" then
		task.spawn(function() BuildCable(c) end)
		c:GetAttributeChangedSignal("RefreshID"):Connect(function() BuildCable(c) end)
	end
end
local pf = workspace:WaitForChild("PlacedObjects", 10)
if pf then pf.ChildAdded:Connect(OnChildAdded); for _, c in ipairs(pf:GetChildren()) do OnChildAdded(c) end end