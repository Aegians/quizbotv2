--[[
    QuizBot v3 Module: Spotify Integration
    Controls Spotify via Web API using OAuth token.
    Registers: /play, /pause, /skip, /prev, /np, /vol, /shuffle, /loop
]]
local ctx = ...

local HttpService = ctx.HttpService

----------------------------------------------------------------
-- Spotify API Helpers
----------------------------------------------------------------
local function base64Encode(input)
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local output = {}
    local buffer = 0
    local bits = 0

    for i = 1, #input do
        buffer = buffer * 256 + string.byte(input, i)
        bits += 8
        while bits >= 6 do
            bits -= 6
            local index = math.floor(buffer / (2 ^ bits)) % 64
            table.insert(output, string.sub(chars, index + 1, index + 1))
        end
    end

    if bits > 0 then
        local index = (buffer * (2 ^ (6 - bits))) % 64
        table.insert(output, string.sub(chars, index + 1, index + 1))
    end

    while (#output % 4) ~= 0 do
        table.insert(output, "=")
    end

    return table.concat(output)
end

local function formEncode(data)
    local parts = {}
    for key, value in pairs(data) do
        table.insert(parts, HttpService:UrlEncode(key) .. "=" .. HttpService:UrlEncode(value))
    end
    return table.concat(parts, "&")
end

local function refreshSpotifyToken()
    if not ctx.settings.spotifyClientId
    or not ctx.settings.spotifyClientSecret
    or not ctx.settings.spotifyRefreshToken then
        return false
    end

    local ok, response = pcall(request, {
        Url = "https://accounts.spotify.com/api/token",
        Method = "POST",
        Headers = {
            ["Authorization"] = "Basic " .. base64Encode(ctx.settings.spotifyClientId .. ":" .. ctx.settings.spotifyClientSecret),
            ["Content-Type"] = "application/x-www-form-urlencoded",
        },
        Body = formEncode({
            grant_type = "refresh_token",
            refresh_token = ctx.settings.spotifyRefreshToken,
        }),
    })

    if not ok then
        ctx.consoleErr("Spotify token refresh failed: " .. tostring(response))
        return false
    end

    local data = nil
    if response.Body and #response.Body > 0 then
        local decodeOk, decoded = pcall(function()
            return HttpService:JSONDecode(response.Body)
        end)
        if decodeOk then data = decoded end
    end

    if response.StatusCode < 200 or response.StatusCode >= 300 then
        local message = data and (data.error_description or data.error) or tostring(response.StatusCode)
        ctx.consoleWarn("Spotify token refresh rejected: " .. tostring(message))
        return false
    end

    if not data or not data.access_token then
        ctx.consoleWarn("Spotify token refresh response had no access token")
        return false
    end

    ctx.settings.spotifyToken = data.access_token
    ctx.settings.spotifyTokenExpiresAt = tick() + math.max((data.expires_in or 3600) - 60, 60)

    if data.refresh_token and data.refresh_token ~= ctx.settings.spotifyRefreshToken then
        ctx.saveSpotifyAuth(ctx.settings.spotifyClientId, ctx.settings.spotifyClientSecret, data.refresh_token)
    end

    ctx.consoleLog("Spotify access token refreshed")
    return true
end

local function ensureSpotifyToken()
    if not ctx.settings.spotifyToken then
        if not refreshSpotifyToken() then
            ctx.consoleWarn("No Spotify token. Use /settoken <token> or /setspotifyauth <client_id> <client_secret> <refresh_token>")
            return false
        end
    elseif ctx.settings.spotifyTokenExpiresAt and tick() >= ctx.settings.spotifyTokenExpiresAt then
        refreshSpotifyToken()
    end

    return true
end

local function spotifyRequest(endpoint, method, body, retried)
    if not ensureSpotifyToken() then return nil end

    method = method and method:upper() or "GET"

    local reqData = {
        Url = "https://api.spotify.com/v1/" .. endpoint,
        Method = method,
        Headers = {
            ["Authorization"] = "Bearer " .. ctx.settings.spotifyToken,
            ["Content-Type"] = "application/json",
        },
    }
    -- PUT/POST need a body or some APIs reject
    if method == "POST" or method == "PUT" then
        -- Pass an explicit body (e.g. play-by-URI) or an empty string
        reqData.Body = body and HttpService:JSONEncode(body) or ""
    end

    local ok, response = pcall(request, reqData)
    if not ok then
        ctx.consoleErr("Spotify request failed: " .. tostring(response))
        return nil
    end

    if response.StatusCode == 401 then
        if not retried and refreshSpotifyToken() then
            return spotifyRequest(endpoint, method, body, true)
        end

        -- Console-acquired tokens can't be auto-refreshed (no refresh_token),
        -- so the user must re-run /settoken. Debounce so we warn at most once
        -- every 30s instead of on every poll.
        local now = tick()
        if not ctx._spotify401At or (now - ctx._spotify401At) > 30 then
            ctx._spotify401At = now
            ctx.consoleWarn("Spotify token expired. Use /settoken <token> to update.")
            ctx.BotChat("⚠️ | Spotify token expired - refresh with /settoken")
        end
        return nil
    end

    if response.Body and #response.Body > 0 then
        local decodeOk, data = pcall(function()
            return HttpService:JSONDecode(response.Body)
        end)
        if decodeOk then
            if data and data.error then
                ctx.consoleWarn("Spotify error: " .. (data.error.message or "unknown"))
                return nil
            end
            return data
        end
    end

    return response.StatusCode >= 200 and response.StatusCode < 300
end

----------------------------------------------------------------
-- Playback Controls
----------------------------------------------------------------
local function spotifyPlay()
    return spotifyRequest("me/player/play", "PUT")
end

local function spotifyPause()
    return spotifyRequest("me/player/pause", "PUT")
end

local function spotifyNext()
    return spotifyRequest("me/player/next", "POST")
end

local function spotifyPrev()
    return spotifyRequest("me/player/previous", "POST")
end

local function spotifyShuffle(enabled)
    return spotifyRequest("me/player/shuffle?state=" .. tostring(enabled), "PUT")
end

local function spotifyRepeat(state)
    return spotifyRequest("me/player/repeat?state=" .. state, "PUT")
end

local function spotifyVolume(percent)
    return spotifyRequest("me/player/volume?volume_percent=" .. percent, "PUT")
end

----------------------------------------------------------------
-- Device Check
-- Playback needs an active device. This returns the active
-- device (or the first available one) so we can fail loudly.
----------------------------------------------------------------
local function getActiveDevice()
    local data = spotifyRequest("me/player/devices")
    if not data or type(data) ~= "table" or not data.devices then return nil end
    local firstDevice = nil
    for _, dev in ipairs(data.devices) do
        firstDevice = firstDevice or dev
        if dev.is_active then return dev end
    end
    return firstDevice  -- no active one, but return something to target
end

----------------------------------------------------------------
-- Search
-- Resolves a text query into a track URI.
----------------------------------------------------------------
local function searchTrack(query)
    -- URL-encode the query
    local encoded = HttpService:UrlEncode(query)
    local data = spotifyRequest("search?q=" .. encoded .. "&type=track&limit=1")
    if not data or type(data) ~= "table" then return nil end
    if not data.tracks or not data.tracks.items or #data.tracks.items == 0 then
        return nil
    end

    local track = data.tracks.items[1]
    local artists = {}
    for _, a in ipairs(track.artists or {}) do
        table.insert(artists, a.name)
    end

    return {
        uri = track.uri,
        name = track.name,
        artists = table.concat(artists, ", "),
    }
end

----------------------------------------------------------------
-- Play by URI
-- Starts playback of a specific track. Optionally targets a
-- device. Returns true on success.
----------------------------------------------------------------
local function playTrackURI(uri, deviceId)
    local endpoint = "me/player/play"
    if deviceId then
        endpoint = endpoint .. "?device_id=" .. deviceId
    end
    return spotifyRequest(endpoint, "PUT", { uris = { uri } })
end

----------------------------------------------------------------
-- Now Playing
----------------------------------------------------------------
local function getNowPlaying()
    local data = spotifyRequest("me/player/currently-playing")
    if not data or type(data) ~= "table" or not data.item then return nil end

    local artists = {}
    if data.item.artists then
        for _, a in ipairs(data.item.artists) do
            table.insert(artists, a.name)
        end
    end

    return {
        name = data.item.name,
        artists = table.concat(artists, ", "),
        album = data.item.album and data.item.album.name or "Unknown",
        playing = data.is_playing,
        progressMs = data.progress_ms,
        durationMs = data.item.duration_ms,
        albumId = data.item.album and data.item.album.id,
    }
end

local function formatMs(ms)
    local totalSec = math.floor(ms / 1000)
    local mins = math.floor(totalSec / 60)
    local secs = totalSec % 60
    return string.format("%d:%02d", mins, secs)
end

----------------------------------------------------------------
-- Album Art Caching (via getcustomasset)
----------------------------------------------------------------
local function cacheAlbumArt(track)
    if not getcustomasset or not track.albumId then return end
    -- Could implement album art caching similar to zzerexx's Spotify player
    -- Skipping for now to save registers
end

----------------------------------------------------------------
-- Register Commands
----------------------------------------------------------------

ctx.registerCommand({
    aliases = {"play", "resume", "p"},
    args = "[song name]",
    info = "Play a song by name, or resume if no name given",
    category = "Spotify",
    fn = function(args)
        -- No query -> just resume current playback
        if args == "" then
            local result = spotifyPlay()
            if result then
                task.wait(0.5)
                local np = getNowPlaying()
                if np then
                    ctx.BotChat("▶️ | " .. np.name .. " - " .. np.artists)
                else
                    ctx.BotChat("▶️ | Resumed playback")
                end
            end
            return
        end

        -- Query given -> search then play by URI
        -- Verify there's a device to play on first (clearer error)
        local device = getActiveDevice()
        if not device then
            ctx.BotChat("❌ | No active Spotify device. Open Spotify on your PC/phone first.")
            return
        end

        ctx.BotChat("🔍 | Searching: " .. args)
        local track = searchTrack(args)
        if not track then
            ctx.BotChat("❌ | No results for: " .. args)
            return
        end

        local ok = playTrackURI(track.uri, device.id)
        if ok then
            ctx.BotChat("🎵 | Now Playing: " .. track.name .. " - " .. track.artists)
        else
            ctx.BotChat("❌ | Failed to start playback (Premium + active device required)")
        end
    end,
})

-- /queue - add a searched track to the up-next queue instead of playing now
ctx.registerCommand({
    aliases = {"queue", "q", "addqueue"},
    args = "<song name>",
    info = "Add a song to the Spotify queue",
    category = "Spotify",
    permission = "all",
    fn = function(args)
        if args == "" then
            ctx.consoleWarn("Usage: /queue <song name>")
            return
        end
        local track = searchTrack(args)
        if not track then
            ctx.BotChat("❌ | No results for: " .. args)
            return
        end
        local encoded = HttpService:UrlEncode(track.uri)
        local ok = spotifyRequest("me/player/queue?uri=" .. encoded, "POST")
        if ok then
            ctx.BotChat("➕ | Queued: " .. track.name .. " - " .. track.artists)
        else
            ctx.BotChat("❌ | Failed to queue")
        end
    end,
})

-- /devices - list available Spotify Connect devices
ctx.registerCommand({
    aliases = {"devices", "dev"},
    info = "List available Spotify devices",
    category = "Spotify",
    fn = function()
        local data = spotifyRequest("me/player/devices")
        if not data or type(data) ~= "table" or not data.devices or #data.devices == 0 then
            ctx.BotChat("🔇 | No Spotify devices found. Open Spotify somewhere.")
            return
        end
        rconsoleprint("\n=== Spotify Devices ===\n")
        for i, dev in ipairs(data.devices) do
            local active = dev.is_active and " [ACTIVE]" or ""
            rconsoleprint("  " .. i .. ". " .. dev.name .. " (" .. dev.type .. ")" .. active .. "\n")
        end
        rconsoleprint("=======================\n\n")
        ctx.BotChat("🔊 | " .. #data.devices .. " device(s) available")
    end,
})

ctx.registerCommand({
    aliases = {"pause", "stop"},
    info = "Pause Spotify playback",
    category = "Spotify",
    fn = function()
        spotifyPause()
        ctx.BotChat("⏸️ | Paused")
    end,
})

ctx.registerCommand({
    aliases = {"skip", "next", "sk"},
    info = "Skip to next track",
    category = "Spotify",
    fn = function()
        spotifyNext()
        task.wait(0.5)
        local np = getNowPlaying()
        if np then
            ctx.BotChat("⏭️ | " .. np.name .. " - " .. np.artists)
        else
            ctx.BotChat("⏭️ | Skipped")
        end
    end,
})

ctx.registerCommand({
    aliases = {"prev", "previous", "back"},
    info = "Previous track",
    category = "Spotify",
    fn = function()
        spotifyPrev()
        task.wait(0.5)
        local np = getNowPlaying()
        if np then
            ctx.BotChat("⏮️ | " .. np.name .. " - " .. np.artists)
        else
            ctx.BotChat("⏮️ | Previous track")
        end
    end,
})

ctx.registerCommand({
    aliases = {"np", "nowplaying", "song", "track"},
    info = "Show currently playing track",
    category = "Spotify",
    fn = function()
        local np = getNowPlaying()
        if not np then
            ctx.BotChat("🔇 | Nothing playing (or token expired)")
            return
        end
        local status = np.playing and "▶️" or "⏸️"
        local progress = formatMs(np.progressMs) .. "/" .. formatMs(np.durationMs)
        ctx.BotChat(status .. " | " .. np.name .. " - " .. np.artists .. " [" .. progress .. "]")
    end,
})

ctx.registerCommand({
    aliases = {"vol", "volume"},
    args = "<0-100>",
    info = "Set Spotify volume",
    category = "Spotify",
    fn = function(args)
        local vol = tonumber(args)
        if not vol or vol < 0 or vol > 100 then
            ctx.consoleWarn("Usage: /vol <0-100>")
            return
        end
        spotifyVolume(math.floor(vol))
        ctx.BotChat("🔊 | Volume: " .. math.floor(vol) .. "%")
    end,
})

ctx.registerCommand({
    aliases = {"shuffle", "shuf"},
    info = "Toggle Spotify shuffle",
    category = "Spotify",
    fn = function()
        -- Get current state first
        local state = spotifyRequest("me/player")
        if state and type(state) == "table" then
            local newState = not state.shuffle_state
            spotifyShuffle(newState)
            ctx.BotChat("🔀 | Shuffle: " .. (newState and "ON" or "OFF"))
        end
    end,
})

ctx.registerCommand({
    aliases = {"loop", "repeat"},
    info = "Cycle repeat mode (off → track → context)",
    category = "Spotify",
    fn = function()
        local state = spotifyRequest("me/player")
        if state and type(state) == "table" then
            local current = state.repeat_state or "off"
            local next_state
            if current == "off" then next_state = "track"
            elseif current == "track" then next_state = "context"
            else next_state = "off" end
            spotifyRepeat(next_state)
            ctx.BotChat("🔁 | Repeat: " .. next_state)
        end
    end,
})
