local Config = {}

Config.SchemaVersion = 1
Config.DataStoreName = "TycoonDecorMilestones"
Config.AutoSaveSeconds = 60

Config.UtilityItems = {
	["Conveyor"] = true,
	["Concrete Path"] = true,
}

-- Only opt-in showcase decor should live in these milestones.
-- Basic resort signage, starter trees, and safety pieces stay free.
-- Retuned Apr 4, 2026: decor milestones are intentionally the longer progression track.
Config.Milestones = {
	{
		Id = "ResortLighting",
		Name = "Resort Lighting",
		Score = 42,
		Unlocks = {
			"Small Floodlight",
			"360 Floodlight",
		},
	},
	{
		Id = "WinterScenery",
		Name = "Winter Scenery",
		Score = 88,
		Unlocks = {
			"Snowy Tree 1",
			"Snowy Tree 2",
		},
	},
}

local milestoneById = {}
local itemToMilestoneId = {}
for index, milestone in ipairs(Config.Milestones) do
	milestone.Index = index
	milestoneById[milestone.Id] = milestone
	for _, itemName in ipairs(milestone.Unlocks or {}) do
		itemToMilestoneId[itemName] = milestone.Id
	end
end

function Config.GetRequirement(itemName)
	local milestoneId = itemToMilestoneId[itemName]
	if not milestoneId then
		return nil
	end
	return milestoneById[milestoneId]
end

function Config.IsMilestoneDecor(itemName)
	return itemToMilestoneId[itemName] ~= nil
end

function Config.GetNextMilestone(score)
	score = tonumber(score) or 0
	for _, milestone in ipairs(Config.Milestones) do
		if score < milestone.Score then
			return milestone
		end
	end
	return nil
end

function Config.GetUnlockedItems(unlockedMilestones)
	local unlockedItems = {}
	if type(unlockedMilestones) ~= "table" then
		return unlockedItems
	end
	for _, milestone in ipairs(Config.Milestones) do
		if unlockedMilestones[milestone.Id] == true then
			for _, itemName in ipairs(milestone.Unlocks or {}) do
				unlockedItems[itemName] = true
			end
		end
	end
	return unlockedItems
end

return Config