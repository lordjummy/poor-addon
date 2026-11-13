-- poor -- Wizard.lua
-- First-run setup: a few questions in a row, shown once after the addon
-- first starts in the guild. Everything it sets is an ordinary option, so
-- skipping it loses nothing. /poor setup shows it again.
local _, P = ...

local Label, Button, Check, EditBox = P.ui.Label, P.ui.Button, P.ui.Check, P.ui.EditBox
local Fill, Border, ACCENT, COLOR = P.ui.Fill, P.ui.Border, P.ui.ACCENT, P.ui.COLOR

local WIDTH, HEIGHT, PAD = 470, 360, 22
local frame, pages, step = nil, {}, 1
local single = false -- one step shown alone, for a new alt of an account that already did the setup

--- A paragraph: wraps inside the page.
local function Text(page, text, y, font)
	local fs = Label(page, text, font)
	fs:SetPoint("TOPLEFT", page, "TOPLEFT", 0, y)
	fs:SetWidth(WIDTH - PAD * 2)
	fs:SetWordWrap(true)
	fs:SetJustifyV("TOP")
	fs:SetSpacing(3)
	return fs
end

local function Option(page, key, text, y, changed)
	local check = Check(page, text, function(on)
		P.db.opts[key] = on
		if changed then changed(on) end
		P.Fire("Options")
	end)
	check:SetPoint("TOPLEFT", page, "TOPLEFT", 0, y)
	page.options = page.options or {}
	page.options[key] = check
	return check
end

-- Each step: a title, build(page) run once, show(page) each time it comes
-- up, and optionally leave(page), which returns false (and may show why) to
-- keep the player on the step. `live` steps redraw when data arrives.
local STEPS = {
	{
		title = "Welcome to poor",
		build = function(page)
			Text(page, "The guild's addon: find a group, see who can craft what, join events, funds and lotteries, "
				.. "get PvP alerts, and see who among us is the poorest.", 0)
			Text(page, "Three short steps: what you share, your characters, and alerts. Everything can be changed later under Options.", -58)
			page.audience = Text(page, "", -108, "GameFontDisable")
		end,
		show = function(page)
			local total = P.AddonAudience()
			page.audience:SetText(total > 0
				and ("%d guildmate%s already use it. What you post in the addon reaches them; the Roster tab shows who."):format(total, total == 1 and "" or "s")
				or "You are among the first in the guild to use it. What you post in the addon reaches members who have it; the Roster tab shows who.")
		end,
	},
	{
		title = "What you share",
		build = function(page)
			Text(page, "Two things are yours to decide. Both are off unless you tick them.", 0)
			Option(page, "share", "My gold, to be ranked on the Poorest leaderboard", -34, function(on)
				if on and P.started then P.SendGoldSoon() end
			end)
			Option(page, "shareShame", "My deaths and repair bills, for the Shame board", -58, function(on)
				if on and P.started then P.Report("shame") end
			end)
			Text(page, "Shared with guildmates who use the addon without asking, because the features need it: your professions and "
				.. "recipes, your level and progress to the next, and which characters are your alts.", -96, "GameFontDisable")
			Text(page, "Nothing leaves the guild, and members without the addon see none of it.", -150, "GameFontDisable")
		end,
		leave = function()
			P.db.opts.shareAsked = true
			return true
		end,
	},
	{
		title = "Your characters",
		live = true,
		build = function(page)
			Text(page, "If this character is an alt, name your main, so the guild counts you once.", 0)
			local label = Label(page, "My main is", "GameFontNormalSmall")
			label:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -34)
			page.main = EditBox(page, 190, 40)
			page.main:SetPoint("LEFT", label, "RIGHT", 10, 0)
			local note = Label(page, "(empty = this one)", "GameFontDisable")
			note:SetPoint("LEFT", page.main, "RIGHT", 10, 0)
			page.problem = Text(page, "", -58)
			page.problem:SetTextColor(1, 0.35, 0.3)
			page.intro = Text(page, "", -84)
			page.rows = {}
			for i = 1, 5 do
				local row = CreateFrame("Frame", nil, page)
				row:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -126 - (i - 1) * 23)
				row:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, -126 - (i - 1) * 23)
				row:SetHeight(21)
				row.name = Label(row)
				row.name:SetPoint("LEFT", row, "LEFT", 0, 0)
				row.name:SetWidth(150)
				row.status = Label(row)
				row.status:SetPoint("LEFT", row, "LEFT", 156, 0)
				row.status:SetWidth(190)
				row.open = Button(row, "Open", 64, function() P.OpenProfession(row.line) end)
				row.open:SetPoint("RIGHT", row, "RIGHT", 0, 0)
				page.rows[i] = row
			end
		end,
		show = function(page, first)
			-- Only when the step comes up, not on each redraw: the box may be being typed in.
			if first then
				local main = P.MainOf(P.me)
				page.main:SetText(main ~= P.me and P.ShortName(main) or "")
				page.problem:SetText("")
			end
			local profs, missing = P.MyProfessions(), 0
			for i, row in ipairs(page.rows) do
				local p = profs[i]
				row:SetShown(p ~= nil)
				if p then
					row.line = p.line
					row.name:SetText(("%s |cff999999%d|r"):format(p.name, p.rank))
					if p.recipes then
						row.status:SetText(("|cff40ff40shared|r  %d recipes"):format(p.recipes))
					else
						missing = missing + 1
						row.status:SetText(p.catalogue and "|cff999999no recipes known|r" or "|cffffd100not read yet|r")
					end
					row.open:SetShown(not p.recipes)
				end
			end
			if #profs == 0 then
				page.intro:SetText("No professions on this character yet. When it learns one, guildmates can find it under Crafters.")
			elseif missing == 0 then
				page.intro:SetText("Your recipes are shared, so guildmates can find you when they need something made.")
			else
				page.intro:SetText("Guildmates look up who can craft what. Press Open on a profession marked \"not read yet\" "
					.. "and it is picked up in a few seconds. Gathering skills have nothing to read.")
			end
		end,
		leave = function(page)
			local typed = strtrim(page.main:GetText() or "")
			local main = typed ~= "" and P.ResolveName(typed) or nil
			if main == P.me then main = nil end
			-- Nothing typed and nothing linked: leave things as they are.
			if not main and P.MainOf(P.me) == P.me then return true end
			if main == P.MainOf(P.me) then return true end
			local ok, err = P.SetMyMain(main)
			if not ok then
				page.problem:SetText(err .. " Check the spelling, or clear the box to go on.")
				return false
			end
			return true
		end,
	},
	{
		title = "Alerts",
		build = function(page)
			Text(page, "What the addon tells you about while you play.", 0)
			Option(page, "groupNotify", "A guildmate is looking for a group near my level", -30)
			Option(page, "alerts", "A guildmate sends a PvP alert", -54)
			Option(page, "alertZoneOnly", "Sound and on-screen warning only for PvP in my own zone", -78)
			Option(page, "alertPin", "Pin a PvP alert on my map (replaces a pin I had set)", -102)
			Option(page, "alertChat", "When I send a PvP alert, post it in guild chat too", -126)
			Text(page, "Send a PvP alert with the red button in the window, |cffffffff/poor pvp|r, or a key set under "
				.. "Options > Keybindings > poor. Finish opens the window; |cffffffff/poor setup|r brings this back.", -160, "GameFontDisable")
		end,
	},
}

local function Show(index)
	step = index
	for i, page in ipairs(pages) do page:SetShown(i == index) end
	local def, page = STEPS[index], pages[index]
	for key, check in pairs(page.options or {}) do check:SetChecked(P.db.opts[key]) end
	if def.show then def.show(page, true) end
	frame.title:SetText(def.title)
	frame.count:SetText(single and "" or ("%d of %d"):format(index, #STEPS))
	frame.back:SetShown(index > 1 and not single)
	frame.skip:SetShown(index < #STEPS and not single)
	frame.next:SetText((single and "Done") or (index == #STEPS and "Finish") or "Next")
	for i, dot in ipairs(frame.dots) do
		dot:SetShown(not single)
		if i <= index then dot:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 1) else dot:SetColorTexture(1, 1, 1, 0.15) end
	end
end

local function Leave()
	local def = STEPS[step]
	return not def.leave or def.leave(pages[step]) ~= false
end

local function Build()
	local f = CreateFrame("Frame", "PoorWizardFrame", UIParent)
	f:Hide()
	f:SetSize(WIDTH, HEIGHT)
	f:SetPoint("CENTER", 0, 40)
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

	local header = f:CreateTexture(nil, "BACKGROUND", nil, -6)
	header:SetColorTexture(COLOR.header[1], COLOR.header[2], COLOR.header[3], 1)
	header:SetPoint("TOPLEFT", 1, -1)
	header:SetPoint("TOPRIGHT", -1, -1)
	header:SetHeight(40)
	local line = f:CreateTexture(nil, "ARTWORK")
	line:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.55)
	line:SetPoint("TOPLEFT", header, "BOTTOMLEFT")
	line:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT")
	line:SetHeight(1)
	local icon = f:CreateTexture(nil, "ARTWORK")
	icon:SetTexture(P.ICON)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	icon:SetSize(20, 20)
	icon:SetPoint("LEFT", header, "LEFT", PAD - 6, 0)
	f.title = f:CreateFontString(nil, "OVERLAY")
	f.title:SetFontObject(P.ui.FONT_TITLE)
	f.title:SetPoint("LEFT", icon, "RIGHT", 10, 0)
	f.count = Label(f, nil, "GameFontDisable")
	f.count:SetPoint("RIGHT", header, "RIGHT", -PAD, 0)

	for i, def in ipairs(STEPS) do
		local page = CreateFrame("Frame", nil, f)
		page:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -62)
		page:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, 52)
		page:Hide()
		def.build(page)
		pages[i] = page
	end

	-- Footer: progress dots, Skip on the left, Back and Next on the right.
	f.dots = {}
	for i = 1, #STEPS do
		local dot = f:CreateTexture(nil, "ARTWORK")
		dot:SetSize(18, 3)
		dot:SetPoint("BOTTOM", f, "BOTTOM", (i - (#STEPS + 1) / 2) * 22, 22)
		f.dots[i] = dot
	end
	f.skip = Button(f, "Skip setup", 84, function() f:Hide() end)
	f.skip:SetHeight(24)
	f.skip:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD, 14)
	f.next = Button(f, "Next", 84, function()
		if not Leave() then return end
		PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
		if single then
			f:Hide()
		elseif step == #STEPS then
			f:Hide()
			P.OpenWindow() -- land on something, not on an empty screen
		else
			Show(step + 1)
		end
	end)
	f.next:SetHeight(24)
	f.next:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, 14)
	f.back = Button(f, "Back", 64, function() Show(step - 1) end)
	f.back:SetHeight(24)
	f.back:SetPoint("RIGHT", f.next, "LEFT", -6, 0)

	-- Finished, skipped or closed with Escape: either way it does not come back by itself.
	f:SetScript("OnHide", function()
		P.db.opts.wizardDone = true
		P.db.wizardChars[P.me] = true
	end)
	tinsert(UISpecialFrames, "PoorWizardFrame")
	return f
end

function P.ShowWizard(onlyStep)
	if not P.EnsureStarted() then return P.Print(P.WhyNotReady()) end
	frame = frame or Build()
	single = onlyStep ~= nil
	Show(onlyStep or 1)
	frame:Show()
end

local CHARACTERS_STEP = 3

--- A character of an account that already did the setup: is there anything
--- on the "Your characters" step still to do for it?
local function AltNeedsSetup()
	local others = 0
	for char in pairs(P.db.myChars) do
		if char ~= P.me then others = others + 1 end
	end
	if others > 0 and P.db.mains[P.me] == nil then return true end -- never said whose alt it is
	for _, p in ipairs(P.MyProfessions()) do
		if not p.recipes and not p.catalogue then return true end
	end
	return false
end

-- Offered once per account in full, a few seconds after the addon first
-- starts in the guild; and once per further character, just the step about
-- that character. Never in the middle of a fight.
local function Offer()
	if InCombatLockdown and InCombatLockdown() then return C_Timer.After(15, Offer) end
	if not P.db.opts.wizardDone then return P.ShowWizard() end
	if P.db.wizardChars[P.me] then return end
	P.db.wizardChars[P.me] = true
	if AltNeedsSetup() then P.ShowWizard(CHARACTERS_STEP) end
end

-- Keep the professions step current while it is on screen: recipes arrive a
-- moment after a profession window opens.
local function Live()
	-- Only that step: redrawing the others would wipe what is being typed.
	if frame and frame:IsShown() and STEPS[step].live then STEPS[step].show(pages[step], false) end
end
P.On("Blob", Live)
P.On("Crafts", Live)

P.On("Started", function()
	-- The full setup soon; the per-character step later, once professions are read.
	C_Timer.After(P.db.opts.wizardDone and 20 or 4, Offer)
end)
