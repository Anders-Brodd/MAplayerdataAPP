--!strict

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local PlacedObjects = Workspace:WaitForChild("PlacedObjects")
local Events = ReplicatedStorage:WaitForChild("Events")
local SlotData = ReplicatedStorage:WaitForChild("SlotData")

local REMOVE_REMOTE_NAME = "RequestRemoveSlopeNet"
local SAVE_EVENT_NAME = "RequestBuildingSave"
local DATASTORE_NAME = "SlopeNetDeletes_v1"
local SAVE_DELAY = 2
local RESYNC_INTERVAL = 2
local DEFAULT_VERTICAL_OFFSET = -0.2
local ALPHA_SCALE = 10000

local removeSlopeNetRemote = Events:FindFirstChild(REMOVE_REMOTE_NAME)
if not removeSlopeNetRemote then
	local remote = Instance.new("RemoteFunction")
	remote.Name = REMOVE_REMOTE_NAME
	remote.Parent = Events
	removeSlopeNetRemote = remote
end

local requestBuildingSave = Events:FindFirstChild(SAVE_EVENT_NAME)
local deleteStore = DataStoreService:GetDataStore(DATASTORE_NAME)

local deletedKeys: {[string]: true} = {}
local saveQueued = false
local saveAgain = false
local loadedDeletes = false

local function getNumberValue(name: string): number?
	local value = SlotData:FindFirstChild(name)
	if value and value:IsA("IntValue") then
		return value.Value
	end
	return nil
end

local function getSaveKey(): string?
	local userId = getNumberValue("UserId")
	local slotNum = getNumberValue("SlotNum")
	local createdTime = getNumberValue("CreatedTime") or 0
	if not userId or not slotNum then
		return nil
	end
	return string.format("%d:%d:%d:%d", game.PlaceId, userId, slotNum, createdTime)
end

local function saveDeletedKeys()
	local saveKey = getSaveKey()
	if not saveKey then
		return
	end

	local payload = table.create(64)
	for key in pairs(deletedKeys) do
		table.insert(payload, key)
	end

	local ok, err = pcall(function()
		deleteStore:SetAsync(saveKey, payload)
	end)
	if not ok then
	end
end

local function queueSave()
	if saveQueued then
		saveAgain = true
		return
	end

	saveQueued = true
	task.delay(SAVE_DELAY, function()
		repeat
			saveAgain = false
			saveDeletedKeys()
		until not saveAgain
		saveQueued = false
	end)

	if requestBuildingSave and requestBuildingSave:IsA("BindableEvent") then
		requestBuildingSave:Fire()
	end
end

local function loadDeletedKeys()
	if loadedDeletes then
		return
	end
	loadedDeletes = true

	local saveKey = getSaveKey()
	if not saveKey then
		return
	end

	local ok, data = pcall(function()
		return deleteStore:GetAsync(saveKey)
	end)
	if not ok then
		return
	end

	if type(data) == "table" then
		for _, key in ipairs(data) do
			if type(key) == "string" then
				deletedKeys[key] = true
			end
		end
	end
end

local function hashString(value: string): string
	local hash = 2166136261
	for index = 1, #value do
		hash = bit32.bxor(hash, string.byte(value, index))
		hash = (hash * 16777619) % 4294967296
	end
	return string.format("%08x", hash)
end

local function getSlopeUuid(slopeModel: Model): string
	local uuid = slopeModel:GetAttribute("UUID")
	if uuid ~= nil and tostring(uuid) ~= "" then
		return tostring(uuid)
	end

	local rawPoints = slopeModel:GetAttribute("RawPoints") or slopeModel:GetAttribute("ControlPoints")
	if type(rawPoints) == "string" and rawPoints ~= "" then
		local owner = slopeModel:GetAttribute("Owner")
		local slopeType = slopeModel:GetAttribute("Type")
		return string.format("legacy:%s:%s:%s", tostring(owner or 0), tostring(slopeType or slopeModel.Name), hashString(rawPoints))
	end

	local pivot = slopeModel:GetPivot().Position
	return string.format("legacy:%s:%s", slopeModel.Name, hashString(string.format("%.2f|%.2f|%.2f", pivot.X, pivot.Y, pivot.Z)))
end

local function decodePoints(raw: any): {Vector3}?
	if type(raw) ~= "string" or raw == "" then
		return nil
	end

	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if not ok or type(decoded) ~= "table" or #decoded < 2 then
		return nil
	end

	local points = table.create(#decoded)
	for _, value in ipairs(decoded) do
		if type(value) == "table" and #value >= 3 then
			table.insert(points, Vector3.new(tonumber(value[1]) or 0, tonumber(value[2]) or 0, tonumber(value[3]) or 0))
		end
	end

	if #points < 2 then
		return nil
	end
	return points
end

local function buildDistances(points: {Vector3}): ({number}, number)
	local distances = table.create(#points)
	distances[1] = 0
	local total = 0
	for index = 2, #points do
		total += (points[index] - points[index - 1]).Magnitude
		distances[index] = total
	end
	return distances, total
end

local function getHorizontalForward(tangent: Vector3): Vector3
	local horizontal = Vector3.new(tangent.X, 0, tangent.Z)
	if horizontal.Magnitude < 1e-4 then
		return Vector3.zAxis
	end
	return horizontal.Unit
end

local function sampleAtAlpha(points: {Vector3}, distances: {number}, totalLength: number, alpha: number): (Vector3, Vector3)
	if totalLength <= 1e-4 then
		return points[1], (points[#points] - points[1]).Magnitude > 0 and (points[#points] - points[1]).Unit or Vector3.xAxis
	end

	local targetDistance = math.clamp(alpha, 0, 1) * totalLength
	for index = 2, #points do
		local segmentStartDistance = distances[index - 1]
		local segmentEndDistance = distances[index]
		if targetDistance <= segmentEndDistance or index == #points then
			local a = points[index - 1]
			local b = points[index]
			local delta = b - a
			local segmentLength = delta.Magnitude
			if segmentLength <= 1e-4 then
				return a, index < #points and (points[index + 1] - a).Unit or Vector3.xAxis
			end
			local segmentAlpha = math.clamp((targetDistance - segmentStartDistance) / segmentLength, 0, 1)
			return a:Lerp(b, segmentAlpha), delta.Unit
		end
	end

	return points[#points], (points[#points] - points[#points - 1]).Unit
end

local function getNearestNetState(netModel: Model, slopeUuid: string, points: {Vector3}, distances: {number}, totalLength: number)
	local pivotPosition = netModel:GetPivot().Position
	local bestDistance = math.huge
	local bestAlpha = 0
	local bestPoint = points[1]
	local bestTangent = (points[2] - points[1]).Unit

	for index = 1, #points - 1 do
		local a = points[index]
		local b = points[index + 1]
		local delta = b - a
		local lengthSquared = delta:Dot(delta)
		if lengthSquared > 1e-4 then
			local t = math.clamp((pivotPosition - a):Dot(delta) / lengthSquared, 0, 1)
			local pointOnSegment = a + delta * t
			local distance = (pivotPosition - pointOnSegment).Magnitude
			if distance < bestDistance then
				bestDistance = distance
				bestPoint = pointOnSegment
				bestTangent = delta.Unit
				local segmentStartDistance = distances[index]
				local segmentLength = math.max(delta.Magnitude, 1e-4)
				bestAlpha = (segmentStartDistance + segmentLength * t) / math.max(totalLength, 1e-4)
			end
		end
	end

	local flatForward = getHorizontalForward(bestTangent)
	local sideAxis = Vector3.yAxis:Cross(flatForward)
	if sideAxis.Magnitude < 1e-4 then
		sideAxis = Vector3.xAxis
	else
		sideAxis = sideAxis.Unit
	end

	local offsetFromPath = pivotPosition - bestPoint
	local sideDot = offsetFromPath:Dot(sideAxis)
	local sideSign = sideDot >= 0 and 1 or -1
	local alphaKey = math.floor(bestAlpha * ALPHA_SCALE + 0.5)
	local persistKey = string.format("%s|%d|%d", slopeUuid, sideSign, alphaKey)

	return {
		alpha = bestAlpha,
		alphaKey = alphaKey,
		persistKey = persistKey,
		sideSign = sideSign,
		sideOffset = math.abs(sideDot),
		verticalOffset = pivotPosition.Y - bestPoint.Y,
		tangent = bestTangent,
		flatForward = flatForward,
	}
end

local function isSlopeModel(instance: Instance?): boolean
	return instance ~= nil
		and instance:IsA("Model")
		and (instance:GetAttribute("Type") == "Slope" or instance:GetAttribute("RawPoints") ~= nil)
end

local function canDeleteSlopeNet(player: Player, slopeModel: Model): boolean
	local owner = slopeModel:GetAttribute("Owner")
	if type(owner) == "number" and owner == player.UserId then
		return true
	end

	local slotOwner = getNumberValue("UserId")
	if slotOwner and slotOwner == player.UserId then
		return true
	end

	local trustedJson = SlotData:FindFirstChild("TrustedUserIdsJson")
	if trustedJson and trustedJson:IsA("StringValue") and trustedJson.Value ~= "" then
		local ok, decoded = pcall(function()
			return HttpService:JSONDecode(trustedJson.Value)
		end)
		if ok and type(decoded) == "table" then
			for _, value in ipairs(decoded) do
				if tonumber(value) == player.UserId then
					return true
				end
			end
		end
	end

	return false
end

local function tagNet(netModel: Model, slopeModel: Model, state)
	netModel:SetAttribute("GeneratedSlopeNet", true)
	netModel:SetAttribute("Type", "SlopeNet")
	netModel:SetAttribute("ParentSlopeUUID", slopeModel:GetAttribute("UUID"))
	netModel:SetAttribute("SlopeNetPersistKey", state.persistKey)
	netModel:SetAttribute("SlopeNetSideSign", state.sideSign)
	netModel:SetAttribute("SlopeNetProgressAlpha", state.alpha)
	netModel:SetAttribute("SlopeNetProgressKey", state.alphaKey)
	netModel:SetAttribute("SlopeNetSideOffset", state.sideOffset)
	netModel:SetAttribute("SlopeNetVerticalOffset", state.verticalOffset)
	local owner = slopeModel:GetAttribute("Owner")
	if type(owner) == "number" then
		netModel:SetAttribute("Owner", owner)
	end
end

local function syncNet(netModel: Model, slopeModel: Model, points: {Vector3}, distances: {number}, totalLength: number)
	local slopeUuid = getSlopeUuid(slopeModel)
	local currentState = getNearestNetState(netModel, slopeUuid, points, distances, totalLength)
	if deletedKeys[currentState.persistKey] then
		netModel:Destroy()
		return
	end

	tagNet(netModel, slopeModel, currentState)

	local targetPosition, targetTangent = sampleAtAlpha(points, distances, totalLength, currentState.alpha)
	local flatForward = getHorizontalForward(targetTangent)
	local sideAxis = Vector3.yAxis:Cross(flatForward)
	if sideAxis.Magnitude < 1e-4 then
		sideAxis = Vector3.xAxis
	else
		sideAxis = sideAxis.Unit
	end

	local sideDirection = sideAxis * currentState.sideSign
	local tangentDirection = targetTangent.Magnitude > 1e-4 and targetTangent.Unit or flatForward
	local upDirection = tangentDirection:Cross(sideDirection)
	if upDirection.Magnitude < 1e-4 then
		upDirection = Vector3.yAxis
	else
		upDirection = upDirection.Unit
		if upDirection:Dot(Vector3.yAxis) < 0 then
			upDirection = -upDirection
		end
	end

	local verticalOffset = currentState.verticalOffset
	if math.abs(verticalOffset) > 25 then
		verticalOffset = DEFAULT_VERTICAL_OFFSET
	end

	local targetPivot = targetPosition + sideDirection * currentState.sideOffset + Vector3.yAxis * verticalOffset
	netModel:PivotTo(CFrame.lookAt(targetPivot, targetPivot + sideDirection, upDirection))
end

local function syncSlope(slopeModel: Model)
	if not slopeModel.Parent then
		return
	end
	if slopeModel:GetAttribute("NetsEnabled") == false then
		return
	end

	local points = decodePoints(slopeModel:GetAttribute("RawPoints") or slopeModel:GetAttribute("ControlPoints"))
	if not points then
		return
	end

	local distances, totalLength = buildDistances(points)
	for _, child in ipairs(slopeModel:GetChildren()) do
		if child:IsA("Model") and child.Name == "Net" then
			syncNet(child, slopeModel, points, distances, totalLength)
		end
	end
end

local NET_MERGE_THRESHOLD = 12 -- studs (horizontal); endpoint nets this close at a junction merge are trimmed conservatively

local function horizontalDistance(a: Vector3, b: Vector3): number
	local axz = Vector3.new(a.X, 0, a.Z)
	local bxz = Vector3.new(b.X, 0, b.Z)
	return (axz - bxz).Magnitude
end

local function removeOverlappingNetsAtMergePoints()
	local allNets = {}
	for _, child in ipairs(PlacedObjects:GetChildren()) do
		if isSlopeModel(child) then
			local slopeUuid = getSlopeUuid(child)
			local points = decodePoints(child:GetAttribute("RawPoints") or child:GetAttribute("ControlPoints"))
			if not points then continue end
			local distances, totalLength = buildDistances(points)
			for _, netModel in ipairs(child:GetChildren()) do
				if netModel:IsA("Model") and netModel.Name == "Net" and netModel.Parent then
					local state = getNearestNetState(netModel, slopeUuid, points, distances, totalLength)
					table.insert(allNets, {
						model = netModel,
						slopeUuid = slopeUuid,
						position = netModel:GetPivot().Position,
						persistKey = state.persistKey,
						alpha = state.alpha,
					})
				end
			end
		end
	end

	for i = 1, #allNets do
		local a = allNets[i]
		if not a.model.Parent then continue end
		for j = i + 1, #allNets do
			local b = allNets[j]
			if not b.model.Parent then continue end
			if a.slopeUuid == b.slopeUuid then continue end
			local aEndpoint = a.alpha <= 0.08 or a.alpha >= 0.92
			local bEndpoint = b.alpha <= 0.08 or b.alpha >= 0.92
			if not (aEndpoint and bEndpoint) then
				continue
			end
			local dist = horizontalDistance(a.position, b.position)
			local verticalSep = math.abs(a.position.Y - b.position.Y)
			if dist < NET_MERGE_THRESHOLD and verticalSep < 12 then
				-- Keep one side of the merge intact so junctions do not reopen as a visible gap.
				deletedKeys[b.persistKey] = true
				b.model:Destroy()
			end
		end
	end

	-- Persist the deletions
	queueSave()
end

local function syncAllSlopes()
	for _, child in ipairs(PlacedObjects:GetChildren()) do
		if isSlopeModel(child) then
			syncSlope(child)
		end
	end
end

local function queueSlopeSync(instance: Instance?)
	if isSlopeModel(instance) then
		task.defer(syncSlope, instance :: Model)
		return
	end
	if instance and instance:IsA("Model") and instance.Name == "Net" and isSlopeModel(instance.Parent) then
		task.defer(syncSlope, instance.Parent :: Model)
	end
end

(removeSlopeNetRemote :: RemoteFunction).OnServerInvoke = function(player: Player, targetModel: Instance)
	if typeof(targetModel) ~= "Instance" or not targetModel:IsA("Model") or targetModel.Name ~= "Net" then
		return false, "Invalid net"
	end

	local slopeModel = targetModel.Parent
	if not isSlopeModel(slopeModel) then
		return false, "Invalid slope"
	end

	if not canDeleteSlopeNet(player, slopeModel :: Model) then
		return false, "Not allowed"
	end

	local points = decodePoints((slopeModel :: Model):GetAttribute("RawPoints") or (slopeModel :: Model):GetAttribute("ControlPoints"))
	if not points then
		return false, "Slope path missing"
	end

	local distances, totalLength = buildDistances(points)
	local slopeUuid = getSlopeUuid(slopeModel :: Model)
	local state = getNearestNetState(targetModel, slopeUuid, points, distances, totalLength)
	deletedKeys[state.persistKey] = true
	targetModel:Destroy()
	queueSave()
	return true
end

loadDeletedKeys()
syncAllSlopes()
removeOverlappingNetsAtMergePoints()

PlacedObjects.ChildAdded:Connect(queueSlopeSync)

task.spawn(function()
	while true do
		task.wait(RESYNC_INTERVAL)
		syncAllSlopes()
		removeOverlappingNetsAtMergePoints()
	end
end)

game:BindToClose(function()
	saveDeletedKeys()
end)