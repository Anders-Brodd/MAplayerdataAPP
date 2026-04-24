local CustomBuildingConfig = {}

CustomBuildingConfig.ITEM_NAME = "Builder Block"
CustomBuildingConfig.TYPE_NAME = "CustomBlock"
CustomBuildingConfig.SNAP = 0.05
CustomBuildingConfig.FINE_STEP = 0.05
CustomBuildingConfig.DEFAULT_STEP = 0.25
CustomBuildingConfig.MIN_SIZE = 0.05
CustomBuildingConfig.MAX_SIZE = 128
CustomBuildingConfig.ROTATION_SNAP = 15
CustomBuildingConfig.DEFAULT_SIZE = Vector3.new(4, 4, 4)
CustomBuildingConfig.DEFAULT_COLOR = Color3.fromRGB(235, 238, 242)
CustomBuildingConfig.DEFAULT_MATERIAL = "SmoothPlastic"

CustomBuildingConfig.ITEMS = {
	["Builder Block"] = { Shape = "Block", Label = "Block", ClassName = "Part", DefaultSize = Vector3.new(4, 4, 4), Asymmetrical = false },
	["Builder Cylinder"] = { Shape = "Cylinder", Label = "Cylinder", ClassName = "Part", DefaultSize = Vector3.new(4, 4, 4), Asymmetrical = false },
	["Builder Sphere"] = { Shape = "Ball", Label = "Sphere", ClassName = "Part", DefaultSize = Vector3.new(4, 4, 4), Asymmetrical = false },
	["Builder Wedge"] = { Shape = "Wedge", Label = "Wedge", ClassName = "WedgePart", DefaultSize = Vector3.new(4, 4, 4), Asymmetrical = true },
	["Builder Corner Wedge"] = { Shape = "CornerWedge", Label = "Corner Wedge", ClassName = "CornerWedgePart", DefaultSize = Vector3.new(4, 4, 4), Asymmetrical = true },
}

CustomBuildingConfig.ITEM_ORDER = {
	"Builder Block",
	"Builder Cylinder",
	"Builder Sphere",
	"Builder Wedge",
	"Builder Corner Wedge",
}

CustomBuildingConfig.PALETTE_COLORS = {
	{ Name = "Snow", Color = Color3.fromRGB(245, 247, 255) },
	{ Name = "Charcoal", Color = Color3.fromRGB(54, 59, 70) },
	{ Name = "Wood", Color = Color3.fromRGB(121, 85, 58) },
	{ Name = "Brick", Color = Color3.fromRGB(151, 84, 84) },
	{ Name = "Pine", Color = Color3.fromRGB(69, 110, 84) },
	{ Name = "Ice", Color = Color3.fromRGB(146, 205, 255) },
	{ Name = "Slate", Color = Color3.fromRGB(102, 114, 135) },
	{ Name = "Sun", Color = Color3.fromRGB(255, 203, 112) },
	{ Name = "Signal", Color = Color3.fromRGB(255, 103, 103) },
	{ Name = "Lift Blue", Color = Color3.fromRGB(92, 148, 255) },
}

CustomBuildingConfig.PALETTE_MATERIALS = {
	"SmoothPlastic",
	"Concrete",
	"Brick",
	"WoodPlanks",
	"Metal",
	"DiamondPlate",
	"Slate",
	"Glass",
	"Ice",
}

local MATERIAL_LOOKUP = {
	SmoothPlastic = Enum.Material.SmoothPlastic,
	Concrete = Enum.Material.Concrete,
	Brick = Enum.Material.Brick,
	WoodPlanks = Enum.Material.WoodPlanks,
	Metal = Enum.Material.Metal,
	DiamondPlate = Enum.Material.DiamondPlate,
	Slate = Enum.Material.Slate,
	Glass = Enum.Material.Glass,
	Ice = Enum.Material.Ice,
}

local PART_SHAPES = {
	Block = Enum.PartType.Block,
	Cylinder = Enum.PartType.Cylinder,
	Ball = Enum.PartType.Ball,
}

local function getItemDefinition(itemName)
	return CustomBuildingConfig.ITEMS[itemName] or CustomBuildingConfig.ITEMS[CustomBuildingConfig.ITEM_NAME]
end

local function getShapeFromBasePart(base)
	if not base then
		return getItemDefinition(CustomBuildingConfig.ITEM_NAME).Shape
	end
	if base:IsA("WedgePart") then
		return "Wedge"
	elseif base:IsA("CornerWedgePart") then
		return "CornerWedge"
	elseif base:IsA("Part") then
		for shapeName, enumValue in pairs(PART_SHAPES) do
			if base.Shape == enumValue then
				return shapeName
			end
		end
	end
	return getItemDefinition(CustomBuildingConfig.ITEM_NAME).Shape
end

local function applyCommonBaseProperties(base)
	base.Name = "Base"
	base.Anchored = true
	base.CanCollide = true
	base.CastShadow = true
	base.TopSurface = Enum.SurfaceType.Smooth
	base.BottomSurface = Enum.SurfaceType.Smooth
end

local function createBasePartForShape(shapeName)
	local base
	if shapeName == "Wedge" then
		base = Instance.new("WedgePart")
	elseif shapeName == "CornerWedge" then
		base = Instance.new("CornerWedgePart")
	else
		base = Instance.new("Part")
		base.Shape = PART_SHAPES[shapeName] or Enum.PartType.Block
	end
	applyCommonBaseProperties(base)
	return base
end

local function ensureShape(model, itemName, shapeName)
	local desiredShape = shapeName or getItemDefinition(itemName).Shape
	local base = CustomBuildingConfig.GetBasePart(model)
	if base and getShapeFromBasePart(base) == desiredShape then
		applyCommonBaseProperties(base)
		return base
	end

	local replacement = createBasePartForShape(desiredShape)
	if base then
		replacement.Size = base.Size
		replacement.Color = base.Color
		replacement.Material = base.Material
		replacement.CFrame = base.CFrame
		base:Destroy()
		model.PrimaryPart = nil
	else
		replacement.Size = getItemDefinition(itemName).DefaultSize or CustomBuildingConfig.DEFAULT_SIZE
	end
		replacement.Parent = model
	model.PrimaryPart = replacement
	return replacement
end

function CustomBuildingConfig.RoundToStep(value, step)
	step = step or CustomBuildingConfig.SNAP
	if step <= 0 then
		return value
	end
	return math.round(value / step) * step
end

function CustomBuildingConfig.SnapVector3(value, step)
	step = step or CustomBuildingConfig.SNAP
	return Vector3.new(
		CustomBuildingConfig.RoundToStep(value.X, step),
		CustomBuildingConfig.RoundToStep(value.Y, step),
		CustomBuildingConfig.RoundToStep(value.Z, step)
	)
end

function CustomBuildingConfig.ClampSize(size)
	return Vector3.new(
		math.clamp(CustomBuildingConfig.RoundToStep(size.X), CustomBuildingConfig.MIN_SIZE, CustomBuildingConfig.MAX_SIZE),
		math.clamp(CustomBuildingConfig.RoundToStep(size.Y), CustomBuildingConfig.MIN_SIZE, CustomBuildingConfig.MAX_SIZE),
		math.clamp(CustomBuildingConfig.RoundToStep(size.Z), CustomBuildingConfig.MIN_SIZE, CustomBuildingConfig.MAX_SIZE)
	)
end

function CustomBuildingConfig.SnapYaw(yaw)
	return CustomBuildingConfig.RoundToStep(yaw, CustomBuildingConfig.ROTATION_SNAP)
end

function CustomBuildingConfig.GetMaterialEnum(materialName)
	return MATERIAL_LOOKUP[materialName] or MATERIAL_LOOKUP[CustomBuildingConfig.DEFAULT_MATERIAL]
end

function CustomBuildingConfig.NormalizeMaterial(materialValue)
	if typeof(materialValue) == "EnumItem" and materialValue.EnumType == Enum.Material then
		for name, enumItem in pairs(MATERIAL_LOOKUP) do
			if enumItem == materialValue then
				return name
			end
		end
	elseif type(materialValue) == "string" and MATERIAL_LOOKUP[materialValue] then
		return materialValue
	end
	return CustomBuildingConfig.DEFAULT_MATERIAL
end

function CustomBuildingConfig.GetYawDegrees(cf)
	local look = cf.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	if flatLook.Magnitude < 1e-4 then
		return 0
	end
	return math.deg(math.atan2(-flatLook.X, -flatLook.Z))
end

function CustomBuildingConfig.GetBasePart(model)
	if not model then
		return nil
	end
	if model:IsA("BasePart") then
		return model
	end
	if model:IsA("Model") then
		if model.PrimaryPart then
			return model.PrimaryPart
		end
		local base = model:FindFirstChild("Base")
		if base and base:IsA("BasePart") then
			model.PrimaryPart = base
			return base
		end
		return model:FindFirstChildWhichIsA("BasePart")
	end
	return nil
end

function CustomBuildingConfig.GetShape(itemOrModel)
	if typeof(itemOrModel) == "Instance" then
		if itemOrModel:IsA("Model") then
			local attrShape = itemOrModel:GetAttribute("BlockShape")
			if type(attrShape) == "string" and attrShape ~= "" then
				return attrShape
			end
			return getShapeFromBasePart(CustomBuildingConfig.GetBasePart(itemOrModel))
		end
		return getShapeFromBasePart(itemOrModel)
	end
	return getItemDefinition(itemOrModel).Shape
end

function CustomBuildingConfig.GetShapeLabel(itemName)
	return getItemDefinition(itemName).Label
end

function CustomBuildingConfig.GetItemNameForShape(shapeName)
	for _, itemName in ipairs(CustomBuildingConfig.ITEM_ORDER) do
		local definition = CustomBuildingConfig.ITEMS[itemName]
		if definition and definition.Shape == shapeName then
			return itemName
		end
	end
	for itemName, definition in pairs(CustomBuildingConfig.ITEMS) do
		if definition.Shape == shapeName then
			return itemName
		end
	end
	return CustomBuildingConfig.ITEM_NAME
end

function CustomBuildingConfig.GetItemNames()
	local items = {}
	for _, itemName in ipairs(CustomBuildingConfig.ITEM_ORDER) do
		table.insert(items, itemName)
	end
	return items
end

function CustomBuildingConfig.SupportsMirror(itemOrModel)
	local itemName = type(itemOrModel) == "string" and itemOrModel or (itemOrModel and itemOrModel.Name)
	return getItemDefinition(itemName).Asymmetrical == true
end

function CustomBuildingConfig.BuildCFrame(position, yaw)
	local snappedPosition = CustomBuildingConfig.SnapVector3(position)
	local snappedYaw = CustomBuildingConfig.SnapYaw(yaw or 0)
	return CFrame.new(snappedPosition) * CFrame.Angles(0, math.rad(snappedYaw), 0)
end

function CustomBuildingConfig.GetAxisVector(yaw, axis)
	local basis = CFrame.Angles(0, math.rad(CustomBuildingConfig.SnapYaw(yaw or 0)), 0)
	if axis == "X" then
		return basis.RightVector
	elseif axis == "Y" then
		return Vector3.yAxis
	end
	return basis.LookVector
end

function CustomBuildingConfig.GetAxisExtent(size, axis)
	if axis == "X" then
		return size.X
	elseif axis == "Y" then
		return size.Y
	end
	return size.Z
end

function CustomBuildingConfig.BuildPlacementPayload(itemName, state)
	return {
		ItemName = itemName,
		CFrame = CustomBuildingConfig.BuildCFrame(state.Position, state.Yaw),
		Size = state.Size,
		Color = state.Color,
		Material = state.Material,
		Shape = state.Shape,
	}
end

function CustomBuildingConfig.GetDuplicateState(itemName, state, axis, direction, useMirror)
	local nextState = {
		Position = state.Position,
		Yaw = state.Yaw,
		Size = state.Size,
		Color = state.Color,
		Material = state.Material,
		Shape = state.Shape,
	}
	local axisDirection = (type(direction) == "number" and direction ~= 0) and direction or 1
	local axisVector = CustomBuildingConfig.GetAxisVector(state.Yaw, axis)
	local distance = CustomBuildingConfig.GetAxisExtent(state.Size, axis)
	nextState.Position = CustomBuildingConfig.SnapVector3(state.Position + (axisVector * distance * axisDirection))
	if useMirror and CustomBuildingConfig.SupportsMirror(itemName) and axis ~= "Y" then
		nextState.Yaw = state.Yaw + 180
	end
	return nextState
end

function CustomBuildingConfig.CreateModel(name)
	local itemName = name or CustomBuildingConfig.ITEM_NAME
	local shapeDef = getItemDefinition(itemName)
	local model = Instance.new("Model")
	model.Name = itemName

	local base = ensureShape(model, itemName, shapeDef.Shape)
	base.Parent = model
	model.PrimaryPart = base

	CustomBuildingConfig.ApplyState(model, {
		Position = Vector3.zero,
		Yaw = 0,
		Size = shapeDef.DefaultSize or CustomBuildingConfig.DEFAULT_SIZE,
		Color = CustomBuildingConfig.DEFAULT_COLOR,
		Material = CustomBuildingConfig.DEFAULT_MATERIAL,
		Shape = shapeDef.Shape,
	})

	model:SetAttribute("Type", CustomBuildingConfig.TYPE_NAME)
	model:SetAttribute("CustomBuild", true)
	model:SetAttribute("BlockShape", shapeDef.Shape)
	return model
end

function CustomBuildingConfig.ReadState(model)
	local base = CustomBuildingConfig.GetBasePart(model)
	if not base then
		return {
			Position = Vector3.zero,
			Yaw = 0,
			Size = CustomBuildingConfig.DEFAULT_SIZE,
			Color = CustomBuildingConfig.DEFAULT_COLOR,
			Material = CustomBuildingConfig.DEFAULT_MATERIAL,
			Shape = getItemDefinition(model and model.Name).Shape,
		}
	end

	return {
		Position = model:GetPivot().Position,
		Yaw = CustomBuildingConfig.GetYawDegrees(model:GetPivot()),
		Size = base.Size,
		Color = base.Color,
		Material = CustomBuildingConfig.NormalizeMaterial(base.Material),
		Shape = CustomBuildingConfig.GetShape(model),
	}
end

function CustomBuildingConfig.ApplyState(model, state)
	if not model then
		return false
	end

	local itemName = model.Name or CustomBuildingConfig.ITEM_NAME
	local current = CustomBuildingConfig.ReadState(model)
	local shapeName = type(state.Shape) == "string" and state.Shape or current.Shape or getItemDefinition(itemName).Shape
	local base = ensureShape(model, itemName, shapeName)
	if not base then
		return false
	end

	local size = CustomBuildingConfig.ClampSize(state.Size or current.Size)
	local color = typeof(state.Color) == "Color3" and state.Color or current.Color or CustomBuildingConfig.DEFAULT_COLOR
	local materialName = CustomBuildingConfig.NormalizeMaterial(state.Material or current.Material)
	local position = state.Position or current.Position or Vector3.zero
	local yaw = state.Yaw
	if yaw == nil and state.CFrame then
		yaw = CustomBuildingConfig.GetYawDegrees(state.CFrame)
	end
	if yaw == nil then
		yaw = current.Yaw or 0
	end

	base.Size = size
	base.Color = color
	base.Material = CustomBuildingConfig.GetMaterialEnum(materialName)
	applyCommonBaseProperties(base)
	base.Parent = model
	model.PrimaryPart = base
	model.Name = CustomBuildingConfig.GetItemNameForShape(shapeName)
	model:PivotTo(CustomBuildingConfig.BuildCFrame(position, yaw))

	model:SetAttribute("Type", CustomBuildingConfig.TYPE_NAME)
	model:SetAttribute("CustomBuild", true)
	model:SetAttribute("BlockShape", shapeName)
	model:SetAttribute("BlockSize", size)
	model:SetAttribute("BlockColor", color)
	model:SetAttribute("BlockMaterial", materialName)
	model:SetAttribute("BlockYaw", CustomBuildingConfig.SnapYaw(yaw))

	return true
end

return CustomBuildingConfig