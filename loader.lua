--[[
    QuizBot v3.0 - Modular Loader
    Entry point. Loads core + all command modules.
    
    Each module receives a shared `ctx` table with:
    - Services (Players, HttpService, etc.)
    - Chat/BotChat functions
    - Command registry (registerCommand, runCommand)
    - Settings, state, and shared utilities
    
    Designed for Volt's 200 local register limit.
    Each module file stays well under budget.
]]

local VERSION = "3.0.0"

-- Guard against double execution
if getgenv().QUIZBOT_V3_RUNNING then
    warn("QuizBot v3 already running!")
    return
end
getgenv().QUIZBOT_V3_RUNNING = true

-- ============================================================
-- DEPLOYMENT CONFIG
-- ============================================================
-- Your GitHub raw base URL. Files live at the repo root on `main`.
-- Format: https://raw.githubusercontent.com/<user>/<repo>/<branch>/
local BASE_URL = "https://raw.githubusercontent.com/Aegians/quizbot-v3/main/"

-- false = load modules from GitHub (deployment)
-- true  = load modules from a local workspace folder (dev/testing)
local USE_LOCAL = false

-- Folder used when USE_LOCAL = true (relative to the executor workspace)
local LOCAL_PATH = "quizbot_v3/"

-- Append a timestamp to GitHub URLs to dodge the ~5 min raw CDN cache.
-- Handy while actively pushing changes; set false for normal use.
local CACHE_BUST = false
-- ============================================================

----------------------------------------------------------------
-- Shared Context Table
-- Every module receives this. All inter-module communication
-- goes through ctx.
----------------------------------------------------------------
local ctx = {}
ctx.VERSION = VERSION
ctx.startTime = tick()

-- Deployment config (exposed so modules like /hop can rebuild the loader call)
ctx.baseUrl = BASE_URL
ctx.useLocal = USE_LOCAL
ctx.localPath = LOCAL_PATH
-- The exact loadstring line that re-runs this bot (used by /hop, /rejoin queueing)
ctx.loaderScript = 'loadstring(game:HttpGet("' .. BASE_URL .. 'loader.lua"))()'

-- Services
ctx.Players           = game:GetService("Players")
ctx.HttpService       = game:GetService("HttpService")
ctx.RunService        = game:GetService("RunService")
ctx.UIS               = game:GetService("UserInputService")
ctx.TextChatService   = game:GetService("TextChatService")
ctx.StarterGui        = game:GetService("StarterGui")
ctx.ReplicatedStorage = game:GetService("ReplicatedStorage")
ctx.PathfindingService = game:GetService("PathfindingService")
ctx.LocalPlayer       = ctx.Players.LocalPlayer

-- Connections for cleanup
ctx.connections = {}
function ctx.track(conn)
    table.insert(ctx.connections, conn)
    return conn
end

----------------------------------------------------------------
-- Shared Player / Character Helpers
-- Used across fly, admin, and quiz modules (avoids duplication)
----------------------------------------------------------------
function ctx.getHRP()
    local char = ctx.LocalPlayer.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

function ctx.getHumanoid()
    local char = ctx.LocalPlayer.Character
    return char and char:FindFirstChildOfClass("Humanoid")
end

function ctx.findPlayer(name)
    if not name or name == "" then return nil end
    name = string.lower(name)
    for _, p in ipairs(ctx.Players:GetPlayers()) do
        if string.lower(p.Name):sub(1, #name) == name
        or string.lower(p.DisplayName):sub(1, #name) == name then
            return p
        end
    end
    return nil
end

function ctx.facePlayer(targetName)
    local target = ctx.Players:FindFirstChild(targetName)
    if not target then
        target = ctx.findPlayer(targetName)
    end
    if target and target.Character and ctx.LocalPlayer.Character then
        local myHRP = ctx.LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        local theirHRP = target.Character:FindFirstChild("HumanoidRootPart")
        if myHRP and theirHRP then
            local lookPos = Vector3.new(theirHRP.Position.X, myHRP.Position.Y, theirHRP.Position.Z)
            myHRP.CFrame = CFrame.lookAt(myHRP.Position, lookPos)
        end
    end
end

function ctx.getPlayerContext()
    local parts = {}
    for _, p in ipairs(ctx.Players:GetPlayers()) do
        table.insert(parts, p.DisplayName .. " (@" .. p.Name .. ")")
    end
    return "Players: " .. table.concat(parts, ", ")
end

-- Settings
ctx.settings = {
    prefix = "!",              -- Command prefix in chat
    consolePrefix = "/",       -- Command prefix in rconsole
    allowedUsers = { ctx.LocalPlayer.Name, "GoDzwolf", "DeezChillaze" },
    chatRadius = 25,
    minMessageCooldown = 2.3,
    
    -- Gemini
    geminiApiKey = nil,        -- Set by user or loaded from file
    modelChat = "gemini-2.5-flash",
    modelQuiz = "gemini-2.5-flash",
    modelTTS  = "gemini-3.1-flash-tts-preview",
    
    -- Spotify
    spotifyToken = nil,
    ttsBridgeUrl = "http://127.0.0.1:8765/say",
    ttsPreferBridge = true,
    
    -- Fly
    flySpeed = 50,
}

-- State
ctx.state = {
    quizRunning = false,
    flying = false,
    following = false,
    followTarget = nil,
    spotifyPlaying = false,
    ttsEnabled = true,
    generationCooldown = false,
}

-- Stats
ctx.stats = {
    messagesSent = 0,
    questionsAsked = 0,
    questionsAnswered = 0,
    aiRequests = 0,
    tokensTotal = 0,
    tokensInput = 0,
    tokensOutput = 0,
    commandsRun = 0,
}

----------------------------------------------------------------
-- Notification Helper
----------------------------------------------------------------
do
    local bindable = Instance.new("BindableFunction")
    function ctx.notify(title, text, duration)
        ctx.StarterGui:SetCore("SendNotification", {
            Title = title,
            Text = text,
            Callback = bindable,
            Duration = duration or 5,
        })
    end
end

----------------------------------------------------------------
-- Console
----------------------------------------------------------------
function ctx.consoleLog(msg)
    rconsoleprint("[LOG] " .. msg .. "\n")
end
function ctx.consoleWarn(msg)
    rconsolewarn("[WARN] " .. msg)
end
function ctx.consoleErr(msg)
    rconsoleerr("[ERR] " .. msg)
end

----------------------------------------------------------------
-- Chat System (RBXGeneral bypass)
----------------------------------------------------------------
do
    local CachedChannel = nil
    local timeSinceLastMessage = 0

    local function FindChannel()
        if CachedChannel then
            local ok = pcall(function() return CachedChannel.Parent end)
            if ok then return CachedChannel end
            CachedChannel = nil
        end

        if getinstances then
            for _, inst in ipairs(getinstances()) do
                if inst.ClassName == "TextChannel" and inst.Name == "RBXGeneral" then
                    CachedChannel = inst
                    return inst
                end
            end
        end

        if getnilinstances then
            for _, inst in ipairs(getnilinstances()) do
                if inst.ClassName == "TextChannel" and inst.Name == "RBXGeneral" then
                    CachedChannel = inst
                    return inst
                end
            end
        end

        if filtergc then
            local funcs = filtergc("function", {Constants = {"RBXGeneral"}, IgnoreExecutor = true})
            for _, func in ipairs(funcs) do
                local ok, ups = pcall(debug.getupvalues, func)
                if ok then
                    for _, v in pairs(ups) do
                        if type(v) == "userdata" then
                            local cn = ""
                            pcall(function() cn = v.ClassName end)
                            if cn == "TextChannel" and v.Name == "RBXGeneral" then
                                CachedChannel = v
                                return v
                            end
                        end
                    end
                end
            end
        end

        local ok, ch = pcall(function()
            return ctx.TextChatService.TextChannels.RBXGeneral
        end)
        if ok and ch then CachedChannel = ch; return ch end
        return nil
    end

    function ctx.Chat(msg)
        local channel = FindChannel()
        if channel then
            local oldId = getthreadidentity and getthreadidentity() or nil
            if setthreadidentity then setthreadidentity(8) end
            local ok = pcall(function() channel:SendAsync(msg) end)
            if oldId and setthreadidentity then setthreadidentity(oldId) end
            if ok then
                ctx.stats.messagesSent += 1
                timeSinceLastMessage = tick()
                return true
            end
        end

        local legacy = ctx.ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
        if legacy then
            local remote = legacy:FindFirstChild("SayMessageRequest")
            if remote then
                pcall(function() remote:FireServer(msg, "All") end)
                ctx.stats.messagesSent += 1
            end
        end
        return false
    end

    function ctx.BotChat(msg)
        msg = string.gsub(msg, "%*%*", "")
        local maxLen = 190
        for i = 1, #msg, maxLen do
            local chunk = string.sub(msg, i, i + maxLen - 1)
            ctx.Chat(chunk)
            if i + maxLen <= #msg then task.wait(0.5) end
        end
    end

    function ctx.canChat()
        return (tick() - timeSinceLastMessage) >= ctx.settings.minMessageCooldown
    end

    function ctx.waitToChat()
        local remaining = ctx.settings.minMessageCooldown - (tick() - timeSinceLastMessage)
        if remaining > 0 then task.wait(remaining) end
    end
end

----------------------------------------------------------------
-- API Key Loading
----------------------------------------------------------------
do
    local KEY_FILE = "quizbot_gemini_key.txt"
    local SPOTIFY_FILE = "quizbot_spotify_token.txt"
    local SPOTIFY_AUTH_FILE = "quizbot_spotify_auth.json"

    local function cleanSecret(value)
        return value and tostring(value):gsub("%s+", "") or nil
    end

    function ctx.loadApiKeys()
        if isfile and isfile(KEY_FILE) then
            ctx.settings.geminiApiKey = readfile(KEY_FILE):gsub("%s+", "")
            ctx.consoleLog("Gemini API key loaded from file")
        end
        if isfile and isfile(SPOTIFY_FILE) then
            ctx.settings.spotifyToken = readfile(SPOTIFY_FILE):gsub("%s+", "")
            ctx.consoleLog("Spotify token loaded from file")
        end
        if isfile and isfile(SPOTIFY_AUTH_FILE) then
            local ok, data = pcall(function()
                return ctx.HttpService:JSONDecode(readfile(SPOTIFY_AUTH_FILE))
            end)
            if ok and type(data) == "table" then
                ctx.settings.spotifyClientId = cleanSecret(data.clientId)
                ctx.settings.spotifyClientSecret = cleanSecret(data.clientSecret)
                ctx.settings.spotifyRefreshToken = cleanSecret(data.refreshToken)
                ctx.settings.spotifyToken = nil
                ctx.settings.spotifyTokenExpiresAt = nil
                ctx.consoleLog("Spotify refresh auth loaded from file")
            else
                ctx.consoleWarn("Spotify auth file exists but could not be read")
            end
        end
    end

    function ctx.saveGeminiKey(key)
        if writefile then
            writefile(KEY_FILE, key)
            ctx.settings.geminiApiKey = key
        end
    end

    function ctx.saveSpotifyToken(token)
        if writefile then
            writefile(SPOTIFY_FILE, token)
            ctx.settings.spotifyToken = token
        end
    end

    function ctx.saveSpotifyAuth(clientId, clientSecret, refreshToken)
        clientId = cleanSecret(clientId)
        clientSecret = cleanSecret(clientSecret)
        refreshToken = cleanSecret(refreshToken)

        ctx.settings.spotifyClientId = clientId
        ctx.settings.spotifyClientSecret = clientSecret
        ctx.settings.spotifyRefreshToken = refreshToken

        if writefile then
            writefile(SPOTIFY_AUTH_FILE, ctx.HttpService:JSONEncode({
                clientId = clientId,
                clientSecret = clientSecret,
                refreshToken = refreshToken,
            }))
        end
    end
end

----------------------------------------------------------------
-- Command Registry (Nameless Admin inspired)
----------------------------------------------------------------
do
    local commands = {}
    local aliasMap = {}

    function ctx.registerCommand(def)
        --[[
        def = {
            aliases = {"fly", "f"},      -- Command names
            args = "<speed>",            -- Argument hint (optional)
            info = "Toggle CFrame fly",  -- Description
            category = "Movement",       -- Category for /help grouping
            permission = "admin",        -- "admin" or "all"
            fn = function(args, player, rawMessage)
                -- args: string after command name
                -- player: Player who sent it
                -- rawMessage: full original message
            end
        }
        ]]
        def.permission = def.permission or "admin"
        def.category = def.category or "Misc"
        table.insert(commands, def)
        for _, alias in ipairs(def.aliases) do
            aliasMap[string.lower(alias)] = def
        end
    end

    function ctx.runCommand(input, player, source)
        -- source is "console" (local rconsole) or "chat" (broadcast).
        -- Defaults to "chat" so anything unspecified is treated as untrusted.
        source = source or "chat"

        -- Parse prefix + command name
        local prefix = ctx.settings.prefix
        local msg = input

        -- Check if it starts with the chat prefix or console prefix
        if string.sub(msg, 1, #prefix) == prefix then
            msg = string.sub(msg, #prefix + 1)
        elseif string.sub(msg, 1, 1) == "/" then
            msg = string.sub(msg, 2)
        else
            return false
        end

        -- Split into command name and args
        local spacePos = string.find(msg, " ")
        local cmdName, args
        if spacePos then
            cmdName = string.lower(string.sub(msg, 1, spacePos - 1))
            args = string.sub(msg, spacePos + 1)
        else
            cmdName = string.lower(msg)
            args = ""
        end

        local def = aliasMap[cmdName]
        if not def then return false end

        -- Console-only guard: sensitive commands (key/token setters) must
        -- come from the local executor console, never from broadcast chat.
        -- Fail silently so the command name isn't confirmed in chat either.
        if def.consoleOnly and source ~= "console" then
            return false
        end

        -- Permission check
        if def.permission == "admin" then
            local allowed = false
            for _, name in ipairs(ctx.settings.allowedUsers) do
                if player and (player.Name == name or player.DisplayName == name) then
                    allowed = true
                    break
                end
            end
            if not allowed then return false end
        end

        -- Execute
        ctx.stats.commandsRun += 1
        local ok, err = pcall(def.fn, args, player, input, source)
        if not ok then
            ctx.consoleErr("Command '" .. cmdName .. "' error: " .. tostring(err))
        end
        return true
    end

    function ctx.getCommands()
        return commands
    end

    function ctx.getCommandByAlias(alias)
        return aliasMap[string.lower(alias)]
    end
end

----------------------------------------------------------------
-- Gemini API Helper
----------------------------------------------------------------
function ctx.geminiRequest(prompt, model, retryCount, generationConfig)
    if not ctx.settings.geminiApiKey then
        ctx.consoleWarn("No Gemini API key set")
        return nil
    end

    model = model or ctx.settings.modelChat
    ctx.stats.aiRequests += 1

    local url = "https://generativelanguage.googleapis.com/v1beta/models/"
        .. model .. ":generateContent?key=" .. ctx.settings.geminiApiKey

    local payload = {
        contents = {{ parts = {{ text = prompt }} }},
        generationConfig = generationConfig or { maxOutputTokens = 300 },
    }

    local ok, response = pcall(function()
        return request({
            Url = url,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = ctx.HttpService:JSONEncode(payload),
        })
    end)

    if not ok then
        ctx.consoleErr("Gemini request failed: " .. tostring(response))
        return nil
    end

    if response.Success and response.StatusCode == 200 then
        local data = ctx.HttpService:JSONDecode(response.Body)
        -- Track tokens
        if data.usageMetadata then
            ctx.stats.tokensTotal += (data.usageMetadata.totalTokenCount or 0)
            ctx.stats.tokensInput += (data.usageMetadata.promptTokenCount or 0)
            ctx.stats.tokensOutput += (data.usageMetadata.candidatesTokenCount or 0)
        end
        local parsed = nil
        pcall(function() parsed = data.candidates[1].content.parts[1].text end)
        return parsed
    elseif response.StatusCode == 429 then
        retryCount = retryCount or 0
        if retryCount < 1 then
            task.wait(5.5)
            return ctx.geminiRequest(prompt, model, retryCount + 1, generationConfig)
        end
        return nil
    else
        ctx.consoleErr("Gemini API error: " .. tostring(response.StatusCode))
        if response.Body and #response.Body > 0 then
            local okBody, data = pcall(function()
                return ctx.HttpService:JSONDecode(response.Body)
            end)
            if okBody and data and data.error then
                ctx.consoleErr("Gemini API message: " .. tostring(data.error.message or data.error.status or "unknown"))
            else
                ctx.consoleErr("Gemini API body: " .. string.sub(tostring(response.Body), 1, 300))
            end
        end
        return nil
    end
end

----------------------------------------------------------------
-- Module Loader
----------------------------------------------------------------
local function loadModule(name)
    local source

    if USE_LOCAL and readfile then
        -- Load from local file system
        local path = LOCAL_PATH .. name
        if not (isfile and isfile(path)) then
            ctx.consoleWarn("Module not found: " .. path)
            return nil
        end
        local ok, data = pcall(readfile, path)
        if not ok then
            ctx.consoleErr("Read failed for " .. name .. ": " .. tostring(data))
            return nil
        end
        source = data
    else
        -- Load from GitHub (raw)
        local url = BASE_URL .. name
        if CACHE_BUST then
            url = url .. "?v=" .. tostring(math.floor(tick() * 1000))
        end
        local ok, data = pcall(function() return game:HttpGet(url) end)
        if not ok then
            ctx.consoleErr("HttpGet failed for " .. name .. ": " .. tostring(data))
            return nil
        end
        -- Guard against GitHub returning a 404 / error page instead of code
        if not data or #data == 0 or data == "404: Not Found" then
            ctx.consoleErr("Empty/404 response for " .. name .. " (check the repo path)")
            return nil
        end
        source = data
    end

    -- Compile. loadstring returns nil + message on a syntax error.
    local chunk, compileErr = loadstring(source, "=" .. name)
    if not chunk then
        ctx.consoleErr("Compile error in " .. name .. ": " .. tostring(compileErr))
        return nil
    end

    -- Run the module, handing it the shared ctx via varargs.
    local runOk, runResult = pcall(chunk, ctx)
    if not runOk then
        ctx.consoleErr("Module error in " .. name .. ": " .. tostring(runResult))
        return nil
    end

    ctx.consoleLog("Loaded: " .. name)
    return runResult
end

----------------------------------------------------------------
-- Boot Sequence
----------------------------------------------------------------
rconsoleshow()
if rconsolename then rconsolename("QuizBot v" .. VERSION) end

rconsoleprint("============================================\n")
rconsoleprint("  QuizBot v" .. VERSION .. " - Modular Architecture\n")
rconsoleprint("  By GoDzwolf | Built with Claude\n")
rconsoleprint("============================================\n\n")

-- Load API keys
ctx.loadApiKeys()

-- Load modules
local modules = {
    "cmd_help.lua",
    "cmd_fly.lua",
    "cmd_admin.lua",
    "cmd_spotify.lua",
    "cmd_tts.lua",
    "cmd_quiz.lua",
    "cmd_categories.lua",
    "cmd_quizgame.lua",
    "cmd_ui.lua",
}

for _, name in ipairs(modules) do
    loadModule(name)
end

-- Report
local cmdCount = #ctx.getCommands()
ctx.consoleLog("Loaded " .. cmdCount .. " commands across " .. #modules .. " modules")
ctx.consoleLog("Prefix: '" .. ctx.settings.prefix .. "' (chat) | '/' (console)")

if not ctx.settings.geminiApiKey then
    -- First-run: prompt privately in the console (rconsoleinput is local,
    -- never broadcast to chat). Paste the key here and it's saved to a
    -- local file for next time. Press Enter to skip.
    rconsoleprint("\n")
    ctx.consoleWarn("No Gemini API key found.")
    rconsoleprint("Paste your Gemini API key and press Enter (or just Enter to skip): ")
    local entered = rconsoleinput()
    if entered and entered:gsub("%s+", "") ~= "" then
        ctx.saveGeminiKey(entered:gsub("%s+", ""))
        ctx.consoleLog("Gemini key saved. AI + TTS commands are ready.")
    else
        ctx.consoleWarn("Skipped. Set later with /setkey <key> in the console.")
    end
    rconsoleprint("\n")
end

-- Chat listener
local recentChatCommands = {}
local function runChatCommandOnce(message, player)
    if not message or not player then return end
    local key = tostring(player.UserId) .. "|" .. message
    local now = tick()
    if recentChatCommands[key] and (now - recentChatCommands[key]) < 0.75 then
        return
    end
    recentChatCommands[key] = now
    ctx.runCommand(message, player, "chat")
end

ctx.track(ctx.TextChatService.MessageReceived:Connect(function(txt)
    local sender = txt.TextSource
    if not sender then return end
    local plr = ctx.Players:GetPlayerByUserId(sender.UserId)
    if not plr then return end
    runChatCommandOnce(txt.Text, plr)
end))

-- Fallback for games/executors where TextChatService.MessageReceived
-- misses command text. Slash-prefixed chat commands may still be consumed
-- by Roblox before scripts see them, so the reliable in-chat prefix is "!".
local function hookPlayerChat(player)
    if not player or not player.Chatted then return end
    ctx.track(player.Chatted:Connect(function(message)
        runChatCommandOnce(message, player)
    end))
end

for _, player in ipairs(ctx.Players:GetPlayers()) do
    hookPlayerChat(player)
end
ctx.track(ctx.Players.PlayerAdded:Connect(hookPlayerChat))

pcall(function()
    ctx.track(ctx.TextChatService.SendingMessage:Connect(function(txt)
        if txt and txt.Text then
            runChatCommandOnce(txt.Text, ctx.LocalPlayer)
        end
    end))
end)

-- Console input listener
task.spawn(function()
    while getgenv().QUIZBOT_V3_RUNNING do
        local inp = rconsoleinput()
        if inp and inp ~= "" then
            rconsoleprint("> " .. inp .. "\n")
            if not ctx.runCommand("/" .. inp, ctx.LocalPlayer, "console") then
                -- Try with prefix too
                ctx.runCommand(ctx.settings.prefix .. inp, ctx.LocalPlayer, "console")
            end
        end
        task.wait(0.1)
    end
end)

-- Anti-AFK
do
    local GC = getconnections or get_signal_cons
    if GC then
        for _, v in pairs(GC(ctx.LocalPlayer.Idled)) do
            if v.Disable then v:Disable()
            elseif v.Disconnect then v:Disconnect() end
        end
    end
    ctx.consoleLog("Anti-AFK enabled")
end

ctx.notify("QuizBot v" .. VERSION, cmdCount .. " commands loaded. Type !help in chat.")
ctx.consoleLog("QuizBot v" .. VERSION .. " ready.\n")

return ctx
