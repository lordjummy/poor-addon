-- poor -- Settings.lua
-- The addon's page in the game's Options > AddOns list. Every checkbox reads
-- and writes PoorDB.opts directly, so the slash toggles and this page always
-- agree.
local _, P = ...

local category

local ROWS = {
	{ header = "General" },
	{ key = "greet", label = "Login greeting",
		tip = "Greet you in chat at login with your gold, your poverty rank, open funds and upcoming events." },
	{ key = "minimap", label = "Minimap button",
		tip = "Show the coin button on the minimap. The addon also sits in the addon compartment and answers to /poor.",
		changed = function() P.MinimapInit() end },
	{ header = "Gold" },
	{ key = "share", label = "Share my gold with the guild",
		tip = "Off by default. Report your characters' gold to guildmates who run the addon, for the Poorest leaderboard. Off: you see others but nobody sees you.",
		changed = function(value)
			P.db.opts.shareAsked = true
			if value and P.started then P.SendGoldSoon() end
		end },
	{ key = "shareShame", label = "Share my deaths and repair bills",
		tip = "Off by default. Report this account's deaths and repair bills to guildmates who run the addon, for the Shame board under Leaderboards.",
		changed = function(value) if value and P.started then P.Report("shame") end end },
	{ key = "combineAlts", label = "Count alts with their main",
		tip = "On the Poorest and Shame boards, add each player's linked characters together. Link yours with /poor main <name>." },
	{ key = "thankDonors", label = "Whisper a thank-you for donations",
		tip = "When you accept a traded or mailed donation for a fund you collect, whisper the donor a thank-you with the fund's progress." },
	{ header = "Groups" },
	{ key = "groupChat", label = "Say my group listings in guild chat too",
		tip = "When you post on the Groups tab, also write a line in guild chat so members without the addon see it." },
	{ key = "boardNotify", label = "Tell me about new requests on the Board",
		tip = "A chat line when a guildmate asks for gold or materials under Gold, Requests and loans." },
	{ key = "shareQuests", label = "Share which quests are in my log",
		tip = "Lets guildmates who use the addon see when they are on the same quest as you (Groups tab, Shared quests). Off: you can still see who shares yours.",
		changed = function() if P.started then P.RefreshQuests(1) end end },
	{ key = "groupNotify", label = "Tell me when a guildmate looks for a group",
		tip = "A chat line when someone posts on the Groups tab. Dungeons far from your level are left out." },
	{ header = "Level-ups" },
	{ key = "levelSong", label = "Play the guild song when I level up",
		tip = "Plays the addon's level-up song on top of the game's own sound." },
	{ key = "dingChat", label = "Say \"Ding BTW\" in guild chat when I level up",
		tip = "Writes \"Ding BTW\" and your new level in guild chat each time you gain a level." },
	{ key = "guildDing", label = "Tell me when a guildmate levels up",
		tip = "A chat line and a short ding when a guildmate who is online gains a level. The ding stays silent in dungeons and raids." },
	{ header = "PvP alerts" },
	{ key = "alerts", label = "Receive PvP alerts",
		tip = "Show a warning and play a sound when a guildmate sends a PvP alert." },
	{ key = "alertZoneOnly", label = "Full warning only for my own zone",
		tip = "On: the on-screen warning, the sound and the map pin are for alerts from the zone you are in. Alerts from elsewhere are a quiet chat line. Off: every alert gets the full warning." },
	{ key = "alertPin", label = "Pin the location of incoming alerts",
		tip = "Set your map pin (and a TomTom arrow, if installed) where the alert came from. This replaces a pin you had set." },
	{ key = "alertChat", label = "Post my alerts in guild chat",
		tip = "When you send an alert, also write a line with a map pin link in guild chat for guildmates without the addon." },
}

local function Build()
	local layout
	category, layout = Settings.RegisterVerticalLayoutCategory("poor")
	for _, row in ipairs(ROWS) do
		if row.header then
			layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(row.header))
		else
			local variable = "POOR_" .. row.key:upper()
			local setting = Settings.RegisterAddOnSetting(category, variable, row.key, P.db.opts,
				Settings.VarType.Boolean, row.label, P.DEFAULT_OPTS[row.key])
			Settings.CreateCheckbox(category, setting, row.tip)
			Settings.SetOnValueChangedCallback(variable, function(_, _, value)
				if row.changed then row.changed(value) end
				P.Fire("Options")
			end)
		end
	end
	layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Setup"))
	layout:AddInitializer(CreateSettingsButtonInitializer("First-time setup", "Run again", function()
		P.ShowWizard()
	end, "Go through the welcome questions again: sharing your gold, your main character and PvP alerts.", true))
	layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Window"))
	layout:AddInitializer(CreateSettingsButtonInitializer("Window position and size", "Reset", function()
		P.ResetWindow()
	end, "Put the poor window back in the middle of the screen at its normal size.", true))
	Settings.RegisterAddOnCategory(category)
end

function P.SettingsInit()
	if category or not (Settings and Settings.RegisterVerticalLayoutCategory) then return end
	local ok, err = pcall(Build)
	if not ok then
		category = nil
		P.settingsError = tostring(err)
	end
end

function P.OpenSettings()
	if category and Settings.OpenToCategory then
		Settings.OpenToCategory(category:GetID())
	elseif P.settingsError then
		P.Print("The options page could not be built: " .. P.settingsError)
		P.Print("The slash toggles still work, see /poor help.")
	else
		P.Print("This client has no options panel for addons. Use the slash toggles, see /poor help.")
	end
end
