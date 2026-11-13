-- poor -- Alts.lua
-- Linking characters to a main, so the leaderboard, the hall of shame and
-- fund donors can count a person once.
--
--   db.mains[char] = { main = "Name-Realm", ts = n }   main == char: "this is a main"
--   db.myChars[char] = true                            this account's characters seen by the addon
--
-- Wire (compatible addition): M^char>main@ts,char>main@ts,...   newest ts per char wins
local _, P = ...

function P.MainOf(name)
	local link = P.db.mains[name]
	return (link and link.main) or name
end

--- Characters linked to `main`, itself included, sorted.
function P.CharsOf(main)
	local list, has = { main }, { [main] = true }
	for char, link in pairs(P.db.mains) do
		if link.main == main and not has[char] then
			has[char] = true
			tinsert(list, char)
		end
	end
	table.sort(list)
	return list
end

local function Part(char, link)
	return ("%s>%s@%d"):format(char, link.main, link.ts)
end

--- Declare the main of every character of this account the addon has seen.
--- nil makes each of them its own main again.
function P.SetMyMain(main)
	if main and not (P.db.myChars[main] or P.members[main]) then
		return nil, P.ShortName(main) .. " is not in the guild."
	end
	local parts, now = {}, P.Now()
	local chars = {}
	for char in pairs(P.db.myChars) do chars[char] = true end
	if main then chars[main] = true end
	for char in pairs(chars) do
		local old = P.db.mains[char]
		local link = { main = main or char, ts = math.max(now, old and old.ts + 1 or 0) }
		P.db.mains[char] = link
		tinsert(parts, Part(char, link))
	end
	P.SendChunked("M^", parts)
	P.Fire("Alts")
	return true
end

P.handlers.M = function(_, packed)
	if not packed then return end
	local changed = false
	for char, main, ts in packed:gmatch("([^>,]+)>([^@,]+)@(%d+)") do
		ts = tonumber(ts)
		P.Hear("M" .. char, ts)
		local old = P.db.mains[char]
		if not old or old.ts < ts then
			P.db.mains[char] = { main = main, ts = ts }
			changed = true
		end
	end
	if changed then P.Fire("Alts") end
end

tinsert(P.syncers, function()
	P.Send(function()
		local parts = {}
		for char, link in pairs(P.db.mains) do
			if P.HeardVersion("M" .. char) < link.ts then tinsert(parts, Part(char, link)) end
		end
		return P.Chunks("M^", parts)
	end)
end)

-- Links of characters that left the guild go with them.
P.On("Roster", function()
	for char in pairs(P.db.mains) do
		if not P.members[char] and not P.db.myChars[char] then P.db.mains[char] = nil end
	end
end)
