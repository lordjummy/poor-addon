-- poor -- Groups.lua
-- Finding guildmates for a dungeon or a quest, right now. A member posts
-- what they want to do and which roles are missing; others join with one
-- click and the poster invites them. A listing lasts half an hour.
--
--   db.groups[id] = { id, rev, state, author, created, role, need, min, max, activity,
--                     joiners = { [name] = { role, ts } } }
--   state: "O" open, "X" closed.   need: letters of the roles still wanted, e.g. "TH".
--   joiner role: "T", "H", "D", or "X" for someone who left again.
--
-- Wire (compatible additions):
--   U^id^rev^state^author^created^role^need^min^max^activity
--   J^id^name:role:ts,name:role:ts
local _, P = ...

local TTL = 30 * 60
P.GROUP_TEXT_MAX = 40

-- WoW Forever's dungeons with the levels they suit, lowest first, for the
-- picker and for "who could come". Forever adds several to the classic set
-- (Hall of Thanes, Ruins of Lordaeron, Excavation Site, City of Dalaran, The
-- Drowned City, Krol'dok Stronghold, Shaper's Terrace) and splits others into
-- wings. Names and ranges are as the Forever dungeon journal addon lists them.
P.DUNGEONS = {
	{ "Ragefire Chasm", 13, 18 }, { "Hall of Thanes", 13, 20 }, { "Ruins of Lordaeron", 15, 22 },
	{ "Wailing Caverns", 15, 24 }, { "The Deadmines", 17, 26 }, { "Shadowfang Keep", 20, 30 },
	{ "Blackfathom Deeps", 24, 32 }, { "The Stockade", 24, 32 }, { "Excavation Site: Wetlands", 26, 33 },
	{ "City of Dalaran", 28, 33 }, { "Gnomeregan", 29, 38 }, { "Razorfen Kraul", 29, 38 },
	{ "Scarlet Monastery: Graveyard", 30, 38 }, { "Scarlet Monastery: Library", 33, 41 },
	{ "Scarlet Monastery: Armory", 34, 42 }, { "The Drowned City", 35, 40 },
	{ "Scarlet Monastery: Cathedral", 36, 45 }, { "Razorfen Downs", 37, 46 }, { "Uldaman", 38, 48 },
	{ "Krol'dok Stronghold", 40, 45 }, { "Zul'Farrak", 43, 50 }, { "Maraudon", 45, 52 },
	{ "Sunken Temple", 49, 56 }, { "Blackrock Depths", 52, 60 }, { "Dire Maul: East", 55, 60 },
	{ "Lower Blackrock Spire", 55, 60 }, { "Upper Blackrock Spire", 55, 60 }, { "Dire Maul: West", 57, 60 },
	{ "Dire Maul: North", 57, 60 }, { "Scholomance", 58, 60 }, { "Shaper's Terrace", 58, 60 },
	{ "Stratholme: Living", 58, 60 }, { "Stratholme: Undead", 58, 60 },
}

local function Line(g)
	return ("U^%s^%d^%s^%s^%d^%s^%s^%d^%d^%s"):format(g.id, g.rev, g.state, g.author, g.created,
		P.ROLE_NAME[g.role] and g.role or "-", (g.need and g.need ~= "") and g.need or "-", g.min or 0, g.max or 0, g.activity)
end

local function JoinLines(g, onlyName)
	local parts = {}
	for name, j in pairs(g.joiners) do
		if not onlyName or name == onlyName then tinsert(parts, ("%s:%s:%d"):format(name, j.role, j.ts)) end
	end
	return P.Chunks("J^" .. g.id .. "^", parts)
end

function P.GroupActive(g)
	return g.state == "O" and P.Now() - g.created < TTL
end

--- Minutes a listing has left.
function P.GroupMinutesLeft(g)
	return math.max(0, math.ceil((g.created + TTL - P.Now()) / 60))
end

--- Open listings whose poster is still online, newest first.
function P.GroupList()
	local list = {}
	for _, g in pairs(P.db.groups) do
		local m = P.members[g.author]
		if P.GroupActive(g) and (g.author == P.me or not m or m.online) then tinsert(list, g) end
	end
	table.sort(list, function(a, b)
		if a.created ~= b.created then return a.created > b.created end
		return a.id > b.id
	end)
	return list
end

--- People who joined and have not left: { name, role }, tanks and healers first.
function P.GroupJoiners(g)
	local list, order = {}, { T = 1, H = 2, D = 3 }
	for name, j in pairs(g.joiners) do
		if j.role ~= "X" then tinsert(list, { name = name, role = j.role }) end
	end
	table.sort(list, function(a, b)
		if (order[a.role] or 9) ~= (order[b.role] or 9) then return (order[a.role] or 9) < (order[b.role] or 9) end
		return a.name < b.name
	end)
	return list
end

--- Online guildmates in a level range who are not in the listing yet:
--- { name, level, class, zone }, highest level first. Works for everyone on
--- the roster, addon or not.
function P.CouldCome(min, max, g)
	local list = {}
	for _, m in ipairs(P.roster) do
		local taken = g and (m.name == g.author or (g.joiners[m.name] and g.joiners[m.name].role ~= "X"))
		if m.online and m.name ~= P.me and not taken and (not min or min <= 0 or (m.level >= min and m.level <= max)) then
			tinsert(list, { name = m.name, level = m.level, class = m.class, zone = m.zone })
		end
	end
	table.sort(list, function(a, b)
		if a.level ~= b.level then return a.level > b.level end
		return a.name < b.name
	end)
	return list
end

function P.MyGroup()
	for _, g in pairs(P.db.groups) do
		if g.author == P.me and P.GroupActive(g) then return g end
	end
end

local function Change(g, change)
	change(g)
	g.rev = g.rev + 1
	P.Send(Line(g))
	P.Fire("Groups")
end

--- Post a listing. A member has one at a time: a new one replaces the old.
function P.PostGroup(activity, need, min, max)
	activity = P.Clean(activity, P.GROUP_TEXT_MAX)
	if activity == "" then return nil, "Say what you want to do, or pick a dungeon." end
	local old = P.MyGroup()
	if old then Change(old, function(g) g.state = "X" end) end
	local g = { id = ("%x%04x"):format(P.Now(), math.random(0, 0xffff)), rev = 1, state = "O", author = P.me, created = P.Now(),
		role = P.MyRole(), need = (need or ""):gsub("[^THD]", ""), min = min or 0, max = max or 0, activity = activity, joiners = {} }
	P.db.groups[g.id] = g
	P.Send(Line(g))
	P.Fire("Groups")
	return g
end

function P.CloseGroup(id)
	local g = P.db.groups[id]
	if not g or g.state ~= "O" or not (g.author == P.me or P.AmOfficer()) then return nil end
	Change(g, function(group) group.state = "X" end)
	return g
end

--- Join a listing with the role set on the Events tab, or leave it again.
function P.JoinGroup(id, join)
	local g = P.db.groups[id]
	if not g or not P.GroupActive(g) then return nil, "That listing is gone." end
	if g.author == P.me then return nil, "That is your own listing." end
	local old = g.joiners[P.me]
	g.joiners[P.me] = { role = join and P.MyRole() or "X", ts = math.max(P.Now(), old and old.ts + 1 or 0) }
	for _, line in ipairs(JoinLines(g, P.me)) do P.Send(line) end
	P.Fire("Groups")
	return g
end

--- The poster invites everyone who joined, is online and is not grouped yet.
function P.InviteGroup(id)
	local g = P.db.groups[id]
	if not g or g.author ~= P.me then return end
	if IsInGroup() and not UnitIsGroupLeader("player") then return P.Print("You need to be the group leader to invite.") end
	local n = 0
	for _, j in ipairs(P.GroupJoiners(g)) do
		local m, short = P.members[j.name], P.ShortName(j.name)
		if (not m or m.online) and not (UnitInParty(short) or UnitInRaid(short)) then
			P.Invite(j.name)
			n = n + 1
		end
	end
	P.Print(n > 0 and ("Invited %d for %s."):format(n, g.activity) or "Nobody new to invite yet.")
end

local function RoleNames(letters)
	local parts = {}
	for _, r in ipairs(P.ROLES) do
		if (letters or ""):find(r, 1, true) then tinsert(parts, P.ROLE_NAME[r]) end
	end
	return table.concat(parts, ", ")
end
P.RoleNames = RoleNames

--- Worth a chat line for this player? A dungeon far from their level is not.
local function Relevant(g)
	if not g.min or g.min <= 0 then return true end
	local level = UnitLevel("player")
	return level >= g.min - 2 and level <= g.max + 3
end

P.handlers.U = function(_, id, rev, state, author, created, role, need, min, max, activity)
	rev, created, min, max = tonumber(rev), tonumber(created), tonumber(min), tonumber(max)
	if not id or id == "" or not rev or not created or not author or not activity or (state ~= "O" and state ~= "X") then return end
	P.Hear("U" .. id, rev)
	local g = P.db.groups[id]
	if g and g.rev >= rev then return end
	local isNew = not g
	g = g or { id = id, joiners = {} }
	g.rev, g.state, g.author, g.created = rev, state, author, created
	g.role, g.need = P.ROLE_NAME[role or ""] and role or nil, (need or ""):gsub("[^THD]", "")
	g.min, g.max, g.activity = min or 0, max or 0, P.Clean(activity, P.GROUP_TEXT_MAX)
	P.db.groups[id] = g
	P.Fire("Groups")
	if isNew and P.GroupActive(g) and author ~= P.me and not P.Syncing() and P.db.opts.groupNotify and Relevant(g) then
		P.Print(("%s is looking for a group: |cffffffff%s|r%s. /poor to join."):format(P.ShortName(author), g.activity,
			g.need ~= "" and (" (needs " .. RoleNames(g.need) .. ")") or ""))
	end
end

P.handlers.J = function(_, id, packed)
	local g = id and P.db.groups[id]
	if not packed then return end
	local changed = false
	for name, role, ts in packed:gmatch("([^:,]+):([THDX]):(%d+)") do
		ts = tonumber(ts)
		P.Hear("J" .. id .. name, ts)
		if g then
			local old = g.joiners[name]
			if not old or old.ts < ts then
				g.joiners[name] = { role = role, ts = ts }
				changed = true
				if g.author == P.me and role ~= "X" and P.GroupActive(g) and not P.Syncing() then
					P.Print(("%s wants to join |cffffffff%s|r as %s. Invite from the Groups tab."):format(
						P.ShortName(name), g.activity, P.ROLE_NAME[role]))
					local sound = SOUNDKIT and (SOUNDKIT.IG_PLAYER_INVITE or SOUNDKIT.READY_CHECK)
					if sound then PlaySound(sound) end
				end
			end
		end
	end
	if changed then P.Fire("Groups") end
end

tinsert(P.syncers, function()
	for id, g in pairs(P.db.groups) do
		if P.GroupActive(g) then
			P.Send(function()
				if P.db.groups[id] == g and P.GroupActive(g) and P.HeardVersion("U" .. id) < g.rev then return Line(g) end
			end)
			P.Send(function()
				if P.db.groups[id] ~= g or not P.GroupActive(g) then return nil end
				local parts = {}
				for name, j in pairs(g.joiners) do
					if P.HeardVersion("J" .. id .. name) < j.ts then tinsert(parts, ("%s:%s:%d"):format(name, j.role, j.ts)) end
				end
				return P.Chunks("J^" .. id .. "^", parts)
			end)
		end
	end
end)

--- Listings are short-lived: closed or expired ones go after an hour.
function P.PruneGroups()
	local cutoff = P.Now() - TTL - 3600
	for id, g in pairs(P.db.groups) do
		if g.created < cutoff then P.db.groups[id] = nil end
	end
end

-- Expired listings drop off the tab by themselves.
P.On("Started", function()
	C_Timer.NewTicker(60, function()
		P.PruneGroups()
		P.Fire("Groups")
	end)
end)
