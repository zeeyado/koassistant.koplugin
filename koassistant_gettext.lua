--[[
Custom gettext implementation for KOAssistant plugin.
Loads translations from the plugin's locale/ folder using KOReader's language setting.
]]--

local KOAssistantGettext = {}

-- Cache for loaded translations
local translations = {}
local current_lang = nil

-- Get the plugin directory path
local function getPluginDir()
    local str = debug.getinfo(1, "S").source:sub(2)
    return str:match("(.*/)") or "./"
end

local plugin_dir = getPluginDir()

-- Parse a PO file and return a table of msgid -> msgstr mappings
local function parsePOFile(filepath)
    local file = io.open(filepath, "r")
    if not file then
        return nil
    end

    local result = {}
    local current_msgid = nil
    local current_msgstr = nil
    local in_msgid = false
    local in_msgstr = false

    local function saveEntry()
        if current_msgid and current_msgstr and current_msgid ~= "" then
            result[current_msgid] = current_msgstr
        end
        current_msgid = nil
        current_msgstr = nil
        in_msgid = false
        in_msgstr = false
    end

    for line in file:lines() do
        if line:match("^msgid%s+") then
            if current_msgid then
                saveEntry()
            end
            in_msgid = true
            in_msgstr = false
            current_msgid = line:match('^msgid%s+"(.*)"$') or ""
        elseif line:match("^msgstr%s+") then
            in_msgid = false
            in_msgstr = true
            current_msgstr = line:match('^msgstr%s+"(.*)"$') or ""
        elseif line:match('^"') then
            local content = line:match('^"(.*)"$')
            if content then
                if in_msgid and current_msgid then
                    current_msgid = current_msgid .. content
                elseif in_msgstr and current_msgstr then
                    current_msgstr = current_msgstr .. content
                end
            end
        elseif line:match("^%s*$") or line:match("^#") then
            if current_msgid then
                saveEntry()
            end
        end
    end

    if current_msgid then
        saveEntry()
    end

    file:close()

    -- Process escape sequences
    for k, v in pairs(result) do
        v = v:gsub("\\n", "\n")
        v = v:gsub("\\t", "\t")
        v = v:gsub('\\"', '"')
        v = v:gsub("\\\\", "\\")
        result[k] = v
    end

    return result
end

-- Get KOReader's current language setting
local function getCurrentLanguage()
    if G_reader_settings then
        local lang = G_reader_settings:readSetting("language")
        if lang then
            return lang
        end
    end

    -- Fallback: try to read directly from settings file
    local ok, result = pcall(function()
        local DataStorage = require("datastorage")
        local LuaSettings = require("luasettings")
        local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
        return settings:readSetting("language")
    end)

    if ok and result then
        return result
    end

    return "en"
end

-- Load translations for the current language
local function loadTranslations()
    local lang = getCurrentLanguage()

    if lang == current_lang and translations[lang] then
        return
    end

    current_lang = lang

    local po_path = plugin_dir .. "locale/" .. lang .. "/LC_MESSAGES/koassistant.po"
    local loaded = parsePOFile(po_path)

    if loaded then
        translations[lang] = loaded
    else
        -- Try without country code (e.g., "es_ES" -> "es")
        local base_lang = lang:match("^([a-z]+)")
        if base_lang and base_lang ~= lang then
            po_path = plugin_dir .. "locale/" .. base_lang .. "/LC_MESSAGES/koassistant.po"
            loaded = parsePOFile(po_path)
            if loaded then
                translations[lang] = loaded
            end
        end
    end

    if not translations[lang] then
        translations[lang] = {}
    end
end

-- The main translation function
local function translate(msgid)
    if not msgid or msgid == "" then
        return ""
    end

    loadTranslations()

    local trans = translations[current_lang]
    if trans and trans[msgid] and trans[msgid] ~= "" then
        return trans[msgid]
    end

    return msgid
end

-- Make the module callable as _()
setmetatable(KOAssistantGettext, {
    __call = function(_, msgid)
        return translate(msgid)
    end
})

KOAssistantGettext.gettext = translate

-- Reload translations (useful if language changes)
KOAssistantGettext.reload = function()
    current_lang = nil
    loadTranslations()
end

return KOAssistantGettext
