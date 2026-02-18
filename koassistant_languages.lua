-- Language data for KOAssistant
-- Shared module for language display names (native scripts)
--
-- Regular languages are shown in native script.
-- Classical/scholarly languages are shown in English.

local Languages = {}

-- Regular languages with native script display names
Languages.REGULAR = {
    { id = "Arabic", display = "العربية" },
    { id = "Bengali", display = "বাংলা" },
    { id = "Bulgarian", display = "Български" },
    { id = "Catalan", display = "Català" },
    { id = "Chinese (Simplified)", display = "简体中文" },
    { id = "Chinese (Traditional)", display = "繁體中文" },
    { id = "Croatian", display = "Hrvatski" },
    { id = "Czech", display = "Čeština" },
    { id = "Danish", display = "Dansk" },
    { id = "Dutch", display = "Nederlands" },
    { id = "English", display = "English" },
    { id = "Estonian", display = "Eesti" },
    { id = "Finnish", display = "Suomi" },
    { id = "French", display = "Français" },
    { id = "Georgian", display = "ქართული" },
    { id = "German", display = "Deutsch" },
    { id = "Greek", display = "Ελληνικά" },
    { id = "Hindi", display = "हिन्दी" },
    { id = "Hungarian", display = "Magyar" },
    { id = "Icelandic", display = "Íslenska" },
    { id = "Indonesian", display = "Bahasa Indonesia" },
    { id = "Irish", display = "Gaeilge" },
    { id = "Italian", display = "Italiano" },
    { id = "Japanese", display = "日本語" },
    { id = "Korean", display = "한국어" },
    { id = "Latvian", display = "Latviešu" },
    { id = "Lithuanian", display = "Lietuvių" },
    { id = "Macedonian", display = "Македонски" },
    { id = "Norwegian (Bokmål)", display = "norsk (bokmål)" },
    { id = "Norwegian (Nynorsk)", display = "norsk (nynorsk)" },
    { id = "Persian", display = "فارسی" },
    { id = "Polish", display = "Polski" },
    { id = "Portuguese", display = "Português" },
    { id = "Portuguese (Brazilian)", display = "Português (Brasil)" },
    { id = "Romanian", display = "Română" },
    { id = "Russian", display = "Русский" },
    { id = "Serbian", display = "Српски" },
    { id = "Slovak", display = "Slovenčina" },
    { id = "Slovenian", display = "Slovenščina" },
    { id = "Spanish", display = "Español" },
    { id = "Swedish", display = "Svenska" },
    { id = "Thai", display = "ไทย" },
    { id = "Turkish", display = "Türkçe" },
    { id = "Ukrainian", display = "Українська" },
    { id = "Urdu", display = "اردو" },
    { id = "Vietnamese", display = "Tiếng Việt" },
    { id = "Welsh", display = "Cymraeg" },
}

-- Classical/scholarly languages (displayed in English only)
Languages.CLASSICAL = {
    "Ancient Greek",
    "Biblical Hebrew",
    "Classical Arabic",
    "Latin",
    "Sanskrit",
}

-- RTL (Right-to-Left) languages
-- Used for BiDi text alignment in dictionary/translation contexts
Languages.RTL_LANGUAGES = {
    "Arabic",
    "Classical Arabic",
    "Persian",
    "Urdu",
}

-- Check if a language is RTL
function Languages.isRTL(lang_id)
    if not lang_id then return false end
    for _, rtl_lang in ipairs(Languages.RTL_LANGUAGES) do
        if lang_id == rtl_lang then return true end
    end
    return false
end

-- Build display name lookup for regular languages
Languages.DISPLAY_MAP = {}
for _, lang in ipairs(Languages.REGULAR) do
    Languages.DISPLAY_MAP[lang.id] = lang.display
end

-- Get display name for a language (native script for regular, as-is for classical/custom)
function Languages.getDisplay(lang_id)
    return Languages.DISPLAY_MAP[lang_id] or lang_id
end

-- Get all language IDs (regular + classical)
function Languages.getAllIds()
    local ids = {}
    for _, lang in ipairs(Languages.REGULAR) do
        table.insert(ids, lang.id)
    end
    for _, lang in ipairs(Languages.CLASSICAL) do
        table.insert(ids, lang)
    end
    return ids
end

-- KOReader locale code → plugin language ID mapping
-- Covers all locales from KOReader's frontend/ui/language.lua
-- Uses base codes where KOReader uses country-specific codes (e.g., it for it_IT)
Languages.KOREADER_LOCALE_MAP = {
    C       = "English",
    en      = "English",
    ar      = "Arabic",
    bg      = "Bulgarian",
    bn      = "Bengali",
    ca      = "Catalan",
    cs      = "Czech",
    da      = "Danish",
    de      = "German",
    el      = "Greek",
    es      = "Spanish",
    fa      = "Persian",
    fi      = "Finnish",
    fr      = "French",
    hi      = "Hindi",
    hr      = "Croatian",
    hu      = "Hungarian",
    it      = "Italian",
    ja      = "Japanese",
    ka      = "Georgian",
    ko      = "Korean",
    lt      = "Lithuanian",
    lv      = "Latvian",
    nb      = "Norwegian (Bokmål)",
    nl      = "Dutch",
    pl      = "Polish",
    pt_PT   = "Portuguese",
    pt_BR   = "Portuguese (Brazilian)",
    ro      = "Romanian",
    ru      = "Russian",
    sk      = "Slovak",
    sr      = "Serbian",
    sv      = "Swedish",
    th      = "Thai",
    tr      = "Turkish",
    uk      = "Ukrainian",
    vi      = "Vietnamese",
    zh_CN   = "Chinese (Simplified)",
    zh_TW   = "Chinese (Traditional)",
}

-- Fallback names for KOReader locales not in REGULAR
-- AI understands these language names even without native script display
Languages.KOREADER_LOCALE_FALLBACK = {
    eo = "Esperanto",
    eu = "Basque",
    gl = "Galician",
    he = "Hebrew",
    kk = "Kazakh",
}

--- Detect primary language from KOReader's UI language setting.
--- Returns a plugin language ID (e.g., "French") or nil if unmappable.
--- Does NOT save anything to settings — purely runtime.
--- @return string|nil: Plugin language ID, or nil on failure
function Languages.detectFromKOReader()
    -- Read KOReader's UI language
    local locale = nil
    if G_reader_settings then
        locale = G_reader_settings:readSetting("language")
    end
    if not locale then
        -- Fallback: try to read directly from settings file
        local ok, result = pcall(function()
            local DataStorage = require("datastorage")
            local LuaSettings = require("luasettings")
            local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
            return settings:readSetting("language")
        end)
        if ok and result then
            locale = result
        end
    end
    if not locale then
        return nil
    end

    -- Try exact match first
    if Languages.KOREADER_LOCALE_MAP[locale] then
        return Languages.KOREADER_LOCALE_MAP[locale]
    end

    -- Try fallback names (Esperanto, Basque, etc.)
    if Languages.KOREADER_LOCALE_FALLBACK[locale] then
        return Languages.KOREADER_LOCALE_FALLBACK[locale]
    end

    -- Try base language code (e.g., "it_IT" → "it", "ko_KR" → "ko")
    local base = locale:match("^([a-z]+)")
    if base and base ~= locale then
        if Languages.KOREADER_LOCALE_MAP[base] then
            return Languages.KOREADER_LOCALE_MAP[base]
        end
        if Languages.KOREADER_LOCALE_FALLBACK[base] then
            return Languages.KOREADER_LOCALE_FALLBACK[base]
        end
    end

    return nil
end

return Languages
