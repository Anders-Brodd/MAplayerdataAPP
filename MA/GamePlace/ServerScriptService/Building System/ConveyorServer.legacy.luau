--[=[ PATH: ServerScriptService/Building System/ConveyorServer.legacy.luau | TYPE: Script ]=]--
--[[
	CONVEYOR SERVER
	Drives standalone conveyors plus magic-carpet lift sections.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Config"))

-- // CONFIG //
local CONVEYOR_SPEED = 10 -- Speed in studs per second
local STANDALONE_CONVEYOR_NAMES = {
	["Conveyor"] = true,
	["MagicCarpet"] = true,
}

local BoundModels = {}

local function IsStandaloneConveyor(model)
	return model and model:IsA("Model") and STANDALONE_CONVEYOR_NAMES[model.Name] == true
end

local function IsCarpetLift(model)
	return model and model:IsA("Model") and model:GetAttribute("Type") == "Carpet"
end

local function ApplyConveyorPhysics(part, direction, speed)
	if not (part and part:IsA("BasePart")) then
		return
	end

	part.Anchored = true
	part.CanCollide = true
	part.CustomPhysicalProperties = PhysicalProperties.new(0.7, 2.0, 0.5, 100, 1)
	part.AssemblyLinearVelocity = direction * speed
end

local function CollectPushParts(model)
	local partsToPush = {}
	local belt = model:FindFirstChild("Belt")
	if belt and belt:IsA("BasePart") then
		table.insert(partsToPush, belt)
	end

	local base = model:FindFirstChild("Base")
	if base and base:IsA("BasePart") and base ~= belt then
		table.insert(partsToPush, base)
	end

	if #partsToPush == 0 and model.PrimaryPart then
		table.insert(partsToPush, model.PrimaryPart)
	end

	return partsToPush, belt
end

local function ResolveLegacyDirection(model, belt, fallbackPart)
	local direction = fallbackPart.CFrame.LookVector
	local att1 = model:FindFirstChild("1", true) or model:FindFirstChild("Start", true)
	local att2 = model:FindFirstChild("2", true) or model:FindFirstChild("End", true)

	if att1 and att2 then
		local vec = att2.WorldPosition - att1.WorldPosition
		if vec.Magnitude > 0.1 then
			direction = vec.Unit
		end
	elseif att1 and att1:IsA("Attachment") then
		direction = att1.WorldCFrame.LookVector
	end

	return direction, att1, att2
end

local function ResolveLiftConfig(liftModel)
	if not liftModel then
		return nil
	end

	local modelId = liftModel:GetAttribute("ID")
	if modelId and type(Config.GetItemById) == "function" then
		local _, itemConfig = Config.GetItemById(modelId)
		if itemConfig then
			return itemConfig
		end
	end

	local defaultName = liftModel:GetAttribute("DefaultPlacedName") or liftModel.Name
	return Config.Items[defaultName]
end

local function ResolveCarpetSpeed(liftModel)
	local liftConfig = ResolveLiftConfig(liftModel)
	local baseSpeed = tonumber(liftConfig and liftConfig.Speed) or CONVEYOR_SPEED
	local targetSpeed = tonumber(liftModel:GetAttribute("TargetSpeed"))
	if targetSpeed == nil then
		local status = tostring(liftModel:GetAttribute("Status") or "")
		targetSpeed = (status == "Stopped" or status == "Broken") and 0 or 1
	end
	return baseSpeed * math.max(0, targetSpeed)
end

local function UpdateStandaloneConveyor(model)
	local partsToPush, belt = CollectPushParts(model)
	local refPart = belt or model.PrimaryPart or partsToPush[1]
	if not refPart then
		return
	end

	local speed = tonumber(model:GetAttribute("ConveyorSpeed")) or CONVEYOR_SPEED
	local direction, att1, att2 = ResolveLegacyDirection(model, belt, refPart)

	for _, part in ipairs(partsToPush) do
		ApplyConveyorPhysics(part, direction, speed)
	end

	local beam = model:FindFirstChild("Beam", true)
	if beam and beam:IsA("Beam") and att1 and att2 then
		beam.Attachment0 = att1
		beam.Attachment1 = att2
		local texLen = beam.TextureLength
		if texLen < 12 then
			texLen = 35
			beam.TextureLength = texLen
		end
		beam.TextureSpeed = speed / texLen
	end
end

local function UpdateCarpetLift(liftModel)
	local sectionsFolder = liftModel:FindFirstChild("Sections")
	if not sectionsFolder then
		return
	end

	local speed = ResolveCarpetSpeed(liftModel)
	for _, section in ipairs(sectionsFolder:GetChildren()) do
		if section:IsA("Model") then
			local partsToPush, belt = CollectPushParts(section)
			local refPart = belt or section.PrimaryPart or partsToPush[1]
			if refPart then
				local direction = refPart.CFrame.LookVector
				for _, part in ipairs(partsToPush) do
					ApplyConveyorPhysics(part, direction, speed)
				end
			end
		elseif section:IsA("BasePart") then
			ApplyConveyorPhysics(section, section.CFrame.LookVector, speed)
		end
	end
end

local function RefreshModel(model)
	if IsStandaloneConveyor(model) then
		UpdateStandaloneConveyor(model)
	elseif IsCarpetLift(model) then
		UpdateCarpetLift(model)
	end
end

local function BindModel(model)
	if not model or BoundModels[model] then
		return
	end
	if not IsStandaloneConveyor(model) and not IsCarpetLift(model) then
		return
	end

	BoundModels[model] = true
	model.Destroying:Connect(function()
		BoundModels[model] = nil
	end)

	if IsStandaloneConveyor(model) then
		if model:GetAttribute("ConveyorSpeed") == nil then
			model:SetAttribute("ConveyorSpeed", CONVEYOR_SPEED)
		end
		RefreshModel(model)
		model:GetPropertyChangedSignal("WorldPivot"):Connect(function()
			RefreshModel(model)
		end)
		model:GetAttributeChangedSignal("ConveyorSpeed"):Connect(function()
			RefreshModel(model)
		end)
		return
	end

	RefreshModel(model)
	for _, attributeName in ipairs({"TargetSpeed", "Status", "RefreshID"}) do
		model:GetAttributeChangedSignal(attributeName):Connect(function()
			RefreshModel(model)
		end)
	end
	model.ChildAdded:Connect(function(child)
		if child.Name == "Sections" then
			task.defer(function()
				RefreshModel(model)
			end)
		end
	end)
	model:GetPropertyChangedSignal("WorldPivot"):Connect(function()
		RefreshModel(model)
	end)

	local sectionsFolder = model:FindFirstChild("Sections")
	if sectionsFolder then
		sectionsFolder.ChildAdded:Connect(function()
			task.defer(function()
				RefreshModel(model)
			end)
		end)
		sectionsFolder.ChildRemoved:Connect(function()
			task.defer(function()
				RefreshModel(model)
			end)
		end)
	end
end

-- // INIT //
task.spawn(function()
	local placedObjects = Workspace:FindFirstChild("PlacedObjects")
	if not placedObjects then
		placedObjects = Workspace:WaitForChild("PlacedObjects")
	end

	placedObjects.ChildAdded:Connect(BindModel)
	for _, child in ipairs(placedObjects:GetChildren()) do
		BindModel(child)
	end
end)