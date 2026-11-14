-- poor -- News.lua
-- What's new: after an update, one chat line and a row on the Home view
-- point to a short list of what changed. /poor news shows it any time.
--
--   db.seenVersion = the version whose news this account has been offered
local _, P = ...

-- Newest first. Keep each line short: it is read in a small window.
P.NEWS = {
	{ "0.17.0", {
		"PvP tab: a guild kill-on-sight list. Add your target with /poor kos, and get a warning when one of them is near.",
		"Kill feed: a chat line when a guildmate kills an enemy player out in the world.",
		"Honor board under Leaderboards: honorable kills, this week's kills, killing blows and PvP rank.",
		"Groups: battlegrounds and world PvP can be picked next to the dungeons.",
		"This list. /poor news shows it again.",
	} },
	{ "0.16.0", {
		"A song plays when you level up, and you say \"Ding BTW\" in guild chat.",
		"A short ding and a chat line when a guildmate levels up.",
		"Each of these can be turned off in the options, under Level-ups.",
	} },
	{ "0.15.0", {
		"Shared quests on the Groups tab: your quests that a guildmate has too.",
		"The dungeon list is WoW Forever's own, with the new dungeons.",
	} },
	{ "0.14.0", {
		"A Home view that shows what is going on in the guild right now.",
		"Fewer tabs: Gold, Leaderboards and Groups each hold several views.",
	} },
}

--- True while there is news this account has not been offered yet.
function P.HasNews()
	local seen = P.db.seenVersion
	return seen ~= nil and P.VersionOlder(seen, P.NEWS[1][1]) and not P.VersionOlder(P.VERSION, P.NEWS[1][1])
end

--- The list as text: everything newer than `since`, or the whole list.
function P.NewsText(since)
	local lines = {}
	for _, entry in ipairs(P.NEWS) do
		if not since or P.VersionOlder(since, entry[1]) then
			if #lines > 0 then tinsert(lines, "") end
			tinsert(lines, "Version " .. entry[1])
			for _, line in ipairs(entry[2]) do tinsert(lines, "  - " .. line) end
		end
	end
	return table.concat(lines, "\n")
end

function P.ShowNews()
	local since = P.HasNews() and P.db.seenVersion or nil
	P.db.seenVersion = P.NEWS[1][1]
	P.Fire("Version") -- the Home view drops its "New" row
	if P.ShowText then
		P.ShowText("What's new in poor", P.NewsText(since))
	else
		print(P.NewsText(since))
	end
end

--- Called once the saved data is loaded. Someone installing for the first
--- time has nothing to catch up on; someone updating from a version before
--- this file existed is shown the newest entry.
function P.StartNews()
	if P.db.seenVersion == nil then
		P.db.seenVersion = P.db.opts.wizardDone and (P.NEWS[2] and P.NEWS[2][1] or P.NEWS[1][1]) or P.NEWS[1][1]
	end
	if P.HasNews() then
		P.Print(("Updated to %s. |cffffd100/poor news|r shows what is new."):format(P.VERSION))
	end
end
