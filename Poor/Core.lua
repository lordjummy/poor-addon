-- poor -- Core.lua
-- Namespace, saved variables, guild roster cache, gold/event data and slash
-- commands. Everything that talks to other players is in Comm.lua.
local ADDON, P = ...

P.GUILD = "poor" -- compared case-insensitively against the player's guild name
P.ICON = "Interface\\Icons\\INV_Misc_Coin_05"
P.TAG = "|cffb87333<poor>|r "
P.VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata(ADDON, "Version")) or "?"

local DAY = 86400

function P.Print(...)
	print(P.TAG .. strjoin(" ", tostringall(...)))
end

-- Forever runs on the modern engine: in a dungeon/raid "chat messaging
-- lockdown" some values arrive as secrets an addon may not read or compare.
function P.Readable(v)
	return v ~= nil and not (issecretvalue and issecretvalue(v))
end

---------------------------------------------------------------------------
-- Tiny callback registry: P.On("Gold", fn) / P.Fire("Gold")
---------------------------------------------------------------------------
local listeners = {}
function P.On(what, fn)
	listeners[what] = listeners[what] or {}
	tinsert(listeners[what], fn)
end
function P.Fire(what, ...)
	for _, fn in ipairs(listeners[what] or {}) do
		fn(...)
	end
end

---------------------------------------------------------------------------
-- Names. Everything is keyed by "Name-Realm".
---------------------------------------------------------------------------
--
-- WoW Forever characters have a first name and a surname ("Pink Guy"), and
-- the game functions that return "name, realm" elsewhere return "first name,
-- surname" there. Players do not see realms on Forever, but each client has
-- an internal one (CAMWOWUS2Realm4PvP, ...Realm6PvP) and guildmates are on
-- different ones. The roster and message senders give bare names, so a name
-- tagged with the local realm would be a different text on every client.
-- On Forever a character is therefore known by "First Surname" alone.
-- On other clients it is "Name-Realm".
local INTERFACE = select(4, GetBuildInfo())
P.FOREVER = (WOW_PROJECT_CAMELOT ~= nil and WOW_PROJECT_ID == WOW_PROJECT_CAMELOT)
	or (type(INTERFACE) == "number" and INTERFACE >= 16000 and INTERFACE < 20000) or false

local myRealm

--- A Forever name without a realm tag, whichever client's realm it carries.
local function StripRealm(name)
	myRealm = myRealm or GetNormalizedRealmName()
	if myRealm and #name > #myRealm + 1 and name:sub(-#myRealm - 1) == "-" .. myRealm then
		return name:sub(1, -#myRealm - 2)
	end
	local base, suffix = name:match("^(.+)%-([^%-%s]+)$")
	if base and (suffix:find("^CAM") or suffix:find("Realm", 1, true)) then return base end
	return name
end
P.StripRealm = StripRealm

--- The one way a character's name is written everywhere in the addon.
function P.FullName(name)
	if not P.Readable(name) or name == "" then return nil end
	if P.FOREVER then
		name = StripRealm(name)
		-- Some sources write a Forever name as "First-Surname".
		if name:find("-", 1, true) and not P.members[name] then
			local spaced = name:gsub("-", " ", 1)
			if P.members[spaced] then return spaced end
		end
		return name
	end
	if name:find("-", 1, true) then return name end
	myRealm = myRealm or GetNormalizedRealmName()
	return myRealm and (name .. "-" .. myRealm) or name
end

--- "Name-Realm" of a unit ("player", "target", "NPC" for a trade partner).
function P.UnitFullName(unit)
	local first, second = UnitName(unit)
	if not P.Readable(first) or not first or first == "" then return nil end
	if not P.Readable(second) or second == "" then second = nil end
	if P.FOREVER then return P.FullName(second and (first .. " " .. second) or first) end
	return P.FullName(second and (first .. "-" .. second) or first)
end

function P.ShortName(full)
	if P.FOREVER then return StripRealm(full) end
	myRealm = myRealm or GetNormalizedRealmName()
	if myRealm and #full > #myRealm + 1 and full:sub(-#myRealm - 1) == "-" .. myRealm then
		return full:sub(1, -#myRealm - 2)
	end
	return Ambiguate(full, "none")
end

--- The name to whisper. Chat commands split on spaces, so a Forever name
--- goes as "First-Surname".
function P.WhisperTarget(full)
	if P.FOREVER then return (P.ShortName(full):gsub(" ", "-")) end
	return full
end

--- Versions before 0.9.4 tagged Forever names with the local realm. Rewrite
--- everything stored to bare names, once. Every client does the same, so
--- the copies agree again without anything having to be resent.
function P.MigrateNames()
	local db = P.db
	if not P.FOREVER or db.namesV2 then return end
	db.namesV2 = true
	local function canon(name)
		return type(name) == "string" and StripRealm(name) or name
	end
	local function rekey(t)
		local moved = {}
		for k in pairs(t or {}) do
			local c = canon(k)
			if c ~= k then moved[k] = c end
		end
		for k, c in pairs(moved) do
			if t[c] == nil then t[c] = t[k] end
			t[k] = nil
		end
	end
	for _, key in ipairs({ "gold", "history", "shame", "profs", "mains", "myChars", "roles", "bankChars", "bankScan", "xp", "levels", "race" }) do
		rekey(db[key])
	end
	for _, link in pairs(db.mains or {}) do link.main = canon(link.main) end
	local blobs = {}
	for key, blob in pairs(db.blobs or {}) do
		local kind, owner, rest = key:match("^(%a):([^:]+)(.*)$")
		local to = kind and (kind .. ":" .. canon(owner) .. rest) or key
		if not blobs[to] or blobs[to].ts < blob.ts then blobs[to] = blob end
	end
	db.blobs = blobs
	for _, e in pairs(db.events or {}) do
		e.author = canon(e.author)
		rekey(e.signups)
	end
	for _, f in pairs(db.funds or {}) do
		f.collector, f.winner = canon(f.collector), canon(f.winner)
		for _, d in pairs(f.entries or {}) do d.name = canon(d.name) end
	end
	for _, r in pairs(db.board or {}) do r.author, r.helper = canon(r.author), canon(r.helper) end
	for _, p in pairs(db.pledges or {}) do p.from = canon(p.from) end
	for _, a in ipairs(db.alertLog or {}) do a.from = canon(a.from) end
end

--- Move everything stored under one character name to another. Used when
--- the addon learns it had a character's name wrong.
function P.RenameCharacter(old, new)
	if not old or not new or old == new then return false end
	local db, touched = P.db, false
	for _, key in ipairs({ "gold", "history", "shame", "profs", "mains", "myChars", "roles", "bankChars", "bankScan", "xp", "levels", "race" }) do
		local t = db[key]
		if t and t[old] ~= nil then
			if t[new] == nil then t[new] = t[old] end
			t[old] = nil
			touched = true
		end
	end
	for _, link in pairs(db.mains or {}) do
		if link.main == old then link.main, touched = new, true end
	end
	local moved = {}
	for key, blob in pairs(db.blobs or {}) do
		local kind, rest = key:match("^(%a):(.*)$")
		if rest and (rest == old or rest:sub(1, #old + 1) == old .. ":") then moved[key] = { kind .. ":" .. new .. rest:sub(#old + 1), blob } end
	end
	for key, to in pairs(moved) do
		local there = db.blobs[to[1]]
		if not there or there.ts < to[2].ts then db.blobs[to[1]] = to[2] end
		db.blobs[key] = nil
		touched = true
	end
	-- Shared records get a new revision so the correction reaches others.
	for _, e in pairs(db.events or {}) do
		local changed = false
		if e.author == old then e.author, changed = new, true end
		if e.signups and e.signups[old] then
			e.signups[new] = e.signups[new] or e.signups[old]
			e.signups[old] = nil
			changed = true
		end
		if changed then e.rev, touched = e.rev + 1, true end
	end
	for _, f in pairs(db.funds or {}) do
		local changed = false
		if f.collector == old then f.collector, changed = new, true end
		if f.winner == old then f.winner, changed = new, true end
		for _, d in pairs(f.entries or {}) do
			if d.name == old then d.name, d.ts, changed = new, d.ts + 1, true end
		end
		if changed then f.rev, touched = f.rev + 1, true end
	end
	for _, r in pairs(db.board or {}) do
		local changed = false
		if r.author == old then r.author, changed = new, true end
		if r.helper == old then r.helper, changed = new, true end
		if changed then r.rev, touched = r.rev + 1, true end
	end
	for _, a in ipairs(db.alertLog or {}) do
		if a.from == old then a.from, touched = new, true end
	end
	for _, p in pairs(db.pledges or {}) do
		if p.from == old then p.from, p.rev, touched = new, p.rev + 1, true end
	end
	return touched
end

function P.Now()
	return GetServerTime()
end

local function Day(ts)
	return math.floor((ts or P.Now()) / DAY)
end

--- Make player-typed text safe for the wire and clip it to maxBytes.
function P.Clean(text, maxBytes)
	text = (text or ""):gsub("[%^|%c]", "") -- "^" is the wire separator, "|" starts escape codes
	text = strtrim(text)
	if #text > maxBytes then
		text = text:sub(1, maxBytes)
		-- never leave half a UTF-8 character at the end
		text = text:gsub("[\192-\255][\128-\191]*$", "")
	end
	return text
end

---------------------------------------------------------------------------
-- Money
---------------------------------------------------------------------------
function P.MoneyText(copper) -- plain text, safe for chat
	copper = math.max(0, math.floor(copper or 0))
	local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
	if g > 0 then return ("%dg %ds %dc"):format(g, s, c) end
	if s > 0 then return ("%ds %dc"):format(s, c) end
	return ("%dc"):format(c)
end

function P.MoneyIcons(copper) -- with coin icons, for the UI
	copper = math.max(0, math.floor(copper or 0))
	if C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then
		return C_CurrencyInfo.GetCoinTextureString(copper)
	elseif GetCoinTextureString then
		return GetCoinTextureString(copper)
	end
	return P.MoneyText(copper)
end

function P.ClassColored(text, classFile)
	local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
	if c and c.colorStr then
		return ("|c%s%s|r"):format(c.colorStr, text)
	end
	return text
end

--- A gold change, coloured: green up, red down.
function P.DeltaText(copper)
	if copper == 0 then return "|cff808080no change|r" end
	return (copper > 0 and "|cff40ff40+" or "|cffff4040-") .. P.MoneyIcons(math.abs(copper)) .. "|r"
end

function P.Ago(ts)
	local d = math.max(0, P.Now() - (ts or 0))
	if d < 90 then return "now" end
	if d < 3600 then return ("%dm ago"):format(math.floor(d / 60)) end
	if d < DAY then return ("%dh ago"):format(math.floor(d / 3600)) end
	return ("%dd ago"):format(math.floor(d / DAY))
end

---------------------------------------------------------------------------
-- Guild
---------------------------------------------------------------------------
function P.InGuild()
	if not IsInGuild() then return false end
	local name = GetGuildInfo("player")
	return P.Readable(name) and name:lower() == P.GUILD
end

P.roster = {}  -- array of member tables
P.members = {} -- fullName -> member table

function P.RequestRoster()
	if not IsInGuild() then return end
	if C_GuildInfo and C_GuildInfo.GuildRoster then
		C_GuildInfo.GuildRoster()
	elseif GuildRoster then
		GuildRoster()
	end
end

function P.ScanRoster()
	if not P.InGuild() then return end
	local roster, members = {}, {}
	local myGUID, rosterMe = UnitGUID("player"), nil
	if not P.Readable(myGUID) then myGUID = nil end
	for i = 1, (GetNumGuildMembers() or 0) do
		local name, rank, rankIndex, level, _, zone, note, _, online, _, classFile, _, _, _, _, _, guid = GetGuildRosterInfo(i)
		local full = P.FullName(name)
		if full and myGUID and P.Readable(guid) and guid == myGUID then rosterMe = full end
		if full then
			local m = {
				name = full,
				rank = P.Readable(rank) and rank or "",
				rankIndex = P.Readable(rankIndex) and rankIndex or 99,
				level = P.Readable(level) and level or 0,
				zone = P.Readable(zone) and zone or "",
				note = P.Readable(note) and note or "",
				online = P.Readable(online) and online and true or false,
				class = P.Readable(classFile) and classFile or nil,
			}
			-- Days since last seen, for telling active members from inactive ones.
			if not m.online and GetGuildRosterLastOnline then
				local years, months, days = GetGuildRosterLastOnline(i)
				if P.Readable(years) and P.Readable(months) and P.Readable(days) and days then
					m.days = (years or 0) * 365 + (months or 0) * 30 + days
				end
			end
			tinsert(roster, m)
			members[full] = m
		end
	end
	if #roster == 0 then return end
	P.roster, P.members = roster, members
	-- The roster is the authority on how this character's name is written.
	if rosterMe and rosterMe ~= P.me then
		P.RenameCharacter(P.me, rosterMe)
		P.me = rosterMe
		P.db.myChars[P.me] = true
	end
	-- People who left the guild drop off the leaderboard.
	for name in pairs(P.db.gold) do
		if not members[name] then
			P.db.gold[name] = nil
			P.db.history[name] = nil
		end
	end
	P.Fire("Roster")
end

--- Whether a member is known to run the addon (heard from in the last month).
function P.HasAddon(name)
	if name == P.me then return true end
	local seen = P.db.addonUsers[name]
	return seen ~= nil and P.Now() - seen < 30 * DAY
end

--- How many guildmates run the addon, and how many of those are online now.
function P.AddonAudience()
	local total, online = 0, 0
	for _, m in ipairs(P.roster) do
		if m.name ~= P.me and P.HasAddon(m.name) then
			total = total + 1
			if m.online then online = online + 1 end
		end
	end
	return total, online
end

--- GM and the rank right below may delete anyone's event.
function P.IsOfficer(name)
	local m = P.members[name]
	return m ~= nil and m.rankIndex <= 1
end

---------------------------------------------------------------------------
-- Gold
---------------------------------------------------------------------------
function P.SetGold(name, copper, level, classFile, ts)
	local old = P.db.gold[name]
	if old and old.ts > ts then return end
	P.db.gold[name] = { copper = copper, level = level, class = classFile, ts = ts }
	-- One value per member per day (the day's latest), for the weekly trend.
	local h = P.db.history[name] or {}
	P.db.history[name] = h
	h[Day(ts)] = copper
	P.Fire("Gold")
end

local HISTORY_DAYS = 35

function P.PruneHistory()
	local cutoff = Day() - HISTORY_DAYS
	for name, h in pairs(P.db.history) do
		for day in pairs(h) do
			if day < cutoff then h[day] = nil end
		end
		if not next(h) then P.db.history[name] = nil end
	end
end

--- Change in copper over the last `days` days. History only holds the days
--- this client heard a report, so the comparison point is the newest record
--- at least `days` old, else the oldest one before today. Returns the change
--- and the number of days it really spans, or nil with no older record.
function P.GoldChange(name, days)
	local g, h = P.db.gold[name], P.db.history[name]
	if not g or not h then return nil end
	local today = Day()
	local best, oldest
	for day in pairs(h) do
		if day <= today - days and (not best or day > best) then best = day end
		if day < today and (not oldest or day < oldest) then oldest = day end
	end
	local from = best or oldest
	if not from then return nil end
	return g.copper - h[from], today - from
end

--- Recorded days for a member, newest first: { { day = ts, copper = n }, ... }
function P.GoldHistory(name, maxDays)
	local list, h = {}, P.db.history[name] or {}
	for day, copper in pairs(h) do
		if day > Day() - maxDays then tinsert(list, { ts = day * DAY + DAY / 2, copper = copper }) end
	end
	table.sort(list, function(a, b) return a.ts > b.ts end)
	return list
end

--- Gold change of several characters together: the sum of those with history.
function P.GroupChange(chars, days)
	local total, span
	for _, char in ipairs(chars) do
		local change, over = P.GoldChange(char, days)
		if change then
			total, span = (total or 0) + change, math.max(span or 0, over)
		end
	end
	return total, span
end

--- Biggest loser and biggest earner over the last week (either may be nil).
function P.WeekSummary()
	local loser, earner
	for _, e in ipairs(P.Leaderboard()) do
		local change = P.GroupChange(e.chars, 7)
		if change and change < 0 and (not loser or change < loser.change) then
			loser = { name = e.name, class = e.class, change = change }
		elseif change and change > 0 and (not earner or change > earner.change) then
			earner = { name = e.name, class = e.class, change = change }
		end
	end
	return loser, earner
end

function P.WeekSummaryText()
	local loser, earner = P.WeekSummary()
	local function who(e)
		return P.ClassColored(P.ShortName(e.name), e.class) .. " " .. P.DeltaText(e.change)
	end
	if not loser and not earner then return nil end
	return (loser and ("Biggest loser: " .. who(loser)) or "")
		.. ((loser and earner) and "    " or "")
		.. (earner and ("Biggest earner: " .. who(earner)) or "")
end

function P.RecordMyGold()
	local _, classFile = UnitClass("player")
	P.SetGold(P.me, GetMoney(), UnitLevel("player"), classFile, P.Now())
end

--- Sorted poorest first: { name, copper, level, class, ts, chars }. With
--- `combine` (default: the "combine alts" option) alts are folded into
--- their main and `chars` lists who was added up.
function P.Leaderboard(combine)
	if combine == nil then combine = P.db.opts.combineAlts end
	local groups, list = {}, {}
	for name, g in pairs(P.db.gold) do
		local key = combine and P.MainOf(name) or name
		local e = groups[key]
		-- A guild bank character holds the guild's gold, not its owner's.
		if P.IsGuildBank and P.IsGuildBank(name) then key, e = nil, nil end
		if key then
		if not e then
			local m, own = P.members[key], P.db.gold[key]
			e = { name = key, copper = 0, ts = 0, chars = {},
				level = (m and m.level) or (own and own.level) or g.level,
				class = (m and m.class) or (own and own.class) or g.class }
			groups[key] = e
			tinsert(list, e)
		end
		e.copper, e.ts = e.copper + g.copper, math.max(e.ts, g.ts)
		tinsert(e.chars, name)
		end
	end
	table.sort(list, function(a, b)
		if a.copper ~= b.copper then return a.copper < b.copper end
		return a.name < b.name
	end)
	return list
end

function P.MyRank()
	local list = P.Leaderboard()
	for i, e in ipairs(list) do
		for _, char in ipairs(e.chars) do
			if char == P.me then return i, #list end
		end
	end
	return nil, #list
end

---------------------------------------------------------------------------
-- Events
--   db.events[id] = { id, title, desc, time, author, rev, deleted,
--                     signups = { [name] = { status, role, ts } } }
--   status: "Y" in, "M" maybe, "N" out.   role: "T" tank, "H" healer, "D" dps
---------------------------------------------------------------------------
P.ROLES = { "T", "H", "D" }
P.ROLE_NAME = { T = "Tank", H = "Healer", D = "DPS" }
P.TITLE_MAX, P.DESC_MAX = 60, 100

function P.MyRole()
	return P.db.roles[P.me] or "D"
end

function P.SetMyRole(role)
	P.db.roles[P.me] = role
	P.Fire("Events")
end

function P.PruneEvents()
	local cutoff = P.Now() - DAY
	for id, e in pairs(P.db.events) do
		if e.time < cutoff then P.db.events[id] = nil end
	end
end

--- Upcoming (and just-started) events, soonest first, tombstones left out.
function P.EventList()
	local list = {}
	local cutoff = P.Now() - 3 * 3600
	for _, e in pairs(P.db.events) do
		if not e.deleted and e.time >= cutoff then tinsert(list, e) end
	end
	table.sort(list, function(a, b)
		if a.time ~= b.time then return a.time < b.time end
		return a.id < b.id
	end)
	return list
end

--- Counts of in / maybe / out, plus the roles of those who are in.
function P.CountSignups(e)
	local y, m, n, roles = 0, 0, 0, { T = 0, H = 0, D = 0 }
	for _, s in pairs(e.signups) do
		if s.status == "Y" then
			y = y + 1
			if roles[s.role] then roles[s.role] = roles[s.role] + 1 end
		elseif s.status == "M" then
			m = m + 1
		elseif s.status == "N" then
			n = n + 1
		end
	end
	return y, m, n, roles
end

local function ValidEvent(title, when, desc)
	title, desc = P.Clean(title, P.TITLE_MAX), P.Clean(desc, P.DESC_MAX)
	if title == "" then return nil, "Give the event a title." end
	if not when or when < P.Now() - 3600 then return nil, "That time is in the past." end
	return title, desc
end

function P.CreateEvent(title, when, desc)
	title, desc = ValidEvent(title, when, desc)
	if not title then return nil, desc end
	local e = {
		id = ("%x%04x"):format(P.Now(), math.random(0, 0xffff)),
		title = title, desc = desc, time = when, author = P.me, rev = 1, deleted = false,
		signups = { [P.me] = { status = "Y", role = P.MyRole(), ts = P.Now() } },
	}
	P.db.events[e.id] = e
	P.SendEvent(e)
	P.SendSignups(e)
	P.Fire("Events")
	return e
end

--- The author, the GM and the rank below may edit, delete and invite.
function P.CanManage(e)
	return e.author == P.me or P.AmOfficer()
end

function P.EditEvent(id, title, when, desc)
	local e = P.db.events[id]
	if not e or e.deleted then return nil, "That event is gone." end
	if not P.CanManage(e) then return nil, "Only the author or an officer can edit this." end
	title, desc = ValidEvent(title, when, desc)
	if not title then return nil, desc end
	e.title, e.desc, e.time, e.rev = title, desc, when, e.rev + 1
	P.SendEvent(e)
	P.Fire("Events")
	return e
end

function P.DeleteEvent(id)
	local e = P.db.events[id]
	if not e or not P.CanManage(e) then return end
	e.rev, e.deleted = e.rev + 1, true
	P.SendEvent(e)
	P.Fire("Events")
end

function P.SignUp(id, status)
	local e = P.db.events[id]
	if not e or e.deleted then return end
	e.signups[P.me] = { status = status, role = P.MyRole(), ts = P.Now() }
	P.SendSignups(e, P.me)
	P.Fire("Events")
end

-- Reminder, once per event start time, 15 minutes ahead, for anyone who
-- answered In or Maybe.
local REMIND_AHEAD = 15 * 60

local function CheckReminders()
	local now = P.Now()
	for _, e in pairs(P.db.events) do
		local mine = e.signups[P.me]
		if not e.deleted and mine and mine.status ~= "N" and e.reminded ~= e.time
			and now >= e.time - REMIND_AHEAD and now < e.time then
			e.reminded = e.time
			local text = ("%s starts in %d min"):format(e.title, math.max(1, math.ceil((e.time - now) / 60)))
			P.Print("|cffffffff" .. text .. "|r")
			if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo and ChatTypeInfo["RAID_WARNING"] then
				RaidNotice_AddMessage(RaidWarningFrame, text, ChatTypeInfo["RAID_WARNING"])
			end
			local sound = SOUNDKIT and (SOUNDKIT.READY_CHECK or SOUNDKIT.RAID_WARNING)
			if sound then PlaySound(sound) end
		end
	end
end

---------------------------------------------------------------------------
-- Invites
---------------------------------------------------------------------------
function P.Invite(name)
	if P.FOREVER then name = P.ShortName(name) end -- no realms there: "First Surname"
	if C_PartyInfo and C_PartyInfo.InviteUnit then
		C_PartyInfo.InviteUnit(name)
	elseif InviteUnit then
		InviteUnit(name)
	end
end

local function ConvertToRaidNow()
	if C_PartyInfo and C_PartyInfo.ConvertToRaid then
		C_PartyInfo.ConvertToRaid()
	elseif ConvertToRaid then
		ConvertToRaid()
	end
end

local pendingInvites -- names waiting for the party to exist so it can become a raid

local function InviteAll(names, first, last)
	for i = first or 1, last or #names do
		if names[i] then P.Invite(names[i]) end
	end
end

--- Invite everyone who signed In, is online and is not already grouped.
--- A party holds five, so a bigger list becomes a raid: at once when a party
--- already exists, otherwise as soon as the first invite is accepted.
function P.InviteSignedUp(id)
	local e = P.db.events[id]
	if not e or e.deleted then return end
	if IsInGroup() and not UnitIsGroupLeader("player") then
		return P.Print("You need to be the group leader to invite.")
	end
	local names = {}
	for name, s in pairs(e.signups) do
		local m, short = P.members[name], P.ShortName(name)
		if s.status == "Y" and name ~= P.me and (not m or m.online)
			and not (UnitInParty(short) or UnitInRaid(short)) then
			tinsert(names, name)
		end
	end
	if #names == 0 then return P.Print("Nobody who signed In is online and ungrouped.") end
	table.sort(names)
	local needRaid = not IsInRaid() and (#names + math.max(1, GetNumGroupMembers())) > 5
	if needRaid and not IsInGroup() then
		InviteAll(names, 1, 4)
		pendingInvites = { unpack(names, 5) }
		P.Print(("Invited 4 of %d. The rest follow as a raid once someone accepts."):format(#names))
	else
		if needRaid then ConvertToRaidNow() end
		InviteAll(names)
		P.Print(("Invited %d for %s."):format(#names, e.title))
	end
end

local function OnGroupChanged()
	if not pendingInvites or not IsInGroup() then return end
	local names = pendingInvites
	pendingInvites = nil
	if not IsInRaid() then ConvertToRaidNow() end
	C_Timer.After(1.5, function() InviteAll(names) end)
end

--- Parse "YYYY-MM-DD" + "HH:MM" (the player's local time) into a timestamp.
function P.ParseWhen(dateText, timeText)
	local y, mo, d = (dateText or ""):match("^%s*(%d%d%d%d)%-(%d%d?)%-(%d%d?)%s*$")
	local h, mi = (timeText or ""):match("^%s*(%d%d?):(%d%d)%s*$")
	if not y or not h then return nil end
	y, mo, d, h, mi = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi)
	if mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59 then return nil end
	return time({ year = y, month = mo, day = d, hour = h, min = mi, sec = 0 })
end

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------
local DEFAULT_OPTS = {
	combineAlts = true, thankDonors = true,
	-- Gold is private until the player says otherwise: sharing starts off, and
	-- the Poorest board asks once (shareAsked) whether to join the leaderboard.
	showOffline = false, share = false, shareAsked = false, wizardDone = false, minimap = true, angle = 215, greet = true,
	alerts = true, alertZoneOnly = true, alertPin = true, alertChat = true, groupNotify = true,
	-- Deaths and repair bills are private until opted in. Group posts also go
	-- to guild chat, so members without the addon see them. Board posts print.
	shareShame = false, groupChat = true, boardNotify = true,
	shareQuests = true, -- the quest log, so guildmates on the same quests find each other
	levelSong = true, guildDing = true } -- a song for my own level-up, a ding for a guildmate's

local function Greet()
	-- An update is worth saying even with the greeting turned off.
	if P.UpdateAvailable() and not P.toldOutdated then
		P.toldOutdated = true
		P.Print(P.UpdateNotice())
	end
	if not P.db.opts.greet then return end
	local rank, total = P.MyRank()
	local line = ("Welcome back, %s. You are holding %s."):format(P.ShortName(P.me), P.MoneyIcons(GetMoney()))
	if rank and total > 1 then
		line = line .. (" That makes you #%d poorest of %d known."):format(rank, total)
		if rank == 1 then line = line .. " Truly, the poorest of the poor." end
	end
	P.Print(line)
	for _, f in ipairs(P.FundList()) do
		if not f.closed then P.Print("Fund - " .. P.FundStatusText(f)) end
	end
	for _, d in ipairs(P.Debts()) do
		if d.debtor == P.me then
			P.Print(("You owe %s %s."):format(P.ShortName(d.creditor), P.MoneyIcons(d.copper)))
		elseif d.creditor == P.me then
			P.Print(("%s owes you %s."):format(P.ShortName(d.debtor), P.MoneyIcons(d.copper)))
		end
	end
	for _, e in ipairs(P.EventList()) do
		if e.time > P.Now() and e.time - P.Now() < DAY then
			local mine = e.signups[P.me]
			P.Print(("Coming up %s: |cffffffff%s|r%s"):format(date("%a %H:%M", e.time), e.title,
				mine and "" or " - you have not answered yet (/poor)"))
		end
	end
end

P.DEFAULT_OPTS = DEFAULT_OPTS

local started, tries = false, 0

--- Start syncing if the character is in the guild. Safe to call any time:
--- commands call it too, so nothing depends on the login timers below.
function P.EnsureStarted()
	if started then return true end
	if not P.me or not P.InGuild() then return false end
	started = true
	P.started = true
	P.RequestRoster()
	P.RecordMyGold()
	P.CommStart()
	C_Timer.NewTicker(30, CheckReminders)
	C_Timer.After(15, Greet) -- after the others have answered with their gold
	P.Fire("Started")
	return true
end

--- Why EnsureStarted said no, in words for the player.
function P.WhyNotReady()
	if not IsInGuild() then return "This character is not in a guild." end
	local name = GetGuildInfo("player")
	if not P.Readable(name) or not name then
		return "The game has not loaded your guild's name yet. Try again in a few seconds."
	end
	return ("This character's guild is <%s>, and the addon only works in <%s>."):format(name, P.GUILD)
end

local function TryStart()
	if P.EnsureStarted() then return end
	tries = tries + 1
	-- Guild info can lag behind login; keep asking for two minutes
	-- (PLAYER_GUILD_UPDATE and any command try again after that).
	if tries < 40 then C_Timer.After(3, TryStart) end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_GUILD_UPDATE")
frame:RegisterEvent("GUILD_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_MONEY")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		if ... ~= ADDON then return end
		PoorDB = PoorDB or {}
		P.db = PoorDB
		P.db.gold = P.db.gold or {}
		P.db.events = P.db.events or {}
		P.db.history = P.db.history or {}
		P.db.roles = P.db.roles or {}
		P.db.funds = P.db.funds or {}
		for _, key in ipairs({ "mains", "myChars", "shame", "board", "blobs", "bankChars", "bankScan", "profs", "alertLog", "race", "levels", "xp", "pledges", "fundAuto", "groups", "recruit", "recruitLog", "addonUsers", "addonVersions", "wizardChars" }) do
			P.db[key] = P.db[key] or {}
		end
		P.db.opts = P.db.opts or {}
		-- Someone who already ran a version where sharing was on by default
		-- keeps their setting and is not asked again.
		if P.db.opts.share ~= nil and P.db.opts.shareAsked == nil then P.db.opts.shareAsked = true end
		for k, v in pairs(DEFAULT_OPTS) do
			if P.db.opts[k] == nil then P.db.opts[k] = v end
		end
	elseif event == "PLAYER_LOGIN" then
		local first, second = UnitName("player")
		P.MigrateNames()
		P.me = P.UnitFullName("player") or (tostring(first) .. "-" .. (GetNormalizedRealmName() or ""))
		-- Versions before 0.8.4 took a Forever surname for a realm and kept
		-- this character as "First-Surname". Move what they stored.
		if P.Readable(first) and P.Readable(second) and first and second and second ~= "" then
			P.RenameCharacter(first .. "-" .. second, P.me)
		end
		P.PruneEvents()
		P.PruneHistory()
		P.PruneFunds()
		P.PruneBoard()
		P.PrunePledges()
		P.PruneGroups()
		P.PruneRecruitLog()
		P.db.myChars[P.me] = true
		P.CommInit()
		P.MinimapInit()
		P.SettingsInit()
		C_Timer.After(2, TryStart)
	elseif event == "PLAYER_GUILD_UPDATE" then
		if P.me and not started then C_Timer.After(1, P.EnsureStarted) end
	elseif event == "GUILD_ROSTER_UPDATE" then
		if started then P.ScanRoster() end
	elseif event == "GROUP_ROSTER_UPDATE" then
		OnGroupChanged()
	elseif event == "PLAYER_MONEY" then
		if started then
			P.RecordMyGold()
			P.SendGoldSoon()
		end
	elseif event == "CHAT_MSG_ADDON" then
		if started then P.OnAddonMessage(...) end
	end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local BROKE_LINES = {
	"I have %s to my name. Spare a copper?",
	"Net worth update: %s. Do not ask about the repair bill.",
	"%s. That is all of it. That is the whole fortune.",
	"Currently worth %s and proud of it.",
}

function P.SayGuild(text)
	if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
		P.Print("Chat is restricted here, try again outside.")
	elseif C_ChatInfo and C_ChatInfo.SendChatMessage then
		C_ChatInfo.SendChatMessage(text, "GUILD")
	else
		SendChatMessage(text, "GUILD")
	end
end

--- A report for troubleshooting, shown in a window the text can be copied from.
function P.ShowDebug()
	local lines = {}
	local function out(text) tinsert(lines, tostring(text)) end
	local function section(title, fn)
		out("")
		out("== " .. title)
		local ok, err = pcall(fn)
		if not ok then out("FAILED: " .. tostring(err)) end
	end
	local version, build, _, interface = GetBuildInfo()
	out(("poor v%s   client %s build %s interface %s   locale %s"):format(P.VERSION, tostring(version), tostring(build), tostring(interface), tostring(GetLocale())))
	section("Guild", function()
		local name = GetGuildInfo("player")
		out(("character: %s   running: %s   in a guild: %s   guild name seen: %s"):format(tostring(P.me), tostring(P.started),
			tostring(IsInGuild()), P.Readable(name) and tostring(name) or "(unreadable)"))
		out(("roster: %d members   officer: %s   main: %s"):format(#P.roster, tostring(P.AmOfficer()), tostring(P.MainOf(P.me))))
	end)
	section("Names", function()
		local function show(...)
			local parts = {}
			for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
			return #parts > 0 and table.concat(parts, " | ") or "(nothing)"
		end
		out("UnitName(player): " .. show(UnitName("player")))
		out("UnitFullName(player): " .. show(UnitFullName("player")))
		out("GetUnitName(player, true): " .. show(GetUnitName and GetUnitName("player", true)))
		out("realm: " .. show(GetNormalizedRealmName()) .. "   Forever client: " .. tostring(P.FOREVER))
		out("addon keeps this character as: " .. tostring(P.me) .. "   on the roster: " .. tostring(P.members[P.me] ~= nil))
		out("last addon message sender, as received: " .. tostring(P.lastSenderRaw))
		out("whisper target for this character: " .. tostring(P.WhisperTarget(P.me)) .. "   short name: " .. tostring(P.ShortName(P.me)))
		local mine = {}
		for char in pairs(P.db.myChars) do tinsert(mine, char) end
		table.sort(mine)
		out("this account's characters: " .. table.concat(mine, ", "))
	end)
	section("Versions", function()
		out(("this copy: %s   newest heard of: %s   update notice due: %s"):format(P.VERSION, tostring(P.db.latestVersion), tostring(P.UpdateAvailable() ~= nil)))
		out(("version messages this session: %d sent, %d received"):format(P.versionSent or 0, P.versionHeard or 0))
		local parts = {}
		for name, e in pairs(P.db.addonVersions) do tinsert(parts, ("%s %s (%s)"):format(P.ShortName(name), e.v, P.Ago(e.ts))) end
		table.sort(parts)
		out("members' versions, as last heard: " .. (#parts > 0 and table.concat(parts, ", ") or "none heard yet"))
	end)
	section("Stored data", function()
		local parts = {}
		for _, key in ipairs({ "gold", "events", "funds", "board", "mains", "shame", "race", "profs", "blobs", "alertLog" }) do
			local n = 0
			for _ in pairs(P.db[key] or {}) do n = n + 1 end
			tinsert(parts, key .. "=" .. n)
		end
		out(table.concat(parts, "  "))
	end)
	section("Professions", function() P.DebugSkills(out) end)
	local text = table.concat(lines, "\n"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	if P.ShowText then
		P.ShowText("poor debug report", text)
	else
		for _, line in ipairs(lines) do P.Print(line) end
	end
end

SLASH_POOR1 = "/poor"
SlashCmdList.POOR = function(msg)
	local cmd, rest = strtrim(msg or ""):match("^(%S*)%s*(.-)$")
	cmd = cmd:lower()
	if cmd == "" then
		P.ToggleWindow()
	elseif cmd == "options" or cmd == "config" or cmd == "settings" then
		P.OpenSettings()
	elseif cmd == "setup" or cmd == "wizard" then
		P.ShowWizard()
	elseif cmd == "reset" then
		P.ResetWindow()
		P.Print("Window position and size reset.")
	elseif cmd == "gold" or cmd == "top" then
		local list = P.Leaderboard()
		if #list == 0 then P.Print("No gold reports yet.") end
		for i = 1, math.min(5, #list) do
			local e = list[i]
			P.Print(("#%d %s - %s"):format(i, P.ClassColored(P.ShortName(e.name), e.class), P.MoneyIcons(e.copper)))
		end
	elseif cmd == "pvp" then
		P.SendPvPAlert(rest)
	elseif cmd == "alerts" then
		P.db.opts.alerts = not P.db.opts.alerts
		P.Print("Receiving PvP alerts: " .. (P.db.opts.alerts and "on" or "off"))
	elseif cmd == "pin" then
		P.db.opts.alertPin = not P.db.opts.alertPin
		P.Print("Map pin on incoming PvP alerts: " .. (P.db.opts.alertPin and "on" or "off"))
	elseif cmd == "pvpchat" then
		P.db.opts.alertChat = not P.db.opts.alertChat
		P.Print("Posting your PvP alerts in guild chat: " .. (P.db.opts.alertChat and "on" or "off"))
	elseif cmd == "funds" or cmd == "fund" then
		local list = P.FundList()
		if #list == 0 then P.Print("No funds.") end
		for _, f in ipairs(list) do
			P.Print(P.FundStatusText(f) .. (f.closed and " (closed)" or ""))
		end
	elseif cmd == "main" then
		local arg = strtrim(rest):lower()
		if arg == "" then
			local main = P.MainOf(P.me)
			P.Print(main == P.me and "This character counts as a main. /poor main <name> links it to one."
				or ("This character is an alt of " .. P.ShortName(main) .. ". /poor main none unlinks it."))
		else
			local ok, err = P.SetMyMain(arg ~= "none" and P.ResolveName(rest) or nil)
			P.Print(ok and (arg == "none" and "Your characters are no longer linked." or "Your characters now count as " .. P.ShortName(P.MainOf(P.me)) .. ".") or err)
		end
	elseif cmd == "debts" or cmd == "board" then
		local debts = P.Debts()
		if #debts == 0 then P.Print("Nobody owes anybody. Suspicious.") end
		for _, d in ipairs(debts) do
			P.Print(("%s owes %s %s"):format(P.ShortName(d.debtor), P.ShortName(d.creditor), P.MoneyIcons(d.copper)))
		end
	elseif cmd == "race" then
		local done = P.Finishers()
		for i = 1, 3 do
			local e = done[i]
			P.Print(("%s: %s"):format(({ "1st", "2nd", "3rd" })[i], e and (P.ClassColored(P.ShortName(e.name), e.class) .. " " .. date("%d %b %H:%M", e.ts)) or "still open"))
		end
		for i, c in ipairs(P.Contenders(3)) do
			P.Print(("Chasing #%d: %s, level %d%s"):format(i, P.ClassColored(P.ShortName(c.name), c.class), c.level, c.pct and (" (" .. c.pct .. "%)") or ""))
		end
	elseif cmd == "testnotice" then
		-- Shows what an update notice looks like, on this screen only.
		if P.pretendUpdate then
			P.pretendUpdate = nil
			P.Print("Pretend update notice removed.")
		else
			P.pretendUpdate = "99.0.0"
			P.Print(P.UpdateNotice())
			P.Print("That was a test: nothing was sent to the guild. /poor testnotice again, or /reload, removes it.")
		end
		P.Fire("Version")
	elseif cmd == "ding" then
		if P.PlayLevelSong() then
			P.Print("That is the level-up song.")
		else
			P.Print("No level-up song found. It should be Sounds\\levelup.mp3 inside the Poor addon folder; /reload after adding it.")
		end
	elseif cmd == "debug" then
		P.ShowDebug()
	elseif cmd == "status" then
		local name = GetGuildInfo("player")
		P.Print(("v%s  running: %s  in a guild: %s  guild name seen: %s"):format(P.VERSION, tostring(P.EnsureStarted()),
			tostring(IsInGuild()), P.Readable(name) and tostring(name) or "(unreadable)"))
	elseif cmd == "week" then
		P.Print(P.WeekSummaryText() or "Not enough gold history yet. It builds up from today.")
	elseif cmd == "broke" then
		if not P.EnsureStarted() then return P.Print(P.WhyNotReady()) end
		P.SayGuild(BROKE_LINES[math.random(#BROKE_LINES)]:format(P.MoneyText(GetMoney())))
	elseif cmd == "share" then
		P.db.opts.share = not P.db.opts.share
		P.db.opts.shareAsked = true
		P.Print("Sharing your gold with the guild: " .. (P.db.opts.share and "on" or "off"))
		if P.db.opts.share then P.SendGoldSoon() end
		P.Fire("Options")
	elseif cmd == "minimap" then
		P.db.opts.minimap = not P.db.opts.minimap
		P.MinimapInit()
	elseif cmd == "greet" then
		P.db.opts.greet = not P.db.opts.greet
		P.Print("Login greeting: " .. (P.db.opts.greet and "on" or "off"))
	else
		P.Print("v" .. P.VERSION .. " commands:")
		print("  /poor - open the window")
		print("  /poor options - open the settings page")
		print("  /poor setup - run the first-time setup again")
		print("  /poor reset - put the window back at its default place and size")
		print("  /poor gold - five poorest members")
		print("  /poor pvp [note] - alert the guild to PvP at your location")
		print("  /poor alerts | pin | pvpchat - toggle receiving alerts, the map pin, the guild chat line")
		print("  /poor main [name|none] - link your characters to a main, or show the link")
		print("  /poor debts - who owes whom on the begging board")
		print("  /poor race - the podium of the race to 60 and who is closest")
		print("  /poor funds - progress of the guild's collections")
		print("  /poor week - the week's biggest loser and earner")
		print("  /poor broke - tell guild chat how broke you are")
		print("  /poor share - toggle sharing your gold with the guild")
		print("  /poor status - whether the addon is running, and the guild name it sees")
		print("  /poor debug - a troubleshooting report in a window you can copy from")
		print("  /poor ding - play the level-up song")
		print("  /poor testnotice - show what an update notice looks like (on your screen only)")
		print("  /poor minimap - toggle the minimap button")
		print("  /poor greet - toggle the login greeting")
	end
end
