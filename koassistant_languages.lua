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
    "Hebrew",
    "Biblical Hebrew",
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

return Languages
