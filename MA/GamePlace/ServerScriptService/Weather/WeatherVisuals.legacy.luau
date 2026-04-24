--[[
	🌨️ WEATHER VISUALS CONTROLLER (Server Broadcaster)
	ServerScriptService/WeatherVisuals
]]

local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local PRESETS = {
	Clear = {
		FogEnd = 90000,
		FogColor = Color3.fromRGB(246, 250, 255),
		SnowRate = 0,
		WindSpeed = 6,
		SnowTurbulence = 0.08,
		WindGust = 0.15,
	},
	PartlyCloudy = {
		FogEnd = 9500,
		FogColor = Color3.fromRGB(231, 238, 245),
		SnowRate = 0,
		WindSpeed = 14,
		SnowTurbulence = 0.14,
		WindGust = 0.24,
	},
	Overcast = {
		FogEnd = 3600,
		FogColor = Color3.fromRGB(205, 212, 224),
		SnowRate = 0,
		WindSpeed = 22,
		SnowTurbulence = 0.2,
		WindGust = 0.34,
	},
	LightSnow = {
		FogEnd = 1700,
		FogColor = Color3.fromRGB(214, 223, 236),
		SnowRate = 360,
		WindSpeed = 30,
		SnowTurbulence = 0.32,
		WindGust = 0.48,
	},
	HeavySnow = {
		FogEnd = 650,
		FogColor = Color3.fromRGB(201, 212, 228),
		SnowRate = 1650,
		WindSpeed = 54,
		SnowTurbulence = 0.5,
		WindGust = 0.74,
	},
	Blizzard = {
		FogEnd = 220,
		FogColor = Color3.fromRGB(182, 195, 214),
		SnowRate = 3200,
		WindSpeed = 105,
		SnowTurbulence = 0.78,
		WindGust = 1.0,
	}
}

local watchedFolders = setmetatable({}, { __mode = "k" })
local snowPartsVisible = false
local snowCoverageRatio = 0

local function isSnowReactiveTreeModel(inst)
	return inst and inst:IsA("Model") and inst:FindFirstChild("SnowParts") ~= nil
end

local function resolveSnowReactiveTree(inst)
	local current = inst
	while current and current ~= Workspace do
		if isSnowReactiveTreeModel(current) then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function getTreeSnowScore(tree)
	local pivot = tree:GetPivot().Position
	local seed = math.abs(math.floor((pivot.X * 17.73) + (pivot.Y * 5.19) + (pivot.Z * 29.11) + (#tree.Name * 13)))
	return (seed % 1000) / 1000
end

local function shouldShowSnowForTree(tree)
	if not snowPartsVisible then
		return false
	end
	if tree:GetAttribute("ForceSnowCover") == true then
		return true
	end
	return getTreeSnowScore(tree) <= snowCoverageRatio
end

local function applySnowPartsToTree(tree)
	if not isSnowReactiveTreeModel(tree) then
		return
	end
	local snowParts = tree:FindFirstChild("SnowParts")
	if not snowParts then
		return
	end
	local showSnow = shouldShowSnowForTree(tree)
	for _, descendant in ipairs(snowParts:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Transparency = showSnow and 0 or 1
			descendant.CanCollide = false
		elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
			descendant.Transparency = showSnow and 0 or 1
		end
	end
end

local function applySnowToContainer(container, recursive)
	if not container then
		return
	end
	local list = recursive and container:GetDescendants() or container:GetChildren()
	for _, child in ipairs(list) do
		if isSnowReactiveTreeModel(child) then
			applySnowPartsToTree(child)
		end
	end
end

local function watchTreeFolder(treeFolder, recursive)
	if not treeFolder or watchedFolders[treeFolder] then
		return
	end
	watchedFolders[treeFolder] = true
	applySnowToContainer(treeFolder, recursive)
	if recursive then
		treeFolder.DescendantAdded:Connect(function(descendant)
			task.defer(function()
				local tree = resolveSnowReactiveTree(descendant)
				if tree then
					applySnowPartsToTree(tree)
				end
			end)
		end)
	else
		treeFolder.ChildAdded:Connect(function(child)
			task.defer(function()
				applySnowPartsToTree(child)
			end)
		end)
	end
end

local function refreshTreeSnow()
	local treeFolder = Workspace:FindFirstChild("TreeFolder")
	if treeFolder then
		watchTreeFolder(treeFolder, false)
		applySnowToContainer(treeFolder, false)
	end
	local placedObjects = Workspace:FindFirstChild("PlacedObjects")
	if placedObjects then
		watchTreeFolder(placedObjects, true)
		applySnowToContainer(placedObjects, true)
	end
end

local function ApplyWeather()
	local w = Lighting:GetAttribute("Weather") or "Clear"

	if w == "Snowing" or (w:find("Snow") and not PRESETS[w]) then
		w = "LightSnow"
	end

	local data = PRESETS[w] or PRESETS.Clear
	local tweenDuration = (w == "Blizzard" or w == "HeavySnow") and 7 or 5

	-- Broadcast the target FogEnd as an attribute so clients can read the intended value
	Lighting:SetAttribute("BaseFogEnd", data.FogEnd)

	TweenService:Create(Lighting, TweenInfo.new(tweenDuration), {
		FogEnd = data.FogEnd,
		FogColor = data.FogColor
	}):Play()
	Lighting:SetAttribute("SnowRate", data.SnowRate)
	Lighting:SetAttribute("WindSpeed", data.WindSpeed)
	Lighting:SetAttribute("SnowTurbulence", data.SnowTurbulence or 0)
	Lighting:SetAttribute("WindGust", data.WindGust or 0)
	snowPartsVisible = (w == "LightSnow" or w == "HeavySnow" or w == "Blizzard")
	if w == "LightSnow" then
		snowCoverageRatio = 0.72
	elseif w == "HeavySnow" then
		snowCoverageRatio = 0.84
	elseif w == "Blizzard" then
		snowCoverageRatio = 0.92
	else
		snowCoverageRatio = 0
	end
	refreshTreeSnow()
end

Workspace.ChildAdded:Connect(function(child)
	if child.Name == "TreeFolder" or child.Name == "PlacedObjects" then
		task.defer(function()
			refreshTreeSnow()
		end)
	end
end)
Lighting:GetAttributeChangedSignal("Weather"):Connect(ApplyWeather)
task.wait(1)
refreshTreeSnow()
ApplyWeather()