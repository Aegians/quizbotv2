--[[
    QuizBot v3 Module: Rayfield UI
    Reintroduces the original quizbot-style UI, wired to the v3 modules.
]]
local ctx = ...

local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")

local selectedCategory = nil
local aiTopic = ""
local selectedVoice = "Aoede"
local selectedTtsMode = "bridge"
local spotifyQuery = ""

local function runConsole(command)
    ctx.runCommand("/" .. command, ctx.LocalPlayer, "console")
end

local function getCategoryNames()
    local names = {}
    local _, order = nil, nil
    if ctx.getQuizCategories then
        _, order = ctx.getQuizCategories()
    end
    if order then
        for _, name in ipairs(order) do
            table.insert(names, name)
        end
    end
    table.sort(names, function(a, b) return string.lower(a) < string.lower(b) end)
    if #names == 0 then
        table.insert(names, "No categories loaded")
    end
    return names
end

local function notify(title, text)
    if ctx.notify then
        ctx.notify(title, text, 4)
    else
        ctx.consoleLog(title .. ": " .. text)
    end
end

local function loadRayfield()
    if setgenv then
        pcall(function()
            getgenv().DISABLE_RAYFIELD_REQUESTS = true
            getgenv().rayfieldCached = true
        end)
    end

    local ok, library = pcall(function()
        return loadstring(game:HttpGet("https://raw.githubusercontent.com/Damian-11/Rayfield/stable/source.lua"))()
    end)
    if not ok or not library then
        ctx.consoleErr("UI failed to load Rayfield: " .. tostring(library))
        return nil
    end
    return library
end

local library = loadRayfield()
if not library then return end

local window = library:CreateWindow({
    Name = "QuizBot v" .. tostring(ctx.VERSION),
    LoadingTitle = "Loading QuizBot...",
    LoadingSubtitle = "v3 modular UI",
    ShowText = "quizbot",
    DisableRayfieldPrompts = true,
    DisableBuildWarnings = true,
})

local function toggleUI(_actionName, inputState)
    if inputState == Enum.UserInputState.Begin then
        library:SetVisibility(not library:IsVisible())
    end
end

if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
    ContextActionService:BindAction("QuizBotToggleUI", toggleUI, true)
end

local mainTab = window:CreateTab("Main", 74002778429106)
mainTab:CreateSection("Category Selection")

local categoryLabel = mainTab:CreateLabel("Selected category: None")
local categoryDropdown

mainTab:CreateInput({
    Name = "Category",
    PlaceholderText = "Type a category name",
    RemoveTextAfterFocusLost = false,
    Callback = function(value)
        if ctx.findQuizCategory then
            local found = ctx.findQuizCategory(value)
            if found then
                selectedCategory = found
                categoryLabel:Set("Selected category: " .. found)
                if categoryDropdown then
                    categoryDropdown:Set({ found })
                end
            end
        end
    end,
})

categoryDropdown = mainTab:CreateDropdown({
    Name = "Category",
    Options = getCategoryNames(),
    CurrentOption = { "Select a category" },
    Callback = function(option)
        selectedCategory = type(option) == "table" and option[1] or option
        if selectedCategory and selectedCategory ~= "No categories loaded" then
            categoryLabel:Set("Selected category: " .. selectedCategory)
        end
    end,
})

mainTab:CreateButton({
    Name = "Refresh category list",
    Callback = function()
        categoryDropdown:Refresh(getCategoryNames())
        notify("Categories", "Category list refreshed")
    end,
})

mainTab:CreateButton({
    Name = "Send category list in chat",
    Callback = function()
        runConsole("categories")
    end,
})

mainTab:CreateSection("AI Quiz Generator")
mainTab:CreateInput({
    Name = "Topic",
    PlaceholderText = "Example: Roblox, Minecraft, music",
    RemoveTextAfterFocusLost = false,
    Callback = function(value)
        aiTopic = value or ""
    end,
})

mainTab:CreateButton({
    Name = "Generate quiz",
    Callback = function()
        if aiTopic == "" then
            notify("Invalid topic", "Enter a topic first")
            return
        end
        runConsole("gen " .. aiTopic)
    end,
})

mainTab:CreateButton({
    Name = "Generate and start quiz",
    Callback = function()
        if aiTopic == "" then
            notify("Invalid topic", "Enter a topic first")
            return
        end
        runConsole("quiz " .. aiTopic)
    end,
})

mainTab:CreateSection("Quiz Controls")
mainTab:CreateButton({
    Name = "Start selected category",
    Callback = function()
        if not selectedCategory or selectedCategory == "No categories loaded" then
            notify("Invalid category", "Select a category first")
            return
        end
        runConsole("start " .. selectedCategory)
    end,
})

mainTab:CreateButton({
    Name = "Start generated quiz",
    Callback = function()
        runConsole("startquiz")
    end,
})

mainTab:CreateButton({
    Name = "Skip current question",
    Callback = function()
        runConsole("skipq")
    end,
})

mainTab:CreateButton({
    Name = "Stop quiz",
    Callback = function()
        runConsole("stopquiz")
    end,
})

mainTab:CreateButton({
    Name = "Show leaderboard",
    Callback = function()
        runConsole("lb")
    end,
})

local spotifyTab = window:CreateTab("Spotify", 98757033223339)
spotifyTab:CreateSection("Playback")
spotifyTab:CreateInput({
    Name = "Song",
    PlaceholderText = "Song name",
    RemoveTextAfterFocusLost = false,
    Callback = function(value)
        spotifyQuery = value or ""
    end,
})

spotifyTab:CreateButton({
    Name = "Play song",
    Callback = function()
        if spotifyQuery ~= "" then runConsole("play " .. spotifyQuery) end
    end,
})

spotifyTab:CreateButton({
    Name = "Queue song",
    Callback = function()
        if spotifyQuery ~= "" then runConsole("queue " .. spotifyQuery) end
    end,
})

spotifyTab:CreateButton({ Name = "Pause", Callback = function() runConsole("pause") end })
spotifyTab:CreateButton({ Name = "Skip", Callback = function() runConsole("skip") end })
spotifyTab:CreateButton({ Name = "Now playing", Callback = function() runConsole("np") end })
spotifyTab:CreateButton({ Name = "Devices", Callback = function() runConsole("devices") end })

local voiceTab = window:CreateTab("Voice", 110736384827503)
voiceTab:CreateSection("TTS")
voiceTab:CreateDropdown({
    Name = "Voice",
    Options = { "Aoede", "Leda", "Zephyr", "Despina", "Sulafat", "Kore", "Puck", "Charon", "Fenrir", "Orus" },
    CurrentOption = { selectedVoice },
    Callback = function(option)
        selectedVoice = type(option) == "table" and option[1] or option
        if selectedVoice then
            runConsole("voice " .. selectedVoice)
        end
    end,
})

voiceTab:CreateDropdown({
    Name = "TTS mode",
    Options = { "bridge", "local", "both" },
    CurrentOption = { selectedTtsMode },
    Callback = function(option)
        selectedTtsMode = type(option) == "table" and option[1] or option
        if selectedTtsMode then
            runConsole("ttsmode " .. selectedTtsMode)
        end
    end,
})

local ttsText = ""
voiceTab:CreateInput({
    Name = "Say",
    PlaceholderText = "Text to speak",
    RemoveTextAfterFocusLost = false,
    Callback = function(value)
        ttsText = value or ""
    end,
})

voiceTab:CreateButton({
    Name = "Speak",
    Callback = function()
        if ttsText ~= "" then runConsole("say " .. ttsText) end
    end,
})

voiceTab:CreateButton({ Name = "Stop TTS", Callback = function() runConsole("stoptts") end })

local settingsTab = window:CreateTab("Settings", 112502172419483)
settingsTab:CreateSection("Bot")
settingsTab:CreateButton({
    Name = "Show commands",
    Callback = function()
        runConsole("help")
    end,
})

settingsTab:CreateButton({
    Name = "Session stats",
    Callback = function()
        runConsole("stats")
    end,
})

settingsTab:CreateButton({
    Name = "Destroy bot",
    Callback = function()
        ContextActionService:UnbindAction("QuizBotToggleUI")
        if library.Destroy then
            pcall(function() library:Destroy() end)
        end
        runConsole("destroy")
    end,
})

ctx.consoleLog("Rayfield UI loaded")
