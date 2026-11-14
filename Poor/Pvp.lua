-- poor -- Pvp.lua
-- Honor board, kill feed and the guild's kill-on-sight list.
--
-- WoW Forever closes the combat log to addons, so kills are taken from
-- PARTY_KILL (attacker and victim GUIDs) and enemies are recognised from the
-- units the player actually sees: target, mouseover and nameplates.
--
--   db.honor[char] = { hk, kb, rank, week, wkhk, wkkb, ts }
--        hk    lifetime honorable kills as the game counts them (-1: not readable)
--        kb    killing blows on enemy players, counted by the addon since install
--        rank  the game's PvP rank number (0: none)
--        week  the week the two weekly numbers belong to
--   db.kos[name]   = { name, ts, state, by, class, level, reason }   state "A" listed, "X" removed
--   db.killLog     = { { ts, by, victim, class, zone }, ... }        newest first, this client's memory
--
-- Wire (compatible additions):
--   O^hk^kb^rank^week^wkhk^wkkb          the sender's own honor numbers
--   I^victim^CLASS^zone                  the sender just killed an enemy player
--   V^name^ts^state^by^CLASS^level^reason   a kill-on-sight entry; the newest ts wins
local _, P = ...

P.KOS_REASON_MAX = 60
local KOS_MAX = 300
local KILL_LOG_MAX = 50
local WEEK = 7 * 86400

local function ThisWeek()
	return math.floor(P.Now() / WEEK)
end

---------------------------------------------------------------------------
-- Honor
---------------------------------------------------------------------------
local function ReadHK()
	if GetPVPLifetimeStats then
		local ok, hk = pcall(GetPVPLifetimeStats)
		if ok and P.Readable(hk) and type(hk) == "number" then return hk end
	end
	if GetStatistic then
		local ok, v = pcall(GetStatistic, 588) -- "Total Honorable Kills"
		v = ok and P.Readable(v) and tonumber(v)
		if v then return v end
	end
	return nil
end

local function ReadRank()
	if not UnitPVPRank then return 0 end
	local ok, rank = pcall(UnitPVPRank, "player")
	return (ok and P.Readable(rank) and type(rank) == "number") and rank or 0
end

--- The title that goes with a rank number, or nil below the first rank.
function P.RankName(rank)
	if not rank or rank < 5 or not GetPVPRankInfo then return nil end
	local ok, name = pcall(GetPVPRankInfo, rank)
	return (ok and P.Readable(name) and name ~= "") and name or nil
end

local function Mine()
	local h = P.db.honor[P.me]
	if not h then
		h = { hk = -1, kb = 0, rank = 0, week = ThisWeek(), wkhk = 0, wkkb = 0, ts = P.Now() }
		P.db.honor[P.me] = h
	end
	return h
end

--- Read the game's numbers into this character's record. True if they changed.
local function Refresh()
	local h = Mine()
	local before = ("%d:%d:%d:%d:%d"):format(h.hk, h.rank, h.week, h.wkhk, h.wkkb)
	if h.week ~= ThisWeek() then
		h.week, h.wkkb, h.base = ThisWeek(), 0, nil
	end
	local hk = ReadHK()
	if hk then
		h.hk = hk
		h.base = h.base or hk -- the first reading of a week is where its count starts
		if hk < h.base then h.base = hk end
		h.wkhk = hk - h.base
	else
		h.wkhk = 0
	end
	h.rank = ReadRank()
	if before == ("%d:%d:%d:%d:%d"):format(h.hk, h.rank, h.week, h.wkhk, h.wkkb) then return false end
	h.ts = P.Now()
	return true
end

P.SelfReport("honor", function()
	if not P.db.opts.shareHonor then return nil end
	Refresh()
	local h = Mine()
	if h.hk <= 0 and h.kb == 0 and h.rank == 0 then return nil end -- nothing to show yet
	return ("O^%d^%d^%d^%d^%d^%d"):format(h.hk, h.kb, h.rank, h.week, h.wkhk, h.wkkb)
end)

P.handlers.O = function(sender, hk, kb, rank, week, wkhk, wkkb)
	hk, kb, rank, week, wkhk, wkkb = tonumber(hk), tonumber(kb), tonumber(rank), tonumber(week), tonumber(wkhk), tonumber(wkkb)
	if not (hk and kb and rank and week and wkhk and wkkb) or kb < 0 or rank < 0 or wkhk < 0 or wkkb < 0 then return end
	P.db.honor[sender] = { hk = hk, kb = kb, rank = rank, week = week, wkhk = wkhk, wkkb = wkkb, ts = P.Now() }
	P.Fire("Honor")
end

--- Rows { name, class, hk, kb, rank, wkhk, wkkb, chars }, alts folded into
--- mains when asked. Weekly numbers from an older week count as zero.
function P.HonorList(combine)
	if combine == nil then combine = P.db.opts.combineAlts end
	local groups, list, week = {}, {}, ThisWeek()
	for char, h in pairs(P.db.honor) do
		if char ~= P.me or P.db.opts.shareHonor then
			local key = combine and P.MainOf(char) or char
			local e = groups[key]
			if not e then
				local m, g = P.members[key], P.db.gold[key]
				e = { name = key, class = (m and m.class) or (g and g.class), hk = 0, kb = 0, rank = 0, wkhk = 0, wkkb = 0, chars = {} }
				groups[key] = e
				tinsert(list, e)
			end
			e.hk = e.hk + math.max(h.hk, 0)
			e.kb = e.kb + h.kb
			e.rank = math.max(e.rank, h.rank)
			if h.week == week then e.wkhk, e.wkkb = e.wkhk + h.wkhk, e.wkkb + h.wkkb end
			tinsert(e.chars, char)
		end
	end
	return list
end

P.On("Roster", function()
	for char in pairs(P.db.honor) do
		if not P.members[char] and char ~= P.me then P.db.honor[char] = nil end
	end
end)

---------------------------------------------------------------------------
-- Enemies in view
---------------------------------------------------------------------------
local seen = {}    -- guid -> { name, class, level }
local recent = {}  -- { name, class, level, ts }, newest first
local warned = {}  -- name -> GetTime() of the last kill-on-sight warning

--- Enemy players seen lately, newest first: { name, class, level, ts }
function P.RecentEnemies()
	return recent
end

local function Remember(guid, name, class, level)
	local e = { name = name, class = class, level = level, ts = P.Now() }
	seen[guid] = e
	for i = #recent, 1, -1 do
		if recent[i].name == name then tremove(recent, i) end
	end
	tinsert(recent, 1, e)
	recent[13] = nil
end

--- The enemy player a unit is, or nil: { name, class, level }, and their GUID.
local function EnemyPlayer(unit)
	local ok, name, class, level, guid = pcall(function()
		if not UnitExists(unit) then return nil end
		local isPlayer, hostile = UnitIsPlayer(unit), UnitIsEnemy("player", unit)
		if not (P.Readable(isPlayer) and P.Readable(hostile)) or not isPlayer or not hostile then return nil end
		local _, classFile = UnitClass(unit)
		local lvl, id = UnitLevel(unit), UnitGUID(unit)
		return P.UnitFullName(unit), P.Readable(classFile) and classFile or nil,
			(P.Readable(lvl) and type(lvl) == "number" and lvl > 0) and lvl or 0, P.Readable(id) and id or nil
	end)
	if not ok or not name then return nil end
	return { name = name, class = class, level = level }, guid
end
P.EnemyPlayer = EnemyPlayer

local function Describe(class, level)
	local what = class and (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class] or class) or nil
	if what and level and level > 0 then return ("%s %d"):format(what, level) end
	return what or ((level and level > 0) and ("level " .. level) or nil)
end
P.DescribeEnemy = Describe

local function Warn(entry, enemy)
	local now = GetTime()
	if warned[entry.name] and now - warned[entry.name] < 90 then return end
	warned[entry.name] = now
	local what = Describe(enemy.class or entry.class, enemy.level)
	P.Print(("|cffff4040Kill on sight:|r %s%s%s"):format(P.ClassColored(entry.name, enemy.class or entry.class),
		what and (" (" .. what .. ")") or "", entry.reason ~= "" and (" - " .. entry.reason) or ""))
	if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo and ChatTypeInfo["RAID_WARNING"] then
		RaidNotice_AddMessage(RaidWarningFrame, "Kill on sight: " .. entry.name, ChatTypeInfo["RAID_WARNING"])
	end
	PlaySound((SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959)
end

local function Look(unit)
	if not P.started then return end
	local enemy, guid = EnemyPlayer(unit)
	if not enemy then return end
	if guid then Remember(guid, enemy.name, enemy.class, enemy.level) end
	local entry = P.db.kos[enemy.name]
	if entry and entry.state == "A" and P.db.opts.kosWarn then Warn(entry, enemy) end
end

---------------------------------------------------------------------------
-- Kill-on-sight list
---------------------------------------------------------------------------
local function KosLine(e)
	return ("V^%s^%d^%s^%s^%s^%d^%s"):format(e.name, e.ts, e.state, e.by, e.class or "", e.level or 0, e.reason or "")
end

local function Publish(e)
	P.db.kos[e.name] = e
	P.Hear("V" .. e.name, e.ts)
	P.Send(KosLine(e))
	P.Fire("Kos")
end

--- Listed enemies, newest first.
function P.KosList()
	local list = {}
	for _, e in pairs(P.db.kos) do
		if e.state == "A" then tinsert(list, e) end
	end
	table.sort(list, function(a, b)
		if a.ts ~= b.ts then return a.ts > b.ts end
		return a.name < b.name
	end)
	return list
end

--- Put an enemy on the list (or change the reason). Returns ok, problem.
function P.AddKos(name, reason, class, level)
	name = P.Clean(name or "", 40)
	if name == "" then return false, "Whose name?" end
	if P.members[name] or P.members[P.FullName(name) or ""] then return false, name .. " is in the guild." end
	local count = 0
	for _, e in pairs(P.db.kos) do
		if e.state == "A" then count = count + 1 end
	end
	local old = P.db.kos[name]
	if count >= KOS_MAX and not (old and old.state == "A") then return false, "The list is full. Remove someone first." end
	Publish({ name = name, ts = math.max(P.Now(), old and old.ts + 1 or 0), state = "A", by = P.me,
		class = class or (old and old.class), level = (level and level > 0) and level or (old and old.level) or 0,
		reason = P.Clean(reason or "", P.KOS_REASON_MAX) })
	return true
end

--- Whoever listed an enemy can take them off again; so can an officer.
function P.CanRemoveKos(e)
	return e.by == P.me or P.AmOfficer()
end

function P.RemoveKos(name)
	local e = P.db.kos[name]
	if not e or e.state ~= "A" or not P.CanRemoveKos(e) then return false end
	Publish({ name = e.name, ts = math.max(P.Now(), e.ts + 1), state = "X", by = e.by, class = e.class, level = e.level, reason = "" })
	return true
end

P.handlers.V = function(_, name, ts, state, by, class, level, reason)
	ts, level = tonumber(ts), tonumber(level)
	if not name or name == "" or not ts or (state ~= "A" and state ~= "X") or not by or by == "" then return end
	name = P.Clean(name, 40)
	P.Hear("V" .. name, ts)
	local old = P.db.kos[name]
	if old and old.ts >= ts then return end
	local e = { name = name, ts = ts, state = state, by = by, class = (class and class ~= "") and class or nil, level = level or 0,
		reason = P.Clean(reason or "", P.KOS_REASON_MAX) }
	P.db.kos[name] = e
	P.Fire("Kos")
	if P.Syncing() or state ~= "A" or (old and old.state == "A") or not P.db.opts.kosWarn then return end
	P.Print(("%s put |cffff4040%s|r on the kill-on-sight list%s"):format(P.ShortName(by), name,
		e.reason ~= "" and (": " .. e.reason) or "."))
end

tinsert(P.syncers, function()
	P.TidyKos()
	for name, e in pairs(P.db.kos) do
		P.Send(function()
			if P.db.kos[name] == e and P.HeardVersion("V" .. name) < e.ts then return KosLine(e) end
		end)
	end
end)

--- Forget removals after a month; they have reached everyone who will hear.
P.TidyKos = function()
	for name, e in pairs(P.db.kos) do
		if e.state == "X" and P.Now() - e.ts > 30 * 86400 then P.db.kos[name] = nil end
	end
end

---------------------------------------------------------------------------
-- Kills
---------------------------------------------------------------------------
local function Log(by, victim, class, zone)
	tinsert(P.db.killLog, 1, { ts = P.Now(), by = by, victim = victim, class = class, zone = zone })
	for i = #P.db.killLog, KILL_LOG_MAX + 1, -1 do P.db.killLog[i] = nil end
	P.Fire("Kills")
end

local lastKill = {} -- victim -> GetTime(), so one death is not counted twice
P.lastPartyKill = nil -- for /poor debug

local function VictimOf(guid)
	if seen[guid] then return seen[guid].name, seen[guid].class end
	if not GetPlayerInfoByGUID then return nil end
	local ok, _, classFile, _, _, _, name = pcall(GetPlayerInfoByGUID, guid)
	if not ok or not P.Readable(name) or not name or name == "" then return nil end
	return name, P.Readable(classFile) and classFile or nil
end

local function OnPartyKill(attacker, target)
	if not (P.Readable(attacker) and P.Readable(target)) or type(target) ~= "string" then return end
	P.lastPartyKill = ("%s -> %s"):format(tostring(attacker), tostring(target))
	if target:sub(1, 7) ~= "Player-" then return end
	local me = UnitGUID("player")
	if not P.Readable(me) or attacker ~= me then return end
	local victim, class = VictimOf(target)
	victim = victim or "an enemy"
	local now = GetTime()
	if lastKill[victim] and now - lastKill[victim] < 20 then return end
	lastKill[victim] = now
	local h = Mine()
	if h.week ~= ThisWeek() then Refresh() end
	h.kb, h.wkkb, h.ts = h.kb + 1, h.wkkb + 1, P.Now()
	P.Report("honor")
	P.Fire("Honor")
	local zone = GetRealZoneText and GetRealZoneText() or ""
	if not P.Readable(zone) then zone = "" end
	Log(P.me, victim, class, zone)
	-- Battlegrounds would flood the feed: only kills out in the world are told.
	if P.db.opts.shareHonor and not (IsInInstance and IsInInstance()) then
		P.Send(("I^%s^%s^%s"):format(P.Clean(victim, 40), class or "", P.Clean(zone, 40)))
	end
end
P.OnPartyKill = OnPartyKill

local lastTold = {} -- sender -> GetTime() of the last feed line printed for them

P.handlers.I = function(sender, victim, class, zone)
	if not victim or victim == "" then return end
	victim, zone = P.Clean(victim, 40), P.Clean(zone or "", 40)
	class = (class and class ~= "") and class or nil
	Log(sender, victim, class, zone)
	if not P.db.opts.killFeed or P.Syncing() then return end
	local now = GetTime()
	if lastTold[sender] and now - lastTold[sender] < 3 then return end
	lastTold[sender] = now
	local listed = P.db.kos[victim] and P.db.kos[victim].state == "A"
	local m = P.members[sender]
	P.Print(("%s killed %s%s%s"):format(P.ClassColored(P.ShortName(sender), m and m.class), P.ClassColored(victim, class),
		zone ~= "" and (" in " .. zone) or "", listed and ". |cffff4040Kill on sight.|r" or "."))
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
for _, event in ipairs({ "PARTY_KILL", "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "NAME_PLATE_UNIT_ADDED",
	"PLAYER_PVP_KILLS_CHANGED", "PLAYER_PVP_RANK_CHANGED", "PLAYER_ENTERING_WORLD" }) do
	pcall(frame.RegisterEvent, frame, event) -- not every client has every one of these
end
frame:SetScript("OnEvent", function(_, event, a, b)
	if not P.started then return end
	if event == "PARTY_KILL" then
		OnPartyKill(a, b)
	elseif event == "PLAYER_TARGET_CHANGED" then
		Look("target")
	elseif event == "UPDATE_MOUSEOVER_UNIT" then
		Look("mouseover")
	elseif event == "NAME_PLATE_UNIT_ADDED" then
		if P.Readable(a) and type(a) == "string" then Look(a) end
	elseif Refresh() then
		P.Report("honor")
		P.Fire("Honor")
	end
end)

--- What this client offers for PvP, for /poor debug.
function P.DebugPvp(out)
	local function try(label, fn, ...)
		if not fn then return out(label .. ": missing") end
		local r = { pcall(fn, ...) }
		if not r[1] then return out(label .. ": error " .. tostring(r[2])) end
		local parts = {}
		for i = 2, math.min(#r, 7) do parts[#parts + 1] = P.Readable(r[i]) and tostring(r[i]) or "(secret)" end
		out(label .. ": " .. (#parts > 0 and table.concat(parts, ", ") or "(nothing)"))
	end
	try("GetPVPLifetimeStats", GetPVPLifetimeStats)
	try("GetPVPSessionStats", GetPVPSessionStats)
	try("GetPVPYesterdayStats", GetPVPYesterdayStats)
	try("GetPVPThisWeekStats", GetPVPThisWeekStats)
	try("GetPVPLastWeekStats", GetPVPLastWeekStats)
	try("GetStatistic(588)", GetStatistic, 588)
	try("UnitPVPRank", UnitPVPRank, "player")
	try("GetPVPRankInfo(rank)", GetPVPRankInfo, ReadRank())
	try("GetPVPRankProgress", GetPVPRankProgress)
	try("UnitHonor", UnitHonor, "player")
	try("UnitHonorMax", UnitHonorMax, "player")
	try("UnitHonorLevel", UnitHonorLevel, "player")
	try("GetHonorCurrency", GetHonorCurrency)
	try("GetPlayerInfoByGUID(me)", GetPlayerInfoByGUID, UnitGUID("player"))
	out("last PARTY_KILL: " .. tostring(P.lastPartyKill))
	local h = P.db.honor[P.me]
	out(h and ("stored: hk %d, killing blows %d, rank %d, this week %d hk / %d blows"):format(h.hk, h.kb, h.rank, h.wkhk, h.wkkb) or "stored: nothing")
	local listed = 0
	for _, e in pairs(P.db.kos) do
		if e.state == "A" then listed = listed + 1 end
	end
	out(("kill on sight: %d listed, %d enemies seen this session, %d kills in the feed"):format(listed, #recent, #P.db.killLog))
end
