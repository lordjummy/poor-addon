-- poor -- Bank.lua
-- Bank alt viewer. A character marked as a guild bank shares what it holds
-- (bags always, bank as of the last time the bank window was open) and the
-- whole guild can browse and search it.
--
--   db.bankChars[char] = true                          this character is a guild bank (set on that character)
--   db.bankScan[char]  = { bags = { [itemID] = n }, bank = { [itemID] = n } }
--   blob "K:Name-Realm" = { "itemID:count", ... }      see Blobs.lua
local _, P = ...

local SEND_EVERY = 120 -- seconds between broadcasts while the bags keep changing
local bankOpen, timer, lastSent = false, false, -SEND_EVERY

--- Whether any character, this account's or another member's, is a guild bank.
function P.IsGuildBank(name)
	if P.db.bankChars[name] then return true end
	local blob = P.db.blobs["K:" .. name]
	return blob ~= nil and #blob.tokens > 0
end

function P.IsBankChar(name)
	return P.db.bankChars[name or P.me] and true or false
end

local function CountBag(bag, into)
	local slots = C_Container.GetContainerNumSlots(bag)
	if not P.Readable(slots) or not slots then return end
	for slot = 1, slots do
		local info = C_Container.GetContainerItemInfo(bag, slot)
		if info and P.Readable(info.itemID) and info.itemID then
			into[info.itemID] = (into[info.itemID] or 0) + (info.stackCount or 1)
		end
	end
end

--- The bank's containers: purchased bank tabs on Forever, else the classic
--- bank and its bag slots.
local function BankBags()
	local bags = {}
	if C_Bank and C_Bank.FetchPurchasedBankTabData and Enum.BankType then
		local tabs = C_Bank.FetchPurchasedBankTabData(Enum.BankType.Character)
		for _, tab in ipairs(tabs or {}) do
			if tab.ID then tinsert(bags, tab.ID) end
		end
	end
	if #bags == 0 then
		tinsert(bags, -1)
		for bag = 5, 11 do tinsert(bags, bag) end
	end
	return bags
end

local function Scan()
	local scan = P.db.bankScan[P.me] or { bags = {}, bank = {} }
	P.db.bankScan[P.me] = scan
	scan.bags = {}
	for bag = 0, (NUM_BAG_SLOTS or 4) do CountBag(bag, scan.bags) end
	if bankOpen then
		scan.bank = {}
		for _, bag in ipairs(BankBags()) do CountBag(bag, scan.bank) end
	end
	local total = {}
	for _, part in ipairs({ scan.bags, scan.bank }) do
		for id, n in pairs(part) do total[id] = (total[id] or 0) + n end
	end
	local ids = {}
	for id in pairs(total) do tinsert(ids, id) end
	table.sort(ids)
	local tokens = {}
	for i, id in ipairs(ids) do tokens[i] = id .. ":" .. total[id] end
	return tokens
end

local function Publish()
	timer = false
	if not P.started then return end
	if P.IsBankChar() then
		local ok, tokens = pcall(Scan)
		if ok then
			lastSent = GetTime()
			P.SetBlob("K:" .. P.me, tokens)
		end
	elseif P.GetBlob("K:" .. P.me) then
		P.SetBlob("K:" .. P.me, {}) -- no longer a bank: clear what was shared
	end
end

local function PublishSoon(delay)
	if timer or not P.IsBankChar() then return end
	timer = true
	C_Timer.After(delay or math.max(3, SEND_EVERY - (GetTime() - lastSent)), Publish)
end

function P.SetBankChar(on)
	P.db.bankChars[P.me] = on and true or nil
	if not on then P.db.bankScan[P.me] = nil end
	timer = true
	C_Timer.After(0.5, Publish)
	P.Fire("Blob", "K:" .. P.me)
end

--- Everything the guild's bank characters hold:
--- { { id = itemID, count = n, holders = { [char] = n } }, ... }, and the list of bank characters.
function P.BankItems()
	local byId, list, chars = {}, {}, {}
	for key, blob in pairs(P.db.blobs) do
		local owner = key:match("^K:(.+)$")
		if owner and #blob.tokens > 0 then
			tinsert(chars, { name = owner, ts = blob.ts })
			for _, token in ipairs(blob.tokens) do
				local id, n = token:match("^(%d+):(%d+)$")
				id, n = tonumber(id), tonumber(n)
				if id and n then
					local e = byId[id]
					if not e then
						e = { id = id, count = 0, holders = {} }
						byId[id] = e
						tinsert(list, e)
					end
					e.count = e.count + n
					e.holders[owner] = (e.holders[owner] or 0) + n
				end
			end
		end
	end
	table.sort(chars, function(a, b) return a.name < b.name end)
	return list, chars
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("BANKFRAME_OPENED")
frame:RegisterEvent("BANKFRAME_CLOSED")
frame:RegisterEvent("BAG_UPDATE_DELAYED")
frame:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
frame:SetScript("OnEvent", function(_, event)
	if event == "BANKFRAME_OPENED" then
		bankOpen = true
		PublishSoon(3)
	elseif event == "BANKFRAME_CLOSED" then
		bankOpen = false
	else
		PublishSoon()
	end
end)

-- First share after login, once the bags have loaded.
P.On("Started", function() PublishSoon(20) end)
