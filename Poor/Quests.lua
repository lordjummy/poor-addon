-- poor -- Quests.lua
-- Shared quests: which guildmates have the same quests in their log, so a
-- group quest does not have to be done with strangers.
--
-- Each addon shares the ids of the quests in its character's log as bulky
-- data (Blobs.lua): blob "Q:<character>" = { "<questID>" or "<questID>g", ... }
-- where "g" marks a quest the game suggests a group for. Titles are never
-- sent: a quest only matters to a member who has it too, and their own log
-- has the title.
local _, P = ...

P.myQuests = {} -- [questID] = { title, level, group }, this character's log

--- Read the quest log. Forever and retail first, the classic way as a fallback.
local function ReadLog()
	local mine = {}
	local function add(id, title, level, suggested)
		if not (P.Readable(id) and P.Readable(title)) or type(id) ~= "number" or id <= 0 then return end
		mine[id] = { title = title or ("Quest " .. id), level = (P.Readable(level) and tonumber(level)) or 0,
			group = P.Readable(suggested) and (tonumber(suggested) or 0) > 1 or false }
	end
	if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then
		for i = 1, C_QuestLog.GetNumQuestLogEntries() or 0 do
			local ok, info = pcall(C_QuestLog.GetInfo, i)
			if ok and type(info) == "table" and not info.isHeader and not info.isHidden then
				add(info.questID, info.title, info.level, info.suggestedGroup)
			end
		end
	elseif GetNumQuestLogEntries and GetQuestLogTitle then
		for i = 1, GetNumQuestLogEntries() or 0 do
			local title, level, suggested, isHeader, _, _, _, id = GetQuestLogTitle(i)
			if not isHeader then add(id, title, level, suggested) end
		end
	end
	return mine
end

local function Update()
	if not P.started then return end
	local ok, mine = pcall(ReadLog)
	if not ok then return end
	P.myQuests = mine
	local key = "Q:" .. P.me
	if P.db.opts.shareQuests then
		local tokens = {}
		for id, q in pairs(mine) do tinsert(tokens, id .. (q.group and "g" or "")) end
		table.sort(tokens)
		P.SetBlob(key, tokens)
	elseif P.GetBlob(key) and #P.GetBlob(key).tokens > 0 then
		P.SetBlob(key, {}) -- stopped sharing: withdraw what was shared
	end
	P.Fire("Quests")
end

--- Look at the log again soon (also called when the sharing option changes).
local pending = false
function P.RefreshQuests(delay)
	if pending then return end
	pending = true
	C_Timer.After(delay or 8, function()
		pending = false
		Update()
	end)
end

-- Who else has which quest: [questID] = { name, ... }, from the lists shared.
local index

local function Index()
	if index then return index end
	index = {}
	for key, blob in pairs(P.db.blobs) do
		local owner = key:match("^Q:(.+)$")
		if owner and owner ~= P.me then
			for _, token in ipairs(blob.tokens) do
				local id = tonumber((token:match("^(%d+)g?$")))
				if id then
					index[id] = index[id] or {}
					tinsert(index[id], owner)
				end
			end
		end
	end
	return index
end

P.On("Blob", function(key)
	if type(key) == "string" and key:sub(1, 2) == "Q:" then
		index = nil
		P.Fire("Quests")
	end
end)

local function Online(name)
	local m = P.members[name]
	return m ~= nil and m.online
end

--- This character's quests that a guildmate has too:
--- { id, title, level, group, holders = { name, ... }, online = n }
--- Group quests first, then the ones with most holders online.
function P.SharedQuests()
	local rows, others = {}, Index()
	for id, q in pairs(P.myQuests) do
		local holders = others[id]
		if holders then
			local list, online = {}, 0
			for _, name in ipairs(holders) do
				tinsert(list, name)
				if Online(name) then online = online + 1 end
			end
			table.sort(list, function(a, b)
				if Online(a) ~= Online(b) then return Online(a) end
				return a < b
			end)
			tinsert(rows, { id = id, title = q.title, level = q.level, group = q.group, holders = list, online = online })
		end
	end
	table.sort(rows, function(a, b)
		if a.group ~= b.group then return a.group end
		if a.online ~= b.online then return a.online > b.online end
		return a.title < b.title
	end)
	return rows
end

local frame = CreateFrame("Frame")
for _, event in ipairs({ "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN", "QUEST_LOG_UPDATE" }) do
	pcall(frame.RegisterEvent, frame, event)
end
frame:SetScript("OnEvent", function() P.RefreshQuests() end)

P.On("Started", function() P.RefreshQuests(12) end)
