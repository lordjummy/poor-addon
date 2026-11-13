-- poor -- Shame.lua
-- Hall of shame: deaths and repair bills since the addon was installed.
-- Like gold, each character reports its own numbers.
--
--   db.shame[char] = { deaths = n, repairs = copper, ts = n }
-- Wire (compatible addition): X^deaths^repairs
local _, P = ...

local function Mine()
	local s = P.db.shame[P.me]
	if not s then
		s = { deaths = 0, repairs = 0, ts = P.Now() }
		P.db.shame[P.me] = s
	end
	return s
end

local function Changed()
	Mine().ts = P.Now()
	P.Report("shame")
	P.Fire("Shame")
end

P.SelfReport("shame", function()
	local s = P.db.shame[P.me]
	if not s or (s.deaths == 0 and s.repairs == 0) then return nil end
	return ("X^%d^%d"):format(s.deaths, s.repairs)
end)

P.handlers.X = function(sender, deaths, repairs)
	deaths, repairs = tonumber(deaths), tonumber(repairs)
	if not deaths or not repairs or deaths < 0 or repairs < 0 then return end
	P.db.shame[sender] = { deaths = deaths, repairs = repairs, ts = P.Now() }
	P.Fire("Shame")
end

--- Rows { name, class, deaths, repairs, chars }, alts folded into mains when asked.
function P.ShameList(combine)
	if combine == nil then combine = P.db.opts.combineAlts end
	local groups, list = {}, {}
	for char, s in pairs(P.db.shame) do
		local key = combine and P.MainOf(char) or char
		local e = groups[key]
		if not e then
			local m, g = P.members[key], P.db.gold[key]
			e = { name = key, class = (m and m.class) or (g and g.class), deaths = 0, repairs = 0, chars = {} }
			groups[key] = e
			tinsert(list, e)
		end
		e.deaths, e.repairs = e.deaths + s.deaths, e.repairs + s.repairs
		tinsert(e.chars, char)
	end
	return list
end

P.On("Roster", function()
	for char in pairs(P.db.shame) do
		if not P.members[char] and char ~= P.me then P.db.shame[char] = nil end
	end
end)

-- Repairs: every "repair all" (the merchant button and auto-repair addons
-- alike) goes through RepairAllItems; the bill is still readable right after
-- the call because the server has not answered yet. Guild-funded repairs and
-- single-item repairs are not counted.
if RepairAllItems and GetRepairAllCost then
	hooksecurefunc("RepairAllItems", function(useGuildFunds)
		if useGuildFunds or not P.started then return end
		local cost, can = GetRepairAllCost()
		if not (P.Readable(cost) and P.Readable(can)) or not can or not cost or cost <= 0 then return end
		if GetMoney() < cost then return end
		local s = Mine()
		s.repairs = s.repairs + cost
		Changed()
	end)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_DEAD")
frame:SetScript("OnEvent", function()
	if not P.started then return end
	local s = Mine()
	s.deaths = s.deaths + 1
	Changed()
end)
