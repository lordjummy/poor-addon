-- poor -- Alert.lua
-- PvP alerts: one press tells the guild where you are. Addon users get a
-- warning, a sound and a map pin; guild chat gets a line with a clickable pin
-- for everyone else.
--
-- Wire (compatible addition to protocol 1):
--   A^mapID^x^y^zone^subzone^note     x, y are 0..10000; mapID 0 = no position
local _, P = ...

local COOLDOWN = 20       -- seconds between your own alerts
local SENDER_THROTTLE = 10 -- ignore repeats from one sender inside this window
local NOTE_MAX = 60

local lastSent, lastFrom = -COOLDOWN, {}

local function PlaceText(zone, sub, x, y)
	local text = zone ~= "" and zone or "unknown location"
	if sub ~= "" and sub ~= zone then text = text .. " - " .. sub end
	if x then text = text .. (" (%.1f, %.1f)"):format(x * 100, y * 100) end
	return text
end

--- Where the player stands: mapID, x, y (0..1; nil inside instances), zone, subzone.
local function Where()
	local mapID, x, y = C_Map.GetBestMapForUnit("player"), nil, nil
	if P.Readable(mapID) then
		local pos = C_Map.GetPlayerMapPosition(mapID, "player")
		if pos then x, y = pos:GetXY() end
	end
	if not (P.Readable(x) and P.Readable(y)) or (x == 0 and y == 0) then
		mapID, x, y = nil, nil, nil
	end
	local zone, sub = GetRealZoneText(), GetSubZoneText()
	return mapID, x, y, P.Readable(zone) and zone or "", P.Readable(sub) and sub or ""
end

--- "Name (60 Rogue)" when an enemy player is targeted.
local function TargetText()
	if not (UnitExists("target") and UnitIsPlayer("target") and UnitIsEnemy("player", "target")) then return nil end
	local name, surname = UnitName("target")
	local level, class = UnitLevel("target"), UnitClass("target")
	if P.FOREVER and P.Readable(name) and P.Readable(surname) and name and surname and surname ~= "" then name = name .. " " .. surname end
	if not (P.Readable(name) and P.Readable(level) and P.Readable(class)) then return nil end
	return ("%s (%s %s)"):format(name, level > 0 and level or "??", class)
end

--- A clickable map-pin link for chat. The client only builds one for the
--- player's own pin, so the pin is set for a moment and then put back.
local function PinLink(mapID, x, y)
	local ok, link = pcall(function()
		if not C_Map.CanSetUserWaypointOnMap(mapID) then return nil end
		local old = C_Map.GetUserWaypoint()
		local tracking = C_SuperTrack.IsSuperTrackingUserWaypoint()
		C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x, y))
		local made = C_Map.GetUserWaypointHyperlink()
		if old then
			C_Map.SetUserWaypoint(old)
			C_SuperTrack.SetSuperTrackedUserWaypoint(tracking)
		else
			C_Map.ClearUserWaypoint()
		end
		return made
	end)
	return ok and link or nil
end

local function SetPin(mapID, x, y, title)
	pcall(function()
		if C_Map.CanSetUserWaypointOnMap(mapID) then
			C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x, y))
			C_SuperTrack.SetSuperTrackedUserWaypoint(true)
		end
	end)
	-- TomTom, when installed, adds its arrow as well.
	if TomTom and TomTom.AddWaypoint then
		pcall(TomTom.AddWaypoint, TomTom, mapID, x, y, { title = title, persistent = false, from = "poor" })
	end
end

--- Keep the last alerts for the Alerts tab.
local function Log(entry)
	tinsert(P.db.alertLog, 1, entry)
	for i = #P.db.alertLog, 31, -1 do P.db.alertLog[i] = nil end
	P.Fire("Alerts")
end

--- Put the pin of a logged alert back on the map.
function P.PinAlert(entry)
	if not entry.mapID then return P.Print("That alert came without a position.") end
	SetPin(entry.mapID, entry.x, entry.y, "PvP: " .. P.ShortName(entry.from))
	P.Print(("Pin set: %s"):format(PlaceText(entry.zone, entry.sub, entry.x, entry.y)))
end

function P.AlertPlace(entry)
	return PlaceText(entry.zone, entry.sub, entry.x, entry.y)
end

local function Warn(text)
	if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo and ChatTypeInfo["RAID_WARNING"] then
		RaidNotice_AddMessage(RaidWarningFrame, text, ChatTypeInfo["RAID_WARNING"])
	end
	PlaySound((SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959)
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------
function P.SendPvPAlert(note)
	if not P.EnsureStarted() then return P.Print(P.WhyNotReady()) end
	if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
		return P.Print("Chat is restricted here, the alert cannot be sent.")
	end
	local wait = COOLDOWN - (GetTime() - lastSent)
	if wait > 0 then return P.Print(("Alert already sent. Again in %d sec."):format(math.ceil(wait))) end
	lastSent = GetTime()

	local mapID, x, y, zone, sub = Where()
	note = P.Clean(note, NOTE_MAX)
	local target = TargetText()
	if target then note = P.Clean(note == "" and target or (note .. " - " .. target), NOTE_MAX) end
	zone, sub = P.Clean(zone, 40), P.Clean(sub, 40)

	P.SendFirst(("A^%d^%d^%d^%s^%s^%s"):format(mapID or 0, x and math.floor(x * 10000 + 0.5) or 0,
		y and math.floor(y * 10000 + 0.5) or 0, zone, sub, note))

	local place = PlaceText(zone, sub, x, y)
	if P.db.opts.alertChat then
		local link = mapID and PinLink(mapID, x, y)
		P.SayGuild(("PvP at %s%s%s"):format(place, note ~= "" and (": " .. note) or "", link and (" " .. link) or ""))
	end
	P.Print(("|cffff4040PvP alert sent:|r %s%s"):format(place, note ~= "" and (": " .. note) or ""))
	Log({ from = P.me, mapID = mapID, x = x, y = y, zone = zone, sub = sub, note = note, ts = P.Now() })
end

---------------------------------------------------------------------------
-- Receiving (called from Comm.lua)
---------------------------------------------------------------------------
--- Is this player in the zone an alert came from? By map, or by zone name
--- where the maps differ (a town inside a zone has a map of its own).
local function SameZone(mapID, zone)
	local myMap = C_Map.GetBestMapForUnit("player")
	if mapID and mapID > 0 and P.Readable(myMap) and myMap == mapID then return true end
	local myZone = GetRealZoneText()
	return zone ~= "" and P.Readable(myZone) and myZone == zone
end

function P.OnAlert(sender, mapID, x, y, zone, sub, note)
	if not P.db.opts.alerts then return end
	local now = GetTime()
	if lastFrom[sender] and now - lastFrom[sender] < SENDER_THROTTLE then return end
	lastFrom[sender] = now

	mapID, x, y = tonumber(mapID), tonumber(x), tonumber(y)
	zone, sub, note = P.Clean(zone, 40), P.Clean(sub, 40), P.Clean(note, NOTE_MAX)
	local hasPos = mapID and mapID > 0 and x and y and x > 0 and x <= 10000 and y > 0 and y <= 10000
	if hasPos then x, y = x / 10000, y / 10000 else x, y = nil, nil end

	Log({ from = sender, mapID = hasPos and mapID or nil, x = x, y = y, zone = zone, sub = sub, note = note, ts = P.Now() })
	local who, place = P.ShortName(sender), PlaceText(zone, sub, x, y)
	local m = P.members[sender]
	local name, tail = P.ClassColored(who, m and m.class), note ~= "" and (": " .. note) or ""

	-- A fight in the zone the player is standing in gets the full warning.
	-- One elsewhere is a quiet chat line, unless they asked to be warned of all.
	local here = SameZone(mapID, zone)
	if here or not P.db.opts.alertZoneOnly then
		P.Print(("|cffff4040PvP%s|r %s at |cffffffff%s|r%s"):format(here and " in your zone!" or "!", name, place, tail))
		Warn(("PvP! %s at %s"):format(who, place))
		if hasPos and P.db.opts.alertPin then
			SetPin(mapID, x, y, "PvP: " .. who)
		end
	else
		P.Print(("|cffff9050PvP elsewhere:|r %s at |cffffffff%s|r%s  |cff999999(the Alerts tab can pin it)|r"):format(name, place, tail))
	end
end

---------------------------------------------------------------------------
-- Key bindings (Bindings.xml)
---------------------------------------------------------------------------
BINDING_HEADER_POOR = "poor"
BINDING_NAME_POOR_PVP_ALERT = "Send PvP alert to guild"
BINDING_NAME_POOR_TOGGLE = "Open poor window"

function Poor_PvPAlert()
	P.SendPvPAlert("")
end
function Poor_Toggle()
	P.ToggleWindow()
end
