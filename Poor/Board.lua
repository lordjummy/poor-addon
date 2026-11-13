-- poor -- Board.lua
-- The begging board: ask the guild for gold or materials. Someone offers to
-- help, the asker confirms it arrived, and a loan stays on the ledger until
-- the lender marks it repaid.
--
--   db.board[id] = { id, rev, state, author, helper, created, ts, amount, loan, text }
--   state: "O" open, "C" someone offered, "R" received, "Q" borrower says repaid
--          (waiting for the lender), "P" repaid, "X" deleted
--
-- Wire (compatible addition): B^id^rev^state^author^helper^created^amount^loan^text
local _, P = ...

local DAY = 86400
P.BOARD_TEXT_MAX = 80
local STATES = { O = true, C = true, R = true, Q = true, P = true, X = true }

local function Line(r)
	return ("B^%s^%d^%s^%s^%s^%d^%d^%d^%s"):format(r.id, r.rev, r.state, r.author, r.helper or "",
		r.created, r.amount or 0, r.loan and 1 or 0, r.text)
end

--- An outstanding loan: received, to be paid back, with an amount.
function P.IsDebt(r)
	return (r.state == "R" or r.state == "Q") and r.loan and (r.amount or 0) > 0
end

--- Requests worth showing: open, offered, and unpaid loans. Newest first.
function P.BoardList()
	local list = {}
	for _, r in pairs(P.db.board) do
		if r.state == "O" or r.state == "C" or P.IsDebt(r) then tinsert(list, r) end
	end
	table.sort(list, function(a, b)
		if a.created ~= b.created then return a.created > b.created end
		return a.id > b.id
	end)
	return list
end

--- Who owes whom: { debtor, creditor, copper } summed per pair, largest first.
function P.Debts()
	local pairsSeen, list = {}, {}
	for _, r in pairs(P.db.board) do
		if P.IsDebt(r) and r.helper then
			local key = r.author .. ">" .. r.helper
			local d = pairsSeen[key]
			if not d then
				d = { debtor = r.author, creditor = r.helper, copper = 0 }
				pairsSeen[key] = d
				tinsert(list, d)
			end
			d.copper = d.copper + r.amount
		end
	end
	table.sort(list, function(a, b)
		if a.copper ~= b.copper then return a.copper > b.copper end
		return a.debtor < b.debtor
	end)
	return list
end

function P.PruneBoard()
	local now = P.Now()
	for id, r in pairs(P.db.board) do
		local age = now - (r.ts or r.created)
		local finished = r.state == "X" or r.state == "P" or (r.state == "R" and not P.IsDebt(r))
		if (finished and age > 14 * DAY) or ((r.state == "O" or r.state == "C") and age > 30 * DAY) then
			P.db.board[id] = nil
		end
	end
end

local function Change(id, allowed, change)
	local r = P.db.board[id]
	if not r or not allowed(r) then return nil end
	change(r)
	r.rev, r.ts = r.rev + 1, P.Now()
	P.Send(Line(r))
	P.Fire("Board")
	return r
end

function P.PostRequest(text, amount, loan)
	text = P.Clean(text, P.BOARD_TEXT_MAX)
	if text == "" then return nil, "Say what you need." end
	if loan and (not amount or amount <= 0) then return nil, "A loan needs an amount of gold." end
	local r = { id = ("%x%04x"):format(P.Now(), math.random(0, 0xffff)), rev = 1, state = "O", author = P.me,
		created = P.Now(), ts = P.Now(), amount = amount or 0, loan = loan and true or false, text = text }
	P.db.board[r.id] = r
	P.Send(Line(r))
	P.Fire("Board")
	return r
end

function P.OfferHelp(id)
	return Change(id, function(r) return r.state == "O" and r.author ~= P.me end,
		function(r) r.state, r.helper = "C", P.me end)
end

function P.WithdrawHelp(id)
	return Change(id, function(r) return r.state == "C" and r.helper == P.me end,
		function(r) r.state, r.helper = "O", nil end)
end

function P.MarkReceived(id)
	return Change(id, function(r) return r.state == "C" and r.author == P.me end,
		function(r) r.state = "R" end)
end

function P.MarkRepaid(id)
	return Change(id, function(r) return P.IsDebt(r) and r.helper == P.me end,
		function(r) r.state = "P" end)
end

--- The borrower says the loan is paid back; the lender still confirms it.
function P.ClaimRepaid(id)
	return Change(id, function(r) return r.state == "R" and P.IsDebt(r) and r.author == P.me end,
		function(r) r.state = "Q" end)
end

--- The asker can take a request down until the help has arrived. After that
--- it is a record (and maybe a debt) and only an officer can remove it, which
--- is also how a debt to someone who left the guild gets cleared.
function P.CanDeleteRequest(r)
	if P.AmOfficer() then return true end
	return r.author == P.me and (r.state == "O" or r.state == "C")
end

function P.DeleteRequest(id)
	return Change(id, P.CanDeleteRequest, function(r) r.state = "X" end)
end

local function Describe(r)
	return ("|cffffffff%s|r%s"):format(r.text, (r.amount or 0) > 0 and (" (" .. P.MoneyIcons(r.amount) .. (r.loan and ", loan" or "") .. ")") or "")
end

P.handlers.B = function(_, id, rev, state, author, helper, created, amount, loan, text)
	rev, created, amount = tonumber(rev), tonumber(created), tonumber(amount)
	if not id or id == "" or not rev or not created or not amount or not STATES[state or ""] or not author or not text then return end
	P.Hear("B" .. id, rev)
	local r = P.db.board[id]
	if r and r.rev >= rev then return end
	local before = r and r.state
	r = r or { id = id }
	r.rev, r.state, r.author, r.helper = rev, state, author, helper ~= "" and helper or nil
	r.created, r.amount, r.loan, r.text, r.ts = created, amount, loan == "1", P.Clean(text, P.BOARD_TEXT_MAX), P.Now()
	P.db.board[id] = r
	P.Fire("Board")
	if P.Syncing() or before == state then return end
	if state == "O" and not before then
		if not P.db.opts.boardNotify then return end
		P.Print(("%s is asking: %s. /poor to help."):format(P.ShortName(author), Describe(r)))
	elseif state == "C" and author == P.me then
		P.Print(("%s offers to help with %s."):format(P.ShortName(r.helper or "?"), Describe(r)))
	elseif state == "R" and r.helper == P.me then
		P.Print(("%s received your help with %s.%s"):format(P.ShortName(author), Describe(r),
			P.IsDebt(r) and " It stays on the ledger until you mark it repaid." or ""))
	elseif state == "Q" and r.helper == P.me then
		P.Print(("%s says the loan is paid back: %s. Confirm it on the Board tab."):format(P.ShortName(author), Describe(r)))
	elseif state == "P" and author == P.me then
		P.Print(("%s marked your loan as repaid: %s."):format(P.ShortName(r.helper or "?"), Describe(r)))
	end
end

tinsert(P.syncers, function()
	for id, r in pairs(P.db.board) do
		P.Send(function()
			if P.db.board[id] == r and P.HeardVersion("B" .. id) < r.rev then return Line(r) end
		end)
	end
end)
