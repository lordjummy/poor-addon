-- poor -- Ding.lua
-- Level-ups: a song for your own, a short ding and a chat line for a
-- guildmate's.
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

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:SetScript("OnEvent", function()
	if P.started and P.db.opts.levelSong then P.PlayLevelSong() end
end)

-- The first roster pass of a session compares against levels stored at the
-- last logout: those are not dings, they happened while this client was away.
local live = false

P.On("LevelUp", function(name, level, class, online)
	if not live or not online or name == P.me or P.Syncing() then return end
	if not P.db.opts.guildDing then return end
	-- Reaching the top level is the race's news; it says so itself.
	if level >= P.MAX_LEVEL then return end
	P.Print(("%s reached level %d."):format(P.ClassColored(P.ShortName(name), class), level))
	-- Quiet in dungeons and raids: a ding mid-pull helps nobody.
	if IsInInstance and IsInInstance() then return end
	PlaySound((SOUNDKIT and SOUNDKIT.MAP_PING) or GUILD_DING)
end)

P.On("Roster", function() live = true end)
