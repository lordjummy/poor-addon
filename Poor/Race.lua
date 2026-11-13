-- poor -- Race.lua
-- The race to level 60: who got there first, and who is closest.
--
-- Levels come from the guild roster, so every member counts, with or without
-- the addon. Any client that sees a member at 60 records the time; the
-- earliest sighting wins. A sighting is "approximate" when that client never
-- saw the member below 60 (already there when tracking began, or reached it
-- while nobody with the addon was online).
--
--   db.race[char]   = { ts = n, approx = bool, class = "MAGE" }
--   db.levels[char] = last level seen on the roster
--   db.xp[char]     = { level = n, pct = n, ts = n }      reported by addon users
--
-- Wire (compatible additions):
--   T^name@ts@flag@CLASS,...     finishers; flag 1 = approximate
--   Y^level^percent              the sender's own progress through its level
local _, P = ...

P.MAX_LEVEL = 60
local XP_EVERY = 300 -- seconds between progress reports

local function Score(d) -- higher is better: earlier, and exact over approximate
	return 4000000000 - d.ts + (d.approx and 0 or 0.5)
end

local function Part(name, d)
	return ("%s@%d@%d@%s"):format(name, d.ts, d.approx and 1 or 0, d.class or "")
end

--- Keep the better of what is known and a new sighting. True if it changed.
local function Record(name, ts, approx, class)
	local old = P.db.race[name]
	if old then
		local earlier = ts < old.ts
		local refines = old.approx and not approx and ts <= old.ts + 300
		if not earlier and not refines then return false end
	end
	P.db.race[name] = { ts = old and math.min(ts, old.ts) or ts, approx = approx, class = class or (old and old.class) }
	P.Fire("Race")
	return true
end

--- Finishers in order. With alts combined, a player counts once, by the
--- first of their characters: { name, main, ts, approx, class }
function P.Finishers(combine)
	if combine == nil then combine = P.db.opts.combineAlts end
	local all = {}
	for name, d in pairs(P.db.race) do
		tinsert(all, { name = name, main = P.MainOf(name), ts = d.ts, approx = d.approx, class = d.class })
	end
	table.sort(all, function(a, b)
		if a.ts ~= b.ts then return a.ts < b.ts end
		return a.name < b.name
	end)
	if not combine then return all end
	local list, seen = {}, {}
	for _, e in ipairs(all) do
		if not seen[e.main] then
			seen[e.main] = true
			tinsert(list, e)
		end
	end
	return list
end

--- Members still on the way, closest first: { name, level, pct, class, online, zone }
function P.Contenders(limit)
	local list = {}
	for _, m in ipairs(P.roster) do
		if m.level < P.MAX_LEVEL then
			local xp = P.db.xp[m.name]
			tinsert(list, { name = m.name, level = m.level, class = m.class, online = m.online, zone = m.zone,
				pct = (xp and xp.level == m.level) and xp.pct or nil })
		end
	end
	table.sort(list, function(a, b)
		if a.level ~= b.level then return a.level > b.level end
		if (a.pct or -1) ~= (b.pct or -1) then return (a.pct or -1) > (b.pct or -1) end
		return a.name < b.name
	end)
	for i = #list, (limit or #list) + 1, -1 do list[i] = nil end
	return list
end

local PLACE = { "1st", "2nd", "3rd" }
local announced = {}

local function Announce(name)
	if announced[name] or P.Syncing() then return end
	announced[name] = true
	local main, place = P.MainOf(name), nil
	for i, e in ipairs(P.Finishers()) do
		if e.main == main then
			-- Only a player's first character takes a place.
			if e.name == name then place = i end
			break
		end
	end
	if not place then return end
	local who = P.ClassColored(P.ShortName(name), P.db.race[name].class)
	if place <= 3 then
		P.Print(("%s reached level %d: |cffffd100%s place|r in the race!"):format(who, P.MAX_LEVEL, PLACE[place]))
		if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo and ChatTypeInfo["RAID_WARNING"] then
			RaidNotice_AddMessage(RaidWarningFrame, ("%s reached %d: %s place!"):format(P.ShortName(name), P.MAX_LEVEL, PLACE[place]),
				ChatTypeInfo["RAID_WARNING"])
		end
		local sound = SOUNDKIT and (SOUNDKIT.UI_LEGENDARY_LOOT_TOAST or SOUNDKIT.RAID_WARNING)
		if sound then PlaySound(sound) end
	else
		P.Print(("%s reached level %d, number %d to get there."):format(who, P.MAX_LEVEL, place))
	end
end

--- Tell the guild about a sighting, unless someone already sent one as good.
local function Broadcast(name)
	-- A client that just logged in knows the least: its own "already 60"
	-- sightings wait until the login sync has had its say.
	local mine = P.db.race[name]
	local wait = (mine and mine.approx and P.Syncing()) and 35 or 0
	C_Timer.After(wait + math.random() * 4, function()
		P.Send(function()
			-- Still the record this client made? If someone supplied an
			-- earlier time meanwhile, there is nothing to add.
			local d = P.db.race[name]
			if d and d == mine and P.HeardVersion("T" .. name) < Score(d) then return "T^" .. Part(name, d) end
		end)
	end)
end

local function Sighted(name, approx, class)
	if Record(name, P.Now(), approx, class) then
		Broadcast(name)
		Announce(name)
	end
end

P.handlers.T = function(_, packed)
	if not packed then return end
	for name, ts, flag, class in packed:gmatch("([^@,]+)@(%d+)@([01])@(%u*)") do
		local d = { ts = tonumber(ts), approx = flag == "1" }
		P.Hear("T" .. name, Score(d))
		if Record(name, d.ts, d.approx, class ~= "" and class or nil) then Announce(name) end
	end
end

tinsert(P.syncers, function()
	P.Send(function()
		local parts = {}
		for name, d in pairs(P.db.race) do
			if P.HeardVersion("T" .. name) < Score(d) then tinsert(parts, Part(name, d)) end
		end
		return P.Chunks("T^", parts)
	end)
end)

P.On("Roster", function()
	for _, m in ipairs(P.roster) do
		local before = P.db.levels[m.name]
		if m.level >= P.MAX_LEVEL and not P.db.race[m.name] then
			Sighted(m.name, not (before and before < P.MAX_LEVEL), m.class)
		end
		if m.level > 0 then P.db.levels[m.name] = m.level end
	end
end)

-- Own progress -----------------------------------------------------------
local lastSent

P.SelfReport("xp", function()
	local level, max = UnitLevel("player"), UnitXPMax("player")
	if level >= P.MAX_LEVEL or not max or max <= 0 then return nil end
	local pct = math.floor(UnitXP("player") / max * 100)
	local now = level .. ":" .. pct
	if now == lastSent then return nil end
	lastSent = now
	P.db.xp[P.me] = { level = level, pct = pct, ts = P.Now() }
	return ("Y^%d^%d"):format(level, pct)
end, XP_EVERY)

P.handlers.Y = function(sender, level, pct)
	level, pct = tonumber(level), tonumber(pct)
	if not level or not pct or pct < 0 or pct > 100 then return end
	P.db.xp[sender] = { level = level, pct = pct, ts = P.Now() }
	P.Fire("Race")
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterEvent("PLAYER_XP_UPDATE")
frame:SetScript("OnEvent", function(_, event, level)
	if not P.started then return end
	if event == "PLAYER_LEVEL_UP" and P.Readable(level) and level and level >= P.MAX_LEVEL then
		local _, class = UnitClass("player")
		P.db.levels[P.me] = level
		Sighted(P.me, false, class)
		P.RequestRoster()
	else
		P.Report("xp")
	end
end)
