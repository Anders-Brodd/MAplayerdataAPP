--[=[ PATH: ReplicatedStorage/QueueSystem | TYPE: ModuleScript ]=]--
local QueueSystem = {}

local PERSON_WIDTH = 3.0
local PADDING = 2.0
local AUTO_QUEUE_ATTACHMENT_NAME = "AutoQueueAnchor"

local function isRoutingGeometryCandidate(inst, container)
	local current = inst
	while current and current ~= container do
		local parent = current.Parent
		if not parent then
			break
		end
		if parent:IsA("Model") then
			local lowered = string.lower(parent.Name)
			if lowered:find("cabin", 1, true)
				or lowered:find("carrier", 1, true)
				or lowered:find("chair", 1, true)
				or lowered:find("gondola", 1, true)
				or lowered:find("vehicle", 1, true)
				or lowered:find("cab", 1, true) then
				return false
			end
		end
		current = parent
	end
	return true
end

local function ensureAttachment(part)
	if not part or not part:IsA("BasePart") then return nil end
	local existing = part:FindFirstChild("Que") or part:FindFirstChild("Queue") or part:FindFirstChild(AUTO_QUEUE_ATTACHMENT_NAME)
	if existing and existing:IsA("Attachment") then
		return existing
	end
	local attachment = Instance.new("Attachment")
	attachment.Name = AUTO_QUEUE_ATTACHMENT_NAME
	attachment.Parent = part
	return attachment
end

local function findLoadHereAnchor(container)
	if not container then return nil end
	local loadHere = container:FindFirstChild("LoadHere", true)
	if not loadHere then return nil end
	if not isRoutingGeometryCandidate(loadHere, container) then
		return nil
	end
	if loadHere:IsA("Attachment") then
		return loadHere
	end
	if loadHere:IsA("BasePart") then
		return ensureAttachment(loadHere)
	end
	return nil
end

function QueueSystem.GetQueueWidth(capacity)
	capacity = math.max(1, capacity or 1)
	return (capacity * PERSON_WIDTH) + PADDING
end

function QueueSystem.GetQueueAttachment(model)
	if not model then return nil end
	
	-- Priority: Check StartStation descendants first (Lift logic)
	local startStation = model:FindFirstChild("StartStation")
	if startStation then
		for _, desc in ipairs(startStation:GetDescendants()) do
			if desc:IsA("Attachment") and (desc.Name == "Que" or desc.Name == "Queue") and isRoutingGeometryCandidate(desc, startStation) then
				return desc
			end
		end
		local loadHereAnchor = findLoadHereAnchor(startStation)
		if loadHereAnchor then
			return loadHereAnchor
		end
	end

	-- Search for "Que" attachment in Base or PrimaryPart
	local searchParts = {model.PrimaryPart}
	if model:FindFirstChild("Base") then table.insert(searchParts, model.Base) end
	
	for _, part in ipairs(searchParts) do
		if part then
			local att = part:FindFirstChild("Que") or part:FindFirstChild("Queue")
			if att and att:IsA("Attachment") and isRoutingGeometryCandidate(att, model) then return att end
		end
	end

	local loadHereAnchor = findLoadHereAnchor(model)
	if loadHereAnchor then
		return loadHereAnchor
	end
	
	-- Deep search fallback
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("Attachment") and (desc.Name == "Que" or desc.Name == "Queue") and isRoutingGeometryCandidate(desc, model) then
			return desc
		end
	end
	
	return nil
end

function QueueSystem.GetQueueStartPosition(model)
	local attachment = QueueSystem.GetQueueAttachment(model)
	if attachment then
		return attachment.WorldPosition
	end
	if not model then return nil end
	local startStation = model:FindFirstChild("StartStation")
	if startStation then
		local loadHere = startStation:FindFirstChild("LoadHere", true)
		if loadHere and loadHere:IsA("BasePart") then
			return loadHere.Position
		end
	end
	return model:GetPivot().Position
end

return QueueSystem