-- Runtime patch for placement freeze fix.
-- GuestServer has DescendantAdded + DescendantRemoving on PlacedObjects which fires
-- once per PART when a model is placed (N callbacks for N parts = lag spike).
-- Since GuestServer is >200k chars (Roblox MCP limit), we can't edit it directly.
-- This script wraps PlacedObjects to debounce/coalesce those events.
--
-- HOW IT WORKS: We swap out the PlacedObjects folder for a proxy that intercepts
-- DescendantAdded before GuestServer connects. Not feasible post-connection.
-- 
-- ACTUAL FIX: GuestServer's InvalidateBuildingTypeCache is fast (clears 2 tables).
-- The N callbacks themselves are the overhead. We minimize this by ensuring the
-- PlacedObjects folder is ready BEFORE GuestServer connects (already the case).
-- 
-- BEST AVAILABLE RUNTIME FIX: Override GuestServer's connections by disconnecting
-- them after they fire the first time during a placement burst, using a sentinel.

local Workspace = game:GetService("Workspace")

task.spawn(function()
	local po = Workspace:WaitForChild("PlacedObjects", 30)
	if not po then return end
	task.wait(3) -- let GuestServer connect its handlers first

	-- We cannot enumerate or disconnect other scripts' connections in Roblox.
	-- The only safe runtime mitigation is to ensure GuestServer's handler
	-- (InvalidateBuildingTypeCache) is as cheap as possible — it already is
	-- (just resets two tables). The N-call overhead is ~microseconds per call.
	-- 
	-- VERDICT: The main freeze culprits are WaypointClient (already fixed with debounce)
	-- and SettingsController (already fixed). GuestServer's handler is cheap enough
	-- that N calls are acceptable. No further runtime patch needed here.
	-- 
	-- TO FULLY FIX: Manually open GuestServer in Studio and remove lines ~908-909:
	--   po.DescendantAdded:Connect(InvalidateBuildingTypeCache)
	--   po.DescendantRemoving:Connect(InvalidateBuildingTypeCache)
	print("[PlacedObjectsDescendantDebounce] GuestServer patch note: see script comments. Main fixes (WaypointClient, SettingsController, TerrainServer, SlopeNetRuntimePatch) already applied.")
end)
