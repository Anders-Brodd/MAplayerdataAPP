--[=[ PATH: ServerScriptService/LiftEditorServer | TYPE: Script ]=]--
--[[
	Lift editor server.
	This path is only used for editing lift poles after placement.
	Keep its cable/sheave math matched to PlacementServer so pole height edits do not recalculate from different attachment references.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local HttpService = game:GetService("HttpService")
local Terrain = game:GetService("Workspace").Terrain

local Events = ReplicatedStorage:WaitForChild("Events")
local Config = require(ReplicatedStorage:WaitForChild("Config"))
local MultiplayerPermissions = require(ServerScriptService.Server:WaitForChild("MultiplayerPermissions"))
local RequestBuildingSave = Events:FindFirstChild("RequestBuildingSave")

local EditEvent = ReplicatedStorage:FindFirstChild("EditPoleEvent") or Instance.new("RemoteEvent", ReplicatedStorage)
EditEvent.Name = "EditPoleEvent"

local DEBUG_POLE_EDIT = true
local POLE_EDIT_MIN_MOVE = 0.05
local ENABLE_TERRAIN_REBUILD_ON_POLE_EDIT = false
local PendingRefreshTokens = {}

local function PoleDebug(message, ...)
	if not DEBUG_POLE_EDIT then return end
	warn(string.format("[LiftEditorServer] %s", tostring(message)), ...)
end

-- Match PlacementServer naming cleanup so edited lifts use the same cable reference attachments.
local function CleanName(n)
	return tostring(n or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
end

local function GetCableCenter(model)
	if not model then return Vector3.zero end
	local pivotPos = model:GetPivot().Position

	local function FindSuffix(m, suffix)
		local target = suffix:lower()
		for _, d in ipairs(m:GetDescendants()) do
			if d:IsA("Attachment") and CleanName(d.Name):sub(-#target) == target then
				return d
			end
		end
		return nil
	end

	local function Validate(pos)
		return (pos - pivotPos).Magnitude <= 200
	end

	local r1, l1 = FindSuffix(model, "R1"), FindSuffix(model, "L1")
	if r1 and l1 then
		local mid = (r1.WorldPosition + l1.WorldPosition) / 2
		if Validate(mid) then return mid end
	end
	if r1 and Validate(r1.WorldPosition) then
		return r1.WorldPosition
	end

	local f1, f2 = FindSuffix(model, "F1"), FindSuffix(model, "F2")
	if f1 and f2 then
		local mid = (f1.WorldPosition + f2.WorldPosition) / 2
		if Validate(mid) then return mid end
	end

	return pivotPos
end

local function GetSafePlanarDirection(inDir, outDir)
	local flat = Vector3.new(inDir.X + outDir.X, 0, inDir.Z + outDir.Z)
	if flat.Magnitude < 0.01 then
		flat = Vector3.new(outDir.X, 0, outDir.Z)
	end
	if flat.Magnitude < 0.01 then
		flat = Vector3.new(inDir.X, 0, inDir.Z)
	end
	if flat.Magnitude < 0.01 then
		return Vector3.zAxis
	end
	return flat.Unit
end

local function ResolveLiftItemConfig(liftModel)
	if not liftModel then return nil, nil end

	if type(Config.GetItemById) == "function" then
		local idName, idConfig = Config.GetItemById(liftModel:GetAttribute("ID"))
		if idConfig then
			return idName, idConfig
		end
	end

	local attrItem = liftModel:GetAttribute("Item") or liftModel:GetAttribute("ItemName")
	if type(attrItem) == "string" and Config.Items[attrItem] then
		return attrItem, Config.Items[attrItem]
	end

	if type(liftModel.Name) == "string" and Config.Items[liftModel.Name] then
		return liftModel.Name, Config.Items[liftModel.Name]
	end

	return nil, nil
end

local function AlignAllSheaths(liftModel)
	local startStation = liftModel:FindFirstChild("StartStation")
	local endStation = liftModel:FindFirstChild("EndStation")
	if not startStation or not endStation then return end

	local poles = {}
	for _, c in ipairs(liftModel:GetChildren()) do
		if c.Name:match("Pole_%d+") then
			table.insert(poles, c)
		end
	end

	table.sort(poles, function(a, b)
		local nA = tonumber(a.Name:match("%d+")) or 0
		local nB = tonumber(b.Name:match("%d+")) or 0
		return nA < nB
	end)

	local nodes = {{Pos = GetCableCenter(startStation)}}
	for _, pole in ipairs(poles) do
		table.insert(nodes, {Pos = GetCableCenter(pole), Model = pole})
	end
	table.insert(nodes, {Pos = GetCableCenter(endStation)})

	local itemName, itemConfig = ResolveLiftItemConfig(liftModel)
	PoleDebug("AlignAllSheaths config", liftModel.Name, itemName or "<nil>", itemConfig and itemConfig.SheaveRotationY or "<no sheave config>")

	for i = 2, #nodes - 1 do
		local prevPos = nodes[i - 1].Pos
		local currPos = nodes[i].Pos
		local nextPos = nodes[i + 1].Pos
		local poleModel = nodes[i].Model

		local vecIn = (currPos - prevPos).Unit
		local vecOut = (nextPos - currPos).Unit
		local flatDir = GetSafePlanarDirection(vecIn, vecOut)

		local dInH = Vector3.new(currPos.X - prevPos.X, 0, currPos.Z - prevPos.Z).Magnitude
		local dInV = currPos.Y - prevPos.Y
		local pitchIn = math.atan2(dInV, dInH)

		local dOutH = Vector3.new(nextPos.X - currPos.X, 0, nextPos.Z - currPos.Z).Magnitude
		local dOutV = nextPos.Y - currPos.Y
		local pitchOut = math.atan2(dOutV, dOutH)

		local pitch = (pitchIn + pitchOut) / 2

		local sheavesToRotate = {}
		local function getSheaves()
			for _, n in ipairs({"Sheath", "Sheave", "Sheaves", "Head", "Assembly", "Train", "Crossarm", "Wheel", "Guide", "Top"}) do
				local matched = false
				for _, desc in ipairs(poleModel:GetDescendants()) do
					if string.lower(desc.Name):find(string.lower(n)) then
						local isChild = false
						for _, s in ipairs(sheavesToRotate) do
							if desc:IsDescendantOf(s) then
								isChild = true
								break
							end
						end
						if not isChild then
							table.insert(sheavesToRotate, desc)
							matched = true
						end
					end
				end
				if matched then return end
			end
		end
		getSheaves()

		for _, s in ipairs(sheavesToRotate) do
			local currentCF = s:GetPivot()
			local cablePitchedCF = CFrame.lookAt(currentCF.Position, currentCF.Position + flatDir) * CFrame.Angles(pitch, 0, 0)
			local localCF = cablePitchedCF:ToObjectSpace(currentCF)
			local _, localYaw, localRoll = localCF:ToOrientation()
			local newCF = cablePitchedCF * CFrame.Angles(0, localYaw, localRoll)
			if DEBUG_POLE_EDIT then
				local _, oldYaw, _ = currentCF:ToOrientation()
				local _, newYaw, _ = newCF:ToOrientation()
				PoleDebug("Sheave rotate", poleModel.Name, s.Name, string.format("oldYaw=%.2f newYaw=%.2f localYaw=%.2f", math.deg(oldYaw), math.deg(newYaw), math.deg(localYaw)))
			end
			s:PivotTo(newCF)
		end
	end
end

local function UpdateTerrainUnderPole(poleModel)
	if not poleModel then return end
	local pivot = poleModel:GetPivot()
	local pos = pivot.Position

	local originalY = poleModel:GetAttribute("OriginalY")
	local clearStartY = originalY or pos.Y

	local clearHeight = 500
	local clearRadius = 28
	local clearCF = CFrame.new(Vector3.new(pos.X, clearStartY + clearHeight / 2, pos.Z)) * CFrame.Angles(0, 0, math.pi / 2)
	Terrain:FillCylinder(clearCF, clearHeight, clearRadius, Enum.Material.Air)

	if originalY and pos.Y < (originalY - 0.1) then return end

	local params = RaycastParams.new()
	params.FilterDescendantsInstances = {poleModel, poleModel.Parent}
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true

	local result = workspace:Raycast(pos, Vector3.new(0, -500, 0), params)
	if result then
		local groundY = result.Position.Y
		local height = pos.Y - groundY
		if height > 0.5 then
			local topRadius = 6
			local bottomRadius = math.min(math.max(topRadius + 2, height * 1.5), 25)
			local steps = math.ceil(height / 1.5)
			for i = 0, steps do
				local alpha = i / steps
				local y = groundY + (height * alpha)
				local r = bottomRadius + (topRadius - bottomRadius) * alpha
				Terrain:FillBall(Vector3.new(pos.X, y, pos.Z), r, Enum.Material.Snow)
			end
		end
	end
end

EditEvent.OnServerEvent:Connect(function(player, liftModel, poleModel, newPos)
	if not liftModel or not poleModel or typeof(newPos) ~= "Vector3" then return end
	if not liftModel:IsDescendantOf(workspace) then return end
	if not poleModel:IsDescendantOf(liftModel) then return end
	if not MultiplayerPermissions.CanDelete(player, liftModel) then
		PoleDebug("Reject edit event (no permission)", player and player.Name or "?", liftModel.Name)
		return
	end

	if poleModel.PrimaryPart then
		local currentPivot = poleModel:GetPivot()
		local currentRot = currentPivot.Rotation
		local currentPrimaryPos = poleModel.PrimaryPart.Position
		local pivotOffset = currentPivot.Position - currentPrimaryPos

		local _, liftItemConfig = ResolveLiftItemConfig(liftModel)
		local targetY = newPos.Y
		if liftItemConfig and liftItemConfig.SurfaceTow then
			targetY = currentPrimaryPos.Y
		end
		local targetPrimaryPos = Vector3.new(newPos.X, targetY, newPos.Z)
		local moveDistance = (targetPrimaryPos - currentPrimaryPos).Magnitude
		PoleDebug("Edit event", player and player.Name or "?", liftModel.Name, poleModel.Name, string.format("move=%.3f", moveDistance), targetPrimaryPos)
		if moveDistance < POLE_EDIT_MIN_MOVE then
			PoleDebug("Skip edit event (below threshold)", poleModel.Name, moveDistance)
			return
		end

		poleModel:PivotTo(CFrame.new(targetPrimaryPos + pivotOffset) * currentRot)
	end

	if ENABLE_TERRAIN_REBUILD_ON_POLE_EDIT then
		UpdateTerrainUnderPole(poleModel)
	else
		PoleDebug("Skipping terrain rebuild for pole edit", poleModel.Name)
	end
	AlignAllSheaths(liftModel)

	local oldCable = liftModel:FindFirstChild("Cable")
	if oldCable then oldCable:Destroy() end

	local oldSys = liftModel:FindFirstChild("CableSystem")
	if oldSys then oldSys:Destroy() end

	PendingRefreshTokens[liftModel] = (PendingRefreshTokens[liftModel] or 0) + 1
	local refreshToken = PendingRefreshTokens[liftModel]
	local refreshId = HttpService:GenerateGUID(false)
	liftModel:SetAttribute("RefreshID", refreshId)
	task.delay(0.08, function()
		if not (liftModel and liftModel.Parent) then
			return
		end
		if PendingRefreshTokens[liftModel] ~= refreshToken then
			return
		end
		liftModel:SetAttribute("RefreshID", HttpService:GenerateGUID(false))
	end)

	if RequestBuildingSave and RequestBuildingSave:IsA("BindableEvent") then
		-- Force immediate persistence so quick rejoin/log out still keeps edited pole positions.
		RequestBuildingSave:Fire(true)
	end
end)
