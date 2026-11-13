-- poor -- Crafts.lua
-- Profession directory: who has which profession at what skill, and who can
-- craft what. Skills are reported like gold. Recipes are read whenever a
-- profession window is open and shared as bulky data (Blobs.lua).
--
--   db.profs[char] = { ts = n, list = { { name, rank, max }, ... } }
--   blob "R:Name-Realm:Profession" = { "i<itemID>" | "s<spellID>", ... }
-- Wire (compatible addition): P^name:rank:max,name:rank:max
local _, P = ...

---------------------------------------------------------------------------
-- Skills
---------------------------------------------------------------------------
-- Reading the character's professions. WoW Forever runs the modern
-- profession system (profession slots, the ProfessionsFrame window and
-- C_TradeSkillUI), not the classic skill list, so that is tried first. The
-- older ways stay as fallbacks for other clients.
local SKILL_LINES = { 164, 165, 171, 182, 186, 197, 202, 333, 393, 755, 129, 185, 356 }
local PROFESSION_SPELLS = { 3273, 2575, 2550, 8613, 9134, 2366, 2018, 7620, 2259, 2108, 3908, 7411, 4036, 25229 }
local ENGLISH = { "First Aid", "Mining", "Cooking", "Skinning", "Herbalism", "Blacksmithing", "Fishing", "Alchemy",
	"Leatherworking", "Tailoring", "Enchanting", "Engineering", "Jewelcrafting" }

local function ProfessionNames()
	local names = {}
	for _, name in ipairs(ENGLISH) do names[name:lower()] = true end
	for _, spell in ipairs(PROFESSION_SPELLS) do
		local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spell)
		if P.Readable(name) and name then names[name:lower()] = true end
	end
	return names
end

local function Collector()
	local list, has = {}, {}
	return list, function(name, rank, max)
		if not (P.Readable(name) and P.Readable(rank) and P.Readable(max)) or type(name) ~= "string" or name == "" then return end
		name = name:gsub("[:,%^=]", "")
		if has[name] then return end
		has[name] = true
		tinsert(list, { name = name, rank = tonumber(rank) or 0, max = tonumber(max) or 0 })
	end
end

-- 1. Profession slots (Forever, retail): two primaries, then the secondaries.
local function FromSlots()
	local list, add = Collector()
	if not (GetProfessions and GetProfessionInfo) then return list end
	local slots = { GetProfessions() }
	for i = 1, select("#", GetProfessions()) do
		if slots[i] then
			local name, _, rank, max = GetProfessionInfo(slots[i])
			add(name, rank, max)
		end
	end
	return list
end

-- 2. Asking for each profession's skill line by its id.
local function FromSkillLineIDs()
	local list, add = Collector()
	if not (C_SkillInfo and C_SkillInfo.GetSkillLineInfoByID) then return list end
	for _, id in ipairs(SKILL_LINES) do
		local info = C_SkillInfo.GetSkillLineInfoByID(id)
		if type(info) == "table" then
			add(info.name or info.skillLineName, info.rank or info.skillLevel, info.maxRank or info.maxSkillLevel)
		end
	end
	return list
end

-- 3. The classic skill list, where professions are picked out by name.
local function FromSkillList()
	local list, add = Collector()
	if not (GetNumSkillLines and GetSkillLineInfo) then return list end
	local wanted = ProfessionNames()
	for i = 1, GetNumSkillLines() or 0 do
		local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(i)
		if P.Readable(name) and name and not isHeader and wanted[name:lower()] then add(name, rank, maxRank) end
	end
	return list
end

local SOURCES = {
	{ "profession slots", FromSlots },
	{ "skill line ids", FromSkillLineIDs },
	{ "classic skill list", FromSkillList },
}

--- The character's professions from the first way of asking that answers,
--- and the name of that way (nil when none did).
local function ReadSkills()
	for _, source in ipairs(SOURCES) do
		local ok, list = pcall(source[2])
		if ok and #list > 0 then return list, source[1] end
	end
	return {}, nil
end

local function Pack(list)
	local parts = {}
	for i, s in ipairs(list) do parts[i] = ("%s:%d:%d"):format(s.name, s.rank, s.max) end
	return table.concat(parts, ",")
end

local function Store(list)
	P.db.profs[P.me] = { ts = P.Now(), list = list }
	P.Report("profs")
	P.Fire("Crafts")
end

local retries = 0
local UpdateSkills

UpdateSkills = function()
	if not P.started then return end
	local list = ReadSkills()
	if #list == 0 and retries < 12 then
		-- Nothing yet: profession data can lag behind login. Look again.
		retries = retries + 1
		C_Timer.After(5, UpdateSkills)
	end
	local old = P.db.profs[P.me]
	local readSomething = #list > 0
	-- Professions only ever learned from an open profession window stay,
	-- in case reading did not show them.
	local found = {}
	for _, s in ipairs(list) do found[s.name] = true end
	for _, s in ipairs(old and old.list or {}) do
		if s.window and not found[s.name] then tinsert(list, s) end
	end
	if #list == 0 and old then return end
	if old and Pack(old.list) == Pack(list) then return end
	-- Recipes of a profession this character dropped are withdrawn, but only
	-- when reading demonstrably works (it found something).
	if readSomething then
		local has = {}
		for _, s in ipairs(list) do has[s.name] = true end
		for key in pairs(P.db.blobs) do
			local owner, prof = key:match("^R:([^:]+):(.+)$")
			if owner == P.me and not has[prof] then P.SetBlob(key, {}) end
		end
	end
	Store(list)
end

--- A profession window is open: that is proof of the profession and its
--- skill, whatever the skill list says.
local function NoteFromWindow(prof, rank, max)
	if not P.started or not P.Readable(prof) or not prof or prof == "" or prof == "UNKNOWN" then return end
	prof = prof:gsub("[:,%^=]", "")
	rank = (P.Readable(rank) and tonumber(rank)) or 0
	max = (P.Readable(max) and tonumber(max)) or 0
	local old = P.db.profs[P.me]
	local list = {}
	for _, s in ipairs(old and old.list or {}) do
		if s.name == prof then
			if s.rank == rank and s.max == max then return end
			list = nil
			s.rank, s.max = rank, max
			return Store(old.list)
		end
		tinsert(list, s)
	end
	tinsert(list, { name = prof, rank = rank, max = max, window = true })
	Store(list)
end

--- Everything needed to see why professions do or do not show; each line goes to out(text).
function P.DebugSkills(out)
	local have = {}
	for _, name in ipairs({ "GetProfessions", "GetProfessionInfo", "GetNumSkillLines", "GetTradeSkillLine", "GetNumCrafts" }) do
		tinsert(have, name .. "=" .. (_G[name] and "yes" or "no"))
	end
	tinsert(have, "C_SkillInfo.GetSkillLineInfoByID=" .. ((C_SkillInfo and C_SkillInfo.GetSkillLineInfoByID) and "yes" or "no"))
	tinsert(have, "C_TradeSkillUI.GetAllRecipeIDs=" .. ((C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs) and "yes" or "no"))
	tinsert(have, "C_TradeSkillUI.GetBaseProfessionInfo=" .. ((C_TradeSkillUI and C_TradeSkillUI.GetBaseProfessionInfo) and "yes" or "no"))
	tinsert(have, "ProfessionsFrame=" .. (ProfessionsFrame and "yes" or "no"))
	tinsert(have, "TradeSkillFrame=" .. (TradeSkillFrame and "yes" or "no"))
	out("Client: " .. table.concat(have, ", "))
	for _, source in ipairs(SOURCES) do
		local ok, list = pcall(source[2])
		out(("Read by %s: %s"):format(source[1], ok and (#list > 0 and Pack(list) or "nothing") or ("error: " .. tostring(list))))
	end
	local mine = P.db.profs[P.me]
	out("Stored for this character: " .. ((mine and #mine.list > 0) and Pack(mine.list) or "nothing"))
	local recipes = {}
	for key, blob in pairs(P.db.blobs) do
		local owner, prof = key:match("^R:([^:]+):(.+)$")
		if owner == P.me then tinsert(recipes, prof .. " " .. #blob.tokens) end
	end
	out("Recipes read from profession windows: " .. (#recipes > 0 and table.concat(recipes, ", ") or "none"))
	out("Last profession window read: " .. (P.lastWindowRead or "never"))
end

P.SelfReport("profs", function()
	local mine = P.db.profs[P.me]
	if not mine or #mine.list == 0 then return nil end
	return "P^" .. Pack(mine.list):sub(1, 236)
end)

P.handlers.P = function(sender, packed)
	if not packed then return end
	local list = {}
	for name, rank, max in packed:gmatch("([^:,]+):(%d+):(%d+)") do
		tinsert(list, { name = name, rank = tonumber(rank), max = tonumber(max) })
	end
	P.db.profs[sender] = { ts = P.Now(), list = list }
	P.Fire("Crafts")
end

--- Rows { char, class, online, prof, rank, max } for every known profession.
function P.ProfessionList()
	local rows = {}
	for char, data in pairs(P.db.profs) do
		local m = P.members[char]
		for _, s in ipairs(data.list) do
			tinsert(rows, { char = char, class = m and m.class, online = m and m.online or char == P.me,
				prof = s.name, rank = s.rank, max = s.max })
		end
	end
	return rows
end

---------------------------------------------------------------------------
-- Recipes
---------------------------------------------------------------------------
local function Token(link)
	if not P.Readable(link) or not link then return nil end
	local item = link:match("item:(%d+)")
	if item then return "i" .. item end
	local spell = link:match("enchant:(%d+)") or link:match("spell:(%d+)")
	return spell and ("s" .. spell) or nil
end

--- Add what the open window lists to this character's recipes of `prof`.
--- A filtered or collapsed window lists only part, so known recipes are kept.
local function Merge(prof, found)
	if not P.started or not P.Readable(prof) or not prof or prof == "" or prof == "UNKNOWN" then return end
	prof = prof:gsub("[:,%^=]", "")
	local key = "R:" .. P.me .. ":" .. prof
	local have, old = {}, P.GetBlob(key)
	for _, token in ipairs(old and old.tokens or {}) do have[token] = true end
	local grew = false
	for token in pairs(found) do
		if not have[token] then
			have[token] = true
			grew = true
		end
	end
	if not grew then return end
	local tokens = {}
	for token in pairs(have) do tinsert(tokens, token) end
	table.sort(tokens)
	P.SetBlob(key, tokens)
end

-- Forever and retail: the ProfessionsFrame window, read through C_TradeSkillUI.
-- Each learned recipe is kept as "s<recipe spell id>".
local function ScanProfessionsFrame()
	local T = C_TradeSkillUI
	if not (T and T.GetAllRecipeIDs and T.GetRecipeInfo and T.GetBaseProfessionInfo) then return end
	-- Someone else's linked profession, or the guild's, is not this character's.
	if (T.IsTradeSkillLinked and T.IsTradeSkillLinked()) or (T.IsTradeSkillGuild and T.IsTradeSkillGuild())
		or (T.IsNPCCrafting and T.IsNPCCrafting()) then
		P.lastWindowRead = "skipped: not this character's own profession"
		return
	end
	local info = T.GetBaseProfessionInfo()
	local prof = type(info) == "table" and (info.professionName or info.parentProfessionName) or nil
	if not P.Readable(prof) or not prof or prof == "" then
		P.lastWindowRead = "no profession reported by the window"
		return
	end
	local found, total, learned = {}, 0, 0
	for _, id in ipairs(T.GetAllRecipeIDs() or {}) do
		total = total + 1
		local recipe = T.GetRecipeInfo(id)
		if type(recipe) == "table" and recipe.learned then
			found["s" .. id] = true
			learned = learned + 1
		end
	end
	P.lastWindowRead = ("%s: %d recipes listed, %d learned"):format(prof, total, learned)
	NoteFromWindow(prof, info.skillLevel, info.maxSkillLevel)
	Merge(prof, found)
end

local function ScanTradeSkill()
	if not (GetNumTradeSkills and GetTradeSkillInfo and GetTradeSkillItemLink and GetTradeSkillLine) then return end
	local found = {}
	for i = 1, GetNumTradeSkills() do
		local _, kind = GetTradeSkillInfo(i)
		if kind ~= "header" then
			local token = Token(GetTradeSkillItemLink(i))
			if token then found[token] = true end
		end
	end
	local prof, rank, max = GetTradeSkillLine()
	NoteFromWindow(prof, rank, max)
	Merge(prof, found)
end

local function ScanCraft() -- enchanting uses the older "craft" window
	if not (GetNumCrafts and GetCraftInfo and GetCraftItemLink and GetCraftDisplaySkillLine) then return end
	local prof, rank, max = GetCraftDisplaySkillLine()
	if not prof then return end -- hunter pet training shares this window
	NoteFromWindow(prof, rank, max)
	local found = {}
	for i = 1, GetNumCrafts() do
		local _, _, kind = GetCraftInfo(i)
		if kind ~= "header" then
			local token = Token(GetCraftItemLink(i))
			if token then found[token] = true end
		end
	end
	Merge(prof, found)
end

--- Display name of a recipe token; nil while the client is still loading it.
local names, asked = {}, {}
function P.TokenName(token)
	if names[token] then return names[token] end
	local kind, id = token:sub(1, 1), tonumber(token:sub(2))
	local name
	if not id then return nil end
	if kind == "i" then
		name = C_Item.GetItemNameByID(id)
		if not name and not asked[token] then
			asked[token] = true
			C_Item.RequestLoadItemDataByID(id)
		end
	elseif C_Spell and C_Spell.GetSpellName then
		name = C_Spell.GetSpellName(id)
		if not name and not asked[token] and C_Spell.RequestLoadSpellData then
			asked[token] = true
			C_Spell.RequestLoadSpellData(id)
		end
	end
	if name and name ~= "" then names[token] = name end
	return names[token]
end

--- Recipes whose name contains `text` (lower case):
--- { { token, name, prof, crafters = { char, ... } }, ... } and how many names are still loading.
function P.FindRecipes(text)
	local byKey, rows, loading = {}, {}, 0
	for key, blob in pairs(P.db.blobs) do
		local owner, prof = key:match("^R:([^:]+):(.+)$")
		if owner then
			for _, token in ipairs(blob.tokens) do
				local name = P.TokenName(token)
				if not name then
					loading = loading + 1
				elseif name:lower():find(text, 1, true) then
					local id = prof .. "\0" .. token
					local row = byKey[id]
					if not row then
						row = { token = token, name = name, prof = prof, crafters = {} }
						byKey[id] = row
						tinsert(rows, row)
					end
					tinsert(row.crafters, owner)
				end
			end
		end
	end
	return rows, loading
end

--- How many recipes each character shared, for the directory: [char][prof] = n
function P.RecipeCounts()
	local counts = {}
	for key, blob in pairs(P.db.blobs) do
		local owner, prof = key:match("^R:([^:]+):(.+)$")
		if owner and #blob.tokens > 0 then
			counts[owner] = counts[owner] or {}
			counts[owner][prof] = #blob.tokens
		end
	end
	return counts
end

P.On("Roster", function()
	for char in pairs(P.db.profs) do
		if not P.members[char] and char ~= P.me then P.db.profs[char] = nil end
	end
end)

local pending = {}
local function Soon(what, fn, delay)
	if pending[what] then return end
	pending[what] = true
	C_Timer.After(delay, function()
		pending[what] = nil
		pcall(fn)
	end)
end

local frame = CreateFrame("Frame")
for _, event in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED",
	"NEW_RECIPE_LEARNED", "CRAFT_SHOW", "CRAFT_UPDATE", "SKILL_LINES_CHANGED", "GET_ITEM_INFO_RECEIVED" }) do
	pcall(frame.RegisterEvent, frame, event) -- an event this client does not know must not stop the rest
end
frame:SetScript("OnEvent", function(_, event)
	if event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_UPDATE" or event == "TRADE_SKILL_LIST_UPDATE"
		or event == "TRADE_SKILL_DATA_SOURCE_CHANGED" or event == "NEW_RECIPE_LEARNED" then
		Soon("trade", function()
			ScanProfessionsFrame()
			ScanTradeSkill()
		end, 1)
		Soon("skills", UpdateSkills, 2)
	elseif event == "CRAFT_SHOW" or event == "CRAFT_UPDATE" then
		Soon("craft", ScanCraft, 1)
	elseif event == "SKILL_LINES_CHANGED" then
		Soon("skills", UpdateSkills, 2)
	elseif event == "GET_ITEM_INFO_RECEIVED" then
		Soon("names", function() P.Fire("Names") end, 0.5)
	end
end)

P.On("Started", function() Soon("skills", UpdateSkills, 6) end)

--- Look at the skill list again (the Crafters tab asks when it opens).
function P.RefreshSkills()
	Soon("skills", UpdateSkills, 0.2)
end
