-- poor -- Recruit.lua
-- Recruitment: where the guild is thin, what officers want recruited, and a
-- search for unguilded players of a class to whisper or invite one at a time.
--
--   db.recruit      = { rev, by, min, classes = "PRIEST,WARLOCK", pitch }   set by officers, shared
--   db.opts.myPitch = this player's own message, used in place of the guild's when set
--   db.recruitLog   = { [name] = { ts, what } }                             who this account approached
--   blob "A:<recruiter>" = { "name~what~ts", ... }                          the same, shared (Blobs.lua)
--
-- Wire (compatible addition): K^rev^by^min^classes^pitch      highest rev wins
local _, P = ...

P.CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
P.PITCH_MAX = 120
P.DEFAULT_PITCH = "Hi! <poor> is looking for a {class}. Friendly leveling guild, no pressure. Want an invite?"
local ACTIVE_DAYS = 14 -- seen within this many days counts as active

function P.ClassLabel(token)
	local names = LOCALIZED_CLASS_NAMES_MALE
	return (names and names[token]) or (token:sub(1, 1) .. token:sub(2):lower())
end

--- The guild by class: { class, total, active, online, capped }, thinnest
--- first by active members. A class the guild has none of is listed too.
--- All nine are open to both factions on WoW Forever.
function P.Composition()
	local by, rows = {}, {}
	for _, token in ipairs(P.CLASSES) do by[token] = { class = token, total = 0, active = 0, online = 0, capped = 0 } end
	for _, m in ipairs(P.roster) do
		local e = m.class and by[m.class]
		if not e and m.class then
			e = { class = m.class, total = 0, active = 0, online = 0, capped = 0 }
			by[m.class] = e
		end
		if e then
			e.total = e.total + 1
			if m.online then e.online = e.online + 1 end
			if m.online or (m.days or 0) <= ACTIVE_DAYS then e.active = e.active + 1 end
			if m.level >= P.MAX_LEVEL then e.capped = e.capped + 1 end
		end
	end
	for _, e in pairs(by) do tinsert(rows, e) end
	table.sort(rows, function(a, b)
		if a.active ~= b.active then return a.active < b.active end
		return a.class < b.class
	end)
	return rows
end

---------------------------------------------------------------------------
-- What the officers want recruited
---------------------------------------------------------------------------
local function Line(r)
	return ("K^%d^%s^%d^%s^%s"):format(r.rev, r.by or "", r.min or 0, r.classes or "", r.pitch or "")
end

function P.Recruit()
	return P.db.recruit
end

function P.IsWanted(token)
	return (("," .. (P.db.recruit.classes or "") .. ","):find("," .. token .. ",", 1, true)) ~= nil
end

--- Wanted classes as readable text, or nil when nothing is set.
function P.WantedText()
	local parts = {}
	for token in (P.db.recruit.classes or ""):gmatch("[^,]+") do tinsert(parts, P.ClassLabel(token)) end
	return #parts > 0 and table.concat(parts, ", ") or nil
end

--- The message template in use and whose it is: "mine", "guild" or "default".
function P.PitchTemplate()
	local mine = P.db.opts.myPitch
	if mine and mine ~= "" then return mine, "mine" end
	local guild = P.db.recruit.pitch
	if guild and guild ~= "" then return guild, "guild" end
	return P.DEFAULT_PITCH, "default"
end

--- The message for a class, and for a candidate when given:
--- {class}, {name} (their first name), {level} and {guild} are filled in.
function P.Pitch(token, candidate)
	local text = P.PitchTemplate()
	local first = candidate and P.ShortName(candidate.name):match("^(%S+)") or ""
	local fill = { class = P.ClassLabel(token), name = first, level = candidate and tostring(candidate.level) or "", guild = "poor" }
	text = text:gsub("{(%a+)}", function(key) return fill[key] end)
	-- Tidy what a missing name or a stray space leaves behind: "Hi !" -> "Hi!"
	text = text:gsub("%s+([,!?%.])", "%1"):gsub("%s%s+", " ")
	return text:sub(1, 240)
end

--- Set this player's own message; empty goes back to the guild's.
function P.SetMyPitch(text)
	text = P.Clean(text, P.PITCH_MAX)
	P.db.opts.myPitch = text ~= "" and text or nil
	P.Fire("Recruit")
	return true
end

local function Save(change)
	if not P.AmOfficer() then return nil, "Only officers set what the guild is recruiting." end
	local r = P.db.recruit
	change(r)
	r.rev, r.by = (r.rev or 0) + 1, P.me
	P.Send(Line(r))
	P.Fire("Recruit")
	return r
end

function P.SetWanted(token, wanted)
	return Save(function(r)
		local keep = {}
		for t in (r.classes or ""):gmatch("[^,]+") do
			if t ~= token then tinsert(keep, t) end
		end
		if wanted then tinsert(keep, token) end
		table.sort(keep)
		r.classes = table.concat(keep, ",")
	end)
end

function P.SetPitch(text)
	text = P.Clean(text, P.PITCH_MAX)
	return Save(function(r) r.pitch = text end)
end

P.handlers.K = function(sender, rev, by, min, classes, pitch)
	rev = tonumber(rev)
	if not rev then return end
	P.Hear("K", rev)
	local r = P.db.recruit
	if (r.rev or 0) >= rev then return end
	local before = r.classes or ""
	r.rev, r.by, r.min = rev, (by and by ~= "") and by or sender, tonumber(min) or 0
	r.classes = (classes or ""):gsub("[^%u,]", "")
	r.pitch = P.Clean(pitch, P.PITCH_MAX)
	P.Fire("Recruit")
	if r.classes ~= before and r.classes ~= "" and not P.Syncing() then
		P.Print(("The guild is recruiting: |cffffffff%s|r. The Recruit tab helps you find them."):format(P.WantedText()))
	end
end

tinsert(P.syncers, function()
	P.Send(function()
		local r = P.db.recruit
		if (r.rev or 0) > 0 and P.HeardVersion("K") < r.rev then return Line(r) end
	end)
end)

---------------------------------------------------------------------------
-- Finding candidates with a /who search
---------------------------------------------------------------------------
P.candidates = {}   -- { name, level, class, zone }, the last search's unguilded results
P.candidateNote = nil

local searching, lastSearch = nil, -10

local REMEMBER = 30 * 86400 -- an approach is remembered for a month

-- Everyone's approaches, built from this account's log and the lists other
-- recruiters share: name -> { ts, what, by }, the newest one per player.
local index

local function Index()
	if index then return index end
	index = {}
	local cutoff = P.Now() - REMEMBER
	local function note(name, ts, what, by)
		if ts >= cutoff and (not index[name] or index[name].ts < ts) then index[name] = { ts = ts, what = what, by = by } end
	end
	for name, e in pairs(P.db.recruitLog) do note(name, e.ts, e.what, P.me) end
	for key, blob in pairs(P.db.blobs) do
		local by = key:match("^A:(.+)$")
		if by and by ~= P.me then
			for _, token in ipairs(blob.tokens) do
				local name, what, ts = token:match("^(.-)~(%a+)~(%d+)$")
				if name then note(name, tonumber(ts), what, by) end
			end
		end
	end
	return index
end

--- Whether anyone in the guild approached this player lately: { ts, what, by } or nil.
function P.Approached(name)
	return Index()[name]
end

P.On("Blob", function(key)
	if type(key) == "string" and key:sub(1, 2) == "A:" then
		index = nil
		P.Fire("Recruit")
	end
end)

-- Share this account's list with the guild, a moment after it changes.
local sharing = false
local function Share()
	sharing = false
	if not P.started then return end
	local tokens = {}
	for name, e in pairs(P.db.recruitLog) do
		tinsert(tokens, ("%s~%s~%d"):format((name:gsub("[~,%^]", "")), e.what, e.ts))
	end
	table.sort(tokens)
	P.SetBlob("A:" .. P.me, tokens)
end

local function Mark(name, what)
	P.db.recruitLog[name] = { ts = P.Now(), what = what }
	index = nil
	if not sharing then
		sharing = true
		C_Timer.After(2, Share)
	end
	P.Fire("Recruit")
end

function P.PruneRecruitLog()
	local cutoff = P.Now() - REMEMBER
	for name, e in pairs(P.db.recruitLog) do
		if e.ts < cutoff then P.db.recruitLog[name] = nil end
	end
	index = nil
end

--- Ask the server who is online of this class and level. The answer arrives
--- a moment later and fires "Recruit". Must come from a click.
function P.FindRecruits(token, min, max)
	local F = C_FriendList
	if not (F and F.SendWho and F.GetNumWhoResults and F.GetWhoInfo) then return nil, "This client has no /who search for addons." end
	local wait = 6 - (GetTime() - lastSearch)
	if wait > 0 then return nil, ("The server limits searches. Try again in %d sec."):format(math.ceil(wait)) end
	min, max = math.max(1, math.floor(min or 1)), math.min(P.MAX_LEVEL, math.floor(max or P.MAX_LEVEL))
	if min > max then min, max = max, min end
	lastSearch = GetTime()
	searching = { class = token, min = min, max = max }
	-- Results to the addon, without the game's own Who window popping up.
	if F.SetWhoToUi then pcall(F.SetWhoToUi, true) end
	if FriendsFrame and FriendsFrame.UnregisterEvent then pcall(FriendsFrame.UnregisterEvent, FriendsFrame, "WHO_LIST_UPDATE") end
	local ok = pcall(F.SendWho, ('c-"%s" %d-%d'):format(P.ClassLabel(token), min, max))
	if not ok then
		searching = nil
		return nil, "The search could not be sent."
	end
	P.candidateNote = "Searching..."
	P.Fire("Recruit")
	-- Whatever happens, hand the Who window its event back.
	C_Timer.After(4, function()
		if FriendsFrame and FriendsFrame.RegisterEvent then pcall(FriendsFrame.RegisterEvent, FriendsFrame, "WHO_LIST_UPDATE") end
		if F.SetWhoToUi then pcall(F.SetWhoToUi, false) end
		if searching then
			searching = nil
			P.candidateNote = "The server did not answer. Try again in a moment."
			P.Fire("Recruit")
		end
	end)
	return true
end

local function OnWho()
	if not searching then return end
	local F, list, seen = C_FriendList, {}, 0
	for i = 1, F.GetNumWhoResults() or 0 do
		local info = F.GetWhoInfo(i)
		if type(info) == "table" and P.Readable(info.fullName) and info.fullName then
			seen = seen + 1
			local guild = info.fullGuildName
			if not P.Readable(guild) or guild == nil or guild == "" then
				tinsert(list, { name = P.FullName(info.fullName), level = info.level or 0, class = info.filename or searching.class, zone = info.area or "" })
			end
		end
	end
	table.sort(list, function(a, b)
		if a.level ~= b.level then return a.level > b.level end
		return a.name < b.name
	end)
	P.candidates = list
	P.candidateNote = ("%d %s level %d-%d online, %d without a guild.%s"):format(seen, P.ClassLabel(searching.class), searching.min, searching.max, #list,
		seen >= 49 and " The server shows at most about 50, so narrow the levels to see others." or "")
	searching = nil
	P.Fire("Recruit")
end

--- Open a whisper to a candidate with the pitch typed in. Nothing is sent
--- until the player presses Enter.
function P.PitchTo(candidate)
	P.ui.Whisper(candidate.name, P.Pitch(candidate.class, candidate))
	Mark(candidate.name, "whispered")
end

function P.CanInviteToGuild()
	if C_GuildInfo and C_GuildInfo.CanInvite then return C_GuildInfo.CanInvite() and true or false end
	if CanGuildInvite then return CanGuildInvite() and true or false end
	return false
end

function P.InviteToGuild(candidate)
	if not P.CanInviteToGuild() then return P.Print("Your rank cannot invite to the guild.") end
	local target = P.FOREVER and P.ShortName(candidate.name) or candidate.name
	local ok
	if C_GuildInfo and C_GuildInfo.Invite then
		ok = pcall(C_GuildInfo.Invite, target)
	elseif GuildInvite then
		ok = pcall(GuildInvite, target)
	end
	if ok then
		Mark(candidate.name, "invited")
		P.Print("Guild invite sent to " .. P.ShortName(candidate.name) .. ".")
	else
		P.Print("The invite could not be sent.")
	end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("WHO_LIST_UPDATE")
frame:SetScript("OnEvent", function() pcall(OnWho) end)
