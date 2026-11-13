-- poor -- Blobs.lua
-- Sync for bulky data (a bank character's inventory, a crafter's recipes).
-- These are too big to resend at every login, so they travel on request:
--
--   N^key=ts,key=ts,...      index: what a client holds (part of the login sync)
--   W^key,key,...            want: "I lack these, or mine are older"
--   L^key^ts^i^n^tokens      one of n pieces of a blob; tokens joined by ","
--
--   db.blobs[key] = { ts = n, tokens = { ... } }     an empty list is a tombstone
--   key: "K:Name-Realm" (bank contents) or "R:Name-Realm:Profession" (recipes)
local _, P = ...

local MAX_LEN = 240

function P.GetBlob(key)
	return P.db.blobs[key]
end

function P.BlobOwner(key)
	return key:match("^%a:([^:]+)")
end

local function Lines(key, blob)
	local head = ("L^%s^%d^"):format(key, blob.ts)
	local room = MAX_LEN - #head - 8 -- "ii^nn^"
	local chunks, line = {}, ""
	for _, token in ipairs(blob.tokens) do
		if line ~= "" and #line + #token + 1 > room then
			tinsert(chunks, line)
			line = ""
		end
		line = line .. (line == "" and "" or ",") .. token
	end
	if line ~= "" or #chunks == 0 then tinsert(chunks, line) end
	for i, chunk in ipairs(chunks) do
		chunks[i] = ("%s%d^%d^%s"):format(head, i, #chunks, chunk)
	end
	return chunks
end

--- Publish this character's own data. Returns false when nothing changed.
function P.SetBlob(key, tokens)
	local old = P.db.blobs[key]
	if old and table.concat(old.tokens, ",") == table.concat(tokens, ",") then return false end
	if not old and #tokens == 0 then return false end
	local blob = { ts = math.max(P.Now(), old and old.ts + 1 or 0), tokens = tokens }
	P.db.blobs[key] = blob
	for _, line in ipairs(Lines(key, blob)) do P.Send(line) end
	P.Fire("Blob", key)
	return true
end

-- Index -------------------------------------------------------------------
tinsert(P.syncers, function()
	P.Send(function()
		local parts = {}
		for key, blob in pairs(P.db.blobs) do
			if P.HeardVersion("N" .. key) < blob.ts then tinsert(parts, ("%s=%d"):format(key, blob.ts)) end
		end
		return P.Chunks("N^", parts)
	end)
end)

local want, wantTimer = {}, false

local function SendWants()
	wantTimer = false
	local parts = {}
	for key, ts in pairs(want) do
		local mine = P.db.blobs[key]
		-- Skip what arrived, or what someone else already asked for, meanwhile.
		if (not mine or mine.ts < ts) and P.HeardVersion("W" .. key) < 1 and P.HeardVersion("L" .. key) < ts then
			tinsert(parts, key)
		end
	end
	want = {}
	P.SendChunked("W^", parts)
end

P.handlers.N = function(_, packed)
	if not packed then return end
	for key, ts in packed:gmatch("([^=,]+)=(%d+)") do
		ts = tonumber(ts)
		P.Hear("N" .. key, ts)
		local mine = P.db.blobs[key]
		if not mine or mine.ts < ts then
			want[key] = math.max(want[key] or 0, ts)
			if not wantTimer then
				wantTimer = true
				C_Timer.After(2 + math.random() * 3, SendWants)
			end
		end
	end
end

-- Requests ----------------------------------------------------------------
P.handlers.W = function(_, packed)
	if not packed then return end
	for key in packed:gmatch("[^,]+") do
		P.Hear("W" .. key, 1)
		local blob = P.db.blobs[key]
		if blob then
			C_Timer.After(1 + math.random() * 3, function()
				P.Send(function()
					local now = P.db.blobs[key]
					if now and P.HeardVersion("L" .. key) < now.ts then return Lines(key, now) end
				end)
			end)
		end
	end
end

-- Pieces ------------------------------------------------------------------
local partial = {}

P.handlers.L = function(_, key, ts, i, n, packed)
	ts, i, n = tonumber(ts), tonumber(i), tonumber(n)
	if not key or key == "" or not ts or not i or not n or n < 1 or n > 200 or i < 1 or i > n then return end
	P.Hear("L" .. key, ts)
	local mine = P.db.blobs[key]
	if mine and mine.ts >= ts then return end
	local p = partial[key]
	if not p or p.ts ~= ts or p.n ~= n then
		p = { ts = ts, n = n, got = 0, parts = {} }
		partial[key] = p
	end
	if not p.parts[i] then
		p.parts[i] = packed or ""
		p.got = p.got + 1
	end
	if p.got < n then return end
	partial[key] = nil
	local tokens = {}
	for index = 1, n do
		for token in p.parts[index]:gmatch("[^,]+") do tinsert(tokens, token) end
	end
	P.db.blobs[key] = { ts = ts, tokens = tokens }
	P.Fire("Blob", key)
end

-- Data of characters that left the guild goes with them; old tombstones too.
P.On("Roster", function()
	local cutoff = P.Now() - 30 * 86400
	for key, blob in pairs(P.db.blobs) do
		local owner = P.BlobOwner(key)
		if (owner and not P.members[owner] and owner ~= P.me) or (#blob.tokens == 0 and blob.ts < cutoff) then
			P.db.blobs[key] = nil
		end
	end
end)
