-- poor -- Minimap.lua
-- Minimap button (drag to move around the rim) and the addon-compartment entry.
local _, P = ...

local button

local function Place(angle)
	local rad = math.rad(angle)
	local r = Minimap:GetWidth() / 2 + 5
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", math.cos(rad) * r, math.sin(rad) * r)
end

local function ShowTooltip(owner)
	GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
	GameTooltip:AddLine("poor")
	GameTooltip:AddLine("You have " .. P.MoneyIcons(GetMoney()), 1, 1, 1)
	local rank, total = P.MyRank()
	if rank and total > 1 then
		GameTooltip:AddLine(("#%d poorest of %d"):format(rank, total), 1, 1, 1)
	end
	GameTooltip:AddLine("Click to open. Drag to move.", 0.6, 0.6, 0.6)
	GameTooltip:Show()
end

local function FollowCursor()
	local cx, cy = Minimap:GetCenter()
	local scale = Minimap:GetEffectiveScale()
	local x, y = GetCursorPosition()
	P.db.opts.angle = math.deg(math.atan2(y / scale - cy, x / scale - cx))
	Place(P.db.opts.angle)
end

local function Build()
	local b = CreateFrame("Button", "PoorMinimapButton", Minimap)
	b:SetSize(31, 31)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(8)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")
	b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local icon = b:CreateTexture(nil, "ARTWORK")
	icon:SetTexture(P.ICON)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	icon:SetSize(19, 19)
	icon:SetPoint("CENTER")

	local border = b:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT")

	b:SetScript("OnClick", function() P.ToggleWindow() end)
	b:SetScript("OnEnter", ShowTooltip)
	b:SetScript("OnLeave", GameTooltip_Hide)
	b:SetScript("OnDragStart", function(self)
		GameTooltip_Hide()
		self:SetScript("OnUpdate", FollowCursor)
	end)
	b:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)
	return b
end

--- Create/show/hide the button according to the saved option.
function P.MinimapInit()
	if not button then
		if not P.db.opts.minimap then return end
		button = Build()
	end
	Place(P.db.opts.angle)
	button:SetShown(P.db.opts.minimap)
end

-- Addon compartment (named in the TOC).
function Poor_OnAddonCompartmentClick()
	P.ToggleWindow()
end
function Poor_OnAddonCompartmentEnter(_, menuButton)
	ShowTooltip(menuButton)
end
function Poor_OnAddonCompartmentLeave()
	GameTooltip_Hide()
end
