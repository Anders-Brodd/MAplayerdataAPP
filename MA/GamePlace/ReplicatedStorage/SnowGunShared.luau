local SnowGunShared = {}

SnowGunShared.ItemNames = {
	"10ft Swine Tower",
	"15ft Swine Tower",
	"Skua-30",
	"Stoat-6",
	"Stoat-10",
	"SnowCannon",
}

SnowGunShared.LegacyNames = {
	"SnowGun",
	"10ft Narwhal Tower",
	"15ft Narwhal Tower",
	"20ft Narwhal Tower",
}

SnowGunShared.Profiles = {
	["10ft Swine Tower"] = {
		OscillationAngle = 28,
		ThrowDistance = 84,
		RadiusMultiplier = 1.0,
		EmitterRateScale = 0.9,
		UpkeepMultiplier = 1.0,
	},
	["15ft Swine Tower"] = {
		OscillationAngle = 24,
		ThrowDistance = 100,
		RadiusMultiplier = 1.12,
		EmitterRateScale = 0.95,
		UpkeepMultiplier = 1.14,
	},
	["10ft Narwhal Tower"] = {
		OscillationAngle = 28,
		ThrowDistance = 84,
		RadiusMultiplier = 1.0,
		EmitterRateScale = 0.9,
		UpkeepMultiplier = 1.0,
	},
	["15ft Narwhal Tower"] = {
		OscillationAngle = 24,
		ThrowDistance = 100,
		RadiusMultiplier = 1.12,
		EmitterRateScale = 0.95,
		UpkeepMultiplier = 1.14,
	},
	["20ft Narwhal Tower"] = {
		OscillationAngle = 18,
		ThrowDistance = 112,
		RadiusMultiplier = 1.24,
		EmitterRateScale = 1.0,
		UpkeepMultiplier = 1.3,
	},
	["Skua-30"] = {
		OscillationAngle = 0,
		ThrowDistance = 118,
		RadiusMultiplier = 0.9,
		EmitterRateScale = 0.85,
		UpkeepMultiplier = 0.9,
	},
	["Stoat-6"] = {
		OscillationAngle = 0,
		ThrowDistance = 92,
		RadiusMultiplier = 0.88,
		EmitterRateScale = 0.82,
		UpkeepMultiplier = 0.85,
	},
	["Stoat-10"] = {
		OscillationAngle = 0,
		ThrowDistance = 108,
		RadiusMultiplier = 0.98,
		EmitterRateScale = 0.9,
		UpkeepMultiplier = 0.92,
	},
	["SnowCannon"] = {
		OscillationAngle = 0,
		ThrowDistance = 88,
		RadiusMultiplier = 0.95,
		EmitterRateScale = 0.8,
		UpkeepMultiplier = 0.9,
	},
	["SnowGun"] = {
		OscillationAngle = 35,
		ThrowDistance = 80,
		RadiusMultiplier = 1.0,
		EmitterRateScale = 0.9,
		UpkeepMultiplier = 1.0,
	},
}

SnowGunShared.ModelConfigs = {
	["10ft Swine Tower"] = {
		DefaultSprayFace = Enum.NormalId.Right,
		SprayFaces = {
			Nozzle = Enum.NormalId.Right,
		},
		YawAxis = "WorldY",
		DisableSpin = true,
	},
	["15ft Swine Tower"] = {
		DefaultSprayFace = Enum.NormalId.Right,
		SprayFaces = {
			Nozzle = Enum.NormalId.Right,
		},
		YawAxis = "WorldY",
		DisableSpin = true,
	},
	["10ft Narwhal Tower"] = {
		DefaultSprayFace = Enum.NormalId.Front,
		YawAxis = "WorldY",
		DisableSpin = true,
	},
	["15ft Narwhal Tower"] = {
		DefaultSprayFace = Enum.NormalId.Front,
		YawAxis = "WorldY",
		DisableSpin = true,
	},
	["20ft Narwhal Tower"] = {
		DefaultSprayFace = Enum.NormalId.Front,
		YawAxis = "WorldY",
		DisableSpin = true,
	},
	["Stoat-6"] = {
		BaseRotationOffset = CFrame.Angles(0, 0, math.pi),
		UseRotateModelPivot = true,
	},
	["Stoat-10"] = {
		BaseRotationOffset = CFrame.Angles(0, 0, math.pi),
		UseRotateModelPivot = true,
	},
	["Skua-30"] = {
		UseRotateModelPivot = true,
	},
}

local NameSet = {}
for _, name in ipairs(SnowGunShared.ItemNames) do
	NameSet[name] = true
end
for _, name in ipairs(SnowGunShared.LegacyNames) do
	NameSet[name] = true
end

local SUPPORTED_VISUAL_EFFECT_CLASSES = {
	ParticleEmitter = true,
	Beam = true,
	Trail = true,
	Smoke = true,
	Fire = true,
	PointLight = true,
	SpotLight = true,
	SurfaceLight = true,
}

local function addUniqueInstance(list, seen, instance)
	if instance and not seen[instance] then
		seen[instance] = true
		table.insert(list, instance)
	end
end

local function firstDescendant(root, names)
	if not root then
		return nil
	end
	for _, name in ipairs(names) do
		local found = root:FindFirstChild(name, true)
		if found then
			return found
		end
	end
	return nil
end

local function firstBasePart(root)
	if not root then
		return nil
	end
	if root:IsA("BasePart") then
		return root
	end
	if root:IsA("Model") and root.PrimaryPart then
		return root.PrimaryPart
	end
	return root:FindFirstChildWhichIsA("BasePart", true)
end

local function localAxisRotation(axisName, angle)
	if axisName == "X" then
		return CFrame.Angles(angle, 0, 0)
	elseif axisName == "Y" then
		return CFrame.Angles(0, angle, 0)
	end
	return CFrame.Angles(0, 0, angle)
end

local function getInstanceCFrame(instance)
	if not instance then
		return nil
	end
	if instance:IsA("Model") then
		return instance:GetPivot()
	elseif instance:IsA("BasePart") then
		return instance.CFrame
	end
	return nil
end

local function applyInstanceCFrame(instance, cf)
	if not instance or not cf then
		return
	end
	if instance:IsA("Model") then
		instance:PivotTo(cf)
	elseif instance:IsA("BasePart") then
		instance.CFrame = cf
	end
end

local function normalIdToLocalVector(normalId)
	if normalId == Enum.NormalId.Top then
		return Vector3.new(0, 1, 0)
	elseif normalId == Enum.NormalId.Bottom then
		return Vector3.new(0, -1, 0)
	elseif normalId == Enum.NormalId.Right then
		return Vector3.new(1, 0, 0)
	elseif normalId == Enum.NormalId.Left then
		return Vector3.new(-1, 0, 0)
	elseif normalId == Enum.NormalId.Front then
		return Vector3.new(0, 0, -1)
	elseif normalId == Enum.NormalId.Back then
		return Vector3.new(0, 0, 1)
	end
	return nil
end

local function partFaceToWorldVector(part, normalId)
	local localVector = normalIdToLocalVector(normalId)
	if not part or not localVector then
		return nil
	end
	return part.CFrame:VectorToWorldSpace(localVector)
end

local function getConfiguredSprayFace(config, partName)
	if not config then
		return nil
	end
	if config.SprayFaces and config.SprayFaces[partName] then
		return config.SprayFaces[partName]
	end
	return config.DefaultSprayFace
end

local function getSpinAxisName(part)
	local size = part.Size
	if size.X <= size.Y and size.X <= size.Z then
		return "X"
	elseif size.Y <= size.Z then
		return "Y"
	end
	return "Z"
end

local function ensureAttachmentAtEdge(part, name, towardWorldPosition)
	local attachment = part:FindFirstChild(name)
	if not attachment or not attachment:IsA("Attachment") then
		if attachment then attachment:Destroy() end
		attachment = Instance.new("Attachment")
		attachment.Name = name
		attachment.Parent = part
	end
	local worldDir = towardWorldPosition - part.Position
	if worldDir.Magnitude > 0.001 then
		local localDir = part.CFrame:VectorToObjectSpace(worldDir.Unit)
		local extents = part.Size * 0.5
		attachment.Position = Vector3.new(
			math.clamp(localDir.X, -1, 1) * extents.X * 0.9,
			math.clamp(localDir.Y, -1, 1) * extents.Y * 0.9,
			math.clamp(localDir.Z, -1, 1) * extents.Z * 0.9
		)
	else
		attachment.Position = Vector3.zero
	end
	return attachment
end

local function ensureBeamBetween(part0, part1, beamName, color, width)
	if not part0 or not part1 or not part0:IsA("BasePart") or not part1:IsA("BasePart") then
		return nil
	end
	local a0 = ensureAttachmentAtEdge(part0, beamName .. "Attachment0", part1.Position)
	local a1 = ensureAttachmentAtEdge(part1, beamName .. "Attachment1", part0.Position)
	local beam = part0:FindFirstChild(beamName)
	if beam and not beam:IsA("Beam") then
		beam:Destroy()
		beam = nil
	end
	if not beam then
		beam = Instance.new("Beam")
		beam.Name = beamName
		beam.Parent = part0
	end
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.FaceCamera = false
	beam.LightEmission = 0
	beam.LightInfluence = 1
	beam.Segments = 6
	beam.Width0 = width
	beam.Width1 = width
	beam.TextureMode = Enum.TextureMode.Wrap
	beam.TextureLength = 1
	beam.Color = ColorSequence.new(color)
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.12),
		NumberSequenceKeypoint.new(1, 0.18),
	})
	return beam
end

function SnowGunShared.IsSnowGunName(name)
	return NameSet[name] == true
end

function SnowGunShared.GetItemNames(includeLegacy)
	local names = table.clone(SnowGunShared.ItemNames)
	if includeLegacy then
		for _, legacyName in ipairs(SnowGunShared.LegacyNames) do
			table.insert(names, legacyName)
		end
	end
	return names
end

function SnowGunShared.GetModelConfig(modelOrName)
	local name = typeof(modelOrName) == "Instance" and modelOrName.Name or tostring(modelOrName or "")
	local config = SnowGunShared.ModelConfigs[name]
	if not config then
		return {}
	end
	return table.clone(config)
end

function SnowGunShared.GetProfile(modelOrName)
	local name = typeof(modelOrName) == "Instance" and modelOrName.Name or tostring(modelOrName or "")
	local profile = SnowGunShared.Profiles[name] or SnowGunShared.Profiles["10ft Swine Tower"]
	return table.clone(profile)
end

function SnowGunShared.PrepareModel(model)
	if not model or not model:IsA("Model") then
		return
	end
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BaseScript") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.AssemblyLinearVelocity = Vector3.zero
			descendant.AssemblyAngularVelocity = Vector3.zero
			local lowerName = string.lower(descendant.Name)
			if lowerName:find("fan", 1, true)
				or lowerName:find("cable", 1, true)
				or lowerName:find("hose", 1, true)
				or lowerName:find("supply", 1, true)
				or lowerName:find("waterstart", 1, true)
				or lowerName:find("airstart", 1, true)
				or lowerName:find("watershoot", 1, true)
				or lowerName:find("dial", 1, true)
				or lowerName:find("snow", 1, true)
			then
				descendant.CanCollide = false
			end
		elseif descendant:IsA("RopeConstraint") then
			descendant.Visible = false
		end
	end

	local waterSupply = firstDescendant(model, { "WATERSUPPLY" })
	local waterStart = firstDescendant(model, { "WaterStart" })
	ensureBeamBetween(waterSupply, waterStart, "WaterHoseBeam", Color3.fromRGB(52, 64, 79), 0.18)

	local airSupply = firstDescendant(model, { "AIRSUPPLY" })
	local airStart = firstDescendant(model, { "AirStart", "AIRSTART" })
	if airSupply and airStart then
		ensureBeamBetween(airSupply, airStart, "AirHoseBeam", Color3.fromRGB(116, 126, 138), 0.14)
	end
end

function SnowGunShared.ResolveRig(model)
	if not model or not model:IsA("Model") then
		return nil
	end

	local rotateModel = model:FindFirstChild("ROTATE")
	if not rotateModel then
		rotateModel = firstDescendant(model, { "ROTATE W/PIVOT", "Lance", "Canon Itself" })
	end

	local emitterFolder = model:FindFirstChild("Emitters") or firstDescendant(model, { "Emitters" })
	local rig = {
		Profile = SnowGunShared.GetProfile(model),
		Config = SnowGunShared.GetModelConfig(model),
		RotateModel = rotateModel,
		RotateTarget = rotateModel,
		PivotPart = nil,
		BaseInstance = nil,
		WaterSound = firstDescendant(model, { "Watah" }),
		RunSound = firstDescendant(model, { "FAN_RUN", "AIRSOUND", "FanHummingSFX" }),
		CompressorSound = firstDescendant(model, { "Compressor" }),
		PressureSound = firstDescendant(model, { "Pressure" }),
		EmitterMode = "None",
		Emitters = {},
		Nozzle = nil,
		Followers = {},
		TargetFromPivot = CFrame.new(),
	}

	rig.PivotPart = firstDescendant(rotateModel or model, { "BLOWERSOUND", "HingeStick", "Mobile", "Shaft", "thick shaft", "SnowMaker" })
	if not rig.PivotPart then
		rig.PivotPart = firstBasePart(rotateModel) or model.PrimaryPart or firstBasePart(model)
	end
	if not rig.RotateTarget then
		rig.RotateTarget = rig.PivotPart or firstBasePart(model)
	end

	if emitterFolder then
		local nozzle = emitterFolder:FindFirstChild("Nozzle")
		if nozzle and nozzle:IsA("BasePart") then
			rig.EmitterMode = "Nozzle"
			rig.Nozzle = nozzle
		else
			for _, partName in ipairs({ "SnowC", "SnowL", "SnowR", "SkuaSnowLong", "SkuaSnowDown", "StoatSnowLong", "StoatSnowDown", "SnowHead", "SnowMaker" }) do
				local emitterPart = emitterFolder:FindFirstChild(partName)
				if emitterPart and emitterPart:IsA("BasePart") then
					table.insert(rig.Emitters, emitterPart)
				end
			end
			if #rig.Emitters == 0 then
				for _, child in ipairs(emitterFolder:GetChildren()) do
					if child:IsA("BasePart") and (child:FindFirstChildOfClass("ParticleEmitter") or child:FindFirstChildOfClass("Smoke")) then
						table.insert(rig.Emitters, child)
					end
				end
			end
			if #rig.Emitters > 0 then
				rig.EmitterMode = "Parts"
			end
		end
	end

	if rig.EmitterMode == "None" then
		for _, partName in ipairs({ "Squirt", "SnowC", "SnowL", "SnowR", "SkuaSnowLong", "SkuaSnowDown", "StoatSnowLong", "StoatSnowDown", "SnowHead", "SnowMaker" }) do
			local emitterPart = model:FindFirstChild(partName, true)
			if emitterPart and emitterPart:IsA("BasePart") then
				table.insert(rig.Emitters, emitterPart)
			end
		end
		if #rig.Emitters > 0 then
			rig.EmitterMode = "Parts"
		end
	end

	rig.BaseInstance = (rig.Config and rig.Config.UseRotateModelPivot and rig.RotateModel) or rig.PivotPart or rig.RotateTarget or rig.RotateModel

	local baseInstanceCFrame = getInstanceCFrame(rig.BaseInstance)
	local targetCFrame = getInstanceCFrame(rig.RotateTarget)
	if baseInstanceCFrame and targetCFrame then
		local targetOffset = baseInstanceCFrame:ToObjectSpace(targetCFrame)
		if rig.Config and rig.Config.UsePositionOnlyTargetOffset then
			rig.TargetFromPivot = CFrame.new(targetOffset.Position)
		else
			rig.TargetFromPivot = targetOffset
		end
	end

	local followerSeen = {}
	local function addFollower(part)
		if not part or not part:IsA("BasePart") or followerSeen[part] then
			return
		end
		followerSeen[part] = true
		if part == rig.PivotPart or part == rig.RotateTarget then
			return
		end
		if rig.RotateTarget and part:IsDescendantOf(rig.RotateTarget) then
			return
		end
		local baseInstanceCFrame = getInstanceCFrame(rig.BaseInstance)
		if not baseInstanceCFrame then
			return
		end
		table.insert(rig.Followers, {
			Part = part,
			RelativeCFrame = baseInstanceCFrame:ToObjectSpace(part.CFrame),
		})
	end

	addFollower(rig.Nozzle)
	for _, emitterPart in ipairs(rig.Emitters) do
		addFollower(emitterPart)
	end

	return rig
end

function SnowGunShared.IsSupportedVisualEffect(instance)
	return instance ~= nil and SUPPORTED_VISUAL_EFFECT_CLASSES[instance.ClassName] == true
end

function SnowGunShared.GetVisualEffectContainers(rig)
	local containers = {}
	local seen = {}
	if not rig then
		return containers
	end
	addUniqueInstance(containers, seen, rig.Nozzle)
	for _, emitterPart in ipairs(rig.Emitters or {}) do
		addUniqueInstance(containers, seen, emitterPart)
	end
	return containers
end

function SnowGunShared.ApplyConfiguredEmissionDirections(rig)
	if not rig then
		return
	end
	local config = rig.Config
	for _, container in ipairs(SnowGunShared.GetVisualEffectContainers(rig)) do
		if container and container:IsA("BasePart") then
			local face = getConfiguredSprayFace(config, container.Name)
			if face then
				for _, child in ipairs(container:GetChildren()) do
					if child:IsA("ParticleEmitter") then
						child.EmissionDirection = face
					end
				end
			end
		end
	end
end

function SnowGunShared.GetSprayDirectionWorld(rig)
	if not rig then
		return nil
	end
	local config = rig.Config
	for _, container in ipairs(SnowGunShared.GetVisualEffectContainers(rig)) do
		if container and container:IsA("BasePart") then
			local face = getConfiguredSprayFace(config, container.Name)
			if not face then
				local emitter = container:FindFirstChildOfClass("ParticleEmitter")
				face = emitter and emitter.EmissionDirection or nil
			end
			local direction = face and partFaceToWorldVector(container, face) or nil
			if direction and direction.Magnitude > 0.001 then
				return direction.Unit
			end
		end
	end
	if rig.PivotPart then
		return rig.PivotPart.CFrame.LookVector
	end
	return nil
end

function SnowGunShared.GetOscillatedBaseCFrame(rig, baseCFrame, yawRadians)
	if not baseCFrame then
		return nil
	end
	local yawAxis = (rig and rig.Config and rig.Config.YawAxis) or "Y"
	if not yawRadians or math.abs(yawRadians) < 0.0001 then
		return baseCFrame
	end
	if yawAxis == "WorldY" then
		local worldRotation = CFrame.Angles(0, yawRadians, 0)
		local rotatedRight = worldRotation:VectorToWorldSpace(baseCFrame.RightVector)
		local rotatedUp = worldRotation:VectorToWorldSpace(baseCFrame.UpVector)
		local rotatedLook = worldRotation:VectorToWorldSpace(baseCFrame.LookVector)
		return CFrame.fromMatrix(baseCFrame.Position, rotatedRight, rotatedUp, -rotatedLook)
	end
	return baseCFrame * localAxisRotation(yawAxis, yawRadians)
end

function SnowGunShared.SetVisualEffectsEnabled(rig, enabled)
	local seenEffects = {}
	for _, container in ipairs(SnowGunShared.GetVisualEffectContainers(rig)) do
		if container and container.Parent then
			for _, descendant in ipairs(container:GetDescendants()) do
				if SnowGunShared.IsSupportedVisualEffect(descendant) and not seenEffects[descendant] then
					seenEffects[descendant] = true
					descendant.Enabled = enabled
				end
			end
		end
	end
end

function SnowGunShared.GetBaseCFrame(rig)
	if not rig then
		return nil
	end
	local pivotTarget = rig.PivotPart or rig.RotateTarget or rig.RotateModel
	local pivotCFrame = getInstanceCFrame(rig.BaseInstance or pivotTarget)
	if not pivotCFrame then
		return nil
	end
	local baseOffset = (rig.Config and rig.Config.BaseRotationOffset) or CFrame.new()
	return pivotCFrame * baseOffset
end

function SnowGunShared.GetSpinParts(model, rig)
	if not model or not rig then
		return {}
	end
	local baseCFrame = SnowGunShared.GetBaseCFrame(rig)
	if not baseCFrame then
		return {}
	end
	local targetRoot = rig.RotateTarget or rig.RotateModel or model
	local spinParts = {}
	local seen = {}
	for _, spec in ipairs({
		{ Name = "FAN", Spin = true },
		{ Name = "Fan", Spin = true },
		{ Name = "fan blade", Spin = true },
		{ Name = "blade cap", Spin = true },
		{ Name = "FAKEFAN", Spin = true },
		{ Name = "BLOWERSOUND", Spin = false },
		{ Name = "Shaft", Spin = false },
	}) do
		local part = targetRoot and targetRoot:FindFirstChild(spec.Name, true) or nil
		if not part then
			part = model:FindFirstChild(spec.Name, true)
		end
		local basePart = nil
		if part and part:IsA("BasePart") then
			basePart = part
		elseif part and part:IsA("Model") then
			basePart = firstBasePart(part)
		end
		local targetCFrame = getInstanceCFrame(part)
		if part and basePart and targetCFrame and not seen[part] then
			seen[part] = true
			table.insert(spinParts, {
				Part = part,
				PivotRelativeCFrame = baseCFrame:ToObjectSpace(basePart.CFrame),
				TargetFromPivot = basePart.CFrame:ToObjectSpace(targetCFrame),
				Axis = spec.Spin and getSpinAxisName(basePart) or nil,
				Spin = spec.Spin,
			})
		end
	end
	-- Inherit spin axis from main fan part for small accessories (blade cap, etc.)
	local primaryAxis = nil
	for _, sp in ipairs(spinParts) do
		if sp.Spin and (sp.Part.Name == "FAN" or sp.Part.Name == "Fan" or sp.Part.Name == "fan blade") then
			primaryAxis = sp.Axis
			break
		end
	end
	if primaryAxis then
		for _, sp in ipairs(spinParts) do
			if sp.Spin and sp.Axis and sp.Axis ~= primaryAxis then
				sp.Axis = primaryAxis
			end
		end
	end

	return spinParts
end

function SnowGunShared.ApplySpinParts(rig, spinParts, spinAngle)
	if not rig or not spinParts or #spinParts == 0 then
		return
	end
	local currentBase = SnowGunShared.GetBaseCFrame(rig)
	if not currentBase then
		return
	end
	for _, entry in ipairs(spinParts) do
		local part = entry.Part
		if part and part.Parent then
			local spinRotation = CFrame.new()
			if entry.Spin and entry.Axis then
				spinRotation = localAxisRotation(entry.Axis, spinAngle)
			end
			local spinPivot = currentBase * entry.PivotRelativeCFrame
			local targetCF = spinPivot * spinRotation * entry.TargetFromPivot
			applyInstanceCFrame(part, targetCF)
		end
	end
end

function SnowGunShared.ApplyYawOffset(rig, baseCFrame, yawRadians)
	if not rig or not baseCFrame then
		return
	end
	local finalPivot = SnowGunShared.GetOscillatedBaseCFrame(rig, baseCFrame, yawRadians)
	local target = rig.RotateTarget or rig.RotateModel or rig.PivotPart
	if target and finalPivot then
		applyInstanceCFrame(target, finalPivot * (rig.TargetFromPivot or CFrame.new()))
	end
	for _, follower in ipairs(rig.Followers or {}) do
		if follower.Part and follower.Part.Parent and finalPivot then
			follower.Part.CFrame = finalPivot * follower.RelativeCFrame
		end
	end
end

return SnowGunShared
