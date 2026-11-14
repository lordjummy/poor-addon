-- poor -- Ding.lua
-- Level-ups: a song for your own and "Ding BTW <level>" in guild chat, a
-- short ding and a chat line for a guildmate's.
--
-- The song is Sounds/levelup.mp3 inside the addon folder. Without that file
-- nothing extra plays for your own level (the game's own sound still does).
-- Guildmates' levels come from the guild roster, so every member counts, with
-- or without the addon; the roster can be some seconds behind.
local _, P = ...

local SONG = "Interface\\AddOns\\Poor\\Sounds\\levelup.mp3"
local GUILD_DING = 3175 -- the map ping: short, and not a sound the game uses for chat

--- Play the level-up song. False when the file is not there.
function P.PlayLevelSong()
	if not PlaySoundFile then return false end
	local ok, played = pcall(PlaySoundFile, SONG, "Master")
	return ok and played and true or false
end

-- What a level-up says in guild chat. Other clients recognise the line, so
-- keep the words in step with DING_PATTERN.
local DING_TEXT, DING_PATTERN = "Ding BTW %d", "^Ding BTW (%d+)"
local said = {} -- member -> when their "Ding BTW" line was seen in guild chat

local function GuildDing()
	-- Quiet in dungeons and raids: a ding mid-pull helps nobody.
	if IsInInstance and IsInInstance() then return end
	PlaySound((SOUNDKIT and SOUNDKIT.MAP_PING) or GUILD_DING)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterEvent("CHAT_MSG_GUILD")
frame:SetScript("OnEvent", function(_, event, a, b)
	if not P.started then return end
	if event == "PLAYER_LEVEL_UP" then
		if P.db.opts.levelSong then P.PlayLevelSong() end
		local level = P.Readable(a) and tonumber(a) or nil
		if P.db.opts.dingChat and level
			and not (C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()) then
			P.SayGuild(DING_TEXT:format(level))
		end
	elseif P.Readable(a) and P.Readable(b) and a:find(DING_PATTERN) then
		-- A guildmate's own announcement: the line is already in chat, so
		-- only the ding is added, and the roster's later news is dropped.
		local name = P.FullName(b)
		if not name or name == P.me then return end
		said[name] = GetTime()
		if P.db.opts.guildDing then GuildDing() end
	end
end)

-- The first roster pass of a session compares against levels stored at the
-- last logout: those are not dings, they happened while this client was away.
local live = false

P.On("LevelUp", function(name, level, class, online)
	if not live or not online or name == P.me or P.Syncing() then return end
	if not P.db.opts.guildDing then return end
	if said[name] and GetTime() - said[name] < 300 then return end -- they said so themselves
	-- Reaching the top level is the race's news; it says so itself.
	if level >= P.MAX_LEVEL then return end
	P.Print(("%s reached level %d."):format(P.ClassColored(P.ShortName(name), class), level))
	GuildDing()
end)

P.On("Roster", function() live = true end)
