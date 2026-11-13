-- poor -- Comm.lua
-- Guild-channel sync between addon users.
--
-- VERSIONING. The protocol number is part of the addon-message prefix
-- ("POOR1"), so clients on different protocols simply do not hear each other
-- and can never misread each other's data.
--   * Compatible change (new command, new field at the END of a message):
--     keep PROTOCOL. Older clients ignore commands they do not know and
--     fields they do not read.
--   * Breaking change (a field moves or changes meaning): bump PROTOCOL.
-- The addon version travels on its own prefix ("POORV") whose format never
-- changes, so every client, however old, can tell the player to update.
--
-- Wire format on POOR<n>, fields split by "^":
--   H                                       hello (login); everyone answers with G and a sync
--   G^copper^level^CLASS                    the sender's own gold
--   E^id^rev^time^deleted^author^title^desc an event (highest rev wins; deleted=1 is a tombstone)
--   S^id^name:SR:ts,name:SR:ts              signups (S = Y/M/N, R = role T/H/D or "-"; newest ts wins)
--   A^mapID^x^y^zone^subzone^note           PvP alert (Alert.lua)
--   F^... and D^...                         funds and donations (Funds.lua)
--   M alts, X hall of shame, B begging board, P professions, N/W/L bulky data: see those files
local _, P = ...

local PROTOCOL = 2 -- 2: Forever names carry no realm tag (0.9.4)
local PREFIX = "POOR" .. PROTOCOL
local VERSION_PREFIX = "POORV"
local MAX_LEN = 240     -- addon messages cap at 255 bytes
local BURST, QUEUE_MAX = 8, 400

local queue, tokens = {}, BURST

local function Locked()
	return C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()
end

-- Server throttles addon messages per prefix (short burst, then ~1/sec), so
-- everything goes through a token bucket. While in a restricted instance the
-- queue just waits.
--
-- A queue item is a message, or a function that builds one when its turn
-- comes: it returns a message, a list of messages, or nil to send nothing.
-- Sync uses functions so that data another client sent while ours waited is
-- dropped instead of repeated.
local function Flush()
	while tokens > 0 and #queue > 0 do
		if Locked() or not P.InGuild() then return end
		local item = tremove(queue, 1)
		if type(item) == "function" then item = item() end
		if type(item) == "table" then
			for i = #item, 1, -1 do tinsert(queue, 1, item[i]) end
		elseif item then
			pcall(C_ChatInfo.SendAddonMessage, PREFIX, item, "GUILD")
			tokens = tokens - 1
		end
	end
end

local function Pump()
	tokens = math.min(BURST, tokens + 1)
	Flush()
end

local function Send(item)
	if #queue < QUEUE_MAX then
		tinsert(queue, item)
		Flush()
	end
end

P.Send = Send

--- Jump the queue (PvP alerts).
function P.SendFirst(msg)
	tinsert(queue, 1, msg)
	Flush()
end

--- `parts` joined by commas behind `head`, as a list of messages that each fit.
local function Chunks(head, parts)
	local lines, line = {}, head
	for _, part in ipairs(parts) do
		if line ~= head and #line + #part + 1 > MAX_LEN then
			tinsert(lines, line)
			line = head
		end
		line = line .. (line == head and "" or ",") .. part
	end
	if line ~= head then tinsert(lines, line) end
	return lines
end
P.Chunks = Chunks

function P.SendChunked(head, parts)
	for _, line in ipairs(Chunks(head, parts)) do Send(line) end
end

-- What other clients sent lately: key -> newest version, remembered for a
-- short while. Sync asks this right before each send.
local heard, HEARD_FOR = {}, 30

function P.Hear(key, version)
	local h = heard[key]
	if h and h.v >= version and GetTime() - h.t <= HEARD_FOR then return end
	heard[key] = { v = version, t = GetTime() }
end

function P.HeardVersion(key)
	local h = heard[key]
	return (h and GetTime() - h.t <= HEARD_FOR) and h.v or 0
end

---------------------------------------------------------------------------
-- Outgoing
---------------------------------------------------------------------------
local lastGold, goldTimer = 0, nil

local function SendGoldNow()
	goldTimer = nil
	if not P.db.opts.share then return end
	lastGold = GetTime()
	local _, classFile = UnitClass("player")
	Send(("G^%d^%d^%s"):format(GetMoney(), UnitLevel("player"), classFile or ""))
end

--- Report own gold, at most about once a minute (delay: optional seconds).
function P.SendGoldSoon(delay)
	if goldTimer or not P.db.opts.share then return end
	delay = delay or math.max(1, 60 - (GetTime() - lastGold))
	goldTimer = true
	C_Timer.After(delay, SendGoldNow)
end

local function EventLine(e)
	return ("E^%s^%d^%d^%d^%s^%s^%s"):format(e.id, e.rev, e.time, e.deleted and 1 or 0, e.author, e.title, e.desc or "")
end

function P.SendEvent(e)
	Send(EventLine(e))
end

--- Messages carrying an event's signups: one name's, or all that pass `filter`.
local function SignupLines(e, onlyName, filter)
	local parts = {}
	for name, s in pairs(e.signups) do
		if (not onlyName or name == onlyName) and (not filter or filter(name, s)) then
			tinsert(parts, ("%s:%s%s:%d"):format(name, s.status, P.ROLE_NAME[s.role] and s.role or "-", s.ts))
		end
	end
	return Chunks("S^" .. e.id .. "^", parts)
end

function P.SendSignups(e, onlyName)
	for _, line in ipairs(SignupLines(e, onlyName)) do Send(line) end
end

-- Sync: after a hello, every client waits a random few seconds and then
-- offers what it holds. Each piece is checked against what was heard right
-- before it goes out, so one client ends up answering and the rest stay
-- silent. While `syncUntil` lasts, incoming data is treated as catching up
-- and not announced in chat.
local syncPending, syncUntil = false, 0

function P.Syncing()
	return syncPending or GetTime() < syncUntil
end

local function Sync()
	syncPending = false
	syncUntil = math.max(syncUntil, GetTime() + 10)
	for id, e in pairs(P.db.events) do
		Send(function()
			if P.db.events[id] == e and P.HeardVersion("E" .. id) < e.rev then return EventLine(e) end
		end)
		Send(function()
			if P.db.events[id] ~= e or e.deleted then return nil end
			return SignupLines(e, nil, function(name, s)
				return P.HeardVersion("S" .. id .. name) < s.ts
			end)
		end)
	end
	P.SyncFunds()
	for _, queue in ipairs(P.syncers) do queue() end
end

local function ScheduleSync(delay)
	if syncPending then return end
	syncPending = true
	C_Timer.After(delay, Sync)
end

---------------------------------------------------------------------------
-- Incoming
---------------------------------------------------------------------------
local handlers = {}
P.handlers = handlers -- other files add their own commands
P.syncers = {}        -- and functions that queue their data at sync time

-- Small facts a character reports about itself, the way gold is: at login,
-- when someone says hello, and on P.Report(name), at most once a minute.
local reports = {}

function P.SelfReport(name, build, every)
	every = every or 60
	reports[name] = { build = build, every = every, last = -every }
end

function P.Report(name, delay)
	local r = reports[name]
	if not r or r.timer then return end
	r.timer = true
	C_Timer.After(delay or math.max(1, r.every - (GetTime() - r.last)), function()
		r.timer = nil
		r.last = GetTime()
		local msg = r.build()
		if msg then Send(msg) end
	end)
end

local function ReportAll(base, spread)
	for name in pairs(reports) do P.Report(name, base + math.random() * spread) end
end

function handlers.H()
	ReportAll(2, 6)
	P.SendGoldSoon(2 + math.random() * 6)
	ScheduleSync(3 + math.random() * 6)
end

-- Update notices. They travel on their own prefix, shared by every version
-- of the addon, so that copies too old to sync still hear them. A message is
-- "<own version>" or "<own version> <newest version heard of>": every copy
-- passes on the newest version it knows, so the news spreads even when
-- nobody running that version is online.
local function VersionNumber(v)
	local a, b, c = tostring(v):match("^(%d+)%.(%d+)%.?(%d*)")
	return a and (tonumber(a) * 1000000 + tonumber(b) * 1000 + (tonumber(c) or 0))
end

function P.VersionOlder(a, b)
	local x, y = VersionNumber(a), VersionNumber(b)
	return x ~= nil and y ~= nil and x < y
end

--- The newer version this copy has heard of, or nil when it is up to date.
function P.UpdateAvailable()
	local latest, mine = VersionNumber(P.db.latestVersion or ""), VersionNumber(P.VERSION)
	if latest and mine and latest > mine then return P.db.latestVersion end
	return nil
end

function P.UpdateNotice()
	local latest = P.UpdateAvailable()
	return latest and ("|cffffd100Update available:|r poor %s (you have %s). Update with WowUp or the CurseForge app, then restart the game."):format(latest, P.VERSION)
end

local function SendVersion()
	P.versionSent = (P.versionSent or 0) + 1
	local latest = P.UpdateAvailable()
	pcall(C_ChatInfo.SendAddonMessage, VERSION_PREFIX, P.VERSION .. (latest and (" " .. latest) or ""), "GUILD")
end

local replyPending = false

local function OnVersion(sender, message)
	-- Their own version first, then the newest they have heard of.
	local theirs, best, bestText
	for text in tostring(message):gmatch("%S+") do
		local n = VersionNumber(text)
		if n then
			-- Remember which version each member runs: the Roster shows it.
			if not theirs then P.db.addonVersions[sender] = { v = text:sub(1, 12), ts = P.Now() } end
			theirs = theirs or n
			if not best or n > best then best, bestText = n, text:sub(1, 12) end
		end
	end
	if not best then return end
	P.versionHeard = (P.versionHeard or 0) + 1
	P.Hear("V", best)
	local known = VersionNumber(P.UpdateAvailable() or P.VERSION)
	if known and best > known then
		P.db.latestVersion = bestText
		P.Fire("Version")
		if not P.toldOutdated then
			P.toldOutdated = true
			P.Print(P.UpdateNotice())
		end
	elseif known and theirs < known and not replyPending then
		-- They are behind what this copy knows. Tell them, unless someone else does first.
		replyPending = true
		C_Timer.After(2 + math.random() * 6, function()
			replyPending = false
			local now = VersionNumber(P.UpdateAvailable() or P.VERSION)
			if now and P.HeardVersion("V") < now then SendVersion() end
		end)
	end
end

function handlers.A(sender, ...)
	P.OnAlert(sender, ...)
end

function handlers.F(_, ...)
	P.OnFund(...)
end

function handlers.D(_, ...)
	P.OnDonations(...)
end

function handlers.G(sender, copper, level, classFile)
	copper, level = tonumber(copper), tonumber(level)
	if not copper or copper < 0 then return end
	P.SetGold(sender, copper, level or 0, classFile ~= "" and classFile or nil, P.Now())
end

function handlers.E(_, id, rev, when, deleted, author, title, desc)
	rev, when = tonumber(rev), tonumber(when)
	if not id or id == "" or not rev or not when or not author or not title then return end
	P.Hear("E" .. id, rev)
	if when < P.Now() - 86400 then return end
	local e = P.db.events[id]
	if e and e.rev >= rev then return end
	local isNew = not e
	e = e or { id = id, signups = {} }
	e.rev, e.time, e.deleted, e.author = rev, when, deleted == "1", author
	e.title, e.desc = P.Clean(title, P.TITLE_MAX), P.Clean(desc, P.DESC_MAX)
	P.db.events[id] = e
	P.Fire("Events")
	if isNew and not e.deleted and not P.Syncing() and when > P.Now() then
		P.Print(("New event from %s: |cffffffff%s|r, %s. /poor to sign up."):format(
			P.ShortName(author), e.title, date("%a %d %b %H:%M", when)))
	end
end

function handlers.S(_, id, packed)
	local e = id and P.db.events[id]
	if not packed then return end
	local changed = false
	for name, status, role, ts in packed:gmatch("([^:,]+):([YMN])([THD%-]):(%d+)") do
		ts = tonumber(ts)
		P.Hear("S" .. id .. name, ts)
		if e and not e.deleted then
			local old = e.signups[name]
			if not old or old.ts < ts then
				e.signups[name] = { status = status, role = role ~= "-" and role or nil, ts = ts }
				changed = true
			end
		end
	end
	if changed then P.Fire("Events") end
end

function P.OnAddonMessage(prefix, msg, channel, sender)
	if not (P.Readable(prefix) and P.Readable(msg) and P.Readable(channel) and P.Readable(sender)) then return end
	if channel ~= "GUILD" or (prefix ~= PREFIX and prefix ~= VERSION_PREFIX) then return end
	P.lastSenderRaw = sender -- for /poor debug: how this client writes sender names
	sender = P.FullName(sender)
	if not sender or sender == P.me then return end
	P.db.addonUsers[sender] = P.Now() -- a message from them means they run the addon
	if prefix == VERSION_PREFIX then return OnVersion(sender, msg) end
	local cmd, rest = msg:match("^(%u)%^(.*)$")
	local handler = cmd and handlers[cmd]
	if handler then handler(sender, strsplit("^", rest)) end
end

---------------------------------------------------------------------------
-- Lifecycle (called from Core.lua)
---------------------------------------------------------------------------
function P.CommInit()
	C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
	C_ChatInfo.RegisterAddonMessagePrefix(VERSION_PREFIX)
end

function P.CommStart()
	C_Timer.NewTicker(1, Pump)
	Send("H^")
	-- An update that has since been installed is no longer news.
	if not P.UpdateAvailable() then P.db.latestVersion = nil end
	SendVersion()
	P.SendGoldSoon(1)
	ReportAll(1, 2)
	-- Listen to what the others answer first, then fill in what they lacked.
	syncUntil = GetTime() + 30
	ScheduleSync(12)
end
