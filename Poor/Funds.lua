-- poor -- Funds.lua
-- Collections: an officer opens a fund ("Tabard design", goal 50g), gold
-- handed to the collector by trade or mail is offered for it with one click,
-- and everyone sees the progress and who gave.
--
--   db.funds[id] = { id, title, goal, collector, rev, closed, deleted, ts,
--                    entries = { [eid] = { name, copper, ts, how, deleted } },
--                    price, winner, winTicket, winOf }
--
-- A fund with a `price` is a LOTTERY: every `price` copper a player pays in
-- is one ticket, the collector draws a winner, and the winner takes the pot.
--   how: "T" trade, "M" mail, "H" entered by hand
--
-- Wire (compatible additions to protocol 1):
--   F^id^rev^goal^flag^collector^title^price^winner^ticket^of
--                                             flag 0 open, 1 closed, 2 deleted; highest rev wins;
--                                             the last four are for lotteries (price 0 = plain fund)
--   D^fundId^eid:name:copper:ts:how:del,...   donations; newest ts per eid wins, del=1 removes
local _, P = ...

local DAY = 86400
P.FUND_TITLE_MAX = 40
P.HOW_TEXT = { T = "trade", M = "mail", H = "by hand" }

--- Officer = GM or the rank below, or anyone the guild lets edit officer notes.
function P.AmOfficer()
	if P.IsOfficer(P.me) then return true end
	if C_GuildInfo and C_GuildInfo.CanEditOfficerNote then return C_GuildInfo.CanEditOfficerNote() and true or false end
	if CanEditOfficerNote then return CanEditOfficerNote() and true or false end
	return false
end

--- "5", "2.5", "5g", "5g 50s", "40s 10c" -> copper. A bare number is gold.
function P.ParseMoney(text)
	text = (text or ""):lower():gsub("%s+", "")
	if text == "" then return nil end
	local plain = tonumber(text)
	if plain then return plain >= 0 and math.floor(plain * 10000 + 0.5) or nil end
	if text:gsub("%d+[gsc]", "") ~= "" then return nil end
	local total, worth = 0, { g = 10000, s = 100, c = 1 }
	for n, unit in text:gmatch("(%d+)([gsc])") do
		total = total + tonumber(n) * worth[unit]
	end
	return total
end

--- Typed name -> "Name-Realm". Guild members match without regard to case.
--- Forever names can be two words ("Pink Guy"), so spaces are kept; a name
--- typed without its space ("pinkguy") still finds the member.
function P.ResolveName(text)
	text = P.Clean(text, 40):gsub("[:,>@=]", ""):gsub("%s+", " ")
	if text == "" then return nil end
	local lower = text:lower()
	local squashed = lower:gsub(" ", "")
	local loose
	for full in pairs(P.members) do
		local fullLower, shortLower = full:lower(), P.ShortName(full):lower()
		if fullLower == lower or shortLower == lower then return full end
		if shortLower:gsub(" ", "") == squashed or fullLower:gsub(" ", "") == squashed then loose = full end
	end
	return loose or P.FullName(text)
end

--- Money for chat, zero parts left out: "12g", "3g 50s".
function P.MoneyShort(copper)
	copper = math.max(0, math.floor(copper or 0))
	local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
	local parts = {}
	if g > 0 then tinsert(parts, g .. "g") end
	if s > 0 then tinsert(parts, s .. "s") end
	if c > 0 or #parts == 0 then tinsert(parts, c .. "c") end
	return table.concat(parts, " ")
end

---------------------------------------------------------------------------
-- Reading
---------------------------------------------------------------------------
--- Total copper, number of distinct donors, number of donations.
function P.FundTotal(f)
	local total, donors, count, seenDonor = 0, 0, 0, {}
	for _, d in pairs(f.entries) do
		if not d.deleted then
			total, count = total + d.copper, count + 1
			local who = P.MainOf(d.name)
			if not seenDonor[who] then
				seenDonor[who] = true
				donors = donors + 1
			end
		end
	end
	return total, donors, count
end

--- Funds that still exist: open ones first, newest first.
function P.FundList()
	local list = {}
	for _, f in pairs(P.db.funds) do
		if not f.deleted then tinsert(list, f) end
	end
	table.sort(list, function(a, b)
		if a.closed ~= b.closed then return not a.closed end
		return a.id > b.id
	end)
	return list
end

--- Donations of a fund, newest first.
function P.FundEntries(f)
	local list = {}
	for eid, d in pairs(f.entries) do
		if not d.deleted then
			tinsert(list, { eid = eid, name = d.name, copper = d.copper, ts = d.ts, how = d.how })
		end
	end
	table.sort(list, function(a, b)
		if a.ts ~= b.ts then return a.ts > b.ts end
		return a.eid > b.eid
	end)
	return list
end

--- Totals per person (alts folded into mains), biggest giver first:
--- { name, copper, count, last }
function P.FundDonors(f)
	local byName, list = {}, {}
	for _, d in pairs(f.entries) do
		if not d.deleted then
			local who = P.MainOf(d.name)
			local e = byName[who]
			if not e then
				e = { name = who, copper = 0, count = 0, last = 0 }
				byName[who] = e
				tinsert(list, e)
			end
			e.copper, e.count, e.last = e.copper + d.copper, e.count + 1, math.max(e.last, d.ts)
		end
	end
	table.sort(list, function(a, b)
		if a.copper ~= b.copper then return a.copper > b.copper end
		return a.name < b.name
	end)
	return list
end

function P.CanManageFund(f)
	return f.collector == P.me or P.AmOfficer()
end

function P.PruneFunds()
	local cutoff = P.Now() - 30 * DAY
	for id, f in pairs(P.db.funds) do
		if f.deleted and (f.ts or 0) < cutoff then P.db.funds[id] = nil end
	end
end

---------------------------------------------------------------------------
-- Wire
---------------------------------------------------------------------------
local function FundLine(f)
	return ("F^%s^%d^%d^%d^%s^%s^%d^%s^%d^%d^%d"):format(f.id, f.rev, f.goal, f.deleted and 2 or (f.closed and 1 or 0),
		f.collector, f.title, f.price or 0, f.winner or "", f.winTicket or 0, f.winOf or 0, f.paid and 1 or 0)
end

local function SendFund(f)
	P.Send(FundLine(f))
end

local function DonationLines(f, onlyEid, filter)
	local parts = {}
	for eid, d in pairs(f.entries) do
		if (not onlyEid or eid == onlyEid) and (not filter or filter(eid, d)) then
			tinsert(parts, ("%s:%s:%d:%d:%s:%d"):format(eid, d.name, d.copper, d.ts, d.how or "H", d.deleted and 1 or 0))
		end
	end
	return P.Chunks("D^" .. f.id .. "^", parts)
end

local function SendDonations(f, onlyEid)
	for _, line in ipairs(DonationLines(f, onlyEid)) do P.Send(line) end
end

--- Called by Comm's sync. Each piece is built when its turn in the send
--- queue comes, leaving out what another client sent in the meantime.
function P.SyncFunds()
	for id, f in pairs(P.db.funds) do
		P.Send(function()
			if P.db.funds[id] == f and P.HeardVersion("F" .. id) < f.rev then return FundLine(f) end
		end)
		P.Send(function()
			if P.db.funds[id] ~= f or f.deleted then return nil end
			return DonationLines(f, nil, function(eid, d)
				return P.HeardVersion("D" .. id .. eid) < d.ts
			end)
		end)
	end
end

function P.OnFund(id, rev, goal, flag, collector, title, price, winner, ticket, of, paid)
	local seen = P.Syncing()
	rev, goal = tonumber(rev), tonumber(goal)
	if not id or id == "" or not rev or not goal or not collector or not title then return end
	P.Hear("F" .. id, rev)
	local f = P.db.funds[id]
	if f and f.rev >= rev then return end
	local isNew = not f
	f = f or { id = id, entries = {} }
	f.rev, f.goal, f.collector, f.title = rev, goal, collector, P.Clean(title, P.FUND_TITLE_MAX)
	f.closed, f.deleted, f.ts = flag == "1", flag == "2", P.Now()
	local hadWinner = f.winner ~= nil
	f.price = (tonumber(price) or 0) > 0 and tonumber(price) or nil
	f.winner = (winner and winner ~= "") and winner or nil
	f.winTicket, f.winOf = tonumber(ticket) or 0, tonumber(of) or 0
	local wasPaid = f.paid
	f.paid = paid == "1"
	P.db.funds[id] = f
	if f.paid and not wasPaid and not seen and f.winner and f.collector == P.me then
		P.Print(("%s confirmed receiving the pot of |cffffffff%s|r."):format(P.ShortName(f.winner), f.title))
	end
	P.Fire("Funds")
	if seen or f.deleted then return end
	if f.winner and not hadWinner then
		local text = ("%s wins the %s lottery: %s!"):format(P.ShortName(f.winner), f.title, P.MoneyShort((P.FundTotal(f))))
		P.Print(("|cffffd100%s|r (ticket %d of %d)"):format(text, f.winTicket, f.winOf))
		if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo and ChatTypeInfo["RAID_WARNING"] then
			RaidNotice_AddMessage(RaidWarningFrame, text, ChatTypeInfo["RAID_WARNING"])
		end
	elseif isNew and not f.closed and f.price then
		P.Print(("New lottery: |cffffffff%s|r, %s a ticket, winner takes all. Trade or mail gold to %s to enter."):format(
			f.title, P.MoneyIcons(f.price), P.ShortName(collector)))
	elseif isNew and not f.closed then
		P.Print(("New fund: |cffffffff%s|r, goal %s. Give your gold to %s."):format(
			f.title, P.MoneyIcons(goal), P.ShortName(collector)))
	end
end

function P.OnDonations(fundId, packed)
	local seen = P.Syncing()
	local f = fundId and P.db.funds[fundId]
	if not packed then return end
	local changed = false
	for eid, name, copper, ts, how, del in packed:gmatch("(%x+):([^:,]+):(%d+):(%d+):([TMH]):([01])") do
		copper, ts = tonumber(copper), tonumber(ts)
		P.Hear("D" .. fundId .. eid, ts)
		if f and not f.deleted then
			local old = f.entries[eid]
			if not old or old.ts < ts then
				f.entries[eid] = { name = name, copper = copper, ts = ts, how = how, deleted = del == "1" }
				changed = true
				if not old and del ~= "1" and not seen then
					local total = P.FundTotal(f)
					P.Print(("%s gave %s to |cffffffff%s|r (%s%s)"):format(P.ShortName(name), P.MoneyIcons(copper), f.title,
						P.MoneyIcons(total), f.goal > 0 and (" of " .. P.MoneyIcons(f.goal)) or ""))
				end
			end
		end
	end
	if changed then P.Fire("Funds") end
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------
local function NewId()
	return ("%x%04x"):format(P.Now(), math.random(0, 0xffff))
end

--- Open a fund, or with `price` (copper per ticket) a lottery.
function P.CreateFund(title, goal, price)
	if not P.AmOfficer() then return nil, "Only officers can open a fund or a lottery." end
	title = P.Clean(title, P.FUND_TITLE_MAX)
	if title == "" then return nil, "Give it a name." end
	if price ~= nil then
		if not price or price <= 0 then return nil, "A lottery needs a ticket price in gold, like 1 or 50s." end
		goal = 0
	elseif not goal then
		return nil, "Goal must be an amount of gold, like 50 or 12g 50s. Leave it empty for no goal."
	end
	local f = { id = NewId(), title = title, goal = goal, price = price, collector = P.me, rev = 1,
		closed = false, deleted = false, ts = P.Now(), entries = {} }
	P.db.funds[f.id] = f
	P.db.activeFund = f.id
	SendFund(f)
	P.Fire("Funds")
	return f
end

local function ChangeFund(id, change)
	local f = P.db.funds[id]
	if not f or f.deleted or not P.CanManageFund(f) then return end
	change(f)
	f.rev, f.ts = f.rev + 1, P.Now()
	SendFund(f)
	P.Fire("Funds")
	return f
end

function P.SetFundClosed(id, closed)
	local f = P.db.funds[id]
	if f and f.winner then return nil end -- a drawn lottery stays closed
	return ChangeFund(id, function(fund) fund.closed = closed end)
end

--- Tickets of a lottery, in the order they are numbered:
--- { { name, copper, tickets, first, last }, ... } and the number of tickets.
--- A player's payments (alts included) are added up before dividing.
function P.LotteryTickets(f)
	local list, total = {}, 0
	if not f.price or f.price <= 0 then return list, 0 end
	for _, d in ipairs(P.FundDonors(f)) do
		local n = math.floor(d.copper / f.price)
		if n > 0 then tinsert(list, { name = d.name, copper = d.copper, tickets = n }) end
	end
	table.sort(list, function(a, b) return a.name < b.name end)
	for _, e in ipairs(list) do
		e.first, e.last = total + 1, total + e.tickets
		total = e.last
	end
	return list, total
end

--- Draw the winner. Only the collector can, since they hold the pot.
function P.DrawLottery(id)
	local f = P.db.funds[id]
	if not f or f.deleted or not f.price then return nil, "That is not a lottery." end
	if f.collector ~= P.me then return nil, "Only " .. P.ShortName(f.collector) .. ", who holds the pot, can draw." end
	if f.winner then return nil, "This lottery was already drawn." end
	local list, total = P.LotteryTickets(f)
	if total == 0 then return nil, "Nobody has a ticket yet." end
	local pick, winner = math.random(1, total), nil
	for _, e in ipairs(list) do
		if pick >= e.first and pick <= e.last then winner = e.name end
	end
	ChangeFund(id, function(fund)
		fund.winner, fund.winTicket, fund.winOf, fund.closed = winner, pick, total, true
	end)
	local pot = P.FundTotal(f)
	P.SayGuild(("%s lottery: ticket %d of %d wins. Congratulations %s, you win %s!"):format(
		f.title, pick, total, P.ShortName(winner), P.MoneyShort(pot)))
	P.Print(("|cffffd100%s wins.|r Pay %s to %s."):format(P.ShortName(winner), P.MoneyIcons(pot), P.ShortName(winner)))
	return winner
end

--- Gold is at stake once anything was paid in. Then only the keeper, who
--- holds it, can delete; and a drawn lottery only after the winner was paid.
function P.CanDeleteFund(f)
	if not P.CanManageFund(f) then return false end
	if P.FundTotal(f) == 0 then return true end
	if f.winner and not f.paid then return false, "The winner has not confirmed the payout yet." end
	if f.collector ~= P.me then return false, "It holds gold. Only " .. P.ShortName(f.collector) .. ", who has it, can delete it." end
	return true
end

function P.DeleteFund(id)
	local f = P.db.funds[id]
	if not f then return nil end
	local ok, why = P.CanDeleteFund(f)
	if not ok then return nil, why end
	return ChangeFund(id, function(fund) fund.deleted = true end)
end

--- The winner of a lottery says the pot arrived. Not the organiser: the
--- point is that someone other than the holder of the gold confirms it.
function P.ConfirmPayout(id)
	local f = P.db.funds[id]
	if not f or f.deleted or not f.winner or f.paid then return nil end
	if P.MainOf(P.me) ~= f.winner and P.me ~= f.winner then return nil, "Only the winner confirms the payout." end
	f.paid, f.rev, f.ts = true, f.rev + 1, P.Now()
	P.Send(FundLine(f))
	P.Fire("Funds")
	return f
end

function P.AddDonation(id, name, copper, how)
	local f = P.db.funds[id]
	if not f or f.deleted then return nil, "That fund is gone." end
	if not P.CanManageFund(f) then return nil, "Only the collector or an officer can record donations." end
	if not name then return nil, "Who gave it?" end
	if not copper or copper <= 0 then return nil, "Amount must be gold, like 5 or 2g 50s." end
	-- Whoever holds the pot and draws the ticket does not also hold tickets.
	if f.price and P.MainOf(name) == P.MainOf(f.collector) then
		return nil, "The organiser of a lottery cannot hold tickets in it."
	end
	if f.winner then return nil, "That lottery is already drawn." end
	local eid = NewId()
	f.entries[eid] = { name = name, copper = copper, ts = P.Now(), how = how or "H", deleted = false }
	SendDonations(f, eid)
	P.Fire("Funds")
	-- Thank the donor for gold that just arrived (not for entries typed in
	-- later), if they are online to hear it.
	local m = P.members[name]
	if P.db.opts.thankDonors and (how == "T" or how == "M") and name ~= P.me and (how == "T" or (m and m.online))
		and not (C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()) then
		local total = P.FundTotal(f)
		local text = ("Thank you for the %s toward %s! %s raised%s."):format(P.MoneyShort(copper), f.title, P.MoneyShort(total),
			f.goal > 0 and (" of " .. P.MoneyShort(f.goal)) or " so far")
		if f.price then
			local mine, all = 0, 0
			local list
			list, all = P.LotteryTickets(f)
			for _, e in ipairs(list) do
				if e.name == P.MainOf(name) then mine = e.tickets end
			end
			text = ("You are in the %s lottery with %d ticket%s of %d. The pot is %s. Good luck!"):format(
				f.title, mine, mine == 1 and "" or "s", all, P.MoneyShort(total))
		end
		if C_ChatInfo.SendChatMessage then
			C_ChatInfo.SendChatMessage(text, "WHISPER", nil, P.WhisperTarget(name))
		else
			SendChatMessage(text, "WHISPER", nil, P.WhisperTarget(name))
		end
	end
	return eid
end

function P.RemoveDonation(id, eid)
	local f = P.db.funds[id]
	local d = f and f.entries[eid]
	if not d or not P.CanManageFund(f) then return end
	d.deleted, d.ts = true, math.max(P.Now(), d.ts + 1)
	SendDonations(f, eid)
	P.Fire("Funds")
end

function P.FundStatusText(f)
	local total, donors = P.FundTotal(f)
	if f.price then
		local _, tickets = P.LotteryTickets(f)
		if f.winner then
			return ("%s lottery: won by %s, %s (ticket %d of %d)"):format(f.title, P.ShortName(f.winner), P.MoneyShort(total), f.winTicket, f.winOf)
		end
		return ("%s lottery: pot %s, %d ticket%s from %d player%s, %s a ticket"):format(f.title, P.MoneyShort(total),
			tickets, tickets == 1 and "" or "s", donors, donors == 1 and "" or "s", P.MoneyShort(f.price))
	end
	local text = ("%s: %s"):format(f.title, P.MoneyShort(total))
	if f.goal > 0 then
		text = text .. (" of %s raised (%d%%)"):format(P.MoneyShort(f.goal), math.floor(total / f.goal * 100))
	else
		text = text .. " raised"
	end
	return text .. (" from %d donor%s"):format(donors, donors == 1 and "" or "s")
end

function P.AnnounceFund(id)
	local f = P.db.funds[id]
	if not f or f.deleted then return end
	local text = P.FundStatusText(f) .. "."
	if f.price then
		if not f.closed then
			text = text .. (" Winner takes all. Trade or mail gold to %s to enter."):format(P.ShortName(f.collector))
		end
		return P.SayGuild(text)
	end
	local top = {}
	for i, d in ipairs(P.FundDonors(f)) do
		if i > 3 then break end
		top[i] = P.ShortName(d.name) .. " " .. P.MoneyShort(d.copper)
	end
	if #top > 1 then text = text .. " Top donors: " .. table.concat(top, ", ") .. "." end
	if not f.closed then
		text = text .. (" Trade or mail gold to %s to chip in."):format(P.ShortName(f.collector))
	end
	P.SayGuild(text)
end

---------------------------------------------------------------------------
-- Noticing gold handed to the collector
---------------------------------------------------------------------------
--- The open fund this character collects for (the one last looked at wins).
local function MyOpenFund()
	local active = P.db.funds[P.db.activeFund or ""]
	if active and not active.deleted and not active.closed and active.collector == P.me then return active end
	for _, f in ipairs(P.FundList()) do
		if not f.closed and f.collector == P.me then return f end
	end
end

local asking, waiting = false, {}

local function AskNext()
	asking = false
	local gift = tremove(waiting, 1)
	if not gift then return end
	local f = P.db.funds[gift.fund]
	if not f or f.deleted or f.closed then return AskNext() end
	local question = ("Count it toward \"%s\"?"):format(f.title)
	if f.price then
		local n = math.floor(gift.copper / f.price)
		question = ("Enter it in the \"%s\" lottery (%s)?"):format(f.title,
			n > 0 and (n .. (n == 1 and " ticket" or " tickets")) or ("less than one ticket at " .. P.MoneyIcons(f.price)))
	end
	local dialog = StaticPopup_Show("POOR_DONATION", ("%s gave you %s by %s.\n%s"):format(
		P.ShortName(gift.name), P.MoneyIcons(gift.copper), P.HOW_TEXT[gift.how], question))
	if dialog then
		dialog.data = gift
		asking = true
	else
		P.Print(("%s gave you %s. Add it on the Funds tab if it was for %s."):format(
			P.ShortName(gift.name), P.MoneyIcons(gift.copper), f.title))
	end
end

StaticPopupDialogs["POOR_DONATION"] = {
	text = "%s",
	button1 = YES,
	button2 = NO,
	OnAccept = function(_, gift)
		local ok, err = P.AddDonation(gift.fund, gift.name, gift.copper, gift.how)
		if not ok then P.Print(err) end
		C_Timer.After(0.2, AskNext)
	end,
	OnCancel = function()
		C_Timer.After(0.2, AskNext)
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

---------------------------------------------------------------------------
-- Pledges: a donor's addon says what gold on its way is for, so the keeper's
-- addon can record it without asking.
--
--   db.pledges[id] = { id, rev, fund, from, copper, created, state }
--   state: "P" waiting for the gold, "D" received, "X" withdrawn
-- Wire (compatible addition): C^id^rev^fund^from^copper^created^state
---------------------------------------------------------------------------
local PLEDGE_STATE = { P = true, D = true, X = true }

local function PledgeLine(p)
	return ("C^%s^%d^%s^%s^%d^%d^%s"):format(p.id, p.rev, p.fund, p.from, p.copper, p.created, p.state)
end

local function SetPledgeState(p, state)
	p.state, p.rev = state, p.rev + 1
	P.Send(PledgeLine(p))
	P.Fire("Funds")
end

--- Pledges of a fund still waiting for their gold, oldest first; `from` narrows to one character.
function P.PendingPledges(fundId, from)
	local list = {}
	for _, p in pairs(P.db.pledges) do
		if p.state == "P" and p.fund == fundId and (not from or p.from == from) then tinsert(list, p) end
	end
	table.sort(list, function(a, b)
		if a.created ~= b.created then return a.created < b.created end
		return a.id < b.id
	end)
	return list
end

--- Promise gold to a fund or lottery. The gold itself still goes by trade or mail.
function P.Pledge(fundId, copper)
	local f = P.db.funds[fundId]
	if not f or f.deleted or f.closed then return nil, "That one is closed." end
	if f.collector == P.me then return nil, "You hold this one yourself. Add your own gold with the Donor and Gold boxes." end
	if not copper or copper <= 0 then return nil, "Amount must be gold, like 5 or 2g 50s." end
	local p = { id = NewId(), rev = 1, fund = fundId, from = P.me, copper = copper, created = P.Now(), state = "P" }
	P.db.pledges[p.id] = p
	P.Send(PledgeLine(p))
	P.Fire("Funds")
	return p
end

function P.CancelPledge(id)
	local p = P.db.pledges[id]
	if not p or p.from ~= P.me or p.state ~= "P" then return nil end
	SetPledgeState(p, "X")
	return p
end

function P.PrunePledges()
	local now = P.Now()
	for id, p in pairs(P.db.pledges) do
		local age, f = now - p.created, P.db.funds[p.fund]
		if not f or f.deleted or (p.state ~= "P" and age > 3 * DAY) or age > 14 * DAY then P.db.pledges[id] = nil end
	end
end

P.handlers.C = function(_, id, rev, fund, from, copper, created, state)
	rev, copper, created = tonumber(rev), tonumber(copper), tonumber(created)
	if not id or id == "" or not rev or not copper or not created or not fund or not from or not PLEDGE_STATE[state or ""] then return end
	P.Hear("C" .. id, rev)
	local p = P.db.pledges[id]
	if p and p.rev >= rev then return end
	local isNew = not p
	p = p or { id = id }
	p.rev, p.fund, p.from, p.copper, p.created, p.state = rev, fund, from, copper, created, state
	P.db.pledges[id] = p
	P.Fire("Funds")
	local f = P.db.funds[fund]
	if isNew and state == "P" and f and f.collector == P.me and not P.Syncing() then
		P.Print(("%s pledged %s to |cffffffff%s|r. It is recorded when the gold arrives."):format(P.ShortName(from), P.MoneyIcons(copper), f.title))
	end
end

tinsert(P.syncers, function()
	for id, p in pairs(P.db.pledges) do
		P.Send(function()
			-- A pledge to a fund that is gone is of no use to anyone.
			local f = P.db.funds[p.fund]
			if f and not f.deleted and P.db.pledges[id] == p and P.HeardVersion("C" .. id) < p.rev then return PledgeLine(p) end
		end)
	end
end)

--- Gold arrived from `name`: which of this character's open funds was it
--- pledged to? Returns the fund and the pledges it settles, or nil when no
--- pledge says, or when pledges to several funds leave it unclear.
local function MatchPledge(name, copper)
	local main, cands = P.MainOf(name), {}
	for _, p in pairs(P.db.pledges) do
		local f = P.db.funds[p.fund]
		if p.state == "P" and f and not f.deleted and not f.closed and f.collector == P.me
			and (p.from == name or P.MainOf(p.from) == main) then
			tinsert(cands, p)
		end
	end
	if #cands == 0 then return nil end
	table.sort(cands, function(a, b) return a.created < b.created end)
	-- One pledge of exactly this amount.
	for _, p in ipairs(cands) do
		if p.copper == copper then return P.db.funds[p.fund], { p } end
	end
	-- Several pledges to one fund paid together, or all pledges are to one
	-- fund anyway (the amount then differs from the promise; the gold counts).
	local perFund, funds = {}, 0
	for _, p in ipairs(cands) do
		if not perFund[p.fund] then
			perFund[p.fund] = { sum = 0, list = {} }
			funds = funds + 1
		end
		perFund[p.fund].sum = perFund[p.fund].sum + p.copper
		tinsert(perFund[p.fund].list, p)
	end
	for fundId, group in pairs(perFund) do
		if group.sum == copper or funds == 1 then return P.db.funds[fundId], group.list end
	end
	return nil
end

--- Whether gold from guildmates is counted for this fund without asking.
function P.FundAuto(fundId)
	return P.db.fundAuto[fundId] and true or false
end

function P.SetFundAuto(fundId, on)
	P.db.fundAuto[fundId] = on and true or nil
	P.Fire("Funds")
end

local function OnReceived(name, copper, how)
	if not P.EnsureStarted() or not name or not copper or copper <= 0 then return end
	-- 1. A pledge says what this gold is for.
	local pledged, settled = MatchPledge(name, copper)
	if pledged then
		local ok, err = P.AddDonation(pledged.id, name, copper, how)
		if ok then
			for _, p in ipairs(settled) do SetPledgeState(p, "D") end
			P.Print(("Recorded %s from %s for |cffffffff%s|r, as pledged."):format(P.MoneyIcons(copper), P.ShortName(name), pledged.title))
		else
			P.Print(err)
		end
		return
	end
	local f = MyOpenFund()
	if not f then return end
	-- 2. The keeper asked for gold from guildmates to be counted unasked.
	--    A lottery only takes whole tickets that way.
	if P.FundAuto(f.id) and P.members[name] and (not f.price or copper % f.price == 0) then
		if P.AddDonation(f.id, name, copper, how) then
			P.Print(("Counted %s from %s for |cffffffff%s|r automatically. Remove on the Funds tab undoes it."):format(
				P.MoneyIcons(copper), P.ShortName(name), f.title))
			return
		end
	end
	-- 3. Otherwise, ask.
	tinsert(waiting, { fund = f.id, name = name, copper = copper, how = how })
	if not asking then AskNext() end
end

---------------------------------------------------------------------------
-- The donor's side: fill in the gold of a pledge when the trade or the mail
-- to the keeper is open, so paying is one click.
---------------------------------------------------------------------------
--- This character's pledges still waiting, with their funds: { { pledge, fund }, ... }
local function MyWaiting()
	local list = {}
	for _, p in pairs(P.db.pledges) do
		local f = P.db.funds[p.fund]
		if p.state == "P" and p.from == P.me and f and not f.deleted and not f.closed then tinsert(list, { p, f }) end
	end
	table.sort(list, function(a, b) return a[1].created < b[1].created end)
	return list
end

local function FillTrade(partner)
	local sum, titles = 0, {}
	for _, w in ipairs(MyWaiting()) do
		if w[2].collector == partner then
			sum = sum + w[1].copper
			tinsert(titles, w[2].title)
		end
	end
	if sum == 0 or sum > GetMoney() then return end
	local ok = MoneyInputFrame_SetCopper and TradePlayerInputMoneyFrame
		and pcall(MoneyInputFrame_SetCopper, TradePlayerInputMoneyFrame, sum)
	P.Print(("You pledged %s for %s.%s"):format(P.MoneyIcons(sum), table.concat(titles, ", "),
		ok and " The amount is filled in; check it and press Trade." or " Put that amount in the trade."))
end

local declinedMail = {}

local function PrepareMail(p, f)
	local ok = pcall(function()
		if MailFrameTab_OnClick then MailFrameTab_OnClick(nil, 2) end
		SendMailNameEditBox:SetText(P.FOREVER and P.ShortName(f.collector) or f.collector)
		SendMailSubjectEditBox:SetText(f.title)
		MoneyInputFrame_SetCopper(SendMailMoney, p.copper)
	end)
	P.Print(ok and ("Mail to %s prepared with %s. Check it and press Send."):format(P.ShortName(f.collector), P.MoneyIcons(p.copper))
		or ("Could not prepare the mail. Send %s to %s yourself."):format(P.MoneyIcons(p.copper), P.ShortName(f.collector)))
end

StaticPopupDialogs["POOR_PLEDGE_MAIL"] = {
	text = "%s",
	button1 = YES,
	button2 = NO,
	OnAccept = function(_, data) PrepareMail(data[1], data[2]) end,
	OnCancel = function(_, data) declinedMail[data[1].id] = true end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

local function OfferMail()
	for _, w in ipairs(MyWaiting()) do
		local p, f = w[1], w[2]
		if not declinedMail[p.id] and p.copper <= GetMoney() then
			local dialog = StaticPopup_Show("POOR_PLEDGE_MAIL", ("You pledged %s to \"%s\".\nPrepare the mail to %s now?"):format(
				P.MoneyIcons(p.copper), f.title, P.ShortName(f.collector)))
			if dialog then dialog.data = w end
			return
		end
	end
end

-- Trade: remember who and how much while the window is open; the gold only
-- counts once the client says the trade completed.
local tradePartner, tradeMoney

local function ReadTrade()
	local money = GetTargetTradeMoney and GetTargetTradeMoney()
	if P.Readable(money) then tradeMoney = tonumber(money) or 0 end
end

-- Mail: Blizzard's "take money" and "open all" both end in one of these two
-- calls; the mail's header is still readable right after.
local lastMail = {}

local function MailTaken(index)
	if not GetInboxHeaderInfo then return end
	local _, _, sender, _, money = GetInboxHeaderInfo(index)
	if not (P.Readable(sender) and P.Readable(money)) or not sender or not money or money <= 0 then return end
	local full = P.FullName(sender)
	if not full or not P.members[full] then return end -- guildmates only: no auction house or vendor mail
	local key = full .. ":" .. money
	if lastMail[key] and GetTime() - lastMail[key] < 3 then return end -- both hooks can fire for one mail
	lastMail[key] = GetTime()
	OnReceived(full, money, "M")
end

if TakeInboxMoney then hooksecurefunc("TakeInboxMoney", MailTaken) end
if AutoLootMailItem then hooksecurefunc("AutoLootMailItem", MailTaken) end

local frame = CreateFrame("Frame")
frame:RegisterEvent("TRADE_SHOW")
frame:RegisterEvent("TRADE_MONEY_CHANGED")
frame:RegisterEvent("TRADE_ACCEPT_UPDATE")
frame:RegisterEvent("UI_INFO_MESSAGE")
frame:RegisterEvent("MAIL_SHOW")
frame:SetScript("OnEvent", function(_, event, _, message)
	if event == "MAIL_SHOW" then
		if P.started then OfferMail() end
	elseif event == "TRADE_SHOW" then
		tradeMoney = 0
		tradePartner = P.UnitFullName("NPC")
		if P.started and tradePartner then pcall(FillTrade, tradePartner) end
	elseif event == "TRADE_MONEY_CHANGED" or event == "TRADE_ACCEPT_UPDATE" then
		ReadTrade()
	elseif event == "UI_INFO_MESSAGE" then
		if tradePartner and P.Readable(message) and message == ERR_TRADE_COMPLETE then
			OnReceived(tradePartner, tradeMoney, "T")
			tradePartner, tradeMoney = nil, 0
		end
	end
end)
