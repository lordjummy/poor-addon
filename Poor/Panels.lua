-- poor -- Panels.lua
-- The tabs added after the first four: Board, Shame, Bank, Crafters, Alerts.
-- Built with the helpers UI.lua exports in P.ui.
local _, P = ...

local Label, Button, EditBox, List, ClassName, Whisper =
	P.ui.Label, P.ui.Button, P.ui.EditBox, P.ui.List, P.ui.ClassName, P.ui.Whisper

local function SearchBox(panel, onChange)
	local box = P.ui.SearchBox(panel, 190, onChange)
	box:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -64)
	return box
end

local function Check(panel, text, x, onClick)
	local check = P.ui.Check(panel, text, onClick)
	check:SetPoint("TOPRIGHT", panel, "TOPRIGHT", x, -66)
	return check
end

local function Names(list)
	local out = {}
	for i, name in ipairs(list) do out[i] = ClassName(name) end
	return table.concat(out, ", ")
end

---------------------------------------------------------------------------
-- Board
---------------------------------------------------------------------------
local function BuildBoard(panel)
	local needLabel = Label(panel, "I need", "GameFontNormalSmall")
	needLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -66)
	local text = EditBox(panel, 270, P.BOARD_TEXT_MAX)
	text:SetPoint("LEFT", needLabel, "RIGHT", 12, 0)
	local goldLabel = Label(panel, "Gold", "GameFontNormalSmall")
	goldLabel:SetPoint("LEFT", text, "RIGHT", 10, 0)
	local gold = EditBox(panel, 60, 16)
	gold:SetPoint("LEFT", goldLabel, "RIGHT", 10, 0)
	local loan = P.ui.Check(panel, "Loan", function() end)
	loan:SetPoint("LEFT", gold, "RIGHT", 10, 0)
	loan:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("A loan you will pay back")
		GameTooltip:AddLine("Once you confirm the gold arrived, it stays on the ledger as a debt until the lender marks it repaid.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	loan:SetScript("OnLeave", GameTooltip_Hide)
	local post = Button(panel, "Post", 60, function()
		local amountText = gold:GetText()
		local amount = amountText ~= "" and P.ParseMoney(amountText) or nil
		if amountText ~= "" and not amount then return P.Print("Gold must look like 5 or 2g 50s.") end
		local r, err = P.PostRequest(text:GetText(), amount, loan:GetChecked())
		if not r then return P.Print(err) end
		text:SetText("")
		gold:SetText("")
		loan:SetChecked(false)
		text:ClearFocus()
	end)
	post:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -28, -64)

	-- What the one action button on a row does for the player looking at it.
	local function ActionFor(r)
		if r.state == "O" and r.author ~= P.me then return "I'll help", P.OfferHelp end
		if r.state == "C" and r.helper == P.me then return "Withdraw", P.WithdrawHelp end
		if r.state == "C" and r.author == P.me then return "Got it", P.MarkReceived end
		if P.IsDebt(r) and r.helper == P.me then return "Repaid", P.MarkRepaid end
	end

	local function Status(r)
		if r.state == "O" then return "|cff40ff40open|r" end
		if r.state == "C" then return "|cffffd100" .. P.ShortName(r.helper or "?") .. " helps|r" end
		return "|cffff4040owes " .. P.ShortName(r.helper or "?") .. "|r"
	end

	local list = List(panel, {
		{ "When", 60 }, { "Who", 90 }, { "Request", 180 }, { "Gold", 76, "RIGHT" }, { "Status", 96 },
	}, function(row, r)
		local c = row.cells
		c[1]:SetText(date("%d %b", r.created))
		c[2]:SetText(ClassName(r.author))
		c[3]:SetText(r.text)
		c[4]:SetText((r.amount or 0) > 0 and P.MoneyIcons(r.amount) or "")
		c[5]:SetText(Status(r))
		local label = ActionFor(r)
		row.action:SetShown(label ~= nil)
		if label then row.action:SetText(label) end
		row.delete:SetShown(P.CanDeleteRequest(r))
	end, function(row)
		row.delete = Button(row, "X", 22, function()
			if IsShiftKeyDown() then
				P.DeleteRequest(row.data.id)
			else
				P.Print("Shift-click the X to delete this request for everyone.")
			end
		end)
		row.delete:SetSize(22, 18)
		row.delete:SetPoint("RIGHT", row, "RIGHT", -4, 0)
		row.action = Button(row, "", 84, function()
			local _, act = ActionFor(row.data)
			if act then act(row.data.id) end
		end)
		row.action:SetSize(84, 18)
		row.action:SetPoint("RIGHT", row, "RIGHT", -30, 0)
		row:SetScript("OnEnter", function(self)
			local r = self.data
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(ClassName(r.author) .. " needs")
			GameTooltip:AddLine(r.text, 1, 1, 1, true)
			if (r.amount or 0) > 0 then
				GameTooltip:AddLine(P.MoneyIcons(r.amount) .. (r.loan and " as a loan" or " as a gift"), 1, 1, 1)
			end
			if r.state == "O" then
				GameTooltip:AddLine("Nobody has offered yet.", 0.6, 0.6, 0.6)
			elseif r.state == "C" then
				GameTooltip:AddLine(P.ShortName(r.helper or "?") .. " offered to help. " .. P.ShortName(r.author) .. " confirms when it arrives.", 0.6, 0.6, 0.6, true)
			else
				GameTooltip:AddLine("Received. " .. P.ShortName(r.helper or "?") .. " marks it repaid.", 0.6, 0.6, 0.6, true)
			end
			GameTooltip:Show()
		end)
	end, nil, 46)

	local empty = Label(panel, "Nobody needs anything. For once.", "GameFontDisable")
	empty:SetPoint("CENTER", panel, "CENTER", 0, -10)

	local ledger = Label(panel, nil, "GameFontNormalSmall")
	ledger:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 10)
	ledger:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -28, 10)
	ledger:SetHeight(28)
	ledger:SetWordWrap(true)
	ledger:SetMaxLines(2)
	ledger:SetJustifyV("BOTTOM")

	function panel:Refresh()
		local rows = P.BoardList()
		list:SetRows(rows)
		empty:SetShown(#rows == 0)
		local parts = {}
		for i, d in ipairs(P.Debts()) do
			parts[i] = ("%s owes %s %s"):format(ClassName(d.debtor), ClassName(d.creditor), P.MoneyIcons(d.copper))
		end
		ledger:SetText(#parts > 0 and ("Ledger: " .. table.concat(parts, "   ")) or "Ledger: nobody owes anybody.")
	end
end

---------------------------------------------------------------------------
-- Shame
---------------------------------------------------------------------------
local function BuildShame(panel)
	local sortBy = "deaths"
	local COLUMNS = { { "#", 24, "RIGHT" }, { "Name", 160 }, { "Deaths", 70, "RIGHT" }, { "Repair bills", 130, "RIGHT" }, { "", 10 }, { "Title", 200 } }

	local list
	list = List(panel, COLUMNS, function(row, e)
		local c = row.cells
		c[1]:SetText(e.rank)
		c[2]:SetText(P.ClassColored(P.ShortName(e.name), e.class) .. (#e.chars > 1 and (" |cff808080+" .. (#e.chars - 1) .. "|r") or ""))
		c[3]:SetText(e.deaths)
		c[4]:SetText(P.MoneyIcons(e.repairs))
		c[6]:SetText(e.title or "")
	end, function(row)
		row:SetScript("OnEnter", function(self)
			local e = self.data
			if #e.chars < 2 then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(P.ClassColored(P.ShortName(e.name), e.class))
			table.sort(e.chars)
			for _, char in ipairs(e.chars) do
				local s = P.db.shame[char]
				GameTooltip:AddDoubleLine(ClassName(char), ("%d deaths, %s"):format(s.deaths, P.MoneyIcons(s.repairs)), 1, 1, 1, 1, 1, 1)
			end
			GameTooltip:Show()
		end)
	end, nil, nil, function(column)
		if column == 3 then sortBy = "deaths" elseif column == 4 then sortBy = "repairs" else return end
		panel:Refresh()
	end)

	local hint = Label(panel, "Counted since each member installed the addon. Click Deaths or Repair bills to sort.")
	hint:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -66)
	hint:SetTextColor(0.6, 0.6, 0.6)
	local total = Label(panel, nil, "GameFontNormalSmall")
	total:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 10)
	local empty = Label(panel, "Nobody has died or repaired yet. Give it an hour.", "GameFontDisable")
	empty:SetPoint("CENTER", panel, "CENTER", 0, -10)

	function panel:Refresh()
		local rows = P.ShameList()
		local deaths, repairs, mostDeaths, mostRepairs = 0, 0, nil, nil
		for _, e in ipairs(rows) do
			deaths, repairs = deaths + e.deaths, repairs + e.repairs
			if e.deaths > 0 and (not mostDeaths or e.deaths > mostDeaths.deaths) then mostDeaths = e end
			if e.repairs > 0 and (not mostRepairs or e.repairs > mostRepairs.repairs) then mostRepairs = e end
		end
		table.sort(rows, function(a, b)
			if a[sortBy] ~= b[sortBy] then return a[sortBy] > b[sortBy] end
			return a.name < b.name
		end)
		for i, e in ipairs(rows) do
			e.rank = i
			e.title = (e == mostDeaths and e == mostRepairs and "Floor inspector, smith's favourite")
				or (e == mostDeaths and "Floor inspector") or (e == mostRepairs and "Blacksmith's favourite") or nil
		end
		list.heads[3]:SetText("Deaths" .. (sortBy == "deaths" and " *" or ""))
		list.heads[4]:SetText("Repair bills" .. (sortBy == "repairs" and " *" or ""))
		list:SetRows(rows)
		empty:SetShown(#rows == 0)
		total:SetText(#rows > 0 and ("The guild has died %d times and paid %s to blacksmiths."):format(deaths, P.MoneyIcons(repairs)) or "")
	end
end

---------------------------------------------------------------------------
-- Bank
---------------------------------------------------------------------------
local function ItemText(id)
	local name = P.TokenName("i" .. id)
	if not name then return "|cff808080loading...|r", nil end
	local icon = C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)
	local quality = C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(id)
	local color = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
	local text = (color and color.hex or "|cffffffff") .. name .. "|r"
	return (icon and ("|T" .. icon .. ":14|t ") or "") .. text, name
end

local function BuildBank(panel)
	local filter = ""
	local list = List(panel, {
		{ "Item", 280 }, { "Count", 60, "RIGHT" }, { "", 10 }, { "Held by", 250 },
	}, function(row, e)
		local c = row.cells
		c[1]:SetText(e.text)
		c[2]:SetText(e.count)
		c[4]:SetText(e.heldBy)
	end, function(row)
		row:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			if GameTooltip.SetItemByID then
				GameTooltip:SetItemByID(self.data.id)
			else
				GameTooltip:SetHyperlink("item:" .. self.data.id)
			end
			GameTooltip:Show()
		end)
	end)

	SearchBox(panel, function(text)
		filter = text
		panel:Refresh()
	end)
	local isBank = Check(panel, "This character is a guild bank", -230, function(on) P.SetBankChar(on) end)
	isBank:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("Share this character's items")
		GameTooltip:AddLine("Its bags, and its bank as of the last time you opened the bank window, are shown to the whole guild here. "
			.. "Untick to stop and clear what was shared.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	isBank:SetScript("OnLeave", GameTooltip_Hide)

	local footer = Label(panel, nil, "GameFontNormalSmall")
	footer:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 10)
	footer:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -28, 10)
	local empty = Label(panel, nil, "GameFontDisable")
	empty:SetPoint("CENTER", panel, "CENTER", 0, -10)

	function panel:Refresh()
		isBank:SetChecked(P.IsBankChar())
		local items, chars = P.BankItems()
		local rows = {}
		for _, e in ipairs(items) do
			local text, name = ItemText(e.id)
			if filter == "" or (name and name:lower():find(filter, 1, true)) then
				local holders = {}
				for holder, n in pairs(e.holders) do tinsert(holders, { name = holder, n = n }) end
				table.sort(holders, function(a, b) return a.name < b.name end)
				local parts = {}
				for i, h in ipairs(holders) do
					parts[i] = ClassName(h.name) .. (#holders > 1 and (" " .. h.n) or "")
				end
				tinsert(rows, { id = e.id, count = e.count, text = text, sortName = name and name:lower() or "\255", heldBy = table.concat(parts, ", ") })
			end
		end
		table.sort(rows, function(a, b)
			if a.sortName ~= b.sortName then return a.sortName < b.sortName end
			return a.id < b.id
		end)
		list:SetRows(rows)

		if #chars == 0 then
			empty:SetText("No guild bank characters yet. Log in on the bank alt and tick the box above.")
			footer:SetText("")
		else
			empty:SetText("Nothing matches.")
			local parts = {}
			for i, char in ipairs(chars) do
				local g = P.db.gold[char.name]
				parts[i] = ("%s%s, updated %s"):format(ClassName(char.name), g and (" " .. P.MoneyIcons(g.copper)) or "", P.Ago(char.ts))
			end
			footer:SetText("Bank: " .. table.concat(parts, "   "))
		end
		empty:SetShown(#rows == 0)
	end
end

---------------------------------------------------------------------------
-- Crafters: professions down the left, the crafters of the chosen one on the
-- right, a click further that crafter's recipes. Search looks through all.
---------------------------------------------------------------------------
local function BuildCrafters(panel)
	local SIDE = 190
	local filter = ""
	local chosen -- the profession picked on the left
	local browse -- { char, prof } while one character's recipes are listed

	local function Online(char)
		local m = P.members[char]
		return char == P.me or (m ~= nil and m.online)
	end

	-- Left: professions ---------------------------------------------------
	local side = CreateFrame("Frame", nil, panel)
	side:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
	side:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 0)
	side:SetWidth(SIDE)
	local divider = side:CreateTexture(nil, "ARTWORK")
	divider:SetColorTexture(P.ui.COLOR.line[1], P.ui.COLOR.line[2], P.ui.COLOR.line[3], P.ui.COLOR.line[4])
	divider:SetWidth(1)
	divider:SetPoint("TOPRIGHT", side, "TOPRIGHT", 0, -58)
	divider:SetPoint("BOTTOMRIGHT", side, "BOTTOMRIGHT", 0, 30)

	local picker = List(side, { { "Professions", 112 }, { "", 36, "RIGHT" } }, function(row, e)
		row.cells[1]:SetText(e.prof)
		row.cells[2]:SetText(e.online > 0 and ("|cff40ff40" .. e.online .. "|r/" .. e.count) or e.count)
		local on = e.prof == chosen and filter == ""
		row.selection:SetShown(on)
		row.mark:SetShown(on)
	end, function(row)
		row.selection = P.ui.Fill(row, "BACKGROUND", { 1, 1, 1, 0.08 })
		row.mark = row:CreateTexture(nil, "ARTWORK")
		row.mark:SetColorTexture(P.ui.ACCENT[1], P.ui.ACCENT[2], P.ui.ACCENT[3], 1)
		row.mark:SetPoint("TOPLEFT")
		row.mark:SetPoint("BOTTOMLEFT")
		row.mark:SetWidth(2)
		row:SetScript("OnClick", function(self)
			chosen, browse = self.data.prof, nil
			PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
			panel:Refresh()
		end)
		row:SetScript("OnEnter", function(self)
			local e = self.data
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(e.prof)
			GameTooltip:AddLine(("%d in the guild, %d online. Best skill %d."):format(e.count, e.online, e.best), 1, 1, 1, true)
			GameTooltip:Show()
		end)
	end, -78, 30)

	-- Right: crafters, recipes or search results --------------------------
	local detail = CreateFrame("Frame", nil, panel)
	detail:SetPoint("TOPLEFT", panel, "TOPLEFT", SIDE, 0)
	detail:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)

	local list = List(detail, {
		{ "Character", 190 }, { "Skill", 92 }, { "", 44 }, { "Recipes shared", 116 },
	}, function(row, e)
		local c = row.cells
		c[1]:SetText(e[1])
		c[2]:SetText(e[2])
		c[3]:SetText(e[3])
		c[4]:SetText(e[4])
		row:SetAlpha(e.online == false and 0.55 or 1)
	end, function(row)
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		row:SetScript("OnClick", function(self, button)
			local e = self.data
			if e.open and button ~= "RightButton" then
				browse = e.open
				PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
				panel:Refresh()
			elseif e.whisper and e.whisper ~= P.me then
				-- A recipe row starts the request for the player; a crafter row just opens the whisper.
				Whisper(e.whisper, e.ask)
			end
		end)
		row:SetScript("OnEnter", function(self)
			local e = self.data
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			if e.token then
				-- A single recipe: the game's own tooltip for it.
				local kind, id = e.token:sub(1, 1), tonumber(e.token:sub(2))
				local ok = id and pcall(function()
					if kind == "i" then GameTooltip:SetItemByID(id) else GameTooltip:SetSpellByID(id) end
				end)
				if not ok then GameTooltip:AddLine(e[1]) end
			elseif e.tip then
				GameTooltip:AddLine(e.tip[1])
				for i = 2, #e.tip do GameTooltip:AddLine(e.tip[i], 1, 1, 1, true) end
			else
				return
			end
			if e.open then
				GameTooltip:AddLine("Click to see the recipes" .. ((e.whisper and e.whisper ~= P.me) and ", right-click to whisper" or ""), 0.6, 0.6, 0.6)
			elseif e.whisper and e.whisper ~= P.me then
				GameTooltip:AddLine(e.ask and ("Click to ask " .. P.ShortName(e.whisper) .. " to craft it. Nothing is sent until you press Enter.")
					or ("Click to whisper " .. P.ShortName(e.whisper)), 0.6, 0.6, 0.6, true)
			end
			GameTooltip:Show()
		end)
	end)

	local search = P.ui.SearchBox(detail, 170, function(text)
		filter = text
		if #text >= 2 then browse = nil end -- searching looks through everyone again
		panel:Refresh()
	end)
	search:SetPoint("TOPLEFT", detail, "TOPLEFT", 10, -64)
	local back = Button(detail, "< Back", 64, function()
		browse = nil
		panel:Refresh()
	end)
	back:SetPoint("LEFT", search, "RIGHT", 10, 0)
	local hint = Label(detail)
	hint:SetWidth(270)
	hint:SetTextColor(0.6, 0.6, 0.6)
	local footer = Label(panel, nil, "GameFontNormalSmall")
	footer:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 10)
	local empty = Label(detail, nil, "GameFontDisable")
	empty:SetPoint("CENTER", detail, "CENTER", -10, -10)
	empty:SetWidth(400)
	empty:SetWordWrap(true)
	empty:SetJustifyH("CENTER")

	local function Heads(a, b, c, d)
		list.heads[1]:SetText(a)
		list.heads[2]:SetText(b)
		list.heads[3]:SetText(c)
		list.heads[4]:SetText(d)
	end

	function panel:Refresh()
		P.RefreshSkills() -- cheap; only announces itself when something changed

		-- Professions on the left, and which one is picked.
		local all, byProf, profs = P.ProfessionList(), {}, {}
		for _, r in ipairs(all) do
			local e = byProf[r.prof]
			if not e then
				e = { prof = r.prof, count = 0, online = 0, best = 0 }
				byProf[r.prof] = e
				tinsert(profs, e)
			end
			e.count, e.best = e.count + 1, math.max(e.best, r.rank)
			if r.online then e.online = e.online + 1 end
		end
		table.sort(profs, function(a, b) return a.prof < b.prof end)
		if not byProf[chosen or ""] then
			-- Start on one of the player's own professions when there is one.
			local mine = P.db.profs[P.me]
			chosen = (mine and mine.list[1] and byProf[mine.list[1].name] and mine.list[1].name) or (profs[1] and profs[1].prof) or nil
		end
		picker:SetRows(profs)

		local rows = {}
		local blob = browse and P.GetBlob("R:" .. browse.char .. ":" .. browse.prof)
		if browse and not (blob and #blob.tokens > 0) then browse, blob = nil, nil end
		back:SetShown(browse ~= nil)
		hint:ClearAllPoints()
		hint:SetPoint("LEFT", browse and back or search, "RIGHT", 10, 0)

		if browse then
			-- One character's recipes
			local loading = 0
			for _, token in ipairs(blob.tokens) do
				local name = P.TokenName(token)
				if not name then loading = loading + 1 end
				tinsert(rows, { name or ("Recipe " .. token:sub(2)), "", "", "", token = token, sort = (name or "\255"):lower(),
					online = Online(browse.char), whisper = browse.char,
					ask = name and ("Hi! Could you craft " .. name .. " for me?") or nil })
			end
			table.sort(rows, function(a, b)
				if a.sort ~= b.sort then return a.sort < b.sort end
				return a.token < b.token
			end)
			Heads("Recipe", "", "", "")
			hint:SetText(("%s of %s"):format(browse.prof, P.ShortName(browse.char)))
			empty:SetText("")
			footer:SetText(("%d recipes%s"):format(#rows, loading > 0 and (", " .. loading .. " names still loading") or ""))
		elseif #filter >= 2 then
			-- Recipe search across the guild
			local found, loading = P.FindRecipes(filter)
			for _, r in ipairs(found) do
				table.sort(r.crafters, function(a, b)
					if Online(a) ~= Online(b) then return Online(a) end
					return a < b
				end)
				tinsert(rows, { r.name, r.prof, "", Names(r.crafters), sort = r.name:lower(),
					online = Online(r.crafters[1]), whisper = r.crafters[1],
					ask = "Hi! Could you craft " .. r.name .. " for me?",
					tip = { r.name, r.prof, "Made by: " .. Names(r.crafters) } })
			end
			table.sort(rows, function(a, b) return a.sort < b.sort end)
			Heads("Recipe", "Profession", "", "Crafters")
			hint:SetText("Searching every profession. Online crafters come first.")
			empty:SetText(loading > 0 and "Loading item names, one moment..." or "Nobody in the guild has shared a recipe like that.")
			footer:SetText(("%d match%s%s"):format(#rows, #rows == 1 and "" or "es",
				loading > 0 and (", " .. loading .. " names still loading") or ""))
		else
			-- The crafters of the chosen profession, best first
			local counts, recipes = P.RecipeCounts(), 0
			for _, r in ipairs(all) do
				if r.prof == chosen then
					local n = counts[r.char] and counts[r.char][r.prof]
					if n then recipes = recipes + n end
					tinsert(rows, { P.ClassColored(P.ShortName(r.char), r.class), ("%d / %d"):format(r.rank, r.max), "",
						n and (n .. " recipes") or "|cff808080none yet|r", rank = r.rank, online = r.online, whisper = r.char,
						open = n and { char = r.char, prof = r.prof } or nil,
						tip = { P.ShortName(r.char) .. ": " .. r.prof,
							n and (n .. " recipes shared.") or "No recipes yet. They appear automatically once anyone in the guild has opened this profession's window." } })
				end
			end
			table.sort(rows, function(a, b)
				if a.rank ~= b.rank then return a.rank > b.rank end
				return a.whisper < b.whisper
			end)
			Heads("Character", "Skill", "", "Recipes shared")
			hint:SetText(chosen and "Click a crafter to see their recipes." or "")
			empty:SetText("No professions known yet. They arrive as guildmates log in with the addon.")
			footer:SetText(chosen and ("%s: %d crafter%s, %d recipes shared. Recipes are read automatically; opening the profession window once helps if none show."):format(
				chosen, #rows, #rows == 1 and "" or "s", recipes) or "")
		end
		list:SetRows(rows)
		empty:SetShown(#rows == 0)
	end
end

---------------------------------------------------------------------------
-- Alerts
---------------------------------------------------------------------------
local function BuildAlerts(panel)
	local list = List(panel, {
		{ "When", 100 }, { "Who", 100 }, { "Where", 240 }, { "Note", 180 },
	}, function(row, a)
		local c = row.cells
		c[1]:SetText(date("%d %b %H:%M", a.ts))
		c[2]:SetText(ClassName(a.from))
		c[3]:SetText(P.AlertPlace(a))
		c[4]:SetText(a.note or "")
		row:SetAlpha(a.mapID and 1 or 0.6)
	end, function(row)
		row:SetScript("OnClick", function(self) P.PinAlert(self.data) end)
		row:SetScript("OnEnter", function(self)
			local a = self.data
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine("PvP alert from " .. ClassName(a.from))
			GameTooltip:AddLine(P.AlertPlace(a), 1, 1, 1, true)
			if a.note and a.note ~= "" then GameTooltip:AddLine(a.note, 1, 1, 1, true) end
			GameTooltip:AddLine(a.mapID and "Click to put the pin back on your map" or "Sent without a position", 0.6, 0.6, 0.6)
			GameTooltip:Show()
		end)
	end)

	local hint = Label(panel, "The last 30 PvP alerts, yours included. Click one to pin it on your map again.")
	hint:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -66)
	hint:SetTextColor(0.6, 0.6, 0.6)
	local empty = Label(panel, "No PvP alerts yet. Peaceful, or nobody dares say.", "GameFontDisable")
	empty:SetPoint("CENTER", panel, "CENTER", 0, -10)
	local clear = Button(panel, "Clear", 60, function()
		if not IsShiftKeyDown() then return P.Print("Shift-click Clear to empty your alert history.") end
		wipe(P.db.alertLog)
		panel:Refresh()
	end)
	clear:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 6)

	function panel:Refresh()
		list:SetRows(P.db.alertLog)
		empty:SetShown(#P.db.alertLog == 0)
		clear:SetShown(#P.db.alertLog > 0)
	end
end

---------------------------------------------------------------------------
-- Race
---------------------------------------------------------------------------
local function BuildRace(panel)
	local MEDAL = { "|cffffd700", "|cffc7c7cf", "|cffcd7f32" }
	local PLACE = { "1st", "2nd", "3rd" }

	local heading = Label(panel, "Race to level " .. P.MAX_LEVEL, "GameFontNormal")
	heading:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -62)
	local podium = {}
	for i = 1, 3 do
		podium[i] = Label(panel)
		podium[i]:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -66 - i * 18)
		podium[i]:SetWidth(640)
	end

	local list = List(panel, {
		{ "#", 24, "RIGHT" }, { "Still running", 180 }, { "Level", 50, "RIGHT" }, { "Progress", 70, "RIGHT" }, { "", 10 }, { "Zone", 200 },
	}, function(row, c)
		local cells = row.cells
		cells[1]:SetText(c.rank)
		cells[2]:SetText(ClassName(c.name))
		cells[3]:SetText(c.level)
		cells[4]:SetText(c.pct and (c.pct .. "%") or "|cff808080?|r")
		cells[6]:SetText(c.online and c.zone or "|cff808080offline|r")
		row:SetAlpha(c.online and 1 or 0.55)
	end, function(row)
		row:SetScript("OnEnter", function(self)
			local c = self.data
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(ClassName(c.name))
			GameTooltip:AddLine(("Level %d, %d to go"):format(c.level, P.MAX_LEVEL - c.level), 1, 1, 1)
			GameTooltip:AddLine(c.pct and "Progress through the level is reported by their addon." or "No progress shown: they do not run the addon.", 0.6, 0.6, 0.6, true)
			GameTooltip:Show()
		end)
	end, -160, 30)

	local footer = Label(panel, nil, "GameFontNormalSmall")
	footer:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 10)
	footer:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -28, 10)

	function panel:Refresh()
		local done = P.Finishers()
		local anyApprox = false
		for i = 1, 3 do
			local e = done[i]
			if e then
				anyApprox = anyApprox or e.approx
				podium[i]:SetText(("%s%s|r   %s   |cff999999%s%s|r"):format(MEDAL[i], PLACE[i], ClassName(e.name),
					e.approx and "by " or "", date("%a %d %b %H:%M", e.ts)))
			else
				podium[i]:SetText(("%s%s|r   |cff808080still open|r"):format(MEDAL[i], PLACE[i]))
			end
		end
		local rows = P.Contenders(40)
		for i, c in ipairs(rows) do c.rank = i end
		list:SetRows(rows)
		local also = {}
		for i = 4, math.min(#done, 9) do tinsert(also, ClassName(done[i].name)) end
		footer:SetText((#done > 3 and ("Also at %d: %s%s.  "):format(P.MAX_LEVEL, table.concat(also, ", "), #done > 9 and " and more" or "") or "")
			.. (anyApprox and "\"by\" a time: already there when the addon first looked." or ""))
	end
end

---------------------------------------------------------------------------
-- Groups: find guildmates for a dungeon or quest right now
---------------------------------------------------------------------------
local function BuildGroups(panel)
	local picked                              -- { name, min, max } from the dungeon menu
	local need = { T = false, H = false, D = false }

	-- Line 1: what for, and which roles are missing
	local forLabel = Label(panel, "Looking for", "GameFontNormalSmall")
	forLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -66)
	local activity = EditBox(panel, 190, P.GROUP_TEXT_MAX)
	activity:SetPoint("LEFT", forLabel, "RIGHT", 10, 0)
	activity:SetScript("OnTextChanged", function(self, byUser)
		-- Typing something else drops the picked dungeon and its level range.
		if byUser and picked and self:GetText() ~= picked[1] then
			picked = nil
			panel:Refresh()
		end
	end)
	local function Pick(dungeon)
		picked = dungeon
		activity:SetText(dungeon[1])
		activity:ClearFocus()
		panel:Refresh()
	end
	local pick = Button(panel, "Dungeons", 76, function(self)
		if MenuUtil and MenuUtil.CreateContextMenu then
			MenuUtil.CreateContextMenu(self, function(_, root)
				root:CreateTitle("Dungeon")
				for _, d in ipairs(P.DUNGEONS) do
					root:CreateButton(("%s  |cff999999%d-%d|r"):format(d[1], d[2], d[3]), function() Pick(d) end)
				end
			end)
		else
			-- No menus on this client: each click steps to the next dungeon.
			local at = 0
			for i, d in ipairs(P.DUNGEONS) do
				if picked == d then at = i end
			end
			Pick(P.DUNGEONS[at % #P.DUNGEONS + 1])
		end
	end)
	pick:SetPoint("LEFT", activity, "RIGHT", 6, 0)
	local needLabel = Label(panel, "Need", "GameFontNormalSmall")
	needLabel:SetPoint("LEFT", pick, "RIGHT", 16, 0)
	local checks, x = {}, 10
	for _, role in ipairs(P.ROLES) do
		local check = P.ui.Check(panel, P.ROLE_NAME[role], function(on) need[role] = on end)
		check:SetPoint("LEFT", needLabel, "RIGHT", x, 0)
		checks[role] = check
		x = x + (role == "H" and 74 or 64)
	end

	-- Line 2: the player's own role, and Post
	local role = Button(panel, "", 130, function()
		local current = P.MyRole()
		for i, r in ipairs(P.ROLES) do
			if r == current then
				P.SetMyRole(P.ROLES[i % #P.ROLES + 1])
				break
			end
		end
		panel:Refresh()
	end)
	role:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -90)
	local post = Button(panel, "Post", 80, function()
		local letters = (need.T and "T" or "") .. (need.H and "H" or "") .. (need.D and "D" or "")
		local g, err = P.PostGroup(activity:GetText(), letters, picked and picked[2], picked and picked[3])
		if not g then return P.Print(err) end
		activity:SetText("")
		activity:ClearFocus()
		panel:Refresh()
	end)
	post:SetPoint("LEFT", role, "RIGHT", 6, 0)
	local hint = Label(panel, "A listing lasts 30 minutes. Your role is the one you post and join with.")
	hint:SetPoint("LEFT", post, "RIGHT", 12, 0)
	hint:SetTextColor(0.6, 0.6, 0.6)

	local ROLE_COLOR = { T = "|cff6699ff", H = "|cff40ff40", D = "|cffff6060" }

	local list = List(panel, {
		{ "Looking for", 160 }, { "Who", 120 }, { "Needs", 100 }, { "Joined", 110 },
	}, function(row, g)
		local c = row.cells
		local m = P.members[g.author]
		local joiners = P.GroupJoiners(g)
		local parts = {}
		for i, j in ipairs(joiners) do
			parts[i] = (ROLE_COLOR[j.role] or "") .. (j.role or "") .. "|r " .. P.ShortName(j.name)
		end
		c[1]:SetText(g.activity)
		c[2]:SetText(ClassName(g.author) .. (m and (" |cff999999" .. m.level .. "|r") or ""))
		c[3]:SetText(g.need ~= "" and P.RoleNames(g.need) or "|cff999999anyone|r")
		c[4]:SetText(#parts > 0 and table.concat(parts, ", ") or "|cff808080nobody yet|r")
		local mine = g.author == P.me
		local joined = g.joiners[P.me] and g.joiners[P.me].role ~= "X"
		row.action:SetText(mine and "Invite" or (joined and "Leave" or "Join"))
		if joined and not mine then row.action:LockHighlight() else row.action:UnlockHighlight() end
		row.close:SetShown(mine or P.AmOfficer())
	end, function(row)
		row.close = Button(row, "Close", 56, function() P.CloseGroup(row.data.id) end)
		row.close:SetSize(56, 18)
		row.close:SetPoint("RIGHT", row, "RIGHT", -4, 0)
		row.action = Button(row, "", 70, function()
			local g = row.data
			if g.author == P.me then
				P.InviteGroup(g.id)
			else
				local joined = g.joiners[P.me] and g.joiners[P.me].role ~= "X"
				local ok, err = P.JoinGroup(g.id, not joined)
				if not ok then P.Print(err) end
			end
		end)
		row.action:SetSize(70, 18)
		row.action:SetPoint("RIGHT", row, "RIGHT", -64, 0)
		row:SetScript("OnEnter", function(self)
			local g = self.data
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(g.activity)
			GameTooltip:AddLine(("%s%s, %d min left"):format(ClassName(g.author),
				P.ROLE_NAME[g.role or ""] and (" (" .. P.ROLE_NAME[g.role] .. ")") or "", P.GroupMinutesLeft(g)), 1, 1, 1)
			if g.min and g.min > 0 then GameTooltip:AddLine(("Levels %d to %d"):format(g.min, g.max), 0.8, 0.8, 0.8) end
			GameTooltip:AddLine("Needs: " .. (g.need ~= "" and P.RoleNames(g.need) or "anyone"), 0.8, 0.8, 0.8)
			for _, j in ipairs(P.GroupJoiners(g)) do
				GameTooltip:AddLine(("%s%s|r  %s"):format(ROLE_COLOR[j.role] or "", P.ROLE_NAME[j.role] or "?", ClassName(j.name)), 1, 1, 1)
			end
			GameTooltip:Show()
		end)
	end, -138, 66)

	local empty = Label(panel, "Nobody is looking for a group. Post something and see who bites.", "GameFontDisable")
	empty:SetPoint("CENTER", panel, "CENTER", 0, -30)

	-- Bottom: who else could come, from the roster
	local could = Label(panel)
	could:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 10)
	could:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -28, 10)
	could:SetHeight(44)
	could:SetWordWrap(true)
	could:SetMaxLines(3)
	could:SetJustifyV("BOTTOM")

	function panel:Refresh()
		role:SetText("My role: " .. P.ROLE_NAME[P.MyRole()])
		for r, check in pairs(checks) do check:SetChecked(need[r]) end
		local rows = P.GroupList()
		list:SetRows(rows)
		empty:SetShown(#rows == 0)

		-- For the player's own listing, else for the dungeon picked above.
		local mine = P.MyGroup()
		local what, min, max
		if mine and mine.min and mine.min > 0 then
			what, min, max = mine.activity, mine.min, mine.max
		elseif picked then
			what, min, max = picked[1], picked[2], picked[3]
		end
		if not what then
			could:SetText("|cff999999Pick a dungeon to see which online guildmates are in its level range, addon or not.|r")
		else
			local parts = {}
			for i, m in ipairs(P.CouldCome(min, max, mine)) do
				if i > 14 then parts[15] = "..." break end
				parts[i] = ("%s |cff999999%d|r"):format(P.ClassColored(P.ShortName(m.name), m.class), m.level)
			end
			could:SetText(#parts > 0 and ("|cffdb8f45Online and level %d-%d for %s:|r  %s"):format(min, max, what, table.concat(parts, ", "))
				or ("|cff999999Nobody else online is level %d-%d right now.|r"):format(min, max))
		end
	end
end

for _, tab in ipairs({
	{ "Race", BuildRace },
	{ "Board", BuildBoard },
	{ "Shame", BuildShame },
	{ "Bank", BuildBank },
	{ "Crafters", BuildCrafters },
	{ "Alerts", BuildAlerts },
}) do
	tinsert(P.tabs, tab)
end
-- The most used tab sits right under the roster.
tinsert(P.tabs, 2, { "Groups", BuildGroups })
