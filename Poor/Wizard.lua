-- poor -- Wizard.lua
-- First-run setup: a few questions in a row, shown once after the addon
-- first starts in the guild. Everything it sets is an ordinary option, so
-- skipping it loses nothing. /poor setup shows it again.
local _, P = ...

local Label, Button, Check, EditBox = P.ui.Label, P.ui.Button, P.ui.Check, P.ui.EditBox
local Fill, Border, ACCENT, COLOR = P.ui.Fill, P.ui.Border, P.ui.ACCENT, P.ui.COLOR

local WIDTH, HEIGHT, PAD = 470, 310, 22
local frame, pages, step = nil, {}, 1

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

-- Each step: a title, build(page) run once, and optionally leave(page), which
-- returns false (and may show why) to keep the player on the step.
local STEPS = {
	{
		title = "Welcome to poor",
		build = function(page)
			Text(page, "This is the guild's addon: the roster, events, funds and lotteries, who can craft what, PvP alerts, "
				.. "and a leaderboard of who among us is the poorest.", 0)
			Text(page, "A few quick questions and you are set. Everything can be changed later under Options, "
				.. "and you can skip this at any point.", -62)
			Text(page, "Open the window any time with |cffffffff/poor|r or the copper coin on your minimap.", -112, "GameFontDisable")
		end,
	},
	{
		title = "Your gold",
		build = function(page)
			Text(page, "The Poorest tab ranks the guild by how little gold everyone has. To be on it, your characters' gold "
				.. "is sent to guildmates who use the addon.", 0)
			Option(page, "share", "Share my gold and put me on the leaderboard", -64, function(on)
				if on and P.started then P.SendGoldSoon() end
			end)
			Text(page, "Left unticked, nobody sees your gold. You can still look at the board.", -92, "GameFontDisable")
		end,
		leave = function()
			P.db.opts.shareAsked = true
			return true
		end,
	},
	{
		title = "Your characters",
		build = function(page)
			Text(page, "If the character you are on is an alt, name your main. Alts are counted together with their main "
				.. "on the leaderboard and as one donor on funds.", 0)
			local label = Label(page, "My main is", "GameFontNormalSmall")
			label:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -70)
			page.main = EditBox(page, 200, 40)
			page.main:SetPoint("LEFT", label, "RIGHT", 10, 0)
			Text(page, "Leave it empty if this character is your main. It applies to every character of yours that has logged in with the addon.",
				-100, "GameFontDisable")
			page.problem = Text(page, "", -146)
			page.problem:SetTextColor(1, 0.35, 0.3)
		end,
		show = function(page)
			local main = P.MainOf(P.me)
			page.main:SetText(main ~= P.me and P.ShortName(main) or "")
			page.problem:SetText("")
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
		title = "PvP alerts",
		build = function(page)
			Text(page, "Anyone can tell the guild where a fight is with one button. Choose what happens when someone does.", 0)
			Option(page, "alerts", "Warn me when a guildmate sends a PvP alert", -48)
			Option(page, "alertPin", "Pin the place on my map (replaces a pin I had set)", -72)
			Option(page, "alertChat", "When I send one, post it in guild chat too", -96)
			Text(page, "Send an alert with the red button in the window, with |cffffffff/poor pvp|r, or with a key you set under "
				.. "Options > Keybindings > poor.", -128, "GameFontDisable")
		end,
	},
	{
		title = "Your professions",
		live = true,
		build = function(page)
			page.intro = Text(page, "", 0)
			page.rows = {}
			for i = 1, 6 do
				local row = CreateFrame("Frame", nil, page)
				row:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -50 - (i - 1) * 24)
				row:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, -50 - (i - 1) * 24)
				row:SetHeight(22)
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
		show = function(page)
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
				page.intro:SetText("This character has no professions yet. When it learns one, its recipes are shared with the guild "
					.. "so members can find who can craft what.")
			elseif missing == 0 then
				page.intro:SetText("Your recipes are shared, so guildmates can find you when they need something made. Nothing to do here.")
			else
				page.intro:SetText("Guildmates can look up who can craft what. Press Open on each profession marked \"not read yet\" "
					.. "and its recipes are picked up within a few seconds. Gathering skills have none.")
			end
		end,
	},
	{
		title = "All set",
		build = function(page)
			Text(page, "That is everything. A few things worth knowing:", 0)
			Text(page, "- Recipes you learn later are added automatically.\n"
				.. "- Events, funds and lotteries appear on their tabs as officers create them.\n"
				.. "- Only guildmates who have the addon see what you share.", -28)
			Text(page, "Run this again with |cffffffff/poor setup|r.", -112, "GameFontDisable")
		end,
	},
}

local function Show(index)
	step = index
	for i, page in ipairs(pages) do page:SetShown(i == index) end
	local def, page = STEPS[index], pages[index]
	for key, check in pairs(page.options or {}) do check:SetChecked(P.db.opts[key]) end
	if def.show then def.show(page) end
	frame.title:SetText(def.title)
	frame.count:SetText(("%d of %d"):format(index, #STEPS))
	frame.back:SetShown(index > 1)
	frame.skip:SetShown(index < #STEPS)
	frame.next:SetText(index == #STEPS and "Finish" or "Next")
	for i, dot in ipairs(frame.dots) do
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
		if step == #STEPS then f:Hide() else Show(step + 1) end
	end)
	f.next:SetHeight(24)
	f.next:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, 14)
	f.back = Button(f, "Back", 64, function() Show(step - 1) end)
	f.back:SetHeight(24)
	f.back:SetPoint("RIGHT", f.next, "LEFT", -6, 0)

	-- Finished, skipped or closed with Escape: either way it does not come back by itself.
	f:SetScript("OnHide", function() P.db.opts.wizardDone = true end)
	tinsert(UISpecialFrames, "PoorWizardFrame")
	return f
end

function P.ShowWizard()
	if not P.EnsureStarted() then return P.Print(P.WhyNotReady()) end
	frame = frame or Build()
	Show(1)
	frame:Show()
end

-- Offered once, a few seconds after the addon first starts in the guild, and
-- never in the middle of a fight.
local function Offer()
	if P.db.opts.wizardDone then return end
	if InCombatLockdown and InCombatLockdown() then return C_Timer.After(15, Offer) end
	P.ShowWizard()
end

-- Keep the professions step current while it is on screen: recipes arrive a
-- moment after a profession window opens.
local function Live()
	-- Only that step: redrawing the others would wipe what is being typed.
	if frame and frame:IsShown() and STEPS[step].live then STEPS[step].show(pages[step]) end
end
P.On("Blob", Live)
P.On("Crafts", Live)

P.On("Started", function()
	if not P.db.opts.wizardDone then C_Timer.After(4, Offer) end
end)
