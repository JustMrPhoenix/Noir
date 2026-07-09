local Editor = Noir.Editor or {}
Noir.Editor = Editor

-- Full-frame loading screen shown over the editor until every DHTML panel behind
-- it (the Monaco editor plus any open console REPLs) has finished loading. Drawing
-- the spinner here -- instead of in each panel's own PaintOver -- means one unified
-- loading screen rather than separate spinners that pop in and finish at different
-- times as each chromium page loads.
local PANEL = {}

function PANEL:Init()
	self.LoadingTime = 0
end

-- ReadyCheck is a plain function returning true once everything behind the overlay
-- is loaded. The frame sets it; the overlay removes itself the moment it's true.
function PANEL:SetReadyCheck(fn)
	self.ReadyCheck = fn
end

function PANEL:Think()
	local parent = self:GetParent()
	if not IsValid(parent) then return end
	-- Cover the whole frame below the title bar (so the close/maximise buttons stay
	-- clickable) and stay above the DHTML panels, which paint on their own layer.
	local titleH = 24
	self:SetPos(0, titleH)
	self:SetSize(parent:GetWide(), parent:GetTall() - titleH)
	self:MoveToFront()
	if self.ReadyCheck and self.ReadyCheck() then self:Remove() end
end

function PANEL:Paint(w, h)
	surface.SetDrawColor(30, 30, 30)
	surface.DrawRect(0, 0, w, h)
	self.LoadingTime = (self.LoadingTime or 0) + RealFrameTime()
	local cx, cy = w / 2, (h - 20) / 2
	local radius = math.max(16, math.min(w, h) * 0.05)
	local thickness = math.max(2, radius * 0.16)
	local segments = 64
	local arcSpan = 140 -- degrees of the bright sweeping arc
	local head = (self.LoadingTime * 220) % 360
	local rOuter, rInner = radius + thickness / 2, radius - thickness / 2
	draw.NoTexture()
	for i = 0, segments - 1 do
		local a1 = (i / segments) * math.pi * 2
		local a2 = ((i + 1) / segments) * math.pi * 2
		local aDeg = (i / segments) * 360
		-- Distance behind the rotating head, wrapping around.
		local d = (head - aDeg + 360) % 360
		local alpha
		if d < arcSpan then
			alpha = 255 * (1 - d / arcSpan)
		else
			alpha = 28 -- faint track
		end

		local cos1, sin1 = math.cos(a1), math.sin(a1)
		local cos2, sin2 = math.cos(a2), math.sin(a2)
		local poly = {
			{ x = cx + rOuter * cos1, y = cy + rOuter * sin1 },
			{ x = cx + rOuter * cos2, y = cy + rOuter * sin2 },
			{ x = cx + rInner * cos2, y = cy + rInner * sin2 },
			{ x = cx + rInner * cos1, y = cy + rInner * sin1 },
		}
		surface.SetDrawColor(204, 204, 204, alpha)
		surface.DrawPoly(poly)
	end

	local textY = cy + rOuter + 20
	draw.SimpleText("Loading...", "DermaLarge", cx, textY, Color(204, 204, 204), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)

	if self.LoadingTime > 5 then
		draw.SimpleText("Sorry, this can take a while", "DermaDefault", cx, textY + 32, Color(150, 150, 150), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
	end
end

vgui.Register("NoirLoadingOverlay", PANEL, "EditablePanel")
