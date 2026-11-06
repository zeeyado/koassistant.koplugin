-- Generates wiki/Settings-Reference.md from koassistant/ui/settings_schema.lua:
-- every row of the KOAssistant menu in menu order, with its help text, its
-- default and its choices, and a link to the wiki page that explains it.
-- The page is never edited by hand; a schema change is followed by
--     lua tests/tools/gen_settings_reference.lua
-- and tests/unit/test_wiki_pages.lua fails until the committed page equals
-- this script's output. OWNERS maps row ids (never positions) to pages, so a
-- row that moves in a menu reorganization keeps its owner; a submenu's owner
-- is inherited by its rows unless they name their own.
--
-- As a module (the unit test): local Gen = dofile(path); Gen.generate() -> text
-- As a script: writes the page and prints its path.

local Gen = {}

-- Owner page per row or submenu id. A row without an entry inherits its
-- nearest ancestor's; the fallback is the Settings-Reference page itself.
Gen.OWNERS = {
    gestures_screen = "Setup-Gestures-and-Panels",
    setup_wizard = "Setup-Gestures-and-Panels",
    about = "Backups-and-Updates",
    auto_check_updates = "Backups-and-Updates",
    check_updates = "Backups-and-Updates",
    temperature = "Providers-and-Models",
    use_action_tiers = "Providers-and-Models",
    enable_book_tools = "Reasoning-Web-Search-and-Book-Tools",
    tool_whole_text = "Reasoning-Web-Search-and-Book-Tools",
    tool_workflow_diagnostics = "Reasoning-Web-Search-and-Book-Tools",
    book_info_in_chat = "Privacy-and-Data",
    spoiler_free_chat = "Spoiler-Protection",
    spoiler_free_chat_xray = "Spoiler-Protection",
    -- top rows
    quick_settings_panel = "Setup-Gestures-and-Panels",
    quick_actions_panel = "Setup-Gestures-and-Panels",
    chat_about_book = "Contexts-and-Chat",
    book_hub = "Book-Settings-and-Book-Hub",
    new_general_chat = "Contexts-and-Chat",
    library_actions = "Contexts-and-Chat",
    chat_history = "Conversations-Notebooks-and-Export",
    browse_notebooks = "Conversations-Notebooks-and-Export",
    browse_artifacts = "Artifacts-and-Caching",
    book_groups = "Book-Groups-and-Series",
    provider_model = "Providers-and-Models",
    api_keys = "Providers-and-Models",
    -- settings submenus
    display_settings = "Chat-Windows",
    emoji_settings = "Setup-Gestures-and-Panels",
    highlight_display_settings = "Chat-Windows",
    chat_settings = "Conversations-Notebooks-and-Export",
    streaming_settings = "Chat-Windows",
    quick_answer_preset = "Contexts-and-Chat",
    content_format = "Conversations-Notebooks-and-Export",
    reading_and_library = "Reading-Analysis-Actions",
    chapter_quiz_menu = "Reading-Analysis-Actions",
    xray_settings_menu = "Using-X-Ray",
    recap_reminder_header = "Reading-Analysis-Actions",
    end_of_book_header = "Reading-Analysis-Actions",
    library_header = "Contexts-and-Chat",
    library_scan_folders_reading = "Privacy-and-Data",
    ai_language_settings = "Languages",
    dictionary_settings = "Dictionary-and-Translation",
    translate_settings = "Dictionary-and-Translation",
    minimal_popup_settings = "Chat-Windows",
    highlight_settings = "Contexts-and-Chat",
    actions_and_prompts = "Actions-and-Menus",
    notebooks = "Conversations-Notebooks-and-Export",
    privacy_data = "Privacy-and-Data",
    menus_and_buttons = "Actions-and-Menus",
    gestures_header = "Setup-Gestures-and-Panels",
    panels_header = "Setup-Gestures-and-Panels",
    backup_and_reset = "Backups-and-Updates",
    advanced = "Advanced-Configuration-and-Development",
    reasoning_submenu = "Reasoning-Web-Search-and-Book-Tools",
    global_tier_pins = "Providers-and-Models",
    web_search_submenu = "Reasoning-Web-Search-and-Book-Tools",
    image_generation_submenu = "Image-Generation",
    provider_settings = "Providers-and-Models",
}

Gen.PAGE_NAMES = {
    ["Setup-Gestures-and-Panels"] = "Setup, Gestures and Panels",
    ["Contexts-and-Chat"] = "Contexts and Chat",
    ["Chat-Windows"] = "Chat Windows",
    ["Book-Settings-and-Book-Hub"] = "Book Settings and Book Hub",
    ["Conversations-Notebooks-and-Export"] = "Conversations, Notebooks and Export",
    ["Artifacts-and-Caching"] = "Artifacts and Caching",
    ["Book-Groups-and-Series"] = "Book Groups and Series",
    ["Providers-and-Models"] = "Providers and Models",
    ["Reading-Analysis-Actions"] = "Reading Analysis Actions",
    ["Using-X-Ray"] = "Using X-Ray",
    ["Spoiler-Protection"] = "Spoiler Protection",
    ["Privacy-and-Data"] = "Privacy and Data",
    ["Languages"] = "Languages",
    ["Dictionary-and-Translation"] = "Dictionary and Translation",
    ["Actions-and-Menus"] = "Actions and Menus",
    ["Backups-and-Updates"] = "Backups and Updates",
    ["Advanced-Configuration-and-Development"] = "Advanced Configuration and Development",
    ["Reasoning-Web-Search-and-Book-Tools"] = "Reasoning, Web Search and Book Tools",
    ["Image-Generation"] = "Image Generation",
    ["Settings-Reference"] = "Settings Reference",
}

-- Labels for rows whose menu text is computed at run time (text_func): what
-- the row shows, with its live part as "…".
Gen.DYNAMIC_LABELS = {
    provider_model = "Model: current model (provider)",
    emoji_font = "Emoji Font: Installed / Restart KOReader / Not Installed",
    quick_preset_nudge_mode = "Brevity nudge: …",
    quick_preset_behavior = "Behavior: …",
    quick_preset_model_mode = "Model override: … (or Keep current / Fastest for provider / a tier)",
    chapter_quiz_menu = "Chapter Quiz: On / Off",
    xray_ahead_card = "Upcoming Entity Cards: …",
    xray_card_length = "Card Shows: …",
    xray_card_style = "Card Style: Footnote Panel / Floating Popup",
    xray_marking_density = "Marking Density: All Occurrences / Once per Page / After 10 Unseen Pages / After 25 Unseen Pages / First Appearance Only",
    xray_marking_families = "Mark: All Entities / People Only / People & Places",
    xray_appearances_rows = "Chapter Appearances Rows: KOReader ToC Settings / Compact",
    library_scan_folders_reading = "Default Scan Folders: …",
    interaction_languages = "Your Languages: …",
    primary_language = "Primary Language: …",
    additional_languages = "Additional Languages: …",
    dictionary_language = "Response Language: …",
    dictionary_context_mode = "Context Mode: Sentence / Paragraph / Characters / None",
    dictionary_bypass_action = "Bypass Action: …",
    translation_language = "Translation Target: …",
    translate_hide_highlight_mode = "Original Text: Follow Global / Always Hide / Hide Long / Never Hide",
    minimal_popup_actions = "Actions Using Minimal Popup: …",
    highlight_bypass_action = "Bypass Action: …",
    manage_behaviors = "Manage Behaviors (N)",
    default_domain_research = "Default Domain & Research (…)",
    trusted_providers = "Trusted Providers: …",
    privacy_preset = "Preset: Default (Ask) / Allow everything / Block everything / Custom",
    text_extraction = "Text Extraction (book text: Ask / Allow / Never)",
    index_scan_folders = "Index Scan Folders: …",
    reasoning_stance = "Global stance: Minimal / Default / Maximum",
    web_search_effort = "Web Search Effort: Light / Standard / Thorough",
    image_gen_provider = "Provider: Follow main provider / …",
    image_gen_model_openai = "OpenAI model: …",
    image_gen_model_xai = "xAI model: …",
    image_gen_model_gemini = "Gemini model: …",
    image_gen_model_openrouter = "OpenRouter model: … (the listed models, More models…)",
    image_gen_shape = "Shape: Fit my screen / Portrait / Landscape / Square / Let the model choose",
    image_gen_detail = "Detail: Draft / Standard / Best",
    image_gen_writer_model = "Prompt writer: Chat model / Fast model",
    image_gen_style = "Style: Book illustration / Watercolor / Ink drawing / Pencil sketch / Woodcut / Photographic / Comic / Map or diagram / Custom…",
    zai_region = "Z.AI Region: International / China",
    zai_search_engine = "Z.AI Search Engine: …",
    gemini_safety = "Gemini Content Filter: Google default / Relaxed for books",
    qwen_region = "Qwen Region: International / China / US",
    kimi_region = "Kimi Region: International / China",
    bedrock_region = "Amazon Bedrock Region: us-east-1 and 13 other AWS regions",
    tool_mode = "Book Tools Mode: Gather then answer / Interactive",
    tool_lookup_effort = "Book Tools Lookup Effort: Quick / Standard / Thorough",
    debug_display_level = "Debug Detail Level: Minimal / Names / Full",
}

local function label(item)
    if type(item.text) == "string" and item.text ~= "" then return item.text end
    if item.id and Gen.DYNAMIC_LABELS[item.id] then return Gen.DYNAMIC_LABELS[item.id] end
    return "(" .. tostring(item.id or "row") .. ")"
end

local function plain(s)
    -- one line, pipes escaped for the table; a computed text (a function of
    -- the live settings) has no static form and is left out
    if type(s) == "function" then return "" end
    s = tostring(s or ""):gsub("\n+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return (s:gsub("|", "\\|"))
end

local function valueText(item, v)
    if item.options then
        for _idx, o in ipairs(item.options) do
            if o.value == v then return plain(o.label or o.text or tostring(v)) end
        end
    end
    if type(v) == "boolean" then return v and "On" or "Off" end
    if type(v) == "table" then return "(list)" end
    if type(v) == "function" then return "" end
    if v == nil then return "" end
    return plain(tostring(v))
end

local function choices(item)
    if not item.options then return "" end
    local out = {}
    for _idx, o in ipairs(item.options) do
        out[#out + 1] = plain(o.label or o.text or tostring(o.value))
    end
    return table.concat(out, " / ")
end

local function anchor(text)
    local s = text:lower():gsub("[^%w%s%-]", ""):gsub("%s", "-")
    return s
end

function Gen.generate(schema)
    schema = schema or require("koassistant.ui.settings_schema")
    local out = {}
    local function w(s) out[#out + 1] = s end
    w("# Settings Reference")
    w("")
    w("Every row of the KOAssistant menu (Tools → KOAssistant, the first row of KOReader's Tools menu), in menu order, with what it does, its default and its choices, and the page that explains the feature. Generated from the plugin's settings schema by `tests/tools/gen_settings_reference.lua`; do not edit by hand, the test suite compares it with the schema.")
    w("")
    w("A row's type: **toggle** (on or off), **choice** (a list of values), **number**, **action** (opens a screen or runs something), **submenu** (holds more rows). Rows that depend on another row are listed under it; \"Settings → …\" paths on the other pages follow the same words as this page.")
    w("")

    -- every row's label by id, for the "grayed out unless" notes
    local label_by_id = {}
    local function index(items)
        for _idx, item in ipairs(items or {}) do
            if item.id then label_by_id[item.id] = plain(label(item)) end
            if item.items then index(item.items) end
        end
    end
    index(schema.items)

    local sections = {}
    local function walk(items, path, owner, depth, bucket)
        for _idx, item in ipairs(items or {}) do
            local text = label(item)
            local own = (item.id and Gen.OWNERS[item.id]) or owner
            if item.type == "submenu" then
                local here = path and (path .. " → " .. text) or text
                if depth == 0 then
                    local sec = { title = text, owner = own, rows = {}, id = item.id }
                    sections[#sections + 1] = sec
                    walk(item.items, here, own, depth + 1, sec.rows)
                else
                    bucket[#bucket + 1] = { kind = "submenu", path = here, owner = own, item = item, depth = depth }
                    walk(item.items, here, own, depth + 1, bucket)
                end
            elseif item.type == "header" then
                bucket[#bucket + 1] = { kind = "header", path = (path and (path .. " → ") or "") .. text, owner = own, item = item, depth = depth }
            else
                if depth == 0 then
                    if not sections.top then
                        sections.top = { title = "Top rows", owner = "Settings-Reference", rows = {} }
                        table.insert(sections, 1, sections.top)
                    end
                    sections.top.rows[#sections.top.rows + 1] = { kind = "row", path = text, owner = own, item = item, depth = 0 }
                else
                    bucket[#bucket + 1] = { kind = "row", path = (path and (path .. " → ") or "") .. text, owner = own, item = item, depth = depth }
                end
            end
        end
    end
    walk(schema.items, nil, "Settings-Reference", 0, nil)

    -- contents
    w("## Contents")
    w("")
    for _idx, sec in ipairs(sections) do
        w(string.format("- [%s](#%s)", sec.title, anchor(sec.title)))
    end
    w("")

    local TYPE_WORD = { toggle = "toggle", dropdown = "choice", radio = "choice", spinner = "number", action = "action", info = "note", submenu = "submenu", header = "" }

    for _idx, sec in ipairs(sections) do
        w("## " .. sec.title)
        w("")
        local owner_page = sec.owner
        if owner_page ~= "Settings-Reference" then
            w(string.format("Explained on [%s](%s).", Gen.PAGE_NAMES[owner_page] or owner_page, owner_page))
            w("")
        end
        w("| Row | Type | Does | Default | Choices | Page |")
        w("|---|---|---|---|---|---|")
        for _j, r in ipairs(sec.rows) do
            local item = r.item
            if r.kind == "header" then
                w(string.format("| **%s** | | | | | |", plain(label(item))))
            else
                -- the row's text, indented by its depth below the section
                local rel = r.path
                if sec.title ~= "Top rows" then
                    rel = rel:sub(#sec.title + 6)  -- past the title and " → " (the arrow is 3 bytes)  -- drop "Section → "
                end
                local does = plain(item.help_text or item.info_text or "")
                if item.depends_on then
                    -- one { id, value } or a list of them
                    local deps = item.depends_on.id and { item.depends_on } or item.depends_on
                    local parts = {}
                    for _d, dep in ipairs(deps) do
                        parts[#parts + 1] = (label_by_id[dep.id] or tostring(dep.id)) .. " is " .. valueText({}, dep.value)
                    end
                    does = does .. (does ~= "" and " " or "") .. "(Grayed out unless " .. table.concat(parts, " and ") .. ".)"
                end
                local default = ""
                if item.default ~= nil then default = valueText(item, item.default) end
                if item.type == "spinner" then
                    local range = {}
                    if item.min then range[#range + 1] = "min " .. tostring(item.min) end
                    if item.max then range[#range + 1] = "max " .. tostring(item.max) end
                    if item.step then range[#range + 1] = "step " .. tostring(item.step) end
                    if #range > 0 then default = default .. " (" .. table.concat(range, ", ") .. ")" end
                end
                local page = r.owner ~= "Settings-Reference" and string.format("[%s](%s)", Gen.PAGE_NAMES[r.owner] or r.owner, r.owner) or ""
                w(string.format("| %s | %s | %s | %s | %s | %s |", plain(rel), TYPE_WORD[item.type] or item.type or "", does, default, choices(item), page))
            end
        end
        w("")
    end
    w("## Related")
    w("")
    w("- [Book Settings and Book Hub](Book-Settings-and-Book-Hub): the per-book rows, which follow these unless set for one book.")
    w("- [Setup, Gestures and Panels](Setup-Gestures-and-Panels): the Quick Settings panel, which holds the rows most people change.")
    w("")
    return table.concat(out, "\n")
end

local function thisScript()
    local src = debug.getinfo(1, "S").source
    return src and src:match("^@?(.*)$") or ""
end

if arg and arg[0] and arg[0]:match("gen_settings_reference") then
    local script = thisScript()
    if script:sub(1, 1) ~= "/" then script = (os.getenv("PWD") or ".") .. "/" .. script end
    local tools_dir = script:match("(.+)/[^/]+$")
    local plugin_dir = tools_dir:match("(.+)/[^/]+$"):match("(.+)/[^/]+$")
    package.path = table.concat({ plugin_dir .. "/?.lua", plugin_dir .. "/tests/?.lua", plugin_dir .. "/tests/lib/?.lua", package.path }, ";")
    require("mock_koreader")
    local text = Gen.generate()
    local path = plugin_dir .. "/wiki/Settings-Reference.md"
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
    print(path)
end

return Gen
