-- poor -- UI.lua
-- The main window: Roster, Poorest and Events tabs.
local _, P = ...

local SIDEBAR = 126 -- the navigation runs down the left; panels start right of it
local HEADER = 32   -- title strip across the top
local WIDTH, HEIGHT = SIDEBAR + 684, 470
local ROW_HEIGHT = 22
local LIST_TOP = -112 -- below the tab buttons and each tab's header strip
local LIST_BOTTOM = 30

local window, panels, tabButtons, activeTab = nil, {}, {}, 1

---------------------------------------------------------------------------
-- Look: a flat dark skin drawn with plain colours and a client font only,
-- so the addon ships no art files. One accent colour, copper, for the guild.
---------------------------------------------------------------------------
local ACCENT = { 0.86, 0.56, 0.27 }
local TEXT, DIM = { 0.92, 0.92, 0.92 }, { 0.58, 0.58, 0.63 }
local COLOR = {
	window = { 0.075, 0.075, 0.085, 0.97 },
	sidebar = { 0.05, 0.05, 0.058, 1 },
	header = { 0.04, 0.04, 0.047, 1 },
	line = { 1, 1, 1, 0.09 },
	field = { 0, 0, 0, 0.4 },
	button = { 1, 1, 1, 0.07 },
}

-- Arial Narrow ships with the client and reads cleaner at small sizes than the
-- default face; locales it has no glyphs for keep the default.
local FACE = ({ koKR = true, zhCN = true, zhTW = true, ruRU = true })[GetLocale()] and STANDARD_TEXT_FONT or "Fonts\\ARIALN.TTF"

local function Font(name, size, color)
	local font = CreateFont(name)
	font:SetFont(FACE, size, "")
	if not font:GetFont() then font:SetFont(STANDARD_TEXT_FONT, size, "") end
	font:SetTextColor(color[1], color[2], color[3])
	font:SetShadowColor(0, 0, 0, 0.9)
	font:SetShadowOffset(1, -1)
	return font
end

-- Callers name fonts by the stock name they replaced.
local FONTS = {
	GameFontHighlightSmall = Font("PoorFontText", 12, TEXT),
	GameFontNormalSmall = Font("PoorFontLabel", 11, DIM),
	GameFontNormal = Font("PoorFontHead", 14, ACCENT),
	GameFontDisable = Font("PoorFontDim", 12, DIM),
}
local FONT_BUTTON = Font("PoorFontButton", 12, TEXT)
local FONT_BUTTON_OFF = Font("PoorFontButtonOff", 12, DIM)
local FONT_TITLE = Font("PoorFontTitle", 17, ACCENT)

local function Fill(frame, layer, color, sublevel)
	local t = frame:CreateTexture(nil, layer, nil, sublevel or 0)
	t:SetAllPoints(frame)
	t:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
	return t
end

--- A one-pixel frame line. Returns an object with :SetColor(r, g, b, a).
local function Border(frame, r, g, b, a)
	local edges = {}
	for i = 1, 4 do
		edges[i] = frame:CreateTexture(nil, "BORDER")
		edges[i]:SetColorTexture(r, g, b, a)
	end
	edges[1]:SetPoint("TOPLEFT")
	edges[1]:SetPoint("TOPRIGHT")
	edges[1]:SetHeight(1)
	edges[2]:SetPoint("BOTTOMLEFT")
	edges[2]:SetPoint("BOTTOMRIGHT")
	edges[2]:SetHeight(1)
	edges[3]:SetPoint("TOPLEFT")
	edges[3]:SetPoint("BOTTOMLEFT")
	edges[3]:SetWidth(1)
	edges[4]:SetPoint("TOPRIGHT")
	edges[4]:SetPoint("BOTTOMRIGHT")
	edges[4]:SetWidth(1)
	function edges:SetColor(...)
		for i = 1, 4 do self[i]:SetColorTexture(...) end
	end
	return edges
end

local function Label(parent, text, font)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	fs:SetFontObject(FONTS[font or "GameFontHighlightSmall"] or FONTS.GameFontHighlightSmall)
	fs:SetJustifyH("LEFT")
	fs:SetWordWrap(false)
	if text then fs:SetText(text) end
	return fs
end

--- Flat button. LockHighlight() keeps it lit, which marks a chosen option.
local function Button(parent, text, width, onClick)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(width, 20)
	Fill(b, "BACKGROUND", COLOR.button)
	Border(b, 1, 1, 1, 0.13)
	local lit = b:CreateTexture(nil, "HIGHLIGHT")
	lit:SetAllPoints(b)
	lit:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.3)
	b:SetHighlightTexture(lit)
	b:SetNormalFontObject(FONT_BUTTON)
	b:SetHighlightFontObject(FONT_BUTTON)
	b:SetDisabledFontObject(FONT_BUTTON_OFF)
	b:SetPushedTextOffset(1, -1)
	b:SetText(text)
	b:SetScript("OnClick", onClick)
	return b
end

local function EditBox(parent, width, maxLetters)
	local e = CreateFrame("EditBox", nil, parent)
	e:SetSize(width, 20)
	e:SetAutoFocus(false)
	e:SetMaxLetters(maxLetters)
	e:SetFontObject(FONTS.GameFontHighlightSmall)
	e:SetTextInsets(6, 6, 0, 0)
	Fill(e, "BACKGROUND", COLOR.field)
	local border = Border(e, 1, 1, 1, 0.13)
	e:SetScript("OnEnterPressed", e.ClearFocus)
	e:SetScript("OnEscapePressed", e.ClearFocus)
	e:SetScript("OnEditFocusGained", function() border:SetColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.9) end)
	e:SetScript("OnEditFocusLost", function() border:SetColor(1, 1, 1, 0.13) end)
	return e
end

--- Edit box with a "Search" hint; onChange(text) gets the trimmed, lower-case text.
local function SearchBox(parent, width, onChange)
	local e = EditBox(parent, width, 40)
	local hint = Label(e, "Search", "GameFontDisable")
	hint:SetPoint("LEFT", e, "LEFT", 7, 0)
	local last = ""
	e:SetScript("OnTextChanged", function(self)
		local raw = self:GetText() or ""
		hint:SetShown(raw == "")
		local text = strtrim(raw):lower()
		if text ~= last then
			last = text
			onChange(text)
		end
	end)
	return e
end

--- Flat checkbox with its label to the right; onClick(checked).
local function Check(parent, text, onClick)
	local c = CreateFrame("CheckButton", nil, parent)
	c:SetSize(16, 16)
	Fill(c, "BACKGROUND", COLOR.field)
	Border(c, 1, 1, 1, 0.2)
	local mark = c:CreateTexture(nil, "ARTWORK")
	mark:SetPoint("TOPLEFT", 3, -3)
	mark:SetPoint("BOTTOMRIGHT", -3, 3)
	mark:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 1)
	c:SetCheckedTexture(mark)
	local lit = c:CreateTexture(nil, "HIGHLIGHT")
	lit:SetAllPoints(c)
	lit:SetColorTexture(1, 1, 1, 0.12)
	c:SetHighlightTexture(lit)
	local label = Label(c, text)
	label:SetPoint("LEFT", c, "RIGHT", 6, 0)
	c:SetHitRectInsets(0, -(label:GetStringWidth() + 8), 0, 0) -- the label is clickable too
	c:SetScript("OnClick", function(self)
		PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
		onClick(self:GetChecked() and true or false)
	end)
	return c
end

--- A small window holding text that can be selected and copied (Ctrl+C).
local copyWindow
function P.ShowText(title, text)
	local f = copyWindow
	if not f then
		f = CreateFrame("Frame", "PoorCopyFrame", UIParent)
		copyWindow = f
		f:SetSize(640, 340)
		f:SetPoint("CENTER", 0, 60)
		f:SetFrameStrata("DIALOG")
		f:SetToplevel(true)
		f:EnableMouse(true)
		f:SetMovable(true)
		f:SetClampedToScreen(true)
		f:RegisterForDrag("LeftButton")
		f:SetScript("OnDragStart", f.StartMoving)
		f:SetScript("OnDragStop", f.StopMovingOrSizing)
		Fill(f, "BACKGROUND", COLOR.window, -8)
		Border(f, 0, 0, 0, 1)
		f.title = Label(f, nil, "GameFontNormal")
		f.title:SetPoint("TOPLEFT", 12, -10)
		local hint = Label(f, "Ctrl+A selects everything, Ctrl+C copies it.", "GameFontDisable")
		hint:SetPoint("BOTTOMLEFT", 12, 10)
		local close = Button(f, "Close", 70, function() f:Hide() end)
		close:SetPoint("BOTTOMRIGHT", -10, 8)

		local scroll = CreateFrame("ScrollFrame", nil, f)
		scroll:SetPoint("TOPLEFT", 12, -34)
		scroll:SetPoint("BOTTOMRIGHT", -12, 36)
		Fill(scroll, "BACKGROUND", COLOR.field)
		local box = CreateFrame("EditBox", nil, scroll)
		box:SetMultiLine(true)
		box:SetAutoFocus(false)
		box:SetFontObject(FONTS.GameFontHighlightSmall)
		box:SetWidth(606)
		box:SetTextInsets(6, 6, 6, 6)
		box:SetScript("OnEscapePressed", function() f:Hide() end)
		scroll:SetScrollChild(box)
		scroll:EnableMouseWheel(true)
		scroll:SetScript("OnMouseWheel", function(self, delta)
			local max = math.max(0, box:GetHeight() - self:GetHeight())
			self:SetVerticalScroll(math.min(max, math.max(0, self:GetVerticalScroll() - delta * 40)))
		end)
		-- Clicking the empty area below the text still focuses it.
		scroll:SetScript("OnMouseDown", function() box:SetFocus() end)
		-- The text is a report, not a form: typing puts it back.
		box:SetScript("OnTextChanged", function(self, byUser)
			if byUser and f.text then
				self:SetText(f.text)
				self:HighlightText()
			end
		end)
		f.box, f.scroll = box, scroll
		tinsert(UISpecialFrames, "PoorCopyFrame")
	end
	f.text = text
	f.title:SetText(title)
	f.box:SetText(text)
	f.scroll:SetVerticalScroll(0)
	f:Show()
	f.box:SetFocus()
	f.box:HighlightText()
end

local function ClassName(name)
	local m, g = P.members[name], P.db.gold[name]
	return P.ClassColored(P.ShortName(name), (m and m.class) or (g and g.class))
end

--- A scrolling list. columns = { { title, width, justify }, ... };
--- fill(row, data) sets row.cells[i] texts; buildRow(row) runs once per row
--- frame. top/bottom are offsets inside the panel. With onSort(columnIndex)
--- the column titles become clickable. Returns the scroll box, with
--- :SetRows(array) and .heads (the title font strings).
local function List(parent, columns, fill, buildRow, top, bottom, onSort)
	top, bottom = top or LIST_TOP, bottom or LIST_BOTTOM
	local x, heads = 8, {}
	for i, col in ipairs(columns) do
		local head = Label(parent, col[1], "GameFontNormalSmall")
		head:SetPoint("TOPLEFT", parent, "TOPLEFT", x, top + 17)
		head:SetWidth(col[2])
		head:SetJustifyH(col[3] or "LEFT")
		heads[i] = head
		if onSort and col[1] ~= "" then
			local click = CreateFrame("Button", nil, parent)
			click:SetPoint("TOPLEFT", head, "TOPLEFT", 0, 3)
			click:SetPoint("BOTTOMRIGHT", head, "BOTTOMRIGHT", 0, -3)
			click:SetScript("OnClick", function()
				PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
				onSort(i)
			end)
			click:SetScript("OnEnter", function() head:SetTextColor(TEXT[1], TEXT[2], TEXT[3]) end)
			click:SetScript("OnLeave", function() head:SetTextColor(DIM[1], DIM[2], DIM[3]) end)
		end
		x = x + col[2] + 6
	end

	local box = CreateFrame("Frame", nil, parent, "WowScrollBoxList")
	box:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, top)
	box:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -24, bottom)
	local bar = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
	bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 6, 0)
	bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 6, 0)

	-- A hairline between the column titles and the rows.
	local rule = parent:CreateTexture(nil, "ARTWORK")
	rule:SetColorTexture(COLOR.line[1], COLOR.line[2], COLOR.line[3], COLOR.line[4])
	rule:SetHeight(1)
	rule:SetPoint("BOTTOMLEFT", box, "TOPLEFT", 0, 1)
	rule:SetPoint("BOTTOMRIGHT", box, "TOPRIGHT", 0, 1)

	-- Position of each row's data in the current list, for the zebra stripes.
	local order = setmetatable({}, { __mode = "k" })

	local view = CreateScrollBoxListLinearView()
	view:SetElementExtent(ROW_HEIGHT)
	view:SetElementInitializer("Button", function(row, data)
		if not row.cells then
			row.cells = {}
			local cx = 4
			for i, col in ipairs(columns) do
				local cell = Label(row)
				cell:SetPoint("LEFT", row, "LEFT", cx, 0)
				cell:SetWidth(col[2])
				cell:SetJustifyH(col[3] or "LEFT")
				row.cells[i] = cell
				cx = cx + col[2] + 6
			end
			row.stripe = Fill(row, "BACKGROUND", { 1, 1, 1, 0.035 }, -8)
			local lit = row:CreateTexture(nil, "HIGHLIGHT")
			lit:SetAllPoints(row)
			lit:SetColorTexture(1, 1, 1, 0.07)
			row:SetHighlightTexture(lit)
			row:SetScript("OnLeave", GameTooltip_Hide)
			if buildRow then buildRow(row) end
		end
		row.data = data
		row.stripe:SetShown((order[data] or 1) % 2 == 0)
		fill(row, data)
	end)
	ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)

	function box:SetRows(rows)
		for i, data in ipairs(rows) do order[data] = i end
		self:SetDataProvider(CreateDataProvider(rows), ScrollBoxConstants.RetainScrollPosition)
	end
	box.heads = heads
	return box
end

---------------------------------------------------------------------------
-- Tab 1: Roster
---------------------------------------------------------------------------
--- Open the chat box on a whisper to `name`, with `text` already typed when
--- given. Nothing is sent: the player reads it and presses Enter.
local function Whisper(name, text)
	name = P.WhisperTarget(name)
	if text and text ~= "" then
		local line = "/w " .. name .. " " .. text
		if ChatFrameUtil and ChatFrameUtil.OpenChat then return ChatFrameUtil.OpenChat(line) end
		if ChatFrame_OpenChat then return ChatFrame_OpenChat(line) end
	end
	if ChatFrameUtil and ChatFrameUtil.SendTell then
		ChatFrameUtil.SendTell(name)
	elseif ChatFrame_SendTell then
		ChatFrame_SendTell(name)
	end
end

-- Sort arrow shown beside the sorted column's title; the second is the same
-- texture flipped upside down.
local ARROW_DOWN = " |TInterface\\Buttons\\UI-SortArrow:9:9:0:0:16:16:0:16:0:16|t"
local ARROW_UP = " |TInterface\\Buttons\\UI-SortArrow:9:9:0:0:16:16:0:16:16:0|t"

local ROSTER_COLUMNS = {
	{ "Name", 140 }, { "Lvl", 28, "RIGHT" }, { "Rank", 90 }, { "Zone", 140 }, { "Addon", 44 }, { "Note", 150 },
}

-- What each column sorts by. Text compares without regard to case. The Addon
-- column marks who will see what is posted on the other tabs.
local ROSTER_SORT = {
	function(m) return P.ShortName(m.name):lower() end,
	function(m) return m.level end,
	function(m) return m.rankIndex end,
	function(m) return (m.online and m.zone or ""):lower() end,
	function(m) return P.HasAddon(m.name) and 0 or 1 end,
	function(m) return m.note:lower() end,
}

local function BuildRoster(panel)
	local filter = ""
	local list

	list = List(panel, ROSTER_COLUMNS, function(row, m)
		local c = row.cells
		local gold = P.db.gold[m.name]
		local main = P.MainOf(m.name)
		c[1]:SetText(P.ClassColored(P.ShortName(m.name), m.class)
			.. (main ~= m.name and (" |cff808080(" .. P.ShortName(main) .. ")|r") or ""))
		c[2]:SetText(m.level)
		c[3]:SetText(m.rank)
		c[4]:SetText(m.online and m.zone or "|cff808080offline|r")
		c[5]:SetText(P.HasAddon(m.name) and "|cff40ff40yes|r" or "|cff606060-|r")
		c[6]:SetText(m.note)
		row:SetAlpha(m.online and 1 or 0.55)
	end, function(row)
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		row:SetScript("OnClick", function(self, button)
			local m = self.data
			if m.name == P.me then return end
			if button == "RightButton" then
				if m.online then P.Invite(m.name) end
			else
				Whisper(m.name)
			end
		end)
		row:SetScript("OnEnter", function(self)
			local m = self.data
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(P.ClassColored(P.ShortName(m.name), m.class))
			local main = P.MainOf(m.name)
			if main ~= m.name then
				GameTooltip:AddLine("Alt of " .. ClassName(main), 0.8, 0.8, 0.8)
			else
				local chars = P.CharsOf(m.name)
				if #chars > 1 then
					local alts = {}
					for _, char in ipairs(chars) do
						if char ~= m.name then tinsert(alts, ClassName(char)) end
					end
					GameTooltip:AddLine("Alts: " .. table.concat(alts, ", "), 0.8, 0.8, 0.8, true)
				end
			end
			if m.note ~= "" then GameTooltip:AddLine(m.note, 1, 1, 1, true) end
			local gold = P.db.gold[m.name]
			if gold then
				GameTooltip:AddLine(("%s (%s)"):format(P.MoneyIcons(gold.copper), P.Ago(gold.ts)), 1, 1, 1)
			end
			GameTooltip:AddLine("Left-click: whisper   Right-click: invite", 0.6, 0.6, 0.6)
			GameTooltip:Show()
		end)
	end, nil, nil, function(column)
		-- Same column again flips the direction; a third click goes back to
		-- the default order (online first, then by rank).
		local sort = P.db.opts.rosterSort
		if not sort or sort.column ~= column then
			P.db.opts.rosterSort = { column = column, desc = false }
		elseif not sort.desc then
			sort.desc = true
		else
			P.db.opts.rosterSort = nil
		end
		panel:Refresh()
	end)

	local count = Label(panel, nil, "GameFontNormalSmall")
	count:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 10)

	local search = SearchBox(panel, 170, function(text)
		filter = text
		panel:Refresh()
	end)
	search:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -64)

	local check = Check(panel, "Show offline", function(on)
		P.db.opts.showOffline = on
		panel:Refresh()
	end)
	check:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -120, -66)

	StaticPopupDialogs["POOR_MAIN"] = {
		text = "Which character is your main?\nType its name, or leave this empty if the character you are on is a main.",
		button1 = ACCEPT,
		button2 = CANCEL,
		hasEditBox = true,
		maxLetters = 40,
		OnAccept = function(self)
			local box = self.EditBox or self.editBox
			local text = strtrim(box and box:GetText() or "")
			local ok, err = P.SetMyMain(text ~= "" and P.ResolveName(text) or nil)
			if not ok then P.Print(err) end
		end,
		EditBoxOnEnterPressed = function(self)
			local parent = self:GetParent()
			StaticPopupDialogs["POOR_MAIN"].OnAccept(parent)
			parent:Hide()
		end,
		EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		preferredIndex = 3,
	}
	local mainButton = Button(panel, "", 150, function() StaticPopup_Show("POOR_MAIN") end)
	mainButton:SetPoint("LEFT", search, "RIGHT", 12, 0)
	mainButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Link your characters")
		GameTooltip:AddLine("Tell the guild which of your characters is your main. Your alts are then counted with it "
			.. "on the Poorest and Shame tabs and as one donor on funds. It applies to every character of yours that has logged in with the addon.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	mainButton:SetScript("OnLeave", GameTooltip_Hide)

	local function Matches(m)
		if filter == "" then return true end
		return P.ShortName(m.name):lower():find(filter, 1, true)
			or P.ShortName(P.MainOf(m.name)):lower():find(filter, 1, true)
			or m.rank:lower():find(filter, 1, true)
			or m.zone:lower():find(filter, 1, true)
			or m.note:lower():find(filter, 1, true)
	end

	function panel:Refresh()
		local showOffline = P.db.opts.showOffline
		check:SetChecked(showOffline)
		local myMain = P.MainOf(P.me)
		mainButton:SetText(myMain == P.me and "Set my main" or ("Main: " .. P.ShortName(myMain)))
		local rows, online = {}, 0
		for _, m in ipairs(P.roster) do
			if m.online then online = online + 1 end
			if (m.online or showOffline) and Matches(m) then tinsert(rows, m) end
		end

		local sort = P.db.opts.rosterSort
		local key = sort and ROSTER_SORT[sort.column]
		table.sort(rows, function(a, b)
			if key then
				local ka, kb = key(a), key(b)
				if ka ~= kb then
					if sort.desc then return ka > kb end
					return ka < kb
				end
			else
				if a.online ~= b.online then return a.online end
				if a.rankIndex ~= b.rankIndex then return a.rankIndex < b.rankIndex end
			end
			return a.name < b.name
		end)
		for i, head in ipairs(list.heads) do
			head:SetText(ROSTER_COLUMNS[i][1] .. ((key and sort.column == i) and (sort.desc and ARROW_DOWN or ARROW_UP) or ""))
		end

		list:SetRows(rows)
		if #P.roster == 0 then
			count:SetText(P.InGuild() and "Loading roster..." or P.WhyNotReady())
		elseif filter ~= "" then
			count:SetText(("%d shown / %d online / %d members"):format(#rows, online, #P.roster))
		else
			count:SetText(("%d online / %d members"):format(online, #P.roster))
		end
	end
end

---------------------------------------------------------------------------
-- Tab 2: Poorest
---------------------------------------------------------------------------
local TITLES = { "Poorest of the poor", "Destitute", "Penniless" }

local function BuildPoorest(panel)
	local list = List(panel, {
		{ "#", 24, "RIGHT" }, { "Name", 130 }, { "Lvl", 28, "RIGHT" }, { "Gold", 110, "RIGHT" },
		{ "This week", 110, "RIGHT" }, { "Title", 120 }, { "Updated", 56 },
	}, function(row, e)
		local c = row.cells
		c[1]:SetText(e.rank)
		c[2]:SetText(P.ClassColored(P.ShortName(e.name), e.class)
			.. (#e.chars > 1 and (" |cff808080+" .. (#e.chars - 1) .. "|r") or ""))
		c[3]:SetText(e.level and e.level > 0 and e.level or "")
		c[4]:SetText(P.MoneyIcons(e.copper))
		c[5]:SetText(e.change and P.DeltaText(e.change) or "|cff808080?|r")
		c[6]:SetText(e.title or "")
		c[7]:SetText(P.Ago(e.ts))
	end, function(row)
		row:SetScript("OnEnter", function(self)
			local e = self.data
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(P.ClassColored(P.ShortName(e.name), e.class))
			if e.change then
				GameTooltip:AddLine(("%s over %d day%s"):format(P.DeltaText(e.change), e.span, e.span == 1 and "" or "s"), 1, 1, 1)
			else
				GameTooltip:AddLine("No earlier record to compare with yet.", 0.6, 0.6, 0.6)
			end
			if #e.chars > 1 then
				-- A person with alts: what each character holds.
				GameTooltip:AddLine(" ")
				table.sort(e.chars)
				for _, char in ipairs(e.chars) do
					GameTooltip:AddDoubleLine(ClassName(char), P.MoneyIcons(P.db.gold[char].copper), 1, 1, 1, 1, 1, 1)
				end
			else
				local days = P.GoldHistory(e.chars[1], 14)
				if #days > 0 then GameTooltip:AddLine(" ") end
				for _, d in ipairs(days) do
					GameTooltip:AddDoubleLine(date("%a %d %b", d.ts), P.MoneyIcons(d.copper), 0.8, 0.8, 0.8, 1, 1, 1)
				end
			end
			GameTooltip:Show()
		end)
	end)

	local total = Label(panel, nil, "GameFontNormalSmall")
	total:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 10)

	local week = Label(panel)
	week:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -66)
	week:SetWidth(300)

	local share = Check(panel, "Share my gold", function(on)
		P.db.opts.share, P.db.opts.shareAsked = on, true
		if on then P.SendGoldSoon() end
		panel:Refresh()
	end)
	share:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("Join the leaderboard")
		GameTooltip:AddLine("Off by default. When on, the gold of your characters is sent to guildmates who use the addon. "
			.. "When off, nobody sees it; your own row here is visible only to you.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	share:SetScript("OnLeave", GameTooltip_Hide)
	StaticPopupDialogs["POOR_SHARE"] = {
		text = "The Poorest tab ranks the guild by how little gold everyone has.\n\nShare your gold with guildmates who use the addon and join the board?\n\nYou can change this any time with the \"Share my gold\" box.",
		button1 = YES,
		button2 = NO,
		OnAccept = function()
			P.db.opts.share = true
			P.SendGoldSoon()
			P.Fire("Options")
		end,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		preferredIndex = 3,
	}
	share:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -120, -66)

	local combine = Check(panel, "Combine alts", function(on)
		P.db.opts.combineAlts = on
		P.Fire("Options")
	end)
	combine:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -250, -66)

	function panel:Refresh()
		-- Asked once, the first time the tab is looked at.
		if not P.db.opts.shareAsked then
			P.db.opts.shareAsked = true
			StaticPopup_Show("POOR_SHARE")
		end
		share:SetChecked(P.db.opts.share)
		combine:SetChecked(P.db.opts.combineAlts)
		local rows, sum = P.Leaderboard(), 0
		for i, e in ipairs(rows) do
			e.rank = i
			e.title = TITLES[i] or (i == #rows and #rows > 3 and "Suspiciously rich") or nil
			e.change, e.span = P.GroupChange(e.chars, 7)
			sum = sum + e.copper
		end
		list:SetRows(rows)
		week:SetText(P.WeekSummaryText()
			or "|cff999999Gold is reported by each member's addon. Weekly changes appear once there is a day of history.|r")
		if #rows == 0 then
			total:SetText("No gold reports yet.")
		else
			total:SetText(("Guild net worth: %s across %d %s (average %s)%s"):format(
				P.MoneyIcons(sum), #rows, P.db.opts.combineAlts and "players" or "characters", P.MoneyIcons(sum / #rows),
				P.db.opts.share and "" or "   |cffff8040You are not sharing: only you see your row.|r"))
		end
	end
end

---------------------------------------------------------------------------
-- Tab 3: Events
---------------------------------------------------------------------------
local STATUS_LABEL = { Y = "In", M = "Maybe", N = "Out" }
local ROLE_TAG = { T = "|cff6699ffTank|r ", H = "|cff40ff40Healer|r ", D = "|cffff6060DPS|r " }
local ROLE_ORDER = { T = 1, H = 2, D = 3 }
local EVENTS_TOP, DETAIL_HEIGHT = -134, 96

--- "Tank Alice, Healer Bob, DPS Cara" for one status, and the head count.
local function SignupNames(e, status)
	local list = {}
	for name, s in pairs(e.signups) do
		if s.status == status then tinsert(list, { name = name, role = s.role }) end
	end
	table.sort(list, function(a, b)
		local ra, rb = ROLE_ORDER[a.role] or 9, ROLE_ORDER[b.role] or 9
		if ra ~= rb then return ra < rb end
		return a.name < b.name
	end)
	local parts = {}
	for i, s in ipairs(list) do
		parts[i] = ((status == "Y" and ROLE_TAG[s.role]) or "") .. ClassName(s.name)
	end
	return table.concat(parts, ", "), #list
end

local function RoleSummary(e)
	local y, _, _, roles = P.CountSignups(e)
	if y == 0 then return "nobody yet" end
	return ("%d tank%s, %d healer%s, %d DPS"):format(roles.T, roles.T == 1 and "" or "s", roles.H, roles.H == 1 and "" or "s", roles.D)
end

local function BuildEvents(panel)
	local selected, editing -- event ids

	-- Form, line 1: title, date, time, Create/Save, Cancel
	local formLabel = Label(panel, "New event", "GameFontNormalSmall")
	formLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -66)
	formLabel:SetWidth(62)
	local title = EditBox(panel, 190, P.TITLE_MAX)
	title:SetPoint("LEFT", formLabel, "RIGHT", 12, 0)
	local dateLabel = Label(panel, "Date", "GameFontNormalSmall")
	dateLabel:SetPoint("LEFT", title, "RIGHT", 10, 0)
	local dateBox = EditBox(panel, 82, 10)
	dateBox:SetPoint("LEFT", dateLabel, "RIGHT", 10, 0)
	local timeLabel = Label(panel, "Time", "GameFontNormalSmall")
	timeLabel:SetPoint("LEFT", dateBox, "RIGHT", 10, 0)
	local timeBox = EditBox(panel, 46, 5)
	timeBox:SetPoint("LEFT", timeLabel, "RIGHT", 10, 0)

	-- Form, line 2: details, my role
	local descLabel = Label(panel, "Details", "GameFontNormalSmall")
	descLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -90)
	descLabel:SetWidth(62)
	local desc = EditBox(panel, 380, P.DESC_MAX)
	desc:SetPoint("LEFT", descLabel, "RIGHT", 12, 0)

	local role = Button(panel, "", 130, function()
		local current = P.MyRole()
		for i, r in ipairs(P.ROLES) do
			if r == current then
				P.SetMyRole(P.ROLES[i % #P.ROLES + 1])
				break
			end
		end
	end)
	role:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -28, -88)
	role:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("The role you sign up as")
		GameTooltip:AddLine("Click to change. Applies the next time you press In or Maybe.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	role:SetScript("OnLeave", GameTooltip_Hide)

	local save, cancel

	local function StopEditing()
		editing = nil
		title:SetText("")
		desc:SetText("")
		title:ClearFocus()
		desc:ClearFocus()
		formLabel:SetText("New event")
		save:SetText("Create")
		cancel:Hide()
	end

	local function StartEditing(e)
		editing = e.id
		title:SetText(e.title)
		desc:SetText(e.desc or "")
		dateBox:SetText(date("%Y-%m-%d", e.time))
		timeBox:SetText(date("%H:%M", e.time))
		formLabel:SetText("Edit event")
		save:SetText("Save")
		cancel:Show()
		title:SetFocus()
	end

	save = Button(panel, "Create", 62, function()
		local when = P.ParseWhen(dateBox:GetText(), timeBox:GetText())
		if not when then
			return P.Print("Date must look like 2026-12-24 and time like 20:00 (your local time).")
		end
		local e, err
		if editing then
			e, err = P.EditEvent(editing, title:GetText(), when, desc:GetText())
		else
			e, err = P.CreateEvent(title:GetText(), when, desc:GetText())
		end
		if not e then return P.Print(err) end
		selected = e.id
		StopEditing()
		panel:Refresh()
	end)
	save:SetPoint("LEFT", timeBox, "RIGHT", 8, 0)
	cancel = Button(panel, "Cancel", 58, function() StopEditing() end)
	cancel:SetPoint("LEFT", save, "RIGHT", 4, 0)
	cancel:Hide()

	-- List
	local list = List(panel, {
		{ "When", 110 }, { "Event", 200 }, { "By", 90 }, { "In/Maybe/Out", 80 },
	}, function(row, e)
		local c = row.cells
		local y, m, n = P.CountSignups(e)
		c[1]:SetText(date("%a %d %b %H:%M", e.time))
		c[2]:SetText(e.title)
		c[3]:SetText(ClassName(e.author))
		c[4]:SetText(("|cff40ff40%d|r / |cffffd100%d|r / |cffff4040%d|r"):format(y, m, n))
		local mine = e.signups[P.me] and e.signups[P.me].status
		for status, b in pairs(row.buttons) do
			if status == mine then b:LockHighlight() else b:UnlockHighlight() end
		end
		row.selection:SetShown(e.id == selected)
		row:SetAlpha(e.time < P.Now() and 0.6 or 1)
	end, function(row)
		row.selection = row:CreateTexture(nil, "BACKGROUND")
		row.selection:SetAllPoints(row)
		row.selection:SetColorTexture(0.72, 0.45, 0.2, 0.25)
		row.buttons = {}
		local x = -4
		for _, status in ipairs({ "N", "M", "Y" }) do
			local b = Button(row, STATUS_LABEL[status], 48, function()
				selected = row.data.id
				P.SignUp(row.data.id, status)
			end)
			b:SetSize(48, 18)
			b:SetPoint("RIGHT", row, "RIGHT", x, 0)
			row.buttons[status] = b
			x = x - 50
		end
		row:SetScript("OnClick", function(self)
			selected = self.data.id
			panel:Refresh()
		end)
		row:SetScript("OnEnter", function(self)
			local e = self.data
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(e.title)
			GameTooltip:AddLine(date("%A %d %B, %H:%M", e.time) .. " (your time)", 1, 1, 1)
			if e.desc and e.desc ~= "" then GameTooltip:AddLine(e.desc, 0.8, 0.8, 0.8, true) end
			GameTooltip:AddLine("Signed in: " .. RoleSummary(e), 1, 1, 1)
			GameTooltip:AddLine("Click for details", 0.6, 0.6, 0.6)
			GameTooltip:Show()
		end)
	end, EVENTS_TOP, DETAIL_HEIGHT + 8)

	local empty = Label(panel, "No events planned. We cannot afford any.", "GameFontDisable")
	empty:SetPoint("CENTER", panel, "CENTER", 0, 10)

	-- Detail pane for the selected event
	local detail = CreateFrame("Frame", nil, panel)
	detail:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 6)
	detail:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10, 6)
	detail:SetHeight(DETAIL_HEIGHT)
	local rule = detail:CreateTexture(nil, "ARTWORK")
	rule:SetColorTexture(1, 1, 1, 0.15)
	rule:SetHeight(1)
	rule:SetPoint("TOPLEFT")
	rule:SetPoint("TOPRIGHT")

	local dTitle = Label(detail, nil, "GameFontNormal")
	dTitle:SetPoint("TOPLEFT", 0, -8)
	dTitle:SetWidth(420)
	local dDesc = Label(detail)
	dDesc:SetPoint("TOPLEFT", dTitle, "BOTTOMLEFT", 0, -4)
	dDesc:SetWidth(640)
	dDesc:SetTextColor(0.8, 0.8, 0.8)
	local dIn = Label(detail)
	dIn:SetPoint("TOPLEFT", dDesc, "BOTTOMLEFT", 0, -4)
	dIn:SetWidth(640)
	dIn:SetWordWrap(true)
	dIn:SetMaxLines(2)
	local dOther = Label(detail)
	dOther:SetPoint("BOTTOMLEFT", detail, "BOTTOMLEFT", 0, 4)
	dOther:SetWidth(640)

	local delete = Button(detail, "Delete", 60, function()
		local e = selected and P.db.events[selected]
		if not e then return end
		if IsShiftKeyDown() then
			if editing == e.id then StopEditing() end
			P.DeleteEvent(e.id)
		else
			P.Print("Shift-click Delete to remove \"" .. e.title .. "\" for everyone.")
		end
	end)
	delete:SetPoint("TOPRIGHT", detail, "TOPRIGHT", 0, -5)
	local edit = Button(detail, "Edit", 50, function()
		local e = selected and P.db.events[selected]
		if e then StartEditing(e) end
	end)
	edit:SetPoint("RIGHT", delete, "LEFT", -4, 0)
	local invite = Button(detail, "Invite signed-in", 110, function()
		if selected then P.InviteSignedUp(selected) end
	end)
	invite:SetPoint("RIGHT", edit, "LEFT", -4, 0)

	local function ShowDetail(e)
		detail:SetShown(e ~= nil)
		if not e then return end
		dTitle:SetText(("%s  |cffffffff%s|r"):format(e.title, date("%a %d %b %H:%M", e.time)))
		dDesc:SetText((e.desc and e.desc ~= "") and e.desc or "No details given.")
		local inNames, inCount = SignupNames(e, "Y")
		dIn:SetText(("|cff40ff40In (%d)|r  %s"):format(inCount, inCount > 0 and inNames or "nobody yet"))
		local maybeNames, maybeCount = SignupNames(e, "M")
		local outNames, outCount = SignupNames(e, "N")
		dOther:SetText(("|cffffd100Maybe (%d)|r %s    |cffff4040Out (%d)|r %s"):format(maybeCount, maybeNames, outCount, outNames))
		local manage = P.CanManage(e)
		delete:SetShown(manage)
		edit:SetShown(manage)
		invite:SetShown(manage)
	end

	function panel:Refresh()
		if dateBox:GetText() == "" then dateBox:SetText(date("%Y-%m-%d")) end
		if timeBox:GetText() == "" then timeBox:SetText("20:00") end
		role:SetText("My role: " .. P.ROLE_NAME[P.MyRole()])
		local rows = P.EventList()
		local current
		for _, e in ipairs(rows) do
			if e.id == selected then current = e end
		end
		-- Nothing chosen, or the chosen event is gone: fall back to the next one.
		current = current or rows[1]
		selected = current and current.id or nil
		if editing and not (P.db.events[editing] and not P.db.events[editing].deleted) then StopEditing() end
		list:SetRows(rows)
		empty:SetShown(#rows == 0)
		ShowDetail(current)
	end
end

---------------------------------------------------------------------------
-- Tab 4: Funds
---------------------------------------------------------------------------
local function BuildFunds(panel)
	local SIDE = 190             -- width of the list of funds on the left
	local current, selectedEntry -- fund id, donation id
	local byDonor = false        -- list shows totals per person instead of single payments

	-- Left: every fund and lottery, one click to switch -------------------
	local side = CreateFrame("Frame", nil, panel)
	side:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
	side:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 0)
	side:SetWidth(SIDE)
	local divider = side:CreateTexture(nil, "ARTWORK")
	divider:SetColorTexture(COLOR.line[1], COLOR.line[2], COLOR.line[3], COLOR.line[4])
	divider:SetWidth(1)
	divider:SetPoint("TOPRIGHT", side, "TOPRIGHT", 0, -58)
	divider:SetPoint("BOTTOMRIGHT", side, "BOTTOMRIGHT", 0, 62)

	local picker = List(side, { { "Funds and lotteries", 106 }, { "", 42, "RIGHT" } }, function(row, f)
		local total = P.FundTotal(f)
		local gold = math.floor(total / 10000)
		row.cells[1]:SetText((f.price and "|cffffd100" or "|cffffffff") .. f.title .. "|r")
		row.cells[2]:SetText(gold > 0 and (gold .. "g") or P.MoneyShort(total))
		row.selection:SetShown(f.id == current)
		row.mark:SetShown(f.id == current)
		row:SetAlpha(f.closed and 0.55 or 1)
	end, function(row)
		row.selection = Fill(row, "BACKGROUND", { 1, 1, 1, 0.08 })
		row.mark = row:CreateTexture(nil, "ARTWORK")
		row.mark:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 1)
		row.mark:SetPoint("TOPLEFT")
		row.mark:SetPoint("BOTTOMLEFT")
		row.mark:SetWidth(2)
		row:SetScript("OnClick", function(self)
			if self.data.id == current then return end
			current, selectedEntry = self.data.id, nil
			PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
			panel:Refresh()
		end)
		row:SetScript("OnEnter", function(self)
			local f = self.data
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(f.title)
			GameTooltip:AddLine(P.FundStatusText(f), 1, 1, 1, true)
			GameTooltip:AddLine((f.price and "Lottery" or "Fund") .. (f.closed and ", closed" or ", open") .. ", run by " .. P.ShortName(f.collector), 0.6, 0.6, 0.6)
			GameTooltip:Show()
		end)
	end, -78, 62)

	-- Right: the chosen one ----------------------------------------------
	local detail = CreateFrame("Frame", nil, panel)
	detail:SetPoint("TOPLEFT", panel, "TOPLEFT", SIDE, 0)
	detail:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)

	-- Line 1: its name, and what its keeper can do with it
	local name = Label(detail, nil, "GameFontNormal")
	name:SetPoint("TOPLEFT", detail, "TOPLEFT", 10, -63)
	name:SetWidth(250)
	local delete = Button(detail, "Delete", 54, function()
		local f = P.db.funds[current or ""]
		if not f then return end
		local allowed, why = P.CanDeleteFund(f)
		if not allowed then return P.Print(why or "You cannot delete this one.") end
		if not IsShiftKeyDown() then return P.Print("Shift-click Delete to remove \"" .. f.title .. "\" for everyone.") end
		P.DeleteFund(current)
	end)
	delete:SetPoint("TOPRIGHT", detail, "TOPRIGHT", -28, -62)
	local close = Button(detail, "Close", 58, function()
		local f = P.db.funds[current or ""]
		if not f then return end
		if f.price then
			-- A lottery is not closed, it is drawn.
			if not IsShiftKeyDown() then return P.Print("Shift-click Draw to pick the winner of \"" .. f.title .. "\". This cannot be undone.") end
			local winner, err = P.DrawLottery(current)
			if not winner then P.Print(err) end
		else
			P.SetFundClosed(current, not f.closed)
		end
	end)
	close:SetPoint("RIGHT", delete, "LEFT", -4, 0)
	local announce = Button(detail, "Announce", 72, function()
		if current then P.AnnounceFund(current) end
	end)
	announce:SetPoint("RIGHT", close, "LEFT", -4, 0)
	announce:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("Post the progress in guild chat", 1, 1, 1)
		GameTooltip:Show()
	end)
	announce:SetScript("OnLeave", GameTooltip_Hide)

	-- Line 2: how far along it is, and the choice of what the list shows
	local progress = Label(detail)
	progress:SetPoint("TOPLEFT", detail, "TOPLEFT", 10, -88)
	progress:SetWidth(330)
	local view = Button(detail, "", 110, function()
		byDonor = not byDonor
		selectedEntry = nil
		panel:Refresh()
	end)
	view:SetPoint("TOPRIGHT", detail, "TOPRIGHT", -28, -84)

	local bar = CreateFrame("StatusBar", nil, detail)
	bar:SetPoint("TOPLEFT", detail, "TOPLEFT", 10, -108)
	bar:SetPoint("TOPRIGHT", detail, "TOPRIGHT", -28, -108)
	bar:SetHeight(8)
	bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
	bar:SetStatusBarColor(ACCENT[1], ACCENT[2], ACCENT[3])
	bar:SetMinMaxValues(0, 1)
	Fill(bar, "BACKGROUND", { 0, 0, 0, 0.5 })

	-- Line 3: pledging. A donor promises gold so it is recorded unasked when it
	-- arrives; the keeper sees what is on its way and can let all gold from
	-- guildmates count without the question.
	StaticPopupDialogs["POOR_PLEDGE"] = {
		text = "%s",
		button1 = ACCEPT,
		button2 = CANCEL,
		hasEditBox = true,
		maxLetters = 12,
		OnAccept = function(self, fundId)
			local box = self.EditBox or self.editBox
			local text = strtrim(box and box:GetText() or "")
			local f = P.db.funds[fundId or ""]
			if not f then return end
			local copper
			if f.price then
				local n = tonumber(text)
				if not n or n < 1 or n ~= math.floor(n) then return P.Print("Type a number of tickets, like 3.") end
				copper = n * f.price
			else
				copper = P.ParseMoney(text)
			end
			local p, err = P.Pledge(fundId, copper)
			if not p then return P.Print(err) end
			P.Print(("Pledged %s to |cffffffff%s|r. Now trade it to %s (the amount fills in), or open a mailbox and the addon offers to prepare the mail."):format(
				P.MoneyIcons(copper), f.title, P.ShortName(f.collector)))
		end,
		EditBoxOnEnterPressed = function(self)
			local parent = self:GetParent()
			StaticPopupDialogs["POOR_PLEDGE"].OnAccept(parent, parent.data)
			parent:Hide()
		end,
		EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		preferredIndex = 3,
	}
	local pledgeRow = CreateFrame("Frame", nil, detail)
	pledgeRow:SetPoint("TOPLEFT", detail, "TOPLEFT", 10, -122)
	pledgeRow:SetPoint("TOPRIGHT", detail, "TOPRIGHT", -28, -122)
	pledgeRow:SetHeight(22)
	local chip = Button(pledgeRow, "Pledge gold", 96, function()
		local f = P.db.funds[current or ""]
		if not f then return end
		local dialog = StaticPopup_Show("POOR_PLEDGE", f.price
			and ("How many tickets for \"%s\"?\n%s each."):format(f.title, P.MoneyIcons(f.price))
			or ("How much gold will you give to \"%s\"?"):format(f.title))
		if dialog then dialog.data = f.id end
	end)
	chip:SetPoint("LEFT", pledgeRow, "LEFT", 0, 0)
	chip:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Promise gold (nothing is paid yet)")
		GameTooltip:AddLine("Say how much you are sending. When you then trade or mail it, the amount is filled in for you, "
			.. "and it is recorded as yours the moment it arrives.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	chip:SetScript("OnLeave", GameTooltip_Hide)
	local cancelPledge = Button(pledgeRow, "Withdraw", 70, function()
		local mine = P.PendingPledges(current, P.me)
		if mine[1] then P.CancelPledge(mine[#mine].id) end
	end)
	cancelPledge:SetPoint("RIGHT", pledgeRow, "RIGHT", 0, 0)
	local auto = Check(pledgeRow, "Count guildmates' gold without asking", function(on) P.SetFundAuto(current, on) end)
	auto:SetPoint("LEFT", pledgeRow, "LEFT", 0, 0)
	auto:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Skip the question")
		GameTooltip:AddLine("While this is the fund you are looking at, gold a guildmate trades or mails you is recorded for it straight away. "
			.. "For a lottery only whole tickets count that way. Pledged gold is always recorded without asking. "
			.. "Remove undoes a wrong entry.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	auto:SetScript("OnLeave", GameTooltip_Hide)
	local pledgeText = Label(pledgeRow)
	pledgeText:SetTextColor(DIM[1], DIM[2], DIM[3])

	-- Line 4: the keeper records a payment by hand
	local manage = CreateFrame("Frame", nil, detail)
	manage:SetPoint("TOPLEFT", detail, "TOPLEFT", 10, -122)
	manage:SetPoint("TOPRIGHT", detail, "TOPRIGHT", -28, -122)
	manage:SetHeight(22)
	local donorLabel = Label(manage, "Donor", "GameFontNormalSmall")
	donorLabel:SetPoint("LEFT", manage, "LEFT", 0, 0)
	local donorBox = EditBox(manage, 104, 40)
	donorBox:SetPoint("LEFT", donorLabel, "RIGHT", 8, 0)
	local goldLabel = Label(manage, "Gold", "GameFontNormalSmall")
	goldLabel:SetPoint("LEFT", donorBox, "RIGHT", 8, 0)
	local goldBox = EditBox(manage, 60, 16)
	goldBox:SetPoint("LEFT", goldLabel, "RIGHT", 8, 0)
	local add = Button(manage, "Add", 44, function()
		local ok, err = P.AddDonation(current, P.ResolveName(donorBox:GetText()), P.ParseMoney(goldBox:GetText()), "H")
		if not ok then return P.Print(err) end
		donorBox:SetText("")
		goldBox:SetText("")
		donorBox:SetFocus()
	end)
	add:SetPoint("LEFT", goldBox, "RIGHT", 6, 0)
	goldBox:SetScript("OnEnterPressed", function() add:Click() end)
	local remove = Button(manage, "Remove", 60, function()
		if not selectedEntry then return P.Print("Click a payment in the list first.") end
		if not IsShiftKeyDown() then return P.Print("Shift-click Remove to delete the selected payment.") end
		P.RemoveDonation(current, selectedEntry)
		selectedEntry = nil
	end)
	remove:SetPoint("LEFT", add, "RIGHT", 4, 0)

	-- Payments
	local list = List(detail, {
		{ "When", 92 }, { "Donor", 124 }, { "Amount", 96, "RIGHT" }, { "", 8 }, { "Received", 104 },
	}, function(row, d)
		local c = row.cells
		c[1]:SetText(date("%d %b %H:%M", d.ts or d.last))
		c[2]:SetText(ClassName(d.name))
		c[3]:SetText(P.MoneyIcons(d.copper))
		c[5]:SetText(d.tickets or (d.count and (d.count .. (d.count == 1 and " donation" or " donations"))) or P.HOW_TEXT[d.how] or "")
		row.selection:SetShown(d.eid ~= nil and d.eid == selectedEntry)
	end, function(row)
		row.selection = Fill(row, "BACKGROUND", { ACCENT[1], ACCENT[2], ACCENT[3], 0.25 })
		row:SetScript("OnClick", function(self)
			if not self.data.eid then return end -- per-donor totals cannot be selected
			selectedEntry = self.data.eid ~= selectedEntry and self.data.eid or nil
			panel:Refresh()
		end)
	end, -192, 62)

	local listEmpty = Label(detail, nil, "GameFontDisable")
	listEmpty:SetPoint("CENTER", detail, "CENTER", -10, -50)
	local empty = Label(panel, nil, "GameFontDisable")
	empty:SetPoint("CENTER", panel, "CENTER", 0, -10)

	-- Bottom: open a new one (officers) -----------------------------------
	local create = CreateFrame("Frame", nil, panel)
	create:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 32)
	create:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -28, 32)
	create:SetHeight(22)
	local newLabel = Label(create, "New", "GameFontNormalSmall")
	newLabel:SetPoint("LEFT", create, "LEFT", 0, 0)
	local newTitle = EditBox(create, 200, P.FUND_TITLE_MAX)
	newTitle:SetPoint("LEFT", newLabel, "RIGHT", 10, 0)
	local goalLabel = Label(create, "Gold", "GameFontNormalSmall")
	goalLabel:SetPoint("LEFT", newTitle, "RIGHT", 10, 0)
	local goalBox = EditBox(create, 64, 16)
	goalBox:SetPoint("LEFT", goalLabel, "RIGHT", 10, 0)

	local function Opened(f, asLottery)
		current, selectedEntry, byDonor = f.id, nil, asLottery
		newTitle:SetText("")
		goalBox:SetText("")
		newTitle:ClearFocus()
		goalBox:ClearFocus()
		panel:Refresh()
	end
	local createButton = Button(create, "Open fund", 80, function()
		local goalText = goalBox:GetText()
		local f, err = P.CreateFund(newTitle:GetText(), goalText == "" and 0 or P.ParseMoney(goalText))
		if not f then return P.Print(err) end
		Opened(f, false)
	end)
	createButton:SetPoint("LEFT", goalBox, "RIGHT", 8, 0)
	createButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Open a fund")
		GameTooltip:AddLine("Collect gold for something. Gold is the goal; leave it empty for no goal.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	createButton:SetScript("OnLeave", GameTooltip_Hide)
	local lotteryButton = Button(create, "Open lottery", 90, function()
		local f, err = P.CreateFund(newTitle:GetText(), nil, P.ParseMoney(goalBox:GetText()) or 0)
		if not f then return P.Print(err) end
		Opened(f, true)
	end)
	lotteryButton:SetPoint("LEFT", createButton, "RIGHT", 4, 0)
	lotteryButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Open a lottery")
		GameTooltip:AddLine("Gold is the price of one ticket. Players trade or mail you gold to enter, you draw a winner, "
			.. "and the winner takes the whole pot. You hold the gold and pay it out.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	lotteryButton:SetScript("OnLeave", GameTooltip_Hide)

	local footer = Label(panel, nil, "GameFontNormalSmall")
	footer:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 10)
	-- The winner of a lottery, and only the winner, confirms the pot arrived.
	local gotIt = Button(panel, "I received the pot", 130, function()
		local ok, err = P.ConfirmPayout(current)
		if not ok and err then P.Print(err) end
	end)
	gotIt:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -28, 6)
	gotIt:Hide()

	function panel:Refresh()
		gotIt:Hide()
		local funds = P.FundList()
		local f
		for _, candidate in ipairs(funds) do
			if candidate.id == current then f = candidate end
		end
		f = f or funds[1]
		current = f and f.id or nil
		-- Gold handed over is offered for the fund its keeper is looking at.
		if f and f.collector == P.me and not f.closed then P.db.activeFund = f.id end

		create:SetShown(P.AmOfficer())
		side:SetShown(f ~= nil)
		detail:SetShown(f ~= nil)
		empty:SetShown(f == nil)
		picker:SetRows(funds)
		if not f then
			footer:SetText("")
			empty:SetText(P.AmOfficer() and "No funds or lotteries yet. Open one below." or "No funds or lotteries. Nothing to collect, nothing to win.")
			return
		end

		local manages = P.CanManageFund(f)
		manage:SetShown(manages)

		-- Pledge line: shown while gold can still come in.
		local keeper = f.collector == P.me
		pledgeRow:SetShown(not f.closed)
		manage:ClearAllPoints()
		manage:SetPoint("TOPLEFT", detail, "TOPLEFT", 10, f.closed and -122 or -146)
		manage:SetPoint("TOPRIGHT", detail, "TOPRIGHT", -28, f.closed and -122 or -146)
		chip:SetShown(not keeper)
		chip:SetText(f.price and "Pledge tickets" or "Pledge gold")
		auto:SetShown(keeper)
		auto:SetChecked(P.FundAuto(f.id))
		pledgeText:ClearAllPoints()
		if keeper then
			local parts = {}
			for i, p in ipairs(P.PendingPledges(f.id)) do
				if i > 4 then parts[5] = "..." break end
				parts[i] = P.ShortName(p.from) .. " " .. P.MoneyIcons(p.copper)
			end
			cancelPledge:Hide()
			pledgeText:SetPoint("RIGHT", pledgeRow, "RIGHT", 0, 0)
			pledgeText:SetWidth(210)
			pledgeText:SetJustifyH("RIGHT")
			pledgeText:SetText(#parts > 0 and ("On its way: " .. table.concat(parts, ", ")) or "")
		else
			local mine, sum = P.PendingPledges(f.id, P.me), 0
			for _, p in ipairs(mine) do sum = sum + p.copper end
			cancelPledge:SetShown(#mine > 0)
			pledgeText:SetPoint("LEFT", chip, "RIGHT", 10, 0)
			pledgeText:SetWidth(270)
			pledgeText:SetJustifyH("LEFT")
			pledgeText:SetText(#mine > 0 and ("You pledged %s. Trade or mail it to %s."):format(P.MoneyIcons(sum), P.ShortName(f.collector)) or "")
		end
		announce:SetShown(manages)
		delete:SetShown(manages)

		local total, donors, count = P.FundTotal(f)
		local rows
		if f.price then
			-- Lottery
			local tickets, ticketCount = P.LotteryTickets(f)
			name:SetText(f.title)
			if f.winner then
				progress:SetText(("|cffffd100Won by %s|r  %s"):format(P.ShortName(f.winner), P.MoneyIcons(total)))
			else
				progress:SetText(("Pot %s   %d ticket%s at %s   |cff999999run by %s|r"):format(P.MoneyIcons(total), ticketCount,
					ticketCount == 1 and "" or "s", P.MoneyIcons(f.price), P.ShortName(f.collector)))
			end
			bar:Hide()
			close:SetText("Draw")
			close:SetShown(manages and not f.winner)
			view:SetText(byDonor and "Show payments" or "Show tickets")
			if byDonor then
				rows = P.FundDonors(f)
				local byName = {}
				for _, t in ipairs(tickets) do byName[t.name] = t end
				for _, d in ipairs(rows) do
					local t = byName[d.name]
					d.tickets = t and ("%d ticket%s, %d%%%s"):format(t.tickets, t.tickets == 1 and "" or "s",
						math.floor(t.tickets / ticketCount * 100 + 0.5), f.winner == d.name and " |cffffd100WON|r" or "")
						or "no ticket yet"
				end
			else
				rows = P.FundEntries(f)
			end
			list.heads[5]:SetText(byDonor and "Tickets" or "Received")
			listEmpty:SetText("Nobody has entered yet.")
			gotIt:SetShown(f.winner ~= nil and not f.paid and (P.MainOf(P.me) == f.winner or P.me == f.winner))
			footer:SetText(f.winner
				and (f.paid and ("Drawn: ticket %d of %d. %s confirmed receiving the pot."):format(f.winTicket, f.winOf, P.ShortName(f.winner))
					or ("Drawn: ticket %d of %d. %s owes %s the pot, until %s confirms it arrived."):format(f.winTicket, f.winOf,
						P.ShortName(f.collector), P.ShortName(f.winner), P.ShortName(f.winner)))
				or ("%d payment%s from %d player%s. Winner takes all."):format(count, count == 1 and "" or "s", donors, donors == 1 and "" or "s"))
		else
			name:SetText(f.title)
			local who = ("   |cff999999collected by %s|r"):format(P.ShortName(f.collector))
			if f.goal > 0 then
				progress:SetText(("%s / %s (%d%%)%s%s"):format(P.MoneyIcons(total), P.MoneyIcons(f.goal),
					math.floor(total / f.goal * 100), f.closed and "  |cffff4040closed|r" or "", who))
				bar:SetValue(math.min(1, total / f.goal))
			else
				progress:SetText(P.MoneyIcons(total) .. (f.closed and "  |cffff4040closed|r" or "") .. who)
				bar:SetValue(total > 0 and 1 or 0)
			end
			bar:Show()
			close:SetText(f.closed and "Reopen" or "Close")
			close:SetShown(manages)
			view:SetText(byDonor and "Show donations" or "Show per donor")
			rows = byDonor and P.FundDonors(f) or P.FundEntries(f)
			list.heads[5]:SetText(byDonor and "Count" or "Received")
			listEmpty:SetText("No donations yet.")
			footer:SetText(("%d donation%s from %d player%s"):format(count, count == 1 and "" or "s", donors, donors == 1 and "" or "s"))
		end
		list:SetRows(rows)
		listEmpty:SetShown(#rows == 0)
	end
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
-- Panels.lua adds its tabs to this list and builds them with these helpers.
P.tabs = {
	{ "Roster", BuildRoster },
	{ "Poorest", BuildPoorest },
	{ "Events", BuildEvents },
	{ "Funds", BuildFunds },
}
P.ui = { Label = Label, Button = Button, EditBox = EditBox, SearchBox = SearchBox, Check = Check, List = List,
	ClassName = ClassName, Whisper = Whisper, Fill = Fill, Border = Border, ACCENT = ACCENT, COLOR = COLOR, FONT_TITLE = FONT_TITLE }

--- Lay the navigation out again, leaving out tabs that have nothing to show
--- for this player right now (a tab says so with a `visible` function).
local function LayoutTabs()
	local row = 0
	for i, tab in ipairs(P.tabs) do
		local shown = not tab.visible or tab.visible()
		tabButtons[i]:SetShown(shown)
		if shown then
			tabButtons[i]:ClearAllPoints()
			tabButtons[i]:SetPoint("TOPLEFT", window, "TOPLEFT", 1, -HEADER - 10 - row * 26)
			row = row + 1
		elseif i == activeTab then
			activeTab = 1
		end
	end
end

local function SelectTab(index)
	activeTab = index
	LayoutTabs()
	for i, panel in ipairs(panels) do
		panel:SetShown(i == activeTab)
		tabButtons[i]:SetSelected(i == activeTab)
	end
	panels[activeTab]:Refresh()
end

local function Refresh()
	if not (window and window:IsShown()) then return end
	local before = activeTab
	LayoutTabs()
	if activeTab ~= before then return SelectTab(activeTab) end
	panels[activeTab]:Refresh()
end

-- Where the window sits and how big it is, kept in PoorDB.opts.win.
local function SavePlace(f)
	local point, _, relativePoint, x, y = f:GetPoint(1)
	P.db.opts.win = { point = point, relativePoint = relativePoint, x = x, y = y,
		width = f:GetWidth(), height = f:GetHeight() }
end

local function Place(f)
	local win = P.db.opts.win
	f:ClearAllPoints()
	if win and win.point then
		f:SetSize(math.max(WIDTH, win.width or WIDTH), math.max(HEIGHT, win.height or HEIGHT))
		f:SetPoint(win.point, UIParent, win.relativePoint or win.point, win.x or 0, win.y or 0)
	else
		f:SetSize(WIDTH, HEIGHT)
		f:SetPoint("CENTER")
	end
end

function P.ResetWindow()
	P.db.opts.win = nil
	if window then Place(window) end
end

--- A row of the navigation: plain text, lit when hovered, marked with an
--- accent bar when it is the open tab.
local function NavButton(parent, text, onClick)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(SIDEBAR - 1, 26)
	local lit = b:CreateTexture(nil, "HIGHLIGHT")
	lit:SetAllPoints(b)
	lit:SetColorTexture(1, 1, 1, 0.05)
	b:SetHighlightTexture(lit)
	local chosen = Fill(b, "BACKGROUND", { 1, 1, 1, 0.07 })
	local bar = b:CreateTexture(nil, "ARTWORK")
	bar:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 1)
	bar:SetPoint("TOPLEFT")
	bar:SetPoint("BOTTOMLEFT")
	bar:SetWidth(3)
	local label = Label(b, text)
	label:SetPoint("LEFT", b, "LEFT", 16, 0)
	function b:SetSelected(on)
		chosen:SetShown(on)
		bar:SetShown(on)
		if on then label:SetTextColor(1, 1, 1) else label:SetTextColor(DIM[1], DIM[2], DIM[3]) end
	end
	b:SetSelected(false)
	b:SetScript("OnClick", onClick)
	return b
end

local function BuildWindow()
	local f = CreateFrame("Frame", "PoorFrame", UIParent)
	f:Hide()
	Place(f)
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		SavePlace(self)
	end)
	Fill(f, "BACKGROUND", COLOR.window, -8)
	Border(f, 0, 0, 0, 1)

	-- Title strip
	local header = f:CreateTexture(nil, "BACKGROUND", nil, -6)
	header:SetColorTexture(COLOR.header[1], COLOR.header[2], COLOR.header[3], COLOR.header[4])
	header:SetPoint("TOPLEFT", 1, -1)
	header:SetPoint("TOPRIGHT", -1, -1)
	header:SetHeight(HEADER)
	local headerLine = f:CreateTexture(nil, "ARTWORK")
	headerLine:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.55)
	headerLine:SetPoint("TOPLEFT", header, "BOTTOMLEFT")
	headerLine:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT")
	headerLine:SetHeight(1)
	local icon = f:CreateTexture(nil, "ARTWORK")
	icon:SetTexture(P.ICON)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	icon:SetSize(18, 18)
	icon:SetPoint("LEFT", header, "LEFT", 12, 0)
	local title = f:CreateFontString(nil, "OVERLAY")
	title:SetFontObject(FONT_TITLE)
	title:SetText("poor")
	title:SetPoint("LEFT", icon, "RIGHT", 8, 0)
	local version = Label(f, "v" .. P.VERSION, "GameFontDisable")
	version:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 8, 1)
	local function ShowVersion()
		local latest = P.UpdateAvailable()
		version:SetText(latest and ("v%s   |cffffd100update available: %s|r"):format(P.VERSION, latest) or ("v" .. P.VERSION))
	end
	ShowVersion()
	P.On("Version", ShowVersion)

	local close = Button(f, "X", 24, function() f:Hide() end)
	close:SetPoint("RIGHT", header, "RIGHT", -6, 0)

	-- Navigation
	local side = f:CreateTexture(nil, "BACKGROUND", nil, -6)
	side:SetColorTexture(COLOR.sidebar[1], COLOR.sidebar[2], COLOR.sidebar[3], COLOR.sidebar[4])
	side:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -1)
	side:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 1, 1)
	side:SetWidth(SIDEBAR - 1)
	local sideLine = f:CreateTexture(nil, "ARTWORK")
	sideLine:SetColorTexture(COLOR.line[1], COLOR.line[2], COLOR.line[3], COLOR.line[4])
	sideLine:SetPoint("TOPLEFT", side, "TOPRIGHT")
	sideLine:SetPoint("BOTTOMLEFT", side, "BOTTOMRIGHT")
	sideLine:SetWidth(1)

	-- Resize from the bottom right corner, never smaller than the default.
	f:SetResizable(true)
	f:SetResizeBounds(WIDTH, HEIGHT, 1100, 1000)
	local grip = CreateFrame("Button", nil, f)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -3, 3)
	grip:SetFrameLevel(f:GetFrameLevel() + 20)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
	grip:SetScript("OnMouseUp", function()
		f:StopMovingOrSizing()
		SavePlace(f)
	end)
	tinsert(UISpecialFrames, "PoorFrame") -- Escape closes it

	-- Panels keep their original inner layout, which left room for a row of
	-- tabs on top; shifting them up puts their first line just under the title.
	window = f -- LayoutTabs positions the navigation on it
	for i, tab in ipairs(P.tabs) do
		local panel = CreateFrame("Frame", nil, f)
		panel:SetPoint("TOPLEFT", f, "TOPLEFT", SIDEBAR, 20)
		panel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
		panel:Hide()
		tab[2](panel)
		panels[i] = panel
		local b = NavButton(f, tab[1], function()
			PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB)
			SelectTab(i)
		end)
		b:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -HEADER - 10 - (i - 1) * 26)
		tabButtons[i] = b
	end

	local alert = Button(f, "|cffff6060PvP alert|r", SIDEBAR - 20, function() P.SendPvPAlert("") end)
	alert:SetHeight(22)
	alert:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 38)
	alert:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("PvP alert")
		GameTooltip:AddLine("Tells the guild where you are: a warning and map pin for addon users, and a line in guild chat. "
			.. "An enemy player you have targeted is named.", 1, 1, 1, true)
		GameTooltip:AddLine("Also: /poor pvp <note>, or bind a key under Options > Keybindings > poor.", 0.6, 0.6, 0.6, true)
		GameTooltip:Show()
	end)
	alert:SetScript("OnLeave", GameTooltip_Hide)
	local options = Button(f, "Options", SIDEBAR - 20, function() P.OpenSettings() end)
	options:SetHeight(22)
	options:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 10)

	f:SetScript("OnShow", function()
		P.EnsureStarted()
		PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN)
		P.RequestRoster()
		P.ScanRoster()
		SelectTab(activeTab)
	end)
	f:SetScript("OnHide", function()
		PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE)
	end)
	return f
end

function P.ToggleWindow()
	window = window or BuildWindow()
	window:SetShown(not window:IsShown())
end

function P.OpenWindow()
	window = window or BuildWindow()
	window:Show()
end

P.On("Roster", Refresh)
P.On("Gold", Refresh)
P.On("Events", Refresh)
P.On("Funds", Refresh)
P.On("Options", Refresh)
for _, what in ipairs({ "Alts", "Shame", "Board", "Blob", "Crafts", "Names", "Alerts", "Race", "Groups", "Recruit" }) do
	P.On(what, Refresh)
end
