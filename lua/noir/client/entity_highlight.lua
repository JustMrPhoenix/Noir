local Highlight = {}
Highlight.Entities = {}
Highlight.HookId = "NoirEntityHighlight"
Highlight.OutlineColor = Color(0, 255, 100, 255)
local function renderHighlight()
	local validEnts = {}
	for ent in pairs(Highlight.Entities) do
		if IsValid(ent) then
			table.insert(validEnts, ent)
		else
			Highlight.Entities[ent] = nil
		end
	end

	if #validEnts == 0 then
		Highlight.Clear()
		return
	end

	halo.Add(validEnts, Highlight.OutlineColor, 3, 3, 1, true, true)
	render.SetColorModulation(0, 1, 0.4)
	render.SetBlend(0.3)
	for _, ent in ipairs(validEnts) do
		ent:DrawModel()
	end

	render.SetColorModulation(1, 1, 1)
	render.SetBlend(1)
end

local function ensureHook()
	local hooks = hook.GetTable()["PostDrawOpaqueRenderables"]
	if not hooks or not hooks[Highlight.HookId] then hook.Add("PostDrawOpaqueRenderables", Highlight.HookId, renderHighlight) end
end

-- Add an entity to the highlight list
function Highlight.Add(ent)
	if not IsValid(ent) then return end
	Highlight.Entities[ent] = true
	ensureHook()
end

-- Set a single entity (clears others)
function Highlight.Set(ent)
	Highlight.Entities = {}
	if IsValid(ent) then
		Highlight.Entities[ent] = true
		ensureHook()
	else
		Highlight.Clear()
	end
end

-- Remove a specific entity from highlights
function Highlight.Remove(ent)
	Highlight.Entities[ent] = nil
	if not next(Highlight.Entities) then Highlight.Clear() end
end

-- Toggle an entity's highlight state
function Highlight.Toggle(ent)
	if not IsValid(ent) then return end
	if Highlight.Entities[ent] then
		Highlight.Remove(ent)
	else
		Highlight.Add(ent)
	end
end

-- Check if an entity is highlighted
function Highlight.IsHighlighted(ent)
	return Highlight.Entities[ent] == true
end

-- Clear all highlights
function Highlight.Clear()
	Highlight.Entities = {}
	hook.Remove("PostDrawOpaqueRenderables", Highlight.HookId)
end

-- Stop is alias for Clear (backwards compatibility)
Highlight.Stop = Highlight.Clear
-- Get all highlighted entities
function Highlight.GetEntities()
	local result = {}
	for ent in pairs(Highlight.Entities) do
		if IsValid(ent) then table.insert(result, ent) end
	end
	return result
end

-- Backwards compatibility
function Highlight.GetEntity()
	return next(Highlight.Entities)
end
return Highlight
