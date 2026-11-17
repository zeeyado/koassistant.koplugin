--[[--
KOAssistant Image Generator

Generates an image from a text description using the currently configured
AI provider's image-generation endpoint and displays the result in
KOReader's full-screen ImageViewer.

Currently supported providers and their image-generation endpoints:
  • openai     → https://api.openai.com/v1/images/generations   (gpt-image family)
  • xai        → https://api.x.ai/v1/images/generations         (grok-imagine-image)
  • gemini     → generateContent with IMAGE modality             (gemini-*-image)
  • openrouter → https://openrouter.ai/api/v1/images             (its Image API: many makers)

Model inventory lives in koassistant/request/model_lists.lua (`_image_models`);
this file holds only wire/endpoint facts. Generated images are kept in
data_dir/koassistant_images (filename = date + prompt snippet); the
Generated Images browser (koassistant/images/image_browser.lua) manages them.

Public API:
  ImageGenerator.generate(word, configuration, settings, book_info)
      `word` = selected text / description; `configuration` = global config
      table (resolved by updateConfigFromSettings); `settings` = LuaSettings
      instance (for GUI-entered API keys); `book_info` = optional
      { file, title } — associates the saved image with a book in the
      images index (per-book gallery / artifact browser row).
  ImageGenerator.effectiveProvider(features, main_provider, settings)
      → provider|nil, reason — the dispatch's provider.
  ImageGenerator.offered(features, main_provider, settings) — the button
      gates: the provider in effect draws, or the chat provider cannot draw
      and some image provider has a key (askProvider asks on the first tap;
      keyedProviders, providerName).
  ImageGenerator.buildPrompt / buildRequest / parseResponse / errorMessage /
      imageExtension — pure: the framed prompt, the request as sent (Shape
      and Detail turned into each model's own parameters, with
      pictureFacts / shapeRatio), the answer read, the refusal worded, the
      file type from the bytes (unit-tested; tests/inspect.lua --image and
      the audit's image probe build and read with them).
  ImageGenerator.regenerate(spec, configuration, settings) — a recorded
      prompt (or the reader's edit of it) drawn again (S7), the kinds it
      carries judged for the provider it goes to (promptKinds).
  ImageGenerator.getImagesDir()
  Index API: readIndex, recordImage, removeIndexEntries, booksWithImages,
  updateIndexForMove, getIndexFilename, promptKinds, subjectFromName.
  Files: saveImage (file, index entry, thumbnail from one decode),
  deleteImages, thumbnailPath / thumbnailSize / makeThumbnail,
  sweepThumbnails.
]]

local json   = require("json")
local ffi    = require("ffi")
local ffiutil = require("ffi/util")
local logger = require("koassistant.core.logger")
local mime   = require("mime")
local BaseHandler = require("koassistant.api.base")
local ModelLists = require("koassistant.request.model_lists")
local _ = require("koassistant.core.gettext")
local T = ffiutil.template

local ImageGenerator = {}

-- ---------------------------------------------------------------------------
-- Provider image-generation endpoint table
-- ---------------------------------------------------------------------------

--[[
 Provider entries (wire/endpoint facts ONLY — model inventory lives in
 koassistant/request/model_lists.lua `_image_models`, first entry = default):
   url        - base URL (OpenAI-style) or base URL for Gemini model interpolation
   key_header - HTTP header used for authentication
   is_gemini  - when true, use Gemini's generateContent protocol instead of OpenAI images API

 Gemini ("Nano Banana") note:
   The gemini-*-image models use the standard generateContent endpoint with
   responseModalities=["IMAGE","TEXT"] and return images as inlineData
   base64 parts in candidates[] -- not the OpenAI images response shape.
]]
local IMAGE_ENDPOINTS = {
    openai = {
        url        = "https://api.openai.com/v1/images/generations",
        key_header = "Authorization",  -- "Bearer <key>"
    },
    xai = {
        url        = "https://api.x.ai/v1/images/generations",
        key_header = "Authorization",
    },
    gemini = {
        -- Base URL; model is appended as: <base>/<model>:generateContent
        url        = "https://generativelanguage.googleapis.com/v1beta/models",
        key_header = "x-goog-api-key",
        is_gemini  = true,
    },
    openrouter = {
        -- OpenRouter's Image API (image round S3): the answer is
        -- data[].b64_json with its media_type; a generation that fails is a
        -- 502 and is not billed. The catalog lists every model with the
        -- parameters it takes (no key needed).
        url        = "https://openrouter.ai/api/v1/images",
        key_header = "Authorization",
        catalog    = "https://openrouter.ai/api/v1/images/models",
    },
}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Resolve the API key for a provider (GUI keys > apikeys.lua, placeholder-
--- aware). Shared logic lives in koassistant/api/base.lua.
local function resolveApiKey(provider, settings)
    return BaseHandler.getApiKey(provider, settings)
end

--- Resolve which provider image generation should use.
--- Chain (maintainer decision 2026-07-16): explicit `image_gen_provider`
--- ("auto"/nil = follow the main provider) > main provider when image-capable.
--- No fallback hunting through other configured keys — never spend on a
--- provider the user didn't pick for the job.
--- @param features table       resolved config features (image_gen_* keys)
--- @param main_provider string the active chat provider
--- @param settings table       LuaSettings instance (for GUI API keys)
--- @return string|nil provider, nil|"no_endpoint"|"no_key" reason
function ImageGenerator.effectiveProvider(features, main_provider, settings)
    local pick = features and features.image_gen_provider
    local provider
    if type(pick) == "string" and pick ~= "" and pick ~= "auto" then
        provider = pick
    else
        provider = main_provider
    end
    if not provider or not IMAGE_ENDPOINTS[provider] then
        return nil, "no_endpoint"
    end
    if not resolveApiKey(provider, settings) then
        return nil, "no_key"
    end
    return provider
end

-- The image providers in the order the settings list them, with their names
ImageGenerator.PROVIDERS = { "openai", "xai", "gemini", "openrouter" }
local PROVIDER_NAMES = { openai = "OpenAI", xai = "xAI (Grok)", gemini = "Gemini", openrouter = "OpenRouter" }

--- A provider's name on the image surfaces: an image provider by its brand
--- (as the Provider row names it), any other by the plugin's display name.
function ImageGenerator.providerName(provider, plugin)
    if PROVIDER_NAMES[provider] then return PROVIDER_NAMES[provider] end
    if provider and plugin and plugin.getProviderDisplayName then
        local ok, name = pcall(plugin.getProviderDisplayName, plugin, provider)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    return tostring(provider)
end

-- Provider on Follow main provider (unset, empty or "auto")
local function followsMain(features)
    local pick = features and features.image_gen_provider
    return not (type(pick) == "string" and pick ~= "" and pick ~= "auto")
end

--- The image providers with an API key, in the settings' order.
function ImageGenerator.keyedProviders(settings)
    local out = {}
    for _idx, p in ipairs(ImageGenerator.PROVIDERS) do
        if resolveApiKey(p, settings) then out[#out + 1] = p end
    end
    return out
end

--- Whether Generate Image is offered (the button gates; image round S4,
--- ruling R4): the provider in effect can draw and has a key, or Provider
--- follows a chat provider that cannot draw while an image provider has a
--- key, and the first tap asks which one (askProvider).
function ImageGenerator.offered(features, main_provider, settings)
    if ImageGenerator.effectiveProvider(features, main_provider, settings) then return true end
    return followsMain(features) and not (main_provider and IMAGE_ENDPOINTS[main_provider])
        and #ImageGenerator.keyedProviders(settings) > 0
end

--- The question when the chat provider cannot draw (S4): which of the keyed
--- image providers makes the images. Every keyed one is listed, even a single
--- one: the answer decides who is billed. on_pick(provider) after a pick;
--- Cancel and a tap outside do nothing, so the next tap asks again.
function ImageGenerator.askProvider(main_provider, keyed, plugin, on_pick)
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local rows = {}
    for _idx, p in ipairs(keyed) do
        local provider = p
        rows[#rows + 1] = { {
            text = ImageGenerator.providerName(provider),
            callback = function()
                UIManager:close(dialog)
                on_pick(provider)
            end,
        } }
    end
    rows[#rows + 1] = { {
        text = _("Cancel"),
        id = "close",
        callback = function() UIManager:close(dialog) end,
    } }
    dialog = ButtonDialog:new{
        title = T(_("%1 can't make images. Make them with:"), ImageGenerator.providerName(main_provider, plugin))
            .. "\n\n" .. _("Your answer is saved as the image provider (Settings → Advanced → Image Generation → Provider)."),
        buttons = rows,
    }
    UIManager:show(dialog)
    return dialog
end

-- The S4 question's answer, saved as Provider (the settings, the request's
-- features, the plugin's copy)
local function saveAskedProvider(settings, features, plugin, picked)
    if settings then
        local f = settings:readSetting("features") or {}
        f.image_gen_provider = picked
        settings:saveSetting("features", f)
        settings:flush()
    end
    if features then features.image_gen_provider = picked end
    if plugin and plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
    logger.info("KOAssistant: image provider set by the first-tap question:", picked)
end

--- The S4 question at the tap, before a picture's popup (B537): when Provider
--- follows a chat provider that cannot draw and an image provider has a key,
--- ask which one makes the images first (the answer saved as Provider), then
--- on_ready(); otherwise on_ready() at once. The popup then shows the
--- provider that draws and its model, and nothing typed in it waits on the
--- question. Cancel does nothing, so the next tap asks again.
function ImageGenerator.providerFirst(plugin, on_ready)
    local settings = plugin and plugin.settings
    local features = settings and settings:readSetting("features") or {}
    local main_provider = require("koassistant.core.config_helper").mainProvider(features)
    local provider, unavailable = ImageGenerator.effectiveProvider(features, main_provider, settings)
    local keyed = (not provider and unavailable == "no_endpoint" and followsMain(features))
        and ImageGenerator.keyedProviders(settings) or {}
    if #keyed == 0 then
        on_ready()
        return
    end
    ImageGenerator.askProvider(main_provider, keyed, plugin, function(picked)
        saveAskedProvider(settings, nil, plugin, picked)
        on_ready()
    end)
end

--- The note for one picture (S5, D9; the picture popup's Add a note…, B537):
--- a box the size of the chat's, its example as the gray hint inside it.
--- on_ok(text), or on_ok(nil) when the note was left empty (the picture goes
--- without one); Cancel does nothing. opts.confirm_text names the button.
function ImageGenerator.askNote(prefill, on_ok, opts)
    opts = opts or {}
    local UIManager = require("ui/uimanager")
    local InputDialog = require("ui/widget/inputdialog")
    local Screen = require("device").screen
    local dialog
    local buttons = { {
        {
            text = _("Cancel"),
            id = "close",
            callback = function() UIManager:close(dialog) end,
        },
        {
            text = opts.confirm_text or _("OK"),
            is_enter_default = true,
            callback = function()
                local text = dialog:getInputText()
                UIManager:close(dialog)
                on_ok((type(text) == "string" and text:match("%S")) and text or nil)
            end,
        },
    } }
    dialog = InputDialog:new{
        title = _("Note for the picture"),
        input = prefill or "",
        input_hint = _("The setting or context, details for the picture (at night, close up, in the rain), what to include, or other instructions"),
        allow_newline = true,
        text_height = Screen:scaleBySize(96),
        buttons = buttons,
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- The X-Ray entries the prompt writer reads for a passage picture (B535,
--- B537): the reader's list, five at most. The ones picked first (at first
--- those the passage and the note name), then the suggested ones, then every
--- other entry under its category, with a name search; a tap marks or clears
--- one, and the rows keep the places they opened in. Closing it (the X, Back)
--- hands the list back in the order picked: there is no Done to find.
--- @param tiers table PromptWriter.pickerTiers(...)
--- @param picks table names picked so far
--- @param on_done function(names)
function ImageGenerator.pickEntries(tiers, picks, on_done)
    local UIManager = require("ui/uimanager")
    local Menu = require("ui/widget/menu")
    local InfoMessage = require("ui/widget/infomessage")
    local Screen = require("device").screen
    local max = require("koassistant.images.prompt_writer").ENTRIES_MAX
    local chosen, order = {}, {}
    for _idx, n in ipairs(picks or {}) do
        if type(n) == "string" and not chosen[n:lower()] then
            chosen[n:lower()] = true
            order[#order + 1] = n
        end
    end
    local filter, menu
    local function title()
        return T(_("Pick X-Ray entries (%1 of %2)"), #order, max)
    end
    local items
    local function toggle(row)
        local low = row.name:lower()
        if chosen[low] then
            chosen[low] = nil
            for i = #order, 1, -1 do
                if order[i]:lower() == low then table.remove(order, i) end
            end
        elseif #order >= max then
            UIManager:show(InfoMessage:new{
                text = T(_("The prompt writer reads %1 entries at most."), max),
                timeout = 3,
            })
            return
        else
            chosen[low] = true
            order[#order + 1] = row.name
        end
        menu:switchItemTable(title(), items(), -1)
    end
    items = function()
        local out = {}
        local function add(label, rows)
            local shown = {}
            for _idx, row in ipairs(rows or {}) do
                if not filter or row.name:lower():find(filter, 1, true) then shown[#shown + 1] = row end
            end
            if #shown == 0 then return end
            if label then out[#out + 1] = { text = label, bold = true, callback = function() end } end
            for _idx, row in ipairs(shown) do
                local r = row
                -- a carried entry names its book, as the X-Ray's category
                -- pages do ("Innkeeper · Book 2")
                out[#out + 1] = {
                    text = (chosen[r.name:lower()] and "\u{2611} " or "\u{2610} ") .. r.name
                        .. (r.role and (" \u{00B7} " .. r.role) or "")
                        .. (r.from and (" \u{00B7} " .. r.from) or ""),
                    callback = function() toggle(r) end,
                }
            end
        end
        add(nil, tiers.picked)
        add(_("Suggested"), tiers.suggested)
        for _idx, g in ipairs(tiers.groups or {}) do add(g.label, g.rows) end
        return out
    end
    menu = Menu:new{
        title = title(),
        item_table = items(),
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        onMenuSelect = function(_self_menu, item)
            if item and item.callback then item.callback() end
            return true
        end,
        close_callback = function() on_done(order) end,
        search_callback = function(search_string)
            filter = (type(search_string) == "string" and search_string ~= "") and search_string:lower() or nil
            menu:switchItemTable(title(), items(), 1)
        end,
    }
    UIManager:show(menu)
    return menu
end

--- Resolve the image model: explicit per-provider setting (a retired id sent
--- as its replacement) > list default.
local function resolveImageModel(provider, features)
    return ModelLists.resolveImageModel(provider, features and features["image_gen_model_" .. provider])
end

--- Show a simple error / informational notice.
local function showNotice(text)
    local UIManager  = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = text })
end

--- Return v only when it is a string, nil otherwise. KOReader's json.decode
--- maps JSON null to a truthy sentinel, so decoded fields must be
--- type-checked, never truthiness-checked.
local function str(v)
    return type(v) == "string" and v or nil
end

function ImageGenerator.getImagesDir()
    local DataStorage = require("datastorage")
    return DataStorage:getDataDir() .. "/koassistant_images"
end

--- The file extension an image's bytes call for: JPEG and WebP by their magic
--- bytes, PNG otherwise. Gemini and xAI answer JPEG; every image used to be
--- named .png. KOReader decodes by content either way.
function ImageGenerator.imageExtension(bytes)
    if type(bytes) == "string" then
        if bytes:sub(1, 3) == "\255\216\255" then return "jpg" end
        if bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WEBP" then return "webp" end
    end
    return "png"
end

--- What a refused or failed request (status other than 200) shows (B459): the
--- provider's own message where the body carries one, and OpenAI's moderation
--- refusal named as such, with the stage it refused at. Runs in the fetch child.
function ImageGenerator.errorMessage(code, body)
    local msg = type(body) == "string" and body or ""
    local okj, parsed = pcall(json.decode, msg)
    local err = okj and type(parsed) == "table" and parsed.error or nil
    if type(err) == "table" then
        local text = str(err.message) or ""
        if str(err.code) == "moderation_blocked" then
            local details = type(err.moderation_details) == "table" and err.moderation_details
                or (type(parsed.moderation_details) == "table" and parsed.moderation_details) or {}
            local stage = str(details.moderation_stage)
            local head
            if stage == "input" then
                head = _("OpenAI's moderation refused the prompt (the passage or its framing).")
            elseif stage == "output" then
                head = _("OpenAI's moderation refused the picture it made.")
            else
                head = _("OpenAI's moderation refused this request.")
            end
            if text ~= "" then head = head .. "\n\n" .. text:sub(1, 300) end
            return head
        end
        if text ~= "" then msg = text end
    elseif type(err) == "string" and err ~= "" then
        msg = err
    end
    return "HTTP " .. tostring(code) .. ": " .. msg:sub(1, 300)
end

-- ---------------------------------------------------------------------------
-- The images index
-- Maps image filename → { book_file, book_title, prompt, provenance,
-- description, provider, model, kinds, created } so the gallery can offer
-- per-book views and draw a prompt again. Lives INSIDE the images dir
-- (already registry-tracked, so reset/backup flows cover it with no new
-- registry work), like the thumbnails folder. Images absent from the index
-- stay valid; a picture made outside a book has no book_file.
-- ---------------------------------------------------------------------------

local INDEX_FILENAME = "koassistant_index.lua"
local THUMB_DIRNAME = "thumbnails"

--- The index file's basename (the gallery excludes it from image listings).
function ImageGenerator.getIndexFilename()
    return INDEX_FILENAME
end

local function openIndex()
    local LuaSettings = require("luasettings")
    return LuaSettings:open(ImageGenerator.getImagesDir() .. "/" .. INDEX_FILENAME)
end

--- Read the whole index: { [filename] = { book_file, book_title, prompt, created, ... } }
function ImageGenerator.readIndex()
    local idx = openIndex():readSetting("images")
    return type(idx) == "table" and idx or {}
end

local function writeIndex(index)
    local store = openIndex()
    store:saveSetting("images", index)
    store:flush()
end

--- Record a saved image (called at save time): its book when it has one, the
--- prompt sent, the provenance line (who wrote the prompt, from what, nil
--- without it), and meta = { description (the picture's subject), provider,
--- model (who drew it), kinds (the kinds of the reader's data its prompt
--- carries, S7), style (the style as the prompt says it) and written (the
--- prompt writer wrote it), S9 }.
function ImageGenerator.recordImage(filename, book_info, prompt, provenance, meta)
    meta = meta or {}
    local index = ImageGenerator.readIndex()
    local description = type(meta.description) == "string"
        and require("koassistant.request.scope_resolver").utf8Head(meta.description, 300) or nil
    index[filename] = {
        book_file = book_info and book_info.file or nil,
        book_title = book_info and book_info.file and book_info.title or nil,
        prompt = prompt,
        provenance = provenance,
        description = description,
        provider = meta.provider,
        model = meta.model,
        kinds = meta.kinds,
        style = type(meta.style) == "string" and meta.style or nil,
        written = type(meta.written) == "boolean" and meta.written or nil,
        -- B486: the X-Ray entries the picture shows, by name (the entry drawn,
        -- or the ones the passage, the note and the reader's picks name)
        entries = type(meta.entries) == "table" and #meta.entries > 0 and meta.entries or nil,
        created = os.time(),
    }
    writeIndex(index)
end

--- The pictures of one X-Ray entry (B486), newest first: the book's pictures
--- whose recorded entries name it. Matched by name, so a rename or a merge
--- (the old name stays among the entry's names) keeps them: the entry's own
--- name always, one of its other names only when no other entry is called
--- that. Pictures gone from disk are left out.
--- @param book_file string
--- @param names table lowercased name -> true (the entry's name and aliases)
--- @param others table|nil lowercased name -> true (the other entries' names)
--- @param main string|nil the entry's own name, lowercased
--- @param index table|nil the images index (read when nil)
--- @return table { filename, ... }
function ImageGenerator.picturesOf(book_file, names, others, main, index)
    local out = {}
    if type(book_file) ~= "string" or type(names) ~= "table" then return out end
    index = index or ImageGenerator.readIndex()
    local lfs = require("libs/libkoreader-lfs")
    local dir = ImageGenerator.getImagesDir()
    local hits = {}
    for filename, rec in pairs(index) do
        if type(rec) == "table" and rec.book_file == book_file and type(rec.entries) == "table" then
            for _idx, n in ipairs(rec.entries) do
                local low = type(n) == "string" and n:lower()
                if low and names[low] and (low == main or not (others and others[low])) then
                    if lfs.attributes(dir .. "/" .. filename, "mode") == "file" then
                        hits[#hits + 1] = { name = filename, created = tonumber(rec.created) or 0 }
                    end
                    break
                end
            end
        end
    end
    table.sort(hits, function(a, b)
        if a.created ~= b.created then return a.created > b.created end
        return a.name > b.name
    end)
    for _idx, h in ipairs(hits) do out[#out + 1] = h.name end
    return out
end

--- The name sets picturesOf takes for an entry of a parsed X-Ray: its own
--- name and other names, the other entries' names, its own name. Pure.
--- @return table names, table others, string|nil main
function ImageGenerator.entryNames(data, item, category_key)
    local XrayParser = require("koassistant.xray.xray_parser")
    local names, others = {}, {}
    local main = XrayParser.getItemName(item, category_key)
    main = type(main) == "string" and main:lower() or nil
    if main then names[main] = true end
    for _idx, a in ipairs(type(item) == "table" and type(item.aliases) == "table" and item.aliases or {}) do
        if type(a) == "string" and a ~= "" then names[a:lower()] = true end
    end
    for _idx, cat in ipairs(XrayParser.getCategories(data) or {}) do
        for _j, other in ipairs(cat.items or {}) do
            if other ~= item then
                local n = XrayParser.getItemName(other, cat.key)
                if type(n) == "string" and n ~= "" then others[n:lower()] = true end
            end
        end
    end
    return names, others, main
end

-- The frame's label for the text around the passage (buildPrompt), and the
-- words that open an X-Ray entry's frame (buildEntryPrompt): a prompt
-- recorded before S7 carries those kinds when it carries these
local FRAME_AROUND = "Surrounding text, for context only: "
local FRAME_ENTRY = " from a book, as described below."

--- The kinds of the reader's data a recorded prompt carries (S7): what its
--- run recorded. Before S7: the frame's text around when the prompt has its
--- label (all a released version's prompt could carry), an X-Ray entry's
--- frame as book text, and a prompt the writer wrote (it has a provenance
--- line; builds between S5 and S7, never released) as both, whatever it
--- used: the record cannot tell. Pure.
function ImageGenerator.promptKinds(entry)
    if type(entry) ~= "table" then return {} end
    if type(entry.kinds) == "table" then
        local out = {}
        for _idx, kind in ipairs(entry.kinds) do
            if type(kind) == "string" then out[#out + 1] = kind end
        end
        return out
    end
    local prompt = type(entry.prompt) == "string" and entry.prompt or ""
    local written = type(entry.provenance) == "string" and entry.provenance ~= ""
    local out = {}
    if written or prompt:find(FRAME_AROUND, 1, true) then out[#out + 1] = "nearby_text" end
    if written or prompt:find(FRAME_ENTRY, 1, true) then out[#out + 1] = "book_text" end
    return out
end

--- The kinds of the reader's data a run's prompt carries, recorded with the
--- picture so drawing it again can judge them (S7): the text around when it
--- went (spec.around); the X-Ray's stamped kinds when a description went
--- (spec.stored = the X-Ray's cache entry, when allowed: the entry to draw
--- (spec.entry), or the passage's entries (spec.entries, a count) in a
--- written prompt (spec.written)). Pure.
function ImageGenerator.kindsSent(spec)
    local out = {}
    if spec.around then out[#out + 1] = "nearby_text" end
    if spec.stored and (spec.entry or (spec.written and (spec.entries or 0) > 0)) then
        local stamped = require("koassistant.request.privacy_gates").stampedKinds(spec.stored)
        for _idx, kind in ipairs({ "book_text", "highlights", "annotations" }) do
            if stamped[kind] then out[#out + 1] = kind end
        end
    end
    return out
end

--- A picture's subject from its file name (the text after the date, without
--- the extension and a " (2)" counter): the label under a thumbnail, and the
--- subject of a picture recorded before S7. Pure.
function ImageGenerator.subjectFromName(name)
    local s = (type(name) == "string" and name or ""):gsub("%.%w+$", "")
    s = s:gsub("^%d%d%d%d%-%d%d%-%d%d %d%d%.%d%d%.%d%d ?", ""):gsub(" %(%d+%)$", "")
    return s
end

-- ---------------------------------------------------------------------------
-- Thumbnails (S7, B062): one small JPEG per image in thumbnails/, cut once,
-- so the gallery's grid never decodes the full pictures
-- ---------------------------------------------------------------------------

--- An image's thumbnail file: the whole image name plus .jpg (two images that
--- differ only by extension never share one).
function ImageGenerator.thumbnailPath(name)
    return ImageGenerator.getImagesDir() .. "/" .. THUMB_DIRNAME .. "/" .. name .. ".jpg"
end

--- A thumbnail's size: the image fitted into a box a third of the screen's
--- shorter side wide and a third of its longer side high, never enlarged. Pure.
function ImageGenerator.thumbnailSize(img_w, img_h, screen_w, screen_h)
    local box_w = math.floor(math.min(screen_w, screen_h) / 3)
    local box_h = math.floor(math.max(screen_w, screen_h) / 3)
    local scale = math.min(box_w / img_w, box_h / img_h, 1)
    return math.max(1, math.floor(img_w * scale + 0.5)), math.max(1, math.floor(img_h * scale + 0.5))
end

--- Write an image's thumbnail: cut from bb when the caller has the picture
--- decoded (bb is kept), else decoded from the file. true when written.
function ImageGenerator.makeThumbnail(name, bb)
    local ok, written = pcall(function()
        local lfs = require("libs/libkoreader-lfs")
        local RenderImage = require("ui/renderimage")
        local Screen = require("device").screen
        local src = bb or RenderImage:renderImageFile(ImageGenerator.getImagesDir() .. "/" .. name, false)
        if not src then return false end
        local w, h = ImageGenerator.thumbnailSize(src:getWidth(), src:getHeight(), Screen:getWidth(), Screen:getHeight())
        -- scaleBlitBuffer scales to exactly w x h (the fit is ours) and hands
        -- back the source itself when it is that size already
        local thumb = RenderImage:scaleBlitBuffer(src, w, h, false)
        local dir = ImageGenerator.getImagesDir() .. "/" .. THUMB_DIRNAME
        if not lfs.attributes(dir, "mode") then lfs.mkdir(dir) end
        local path = ImageGenerator.thumbnailPath(name)
        local done
        if thumb.writeToFile then
            done = thumb:writeToFile(path, "jpg", 85)
        else
            -- an older frontend without writeToFile: a PNG under the same
            -- name (the decoders read the bytes, not the extension)
            done = pcall(thumb.writePNG, thumb, path)
        end
        if thumb ~= src then thumb:free() end
        if not bb then src:free() end
        -- the JPEG writer drops the encoder's own failure (a full disk, no
        -- folder): the file is the proof, and an empty one goes
        if done and (lfs.attributes(path, "size") or 0) > 0 then return true end
        os.remove(path)
        return false
    end)
    if not ok then
        logger.warn("KOAssistant: thumbnail failed:", written)
        return false
    end
    return written
end

--- Delete pictures with their thumbnails and index entries (one index write).
--- @param names table array of image file names
function ImageGenerator.deleteImages(names)
    local dir = ImageGenerator.getImagesDir()
    for _idx, name in ipairs(names) do
        os.remove(dir .. "/" .. name)
        os.remove(ImageGenerator.thumbnailPath(name))
    end
    ImageGenerator.removeIndexEntries(names)
end

--- Remove the thumbnails whose picture is gone (deleted outside the gallery).
function ImageGenerator.sweepThumbnails()
    local lfs = require("libs/libkoreader-lfs")
    local dir = ImageGenerator.getImagesDir()
    local tdir = dir .. "/" .. THUMB_DIRNAME
    if lfs.attributes(tdir, "mode") ~= "directory" then return end
    local gone = {}
    for entry in lfs.dir(tdir) do
        local image = entry:match("^(.+)%.jpg$")
        if image and lfs.attributes(dir .. "/" .. image, "mode") ~= "file" then
            gone[#gone + 1] = tdir .. "/" .. entry
        end
    end
    for _idx, path in ipairs(gone) do os.remove(path) end
end

--- What an image's caption and the gallery's hold view show: the provenance
--- line first (D13), then the prompt sent.
function ImageGenerator.promptShown(prompt, provenance)
    if type(provenance) == "string" and provenance ~= "" then
        return provenance .. "\n\n" .. (prompt or "")
    end
    return prompt
end

--- Drop index entries for deleted images.
--- @param filenames table array of image basenames
function ImageGenerator.removeIndexEntries(filenames)
    local index = ImageGenerator.readIndex()
    local changed = false
    for _idx, name in ipairs(filenames) do
        if index[name] ~= nil then
            index[name] = nil
            changed = true
        end
    end
    if changed then writeIndex(index) end
end

--- Map of book_file → { count, modified, book_title } for books with images.
--- Joins the index against the directory; stale entries (image file removed
--- outside the gallery) are pruned in passing. Pictures made outside a book
--- are kept and not counted.
function ImageGenerator.booksWithImages()
    local lfs = require("libs/libkoreader-lfs")
    local dir = ImageGenerator.getImagesDir()
    -- Cheap stat guard: this runs from every View Artifacts surface incl.
    -- file-browser long-press rows and the QS panel — skip the settings-file
    -- read while no index exists
    if not lfs.attributes(dir .. "/" .. INDEX_FILENAME, "mode") then
        return {}
    end
    local index = ImageGenerator.readIndex()
    local books = {}
    local stale = false
    for filename, entry in pairs(index) do
        local valid = type(entry) == "table"
            and lfs.attributes(dir .. "/" .. filename, "mode") == "file"
        if valid and type(entry.book_file) == "string" then
            local b = books[entry.book_file]
            if not b then
                b = { count = 0, modified = 0 }
                books[entry.book_file] = b
            end
            b.count = b.count + 1
            if (entry.created or 0) > b.modified then b.modified = entry.created end
            if type(entry.book_title) == "string" and entry.book_title ~= "" then
                b.book_title = entry.book_title
            end
        elseif not valid then
            index[filename] = nil
            stale = true
        end
    end
    if stale then writeIndex(index) end
    return books
end

--- Keep book associations valid across file-manager operations (called from
--- the DocSettings.updateLocation patch in main.lua). Move rewrites
--- book_file; delete drops the association (images are kept, with their
--- prompts, as pictures without a book); copy leaves images with the
--- original book. `folder`: old_path and new_path are a folder's, moved or
--- renamed (B507), and every picture of a book inside it follows.
function ImageGenerator.updateIndexForMove(old_path, new_path, copy, folder)
    if copy then return end
    -- Cheap stat guard: this runs on EVERY file-manager move/delete
    local lfs = require("libs/libkoreader-lfs")
    if not lfs.attributes(ImageGenerator.getImagesDir() .. "/" .. INDEX_FILENAME, "mode") then
        return
    end
    local movedPath = folder and require("koassistant.storage.doc_settings").movedPath
    local index = ImageGenerator.readIndex()
    local changed = false
    for filename, entry in pairs(index) do
        if movedPath then
            local moved = type(entry) == "table" and movedPath(entry.book_file, old_path, new_path)
            if moved then
                entry.book_file = moved
                changed = true
            end
        elseif type(entry) == "table" and entry.book_file == old_path then
            if new_path then
                entry.book_file = new_path
            else
                entry.book_file = nil
                entry.book_title = nil
            end
            changed = true
        end
    end
    if changed then writeIndex(index) end
end

--- Filesystem-safe fragment from the prompt (FAT-safe: device storage).
local function sanitizeForFilename(s)
    s = s:gsub("[%c/\\:*?\"<>|%.]", " "):gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
    if #s > 40 then
        -- Byte-truncate, then drop a possibly split trailing UTF-8 sequence
        s = require("util").fixUtf8(s:sub(1, 40), ""):match("^%s*(.-)%s*$") or ""
    end
    return s
end

--- Save a picture beside the others: the file named by date and subject with
--- the extension its bytes call for, its index entry (recordImage: the book,
--- the prompt sent, the provenance, meta), and its thumbnail cut from one
--- decode. Images are KEPT (maintainer decision 2026-07-16); the gallery
--- handles deletion. Returns the path and the decoded picture (for the
--- viewer; nil when it did not decode), or nil when the file could not be
--- written.
function ImageGenerator.saveImage(image_data, description, book_info, full_prompt, provenance, meta)
    local lfs = require("libs/libkoreader-lfs")
    local dir = ImageGenerator.getImagesDir()
    if not lfs.attributes(dir, "mode") then
        lfs.mkdir(dir)
    end
    local snippet = description and sanitizeForFilename(description) or ""
    if snippet == "" then snippet = "image" end
    local base = string.format("%s/%s %s", dir, os.date("%Y-%m-%d %H.%M.%S"), snippet)
    local ext = ImageGenerator.imageExtension(image_data)
    local path = base .. "." .. ext
    local n = 1
    while lfs.attributes(path, "mode") do
        n = n + 1
        path = string.format("%s (%d).%s", base, n, ext)
    end
    local f = io.open(path, "wb")
    if not f then return nil end
    f:write(image_data)
    f:close()
    local name = path:match("([^/]+)$")
    meta = meta or {}
    meta.description = meta.description or description
    ImageGenerator.recordImage(name, book_info, full_prompt or description, provenance, meta)
    local okd, bb = pcall(function()
        return require("ui/renderimage"):renderImageData(image_data, #image_data, false)
    end)
    if not (okd and bb) then return path end
    ImageGenerator.makeThumbnail(name, bb)
    return path, bb
end

--- Save the generated image (saveImage) and show it in KOReader's
--- ImageViewer. `image_data` is the raw PNG/JPEG/WebP binary string.
--- `book_info` = optional { file, title } → recorded in the images index.
--- full_prompt (optional): the exact prompt sent to the API (context-framed);
--- recorded in the index so the gallery's "Show full prompt" shows the truth.
--- `description` stays the raw selection — it drives filename + viewer title.
--- provenance = the prompt writer's line, recorded and shown before the prompt.
--- meta = { provider, model, kinds } for the index (S7).
local function showImage(image_data, description, on_close, book_info, full_prompt, provenance, meta, on_saved)
    local UIManager  = require("ui/uimanager")

    local path, bb = ImageGenerator.saveImage(image_data, description, book_info, full_prompt, provenance, meta)
    if not path then
        showNotice(_("Failed to save generated image to disk."))
        return
    end
    -- the new picture is on disk: a replace may delete the old one now (S9),
    -- never before
    if on_saved then
        local ok_s, err_s = pcall(on_saved, path)
        if not ok_s then logger.warn("KOAssistant: after saving an image:", err_s) end
    end

    -- Try to load KOReader's ImageViewer
    local ok, ImageViewer = pcall(require, "ui/widget/imageviewer")
    if not ok then
        -- Older KOReader builds may not have ImageViewer — offer a save notice
        if bb then bb:free() end
        showNotice(T(_("Image saved to:\n%1"), path))
        if on_close then on_close() end
        return
    end

    local title_text = _("Generated image")
    if description then
        title_text = description
        if #title_text > 60 then
            -- Byte-truncate, then drop a possibly split trailing UTF-8 sequence
            title_text = require("util").fixUtf8(title_text:sub(1, 60), "") .. "…"
        end
    end

    -- Framed prompt rides as the native ImageViewer caption (triangle icon in
    -- the title bar toggles it; starts hidden). Truncated — a full multi-side
    -- frame as a title-bar subtitle would squeeze the image out; the complete
    -- prompt is a gallery hold away. Skipped when unframed (= title already).
    local caption
    if (full_prompt and full_prompt ~= description) or provenance then
        caption = ImageGenerator.promptShown(full_prompt or description, provenance)
        if #caption > 400 then
            caption = require("util").fixUtf8(caption:sub(1, 400), "") .. "…"
        end
    end
    -- the picture decoded once for its thumbnail is the one shown (the
    -- viewer frees it on close); the file when it did not decode here
    local viewer = ImageViewer:new{
        file = (not bb) and path or nil,
        image = bb,
        image_disposable = true,
        with_title_bar = true,
        title_text = title_text,
        caption = caption,
        caption_visible = false,
        is_doc_page = false,
    }
    if on_close then
        local orig_onClose = viewer.onClose
        viewer.onClose = function(self_v, ...)
            if orig_onClose then orig_onClose(self_v, ...) end
            on_close()
        end
    end
    UIManager:show(viewer)
end

-- ---------------------------------------------------------------------------
-- Background subprocess fetches (transport shared with base.lua)
-- ---------------------------------------------------------------------------

--- Build a background function for ffiutil.runInSubProcess that runs `fetch`
--- (returning status_code, body) and writes "OK:<body>" / "ERR:<message>" to
--- the pipe. Transport lives in BaseHandler.fetchInSubprocess (macOS raw-SSL
--- + standard paths); writes go through the looped BaseHandler.writeAllToFD.
local function makePipeFetchFn(fetch, err_prefix)
    return function(pid, child_write_fd)
        if not pid or not child_write_fd then return end
        local ok, err = pcall(function()
            local code, body = fetch()
            if code ~= 200 then
                -- a refusal arrives as JSON with error.message (an OpenAI
                -- moderation refusal is a 400): show the message, not the body (B459)
                BaseHandler.writeAllToFD(child_write_fd, "ERR:" .. ImageGenerator.errorMessage(code, body))
            else
                BaseHandler.writeAllToFD(child_write_fd, "OK:" .. (body or ""))
            end
        end)
        if not ok then
            BaseHandler.writeAllToFD(child_write_fd, "ERR:" .. err_prefix .. tostring(err))
        end
        ffi.C.close(child_write_fd)
        pcall(function() ffi.C._exit(0) end)
    end
end

--- POST the image-generation request; pipe carries "OK:<json>" or "ERR:<msg>".
--- @param endpoint table: IMAGE_ENDPOINTS entry (used for key_header)
--- @param extra_headers table|nil: the request's own headers (buildRequest)
local function makeBackgroundFn(url, api_key, request_body_str, endpoint, extra_headers)
    -- Pre-resolve DNS in parent (needed on macOS after fork)
    local resolved_ip = BaseHandler.resolveForSubprocess(url)

    local auth_header_name  = (endpoint and endpoint.key_header) or "Authorization"
    local auth_header_value = (auth_header_name == "Authorization")
        and ("Bearer " .. api_key)
        or api_key
    local headers = {
        ["Content-Type"]   = "application/json",
        [auth_header_name] = auth_header_value,
        ["Content-Length"] = tostring(#request_body_str),
    }
    for name, value in pairs(extra_headers or {}) do headers[name] = value end

    return makePipeFetchFn(function()
        return BaseHandler.fetchInSubprocess(url, {
            method = "POST",
            headers = headers,
            body = request_body_str,
            resolved_ip = resolved_ip,
            -- OpenAI: "complex prompts may take up to 2 minutes"
            timeout = 180,
        })
    end, "Subprocess error: ")
end

--- GET binary content from a URL; pipe carries "OK:<binary>" or "ERR:<msg>".
local function makeDownloadFn(image_url)
    local resolved_ip = BaseHandler.resolveForSubprocess(image_url)

    return makePipeFetchFn(function()
        return BaseHandler.fetchInSubprocess(image_url, {
            resolved_ip = resolved_ip,
            timeout = 60,
        })
    end, "Download subprocess error: ")
end

-- ---------------------------------------------------------------------------
-- Poll helper: read subprocess pipe until EOF, then reap the child
-- ---------------------------------------------------------------------------

--- Non-blocking polling via ffiutil.getNonBlockingReadSize (portable — raw
--- O_NONBLOCK constants differ between Linux and macOS).
local function pollSubprocess(pid, parent_read_fd, on_done)
    local UIManager = require("ui/uimanager")
    local time = require("ui/time")
    local chunksize = 1024 * 64
    local buf = ffi.new("char[?]", chunksize)
    local buf_ptr = ffi.cast("void*", buf)
    local response_parts = {}
    local poll_task
    local first_at -- when the answer started coming through the pipe

    local function finish()
        ffi.C.close(parent_read_fd)
        local size = 0
        for _idx, part in ipairs(response_parts) do size = size + #part end
        logger.dbg("KOAssistant: image subprocess answer:", size, "bytes, through the pipe in",
            first_at and time.to_ms(time.now() - first_at) or 0, "ms")
        -- Reap the child so it doesn't linger as a zombie (EOF can arrive a
        -- moment before the process is collectable)
        if not ffiutil.isSubProcessDone(pid) then
            local collect
            collect = function()
                if not ffiutil.isSubProcessDone(pid) then
                    UIManager:scheduleIn(1, collect)
                end
            end
            UIManager:scheduleIn(1, collect)
        end
        on_done(table.concat(response_parts))
    end

    poll_task = function()
        while true do
            local readsize = ffiutil.getNonBlockingReadSize(parent_read_fd) or 0
            if readsize > 0 then
                local bytes = tonumber(ffi.C.read(parent_read_fd, buf_ptr, chunksize))
                if bytes and bytes > 0 then
                    first_at = first_at or time.now()
                    table.insert(response_parts, ffi.string(buf_ptr, bytes))
                else
                    finish()  -- 0 = EOF, negative = read error
                    return
                end
            elseif ffiutil.isSubProcessDone(pid) then
                -- Child exited (and is now reaped); its pipe end is closed, so
                -- blocking reads drain the remainder and then return 0
                while true do
                    local bytes = tonumber(ffi.C.read(parent_read_fd, buf_ptr, chunksize))
                    if bytes and bytes > 0 then
                        table.insert(response_parts, ffi.string(buf_ptr, bytes))
                    else
                        break
                    end
                end
                finish()
                return
            else
                -- Once the answer is flowing, drain it quickly: the child
                -- holds it whole and waits on a full pipe (64 KB) until we
                -- read. A picture's answer runs to megabytes, and on a
                -- one-core reader each poll moved one pipe-full: half a
                -- minute for 10 MB.
                UIManager:scheduleIn(#response_parts > 0 and 0.01 or 0.15, poll_task)
                return
            end
        end
    end

    UIManager:scheduleIn(0.15, poll_task)
    return poll_task
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Generate an image from `word` using the currently selected agent/provider.
---
--- @param word         string  The selected text (place / person description)
--- @param config_table table   The global `configuration` table from main.lua
--- @param settings     table   LuaSettings instance (for GUI API keys)
--- @param book_info    table|nil { file, title } for the images index
--- Assemble the prompt actually sent to the image API (context framing,
--- 2026-08-13). Exported so the action-details view and the settings screen
--- render the SAME template through the same code — no display copy to drift.
--- opts: { book_metadata = {title, author}, window = {prev, next},
---        after_limit = ScopeResolver.limitAfter's value (Context Direction and
---        the spoiler clamp, B461), book_info_level = "none"|"title"|"basic"|"full"
---        (the Book info level, P7; nil = basic) }.
--- features gates the frame parts: image_gen_frame_identity /
--- image_gen_frame_context (both opt-out, default on — schema defaults).
--- `description` stays the raw selection (filename + viewer title); English
--- frame on purpose — model-facing, like the quiz/nudge templates.
function ImageGenerator.buildPrompt(description, opts, features)
    local fixUtf8 = require("util").fixUtf8
    features = features or {}
    local frame = {}
    local meta = (features.image_gen_frame_identity ~= false)
        and opts and opts.book_metadata or nil
    -- The Book info level decides the identity, as it does in chat: None sends
    -- neither, Title the title alone (data_access_picture.md P7)
    local info_level = opts and opts.book_info_level or "basic"
    if info_level == "none" then meta = nil end
    if meta and meta.title and meta.title ~= "" then
        if info_level ~= "title" and meta.author and meta.author ~= "" then
            table.insert(frame, string.format('The passage is from the book "%s" by %s; match the book\'s setting and period.', meta.title, meta.author))
        else
            table.insert(frame, string.format('The passage is from the book "%s"; match the book\'s setting and period.', meta.title))
        end
    end
    local w = (features.image_gen_frame_context ~= false)
        and opts and opts.window or nil
    local prev = w and type(w.prev) == "string" and w.prev or ""
    local next_ = w and type(w.next) == "string" and w.next or ""
    -- The text after the selection is cut as chat's context is: Context
    -- Direction "before" drops it, spoiler protection keeps the selection's
    -- own sentence or paragraph (B461)
    next_ = require("koassistant.request.scope_resolver").limitAfter(next_, opts and opts.after_limit)
    if prev ~= "" or next_ ~= "" then
        -- Image prompts reward brevity: ~400 chars a side, UTF-8-safe cuts
        if #prev > 400 then prev = "…" .. fixUtf8(prev:sub(-400), "") end
        if #next_ > 400 then next_ = fixUtf8(next_:sub(1, 400), "") .. "…" end
        table.insert(frame, FRAME_AROUND .. prev .. " […] " .. next_)
    end
    -- The style (S6) when it is not the frame's own "illustration", and the
    -- reader's note (S5), as lines after the frame
    local extra = ImageGenerator.extraLines(opts, features)
    -- Subject-first (2026-08-14 audit): the passage leads, the frame follows as
    -- labeled context — image models weight the opening as the subject, and the
    -- old shape (up to ~900 frame chars before the passage) risked the model
    -- illustrating the context window. The no-text rule guards against the
    -- title/author frame inviting book-cover compositions with rendered text.
    if #frame > 0 then
        return "Create an illustration of the following passage from a book. "
            .. "Illustrate the passage itself; do not render any text, titles, or captions in the image."
            .. "\n\nPassage to illustrate: " .. description
            .. "\n\n" .. table.concat(frame, " ") .. extra
    end
    return description .. extra
end

--- The lines a framed prompt ends with: the style when it is not the
--- default, the reader's note. "" when there are none.
function ImageGenerator.extraLines(opts, features)
    local lines = {}
    local style, is_default = require("koassistant.images.prompt_writer").styleText(features)
    if not is_default then lines[#lines + 1] = "Style: " .. style .. "." end
    local note = opts and opts.note
    if type(note) == "string" and note:match("%S") then
        lines[#lines + 1] = "The reader's note: " .. note:gsub("%s+", " "):match("^%s*(.-)%s*$")
    end
    if #lines == 0 then return "" end
    return "\n\n" .. table.concat(lines, "\n")
end

--- A recorded prompt in another style without a request (S9): a framed
--- prompt's closing lines (extraLines: the style, the reader's note) with the
--- style line swapped, or the line added (a written prompt with the writer
--- off); the default style is the frame's own word and needs no line. Pure.
function ImageGenerator.restyleFramed(prompt, style_text, is_default)
    prompt = type(prompt) == "string" and prompt or ""
    local body, tail = prompt, ""
    local last = prompt:match(".*()\n\n")
    if last then
        local block = prompt:sub(last + 2)
        local closing = block ~= ""
        for line in (block .. "\n"):gmatch("(.-)\n") do
            if not (line:find("^Style: ") or line:find("^The reader's note: ")) then closing = false end
        end
        if closing then body, tail = prompt:sub(1, last - 1), block end
    end
    local lines = {}
    if not is_default then lines[#lines + 1] = "Style: " .. tostring(style_text) .. "." end
    for line in (tail .. "\n"):gmatch("(.-)\n") do
        if line:find("^The reader's note: ") then lines[#lines + 1] = line end
    end
    if #lines == 0 then return body end
    return body .. "\n\n" .. table.concat(lines, "\n")
end

--- A picture drawn again, in its provenance line (S7, S9): how it was drawn
--- (head), what happened to the prompt on the way (line: the restyle, or
--- nil), then its source's own line. Pure.
function ImageGenerator.regeneratedProvenance(head, line, source)
    local parts = { head }
    if line then parts[#parts + 1] = line end
    if source then parts[#parts + 1] = source end
    return table.concat(parts, " ")
end

--- Whether the prompt writer wrote a recorded prompt (S9): what the record
--- says, else the no-text line every written prompt ends with. Pure.
function ImageGenerator.promptWritten(entry)
    if type(entry) ~= "table" then return false end
    if type(entry.written) == "boolean" then return entry.written end
    local prompt = type(entry.prompt) == "string" and entry.prompt or ""
    local tail = require("koassistant.images.prompt_writer").NO_TEXT
    return prompt:sub(-#tail) == tail
end

--- The style a recorded picture was drawn in, as the prompt says it (S9): its
--- record, else the default (pictures from before styles were drawn without
--- one, which is the default's look). Pure.
function ImageGenerator.recordedStyle(entry)
    local s = type(entry) == "table" and entry.style
    if type(s) == "string" and s ~= "" then return s end
    return (require("koassistant.images.prompt_writer").styleText({}))
end

--- The framed prompt for an X-Ray entry (Illustrate from X-Ray with the
--- writer off, or its fallback): the entry's name and description, the title
--- and author per the Book info level, the style and the note. Pure.
function ImageGenerator.buildEntryPrompt(entry, opts, features)
    features = features or {}
    entry = entry or {}
    local kind = type(entry.type) == "string" and entry.type ~= "" and entry.type or "thing"
    local parts = { "Create an illustration of " .. (kind:match("^[aeiou]") and "an " or "a ") .. kind
        .. FRAME_ENTRY .. " Do not render any text, titles, or captions in the image." }
    local desc = type(entry.description) == "string" and entry.description ~= "" and (": " .. entry.description) or ""
    parts[#parts + 1] = "To illustrate: " .. (entry.name or "") .. desc
    local meta = (features.image_gen_frame_identity ~= false) and opts and opts.book_metadata or nil
    local level = opts and opts.book_info_level or "basic"
    if level ~= "none" and meta and type(meta.title) == "string" and meta.title ~= "" then
        if level ~= "title" and type(meta.author) == "string" and meta.author ~= "" then
            parts[#parts + 1] = string.format('From the book "%s" by %s; match the book\'s setting and period.', meta.title, meta.author)
        else
            parts[#parts + 1] = string.format('From the book "%s"; match the book\'s setting and period.', meta.title)
        end
    end
    return table.concat(parts, "\n\n") .. ImageGenerator.extraLines(opts, features)
end

--- The prompt template as display text: the real builder run with placeholder
--- tokens, honoring the caller's current frame toggles, style and writer
--- setting. Tokens stay English — this shows the wire truth, and the frame
--- itself is English. With the prompt writer on, its instructions and the
--- material it reads come first, then the framed prompt it falls back to.
function ImageGenerator.promptTemplateText(features)
    features = features or {}
    local plain = ImageGenerator.buildPrompt("{selected text}", {
        book_metadata = { title = "{book title}", author = "{book author}" },
        window = { prev = "{text before selection}", next = "{text after selection}" },
    }, features)
    if features.image_gen_writer == false then return plain end
    local PromptWriter = require("koassistant.images.prompt_writer")
    local material = PromptWriter.material({
        passage = "{selected text}",
        note = "{your note, when you add one}",
        around = (features.image_gen_frame_context ~= false)
            and { before = "{text before selection}", after = "{text after selection}" } or nil,
        entries = { { name = "{a name in the passage}", type = "person",
            description = "{its description from the book's X-Ray}" } },
        book = (features.image_gen_frame_identity ~= false)
            and { title = "{book title}", author = "{book author}" } or nil,
        background = "{the book's Background}",
        style = (PromptWriter.styleText(features)),
        shape = PromptWriter.shapeLine(features.image_gen_shape or "fit", 3 / 4, true),
    })
    return T(_("Write the prompt with AI is on: the prompt writer (your chat model, or its fast model if Prompt writer says so) reads the material below and writes the prompt the image model receives (with \"The picture contains no text, letters, titles or captions.\" added). Its instructions:\n\n%1\n\nThe material (each block only when there is something for it):\n\n%2\n\nIf the writer fails, this prompt is sent instead:\n\n%3"),
        PromptWriter.systemText({}), material, plain)
end

--- What of a run's material may go (S5): a kind goes only when it is allowed
--- for every provider it reaches, the prompt writer's and the image
--- provider's (the text around the passage is "text around what you tap",
--- data_access_picture.md; X-Ray descriptions are stored material, judged by
--- the kinds the X-Ray was built from). spec = { features (the run's, with an
--- Allow once on it), recipients, book (the book's own values), path, window
--- (whether the text around is in the material), stored (the X-Ray's cache
--- entry) }. Pure.
--- @return table { around = boolean, stored = boolean }
function ImageGenerator.allowedMaterial(spec)
    local Gates = require("koassistant.request.privacy_gates")
    local function forAll(kind)
        for _idx, p in ipairs(spec.recipients or {}) do
            local ctx = { features = spec.features, provider = p, book = spec.book,
                once = Gates.onceFor(spec.features, spec.path) }
            if not Gates.allows(kind, ctx) then return false end
        end
        return true
    end
    local out = { around = (spec.window and forAll("nearby_text")) or false, stored = true }
    if spec.stored then
        for kind, used in pairs(Gates.stampedKinds(spec.stored)) do
            if used and not forAll(kind) then out.stored = false end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Shape and Detail (image round S2): one pair of settings for every provider,
-- turned here into what each model takes (the providers' docs and probes,
-- 2026-10-14)
-- ---------------------------------------------------------------------------

-- The aspect ratios a model takes; a shape goes out as the nearest of them
-- (xAI's grok-imagine-image took 3:4 and 4:3 in a probe, 2026-10-14)
local XAI_V1_RATIOS = { "1:1", "4:3", "3:4", "3:2", "2:3", "16:9", "9:16" }
local XAI_V2_RATIOS = { "1:1", "4:3", "3:4", "3:2", "2:3", "16:9", "9:16", "2:1", "1:2",
    "19.5:9", "9:19.5", "20:9", "9:20", "21:9", "5:2" }
local GEMINI_RATIOS = { "1:1", "5:4", "4:5", "4:3", "3:4", "3:2", "2:3", "16:9", "9:16", "21:9" }
-- The Gemini image models that think before they draw and take the level
-- "minimal", which Draft sends (a probe, 2026-10-15: Nano Banana 2.1 drew in
-- about 9 s instead of 13 to 23 s, with no thinking tokens and pictures as
-- good). Exact ids: a level a model refuses is a 400. Flash Lite does not
-- think, so it gets nothing.
local GEMINI_THINKING_MINIMAL = { ["gemini-nano-banana-2.1"] = true, ["gemini-3-pro-image"] = true }
-- The three sizes every gpt-image model takes, with their ratios
local OPENAI_SIZES = { { "1024x1024", 1 }, { "1536x1024", 3 / 2 }, { "1024x1536", 2 / 3 } }

-- What OpenRouter's listed models take, as its catalog lists them
-- (GET /api/v1/images/models, 2026-10-14): aspect ratios, resolutions,
-- qualities, output formats. A model picked from the live catalog (More
-- models… in the settings) brings its own lists, stored beside the pick
-- (image_gen_openrouter_caps).
local OPENROUTER_FACTS = {
    ["openai/gpt-image-2.5-flare"] = {
        ratios = { "1:1", "3:2", "2:3", "4:3", "3:4", "16:9", "9:16", "21:9", "auto" },
        qualities = { "auto", "low", "medium", "high", "xhigh", "max" },
        -- not in the catalog, but passed on to OpenAI: a probe answered JPEG
        -- (255 KB for the PNG's 3 MB, 2026-10-14); FLUX 3 refuses the key
        formats = { "png", "jpeg", "webp" },
    },
    ["google/gemini-nano-banana-2.1"] = {
        ratios = { "1:1", "1:4", "1:8", "2:3", "3:2", "3:4", "4:1", "4:3", "4:5", "5:4", "8:1", "9:16",
            "16:9", "21:9" },
        resolutions = { "1K", "2K", "4K" },
    },
    ["black-forest-labs/flux-3-image"] = {
        ratios = { "21:9", "2:1", "16:9", "3:2", "7:5", "4:3", "5:4", "1:1", "4:5", "3:4", "5:7", "2:3",
            "9:16", "1:2", "9:21", "auto" },
        resolutions = { "768", "1K", "1.5K", "2K", "4K" },
    },
    -- (the catalog, 2026-10-16: the same lists as FLUX 3 Image)
    ["black-forest-labs/flux-3-image-klein"] = {
        ratios = { "21:9", "2:1", "16:9", "3:2", "7:5", "4:3", "5:4", "1:1", "4:5", "3:4", "5:7", "2:3",
            "9:16", "1:2", "9:21", "auto" },
        resolutions = { "768", "1K", "1.5K", "2K", "4K" },
    },
    ["bytedance-seed/seedream-5-0-flash"] = {
        ratios = { "1:1", "1:2", "2:1", "2:3", "3:2", "3:4", "4:3", "4:5", "5:4", "9:16", "16:9", "9:19.5",
            "19.5:9", "9:20", "20:9", "9:21", "21:9", "auto" },
        resolutions = { "1K", "2K" },
    },
    ["recraft/recraft-v4.1-flash"] = {
        ratios = { "1:1", "4:3", "3:4", "16:9", "9:16", "auto" },
    },
}

-- Detail as an OpenRouter quality: the first of these the model lists
local OPENROUTER_QUALITY = {
    draft = { "low", "medium", "high" },
    standard = { "medium", "high", "low" },
    best = { "xhigh", "high", "medium" },
}

local SHAPES = { fit = true, portrait = true, landscape = true, square = true, auto = true }
local DETAILS = { draft = true, standard = true, best = true }

local function ratioValue(spec)
    local w, h = spec:match("^([%d%.]+):([%d%.]+)$")
    return tonumber(w) / tonumber(h)
end

-- The entry of `list` nearest to `ratio`, compared on a log scale so a
-- portrait and a landscape miss weigh alike; value_of reads an entry's ratio
local function nearest(list, ratio, value_of)
    local best, best_d
    for _idx, entry in ipairs(list) do
        local d = math.abs(math.log(value_of(entry) / ratio))
        if not best_d or d < best_d - 1e-9 then best, best_d = entry, d end
    end
    return best
end

-- The ratios of a list that are ratios ("auto" and the like left out)
local function ratioList(list)
    local out = {}
    for _idx, spec in ipairs(type(list) == "table" and list or {}) do
        if type(spec) == "string" and spec:match("^[%d%.]+:[%d%.]+$") and ratioValue(spec) > 0 then
            out[#out + 1] = spec
        end
    end
    return #out > 0 and out or nil
end

-- A resolution as a number of K: "768" = 0.75, "1.5K" = 1.5
local function resolutionK(spec)
    if type(spec) ~= "string" then return nil end
    local k = spec:upper():match("^([%d%.]+)K$")
    if k then return tonumber(k) end
    local px = tonumber(spec)
    return px and px / 1024 or nil
end

-- The first of `wanted` that `list` holds
local function firstListed(list, wanted)
    for _idx, w in ipairs(wanted) do
        for _j, v in ipairs(list) do
            if v == w then return w end
        end
    end
    return nil
end

--- What an OpenRouter catalog entry's supported_parameters say a model
--- takes: { ratios, resolutions, qualities, formats } (each a list of the
--- catalog's strings, or nil). Pure; the catalog list and the stored pick use it.
function ImageGenerator.openRouterFacts(params)
    params = type(params) == "table" and params or {}
    local function enum(key)
        local p = type(params[key]) == "table" and params[key] or nil
        if not (p and type(p.values) == "table") then return nil end
        local list = {}
        for _idx, v in ipairs(p.values) do
            if type(v) == "string" then list[#list + 1] = v end
        end
        return #list > 0 and list or nil
    end
    return { ratios = enum("aspect_ratio"), resolutions = enum("resolution"),
             qualities = enum("quality"), formats = enum("output_format") }
end

--- OpenRouter's image catalog answer as the More models… list: { { id, name,
--- facts }, ... } sorted by id, or nil when the answer is not a catalog. A
--- model that answers only in SVG (a vector maker) is left out: the image
--- viewer shows raster pictures. Pure.
function ImageGenerator.parseOpenRouterCatalog(body)
    local ok, resp = pcall(json.decode, body or "")
    if not ok or type(resp) ~= "table" or type(resp.data) ~= "table" then return nil end
    local out = {}
    for _idx, m in ipairs(resp.data) do
        if type(m) == "table" and str(m.id) and m.id ~= "" then
            local facts = ImageGenerator.openRouterFacts(m.supported_parameters)
            local raster = not facts.formats
                or firstListed(facts.formats, { "png", "jpeg", "webp" }) ~= nil
            if raster then
                out[#out + 1] = { id = m.id, name = str(m.name) or m.id, facts = facts }
            end
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Fetch OpenRouter's image catalog in the background (no key needed):
--- on_done(models) with parseOpenRouterCatalog's list, or on_done(nil, message).
function ImageGenerator.fetchOpenRouterCatalog(on_done)
    BaseHandler.fetchAsync(IMAGE_ENDPOINTS.openrouter.catalog, { timeout = 20 }, function(code, body)
        if code ~= 200 then
            on_done(nil, code and ("HTTP " .. tostring(code)) or tostring(body))
            return
        end
        local models = ImageGenerator.parseOpenRouterCatalog(body)
        if not models or #models == 0 then
            on_done(nil, _("No models found in the response"))
            return
        end
        on_done(models)
    end)
end

--- What an image model takes for Shape and Detail: `ratios` (its aspect
--- ratios; OpenAI takes sizes instead), `custom_size` (any width and height in
--- steps of 16: OpenAI's 2.5 models), `best_quality` (the quality Best sends to
--- OpenAI), `detail` (false where the model has one quality and size: xAI's
--- grok-imagine-image, Gemini's Flash Lite), `thinking_minimal` (a Gemini
--- model that thinks first and takes "minimal", which Draft sends). OpenRouter's
--- models add `resolutions`, `qualities` and `formats` from its catalog: the listed
--- models' own, or a More models… pick's, stored in
--- features.image_gen_openrouter_caps. Pure; the Detail row asks it too.
function ImageGenerator.pictureFacts(provider, model, features)
    model = type(model) == "string" and model or ""
    if provider == "openrouter" then
        local caps = features and features.image_gen_openrouter_caps
        local listed = OPENROUTER_FACTS[model]
            or (type(caps) == "table" and caps.model == model and caps) or {}
        local resolutions = {}
        for _idx, r in ipairs(type(listed.resolutions) == "table" and listed.resolutions or {}) do
            if resolutionK(r) then resolutions[#resolutions + 1] = r end
        end
        local qualities = type(listed.qualities) == "table" and listed.qualities or {}
        local graded = firstListed(qualities, { "low", "medium", "high", "xhigh" }) ~= nil
        return {
            ratios = ratioList(listed.ratios),
            resolutions = #resolutions > 0 and resolutions or nil,
            qualities = graded and qualities or nil,
            formats = type(listed.formats) == "table" and listed.formats or nil,
            detail = graded or #resolutions > 1,
        }
    end
    if provider == "openai" then
        local v25 = model:find("^gpt%-image%-2%.5") ~= nil
        return { custom_size = v25, best_quality = v25 and "xhigh" or "high", detail = true }
    elseif provider == "xai" then
        -- 2.0 and its point releases; a dated id (grok-imagine-image-2026-…) is 1.0
        if model:find("^grok%-imagine%-image%-%d+%.%d") then
            return { ratios = XAI_V2_RATIOS, detail = true }
        end
        return { ratios = XAI_V1_RATIOS, detail = false }
    elseif provider == "gemini" then
        return { ratios = GEMINI_RATIOS, detail = model:find("flash%-lite") == nil,
            thinking_minimal = GEMINI_THINKING_MINIMAL[model] or nil }
    end
    return { detail = false }
end

--- The proportions a Shape asks for, width over height; nil = the model
--- chooses. Fit my screen is the screen as the reader holds it, 3:4 (an
--- e-reader held upright) when no screen is known.
function ImageGenerator.shapeRatio(shape, screen)
    if shape == "auto" then return nil end
    if shape == "portrait" then return 2 / 3 end
    if shape == "landscape" then return 3 / 2 end
    if shape == "square" then return 1 end
    local w = screen and tonumber(screen.w)
    local h = screen and tonumber(screen.h)
    if w and h and w > 0 and h > 0 then return w / h end
    return 3 / 4
end

-- OpenAI's size: Fit my screen on a model that takes any size is the
-- screen's own proportions (the long edge 1536, the short one in steps of 16,
-- the ratio held within 1:3 to 3:1: 1152x1536 on a 3:4 screen); every other
-- shape and model gets the nearest of the three common sizes
local function openaiSize(ratio, shape, custom)
    if custom and shape == "fit" then
        ratio = math.max(1 / 3, math.min(3, ratio))
        local short = math.floor(1536 * math.min(ratio, 1 / ratio) / 16 + 0.5) * 16
        if ratio < 1 then return string.format("%dx1536", short) end
        return string.format("1536x%d", short)
    end
    return nearest(OPENAI_SIZES, ratio, function(e) return e[2] end)[1]
end

--- The request one image costs (B064): the URL, the authentication header's
--- name and the body, exactly as sent. Shape and Detail come from features
--- (image_gen_shape, default Fit my screen; image_gen_detail, default Draft);
--- `screen` = { w, h } is the screen Fit my screen fits. Pure;
--- tests/inspect.lua --image and the audit's image probe build with it too.
--- @return table|nil { url, key_header, body, headers (extra, or nil) } (nil
---   for a provider with no image endpoint)
function ImageGenerator.buildRequest(provider, model, prompt, features, screen)
    features = features or {}
    local endpoint = IMAGE_ENDPOINTS[provider]
    if not endpoint then return nil end
    local shape = SHAPES[features.image_gen_shape] and features.image_gen_shape or "fit"
    local detail = DETAILS[features.image_gen_detail] and features.image_gen_detail or "draft"
    local ratio = ImageGenerator.shapeRatio(shape, screen)
    local facts = ImageGenerator.pictureFacts(provider, model, features)
    if provider == "openrouter" then
        -- Each model takes what its catalog entry lists: the nearest ratio,
        -- Detail as a quality and a resolution (1K, Best 2K, else the nearest
        -- listed), JPEG where a model offers it; Let the model choose and a
        -- model that lists nothing send no parameter
        local body = { model = model, prompt = prompt }
        if ratio and facts.ratios then body.aspect_ratio = nearest(facts.ratios, ratio, ratioValue) end
        if facts.qualities then body.quality = firstListed(facts.qualities, OPENROUTER_QUALITY[detail]) end
        if facts.resolutions then
            body.resolution = nearest(facts.resolutions, (detail == "best") and 2 or 1, resolutionK)
        end
        if facts.formats and firstListed(facts.formats, { "jpeg" }) then body.output_format = "jpeg" end
        local github = require("koassistant.core.constants").GITHUB
        return {
            url = endpoint.url,
            key_header = endpoint.key_header,
            body = body,
            -- the app's attribution, as OpenRouter's chat requests send it
            headers = { ["HTTP-Referer"] = github and github.URL or nil, ["X-Title"] = "KOAssistant" },
        }
    end
    if endpoint.is_gemini then
        -- generateContent with image output; model in the path. The Gemini
        -- Content Filter setting applies here as it does to chat (a book
        -- passage is refused by Google's default filter more often)
        local image_config = {}
        if ratio then image_config.aspectRatio = nearest(facts.ratios, ratio, ratioValue) end
        if facts.detail then image_config.imageSize = (detail == "best") and "2K" or "1K" end
        local generation = {
            responseModalities = { "IMAGE", "TEXT" },
            imageConfig = next(image_config) and image_config or nil,
        }
        -- Draft is the quick picture: a model that thinks first thinks as
        -- little as it can (Standard and Best leave it to the model)
        if detail == "draft" and facts.thinking_minimal then
            generation.thinkingConfig = { thinkingLevel = "minimal" }
        end
        return {
            url = endpoint.url .. "/" .. model .. ":generateContent",
            key_header = endpoint.key_header,
            body = {
                contents = { { role = "user", parts = { { text = prompt } } } },
                generationConfig = generation,
                safetySettings = require("koassistant.api.gemini").safetySettings(features),
            },
        }
    end
    -- OpenAI-style images/generations request. Parameter support diverges
    -- (verified live 2026-07-16): OpenAI's gpt-image models reject
    -- response_format (b64_json is their default output); xAI rejects
    -- size/quality/style but honors response_format.
    local body = { model = model, prompt = prompt, n = 1 }
    if provider == "openai" then
        if ratio then body.size = openaiSize(ratio, shape, facts.custom_size) end
        body.quality = (detail == "best") and facts.best_quality
            or (detail == "standard") and "medium" or "low"
        -- JPEG: faster to make (OpenAI) and to show, and a fraction of the
        -- PNG's size on the device; a grayscale screen gains nothing from PNG
        body.output_format = "jpeg"
    else
        body.response_format = "b64_json"
        if provider == "xai" then
            if ratio then body.aspect_ratio = nearest(facts.ratios, ratio, ratioValue) end
            if facts.detail then
                body.quality = (detail == "draft") and "low" or "medium"
                body.resolution = (detail == "best") and "2k" or "1k"
            end
        end
    end
    return { url = endpoint.url, key_header = endpoint.key_header, body = body }
end

-- A Gemini answer without a picture, worded with its reason (B459): the
-- prompt's blockReason, else the candidate's finishReason, then whatever the
-- model said in text.
local function geminiNoImageMessage(resp, candidate, texts)
    local feedback = type(resp.promptFeedback) == "table" and resp.promptFeedback or {}
    local block = str(feedback.blockReason)
    local finish = str(candidate.finishReason)
    local head
    if block then
        head = T(_("Gemini refused the prompt (%1)."), block)
    elseif finish == "IMAGE_SAFETY" or finish == "SAFETY" or finish == "IMAGE_PROHIBITED_CONTENT"
            or finish == "PROHIBITED_CONTENT" or finish == "BLOCKLIST" or finish == "SPII" then
        head = T(_("Google's safety filter refused the picture (%1)."), finish)
    elseif finish and finish ~= "STOP" then
        head = T(_("Gemini returned no picture (%1)."), finish)
    else
        head = _("Gemini answered without a picture.")
    end
    local said = table.concat(texts, " "):gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
    if said ~= "" then
        if #said > 300 then said = require("util").fixUtf8(said:sub(1, 300), "") .. "…" end
        head = head .. "\n\n" .. said
    end
    return head
end

--- Read an image provider's answer (B064): { bytes = <binary> }, or
--- { url = <string> } when an OpenAI-style answer links the image, or nil and
--- the message to show. A Gemini answer without a picture names its reason.
function ImageGenerator.parseResponse(provider, body)
    local ok_parse, resp = pcall(json.decode, body or "")
    if not ok_parse or type(resp) ~= "table" then
        return nil, _("Failed to parse image generation response.")
    end
    -- API-level error ({ error = {...} } or { error = "..." }); type-checked
    -- so a JSON null (truthy sentinel) doesn't trip this on a success response
    if type(resp.error) == "table" or type(resp.error) == "string" then
        local err_msg = str(resp.error)
            or (type(resp.error) == "table" and str(resp.error.message))
            or _("Unknown API error")
        return nil, T(_("Image generation API error:\n\n%1"), err_msg)
    end
    local endpoint = IMAGE_ENDPOINTS[provider]
    if endpoint and endpoint.is_gemini then
        -- Images arrive as inlineData parts inside candidates[].content.parts
        local candidates = type(resp.candidates) == "table" and resp.candidates or {}
        local first = type(candidates[1]) == "table" and candidates[1] or {}
        local content = type(first.content) == "table" and first.content or {}
        local parts = type(content.parts) == "table" and content.parts or {}
        local texts = {}
        for _idx, part in ipairs(parts) do
            if type(part) == "table" and type(part.inlineData) == "table" then
                local mime_type = str(part.inlineData.mimeType)
                local data_b64 = str(part.inlineData.data)
                if mime_type and mime_type:sub(1, 6) == "image/" and data_b64 then
                    local bytes = mime.unb64(data_b64)
                    if not bytes or bytes == "" then
                        return nil, _("Failed to decode image data.")
                    end
                    return { bytes = bytes }
                end
            elseif type(part) == "table" and type(part.text) == "string" and part.thought ~= true then
                table.insert(texts, part.text)
            end
        end
        return nil, geminiNoImageMessage(resp, first, texts)
    end
    -- OpenAI-style answer: data[1].b64_json (preferred) or data[1].url
    local data_list = type(resp.data) == "table" and resp.data or nil
    local entry = data_list and type(data_list[1]) == "table" and data_list[1] or nil
    if not entry then
        return nil, _("No image data in response.")
    end
    local b64 = str(entry.b64_json)
    if b64 and b64 ~= "" then
        local bytes = mime.unb64(b64)
        if not bytes or bytes == "" then
            return nil, _("Failed to decode image data.")
        end
        return { bytes = bytes }
    end
    local image_url = str(entry.url)
    if image_url and image_url ~= "" then
        return { url = image_url }
    end
    return nil, _("No image URL in response.")
end

function ImageGenerator.generate(word, config_table, settings, book_info, opts)
    local ok, err = pcall(function()
        ImageGenerator._generateImpl(word, config_table, settings, book_info, opts)
    end)
    if not ok then
        logger.err("KOAssistant: image generation error:", err)
        showNotice(T(_("Image generation error:\n\n%1"), tostring(err)))
    end
end

--- Internal implementation — called via pcall from generate() for error catching.
--- opts (optional): { book_metadata = {title, author}, window = {prev, next},
--- after_limit, book_info_level, book_privacy, plugin } — context the prompt is
--- framed with (2026-08-13). book_metadata carries the per-book AI-identity
--- overrides already applied; window is the pre-extracted surrounding-context
--- selection window (hard-capped upstream; sent only where privacy_gates allows
--- the "nearby_text" kind for the image provider); book_privacy is the book's
--- own privacy values (PrivacyGates.overridesOf); plugin names the chat
--- provider in the questions and refreshes the settings after an answer.
--- The provider that draws, then run_fn(provider). Effective provider
--- (maintainer decision 2026-07-16): explicit image_gen_provider >
--- image-capable main provider; never fall back to a merely-keyed provider.
--- When the chat provider cannot draw, the S4 question first (its answer
--- saved as Provider, then retry()); without one, a notice.
local function withImageProvider(config_table, settings, opts, retry, run_fn)
    local features = (config_table and config_table.features) or {}
    local main_provider = config_table and config_table.provider
    local provider, unavailable = ImageGenerator.effectiveProvider(features, main_provider, settings)
    if not provider and unavailable == "no_endpoint" and followsMain(features) then
        -- The chat provider cannot draw (S4, ruling R4): ask once which keyed
        -- image provider makes the images, and save the answer as Provider
        local keyed = ImageGenerator.keyedProviders(settings)
        if #keyed > 0 then
            local plugin = opts and opts.plugin
            ImageGenerator.askProvider(main_provider, keyed, plugin, function(picked)
                saveAskedProvider(settings, features, plugin, picked)
                retry()
            end)
            return
        end
    end
    if not provider then
        if unavailable == "no_key" then
            showNotice(_("No API key found for the image generation provider.\n\nPlease add your key in KOAssistant settings."))
        else
            showNotice(_("Image generation is not available for the current provider.\n\nSupported: OpenAI, xAI (Grok), Gemini, OpenRouter. You can also pick a dedicated image provider in KOAssistant settings (Advanced)."))
        end
        return
    end
    run_fn(provider)
end

function ImageGenerator._generateImpl(word, config_table, settings, book_info, opts)
    withImageProvider(config_table, settings, opts, function()
        ImageGenerator.generate(word, config_table, settings, book_info, opts)
    end, function(provider)
        -- The subject: the selection, or (Illustrate from X-Ray, S8) an entry
        -- of the book's X-Ray
        opts = opts or {}
        local description
        if opts.entry then
            description = type(opts.entry.name) == "string" and opts.entry.name or ""
        else
            description = (word or ""):match("^%s*(.-)%s*$") or ""
        end
        if description == "" then
            showNotice(_("No description selected."))
            return
        end
        ImageGenerator._askAndRun(provider, description, config_table, settings, book_info, opts)
    end)
end

--- Draw a recorded prompt again (S7), or the reader's edit of it: the image
--- provider and model now in effect, Shape and Detail now in effect, no
--- prompt writer (the prompt is final). The Style now in effect too (S9): a
--- picture drawn in another style (recordedStyle) is restyled first, a
--- framed prompt by swapping its style line, a written one by the prompt
--- writer (one request; with the writer off, the style as a line); an edit
--- is drawn as the reader wrote it. The new picture is saved beside the
--- source, or in its place with spec.replace (the old one deleted once the
--- new one is saved). The prompt is stored material: the kinds it carries
--- (promptKinds) are judged for every provider it goes to, required (a
--- written prompt cannot go without what is in it), so Ask asks and Never
--- refuses. spec = { name (the source's file name), entry (its index entry),
--- prompt (the text to draw), edited, replace, plugin, ui, on_viewer_close }.
function ImageGenerator.regenerate(spec, config_table, settings)
    local ok, err = pcall(ImageGenerator._regenerateImpl, spec, config_table, settings)
    if not ok then
        logger.err("KOAssistant: image regeneration error:", err)
        showNotice(T(_("Image generation error:\n\n%1"), tostring(err)))
    end
end

function ImageGenerator._regenerateImpl(spec, config_table, settings)
    local prompt = type(spec.prompt) == "string" and spec.prompt:match("^%s*(.-)%s*$") or ""
    if prompt == "" then
        showNotice(_("The prompt is empty."))
        return
    end
    local opts = { plugin = spec.plugin, ui = spec.ui, on_viewer_close = spec.on_viewer_close }
    if spec.replace then
        local old = spec.name
        opts.on_saved = function() ImageGenerator.deleteImages({ old }) end
    end
    withImageProvider(config_table, settings, opts, function()
        ImageGenerator.regenerate(spec, config_table, settings)
    end, function(provider)
        local PromptWriter = require("koassistant.images.prompt_writer")
        local features = (config_table and config_table.features) or {}
        local entry = type(spec.entry) == "table" and spec.entry or {}
        local path = type(entry.book_file) == "string" and entry.book_file or nil
        -- the reader's UI reads the open book's values; a picture without a
        -- book must not borrow them
        if not path then opts.ui = nil end
        local kinds = ImageGenerator.promptKinds(entry)
        local description = type(entry.description) == "string" and entry.description:match("%S") and entry.description
            or ImageGenerator.subjectFromName(spec.name)
        -- The Style now in effect (S9): a picture drawn in another one is
        -- restyled first; an edit is drawn as the reader wrote it
        local style_text, style_default = PromptWriter.styleText(features)
        local written = ImageGenerator.promptWritten(entry)
        local restyle = not spec.edited and style_text ~= ImageGenerator.recordedStyle(entry)
        local writer_provider, writer_model
        if restyle and written and features.image_gen_writer ~= false then
            writer_provider, writer_model = PromptWriter.target(features,
                (config_table and config_table.provider) or require("koassistant.core.config_helper").mainProvider(features))
        end
        local head
        if spec.edited then
            head = _("Drawn from your edit of an earlier picture's prompt.")
        elseif restyle then
            head = T(_("Drawn again in another style (%1) from an earlier picture's prompt."),
                PromptWriter.styleLabel(features))
        else
            head = _("Drawn again from an earlier picture's prompt.")
        end
        local recipients = { provider }
        if writer_provider and writer_provider ~= provider then recipients = { writer_provider, provider } end
        local run_features = {}
        for k, v in pairs(features) do run_features[k] = v end
        run_features._data_once = nil
        local st = {
            provider = provider, description = description, config_table = config_table, settings = settings,
            book_info = path and { file = path, title = entry.book_title } or nil, opts = opts,
            features = run_features, writer_on = false, recipients = recipients, entries = {}, path = path,
            fixed_prompt = (restyle and not writer_provider) and ImageGenerator.restyleFramed(prompt, style_text, style_default)
                or prompt,
            fixed_head = head,
            fixed_source = type(entry.provenance) == "string" and entry.provenance:match("%S") and entry.provenance or nil,
            fixed_written = written,
            fixed_style = restyle and style_text or ImageGenerator.recordedStyle(entry),
            restyle = writer_provider and { provider = writer_provider, model = writer_model,
                style = style_text, default = style_default } or nil,
            kinds = kinds,
            about = type(entry.entries) == "table" and entry.entries or nil,
        }
        if #kinds == 0 then
            ImageGenerator._run(st)
            return
        end
        local who = ImageGenerator.providerName(provider, opts.plugin)
        if #recipients == 2 then
            who = T(_("%1, to restyle the prompt, and to %2, to draw it"),
                ImageGenerator.providerName(writer_provider, opts.plugin), who)
        end
        require("koassistant.ui.data_access").withAccess(opts.plugin, nil, {
            features = run_features, kinds = kinds, providers = recipients, required = true,
            path = path, ui = opts.ui,
            action_name = _("Regenerate"),
            provider_name = who,
            amounts = {
                nearby_text = _("the text around the passage, in this picture's prompt"),
                book_text = _("what X-Ray descriptions made from the book's text gave this picture's prompt"),
                highlights = _("what X-Ray descriptions made with your highlights gave this picture's prompt"),
                annotations = _("what X-Ray descriptions made with your notes gave this picture's prompt"),
            },
        }, function()
            local ok, err = pcall(ImageGenerator._run, st)
            if not ok then
                logger.err("KOAssistant: image regeneration error:", err)
                showNotice(T(_("Image generation error:\n\n%1"), tostring(err)))
            end
        end)
    end)
end

--- The X-Ray a passage picture's entries come from (B537): the book's own
--- installed X-Ray with its carried entries among its own entries
--- (PromptWriter.withCarried, each carried row naming its book), minus the
--- rows carried from a book whose text is Never for a provider the material
--- reaches (the entity index's rule: XrayMerge.neverSourceFiles). Returns
--- that data and ActionCache.parsedXrayFor's answer; nil without an X-Ray.
--- @param path string|nil the book
--- @param features table
--- @param providers table the providers the material reaches
--- @param ui table|nil
function ImageGenerator.pictureXray(path, features, providers, ui)
    local xray = path and require("koassistant.artifacts.action_cache").parsedXrayFor(path) or nil
    if not xray then return nil end
    local XrayMerge = require("koassistant.xray.xray_merge")
    local skip = {}
    for _idx, p in ipairs(providers or {}) do
        for file in pairs(XrayMerge.neverSourceFiles(xray.data, features or {}, p, ui)) do skip[file] = true end
    end
    return require("koassistant.images.prompt_writer").withCarried(xray.data, {
        skip = skip,
        from = require("koassistant.books.book_groups").carriedSourceLabeler(path),
    }), xray
end

--- What a run sends and to whom, the question for it, then the run (S5, D12):
--- with the prompt writer on, the text around the passage and the X-Ray
--- descriptions reach two providers (the writer's, which reads them, and the
--- image provider's, whose prompt carries what the writer took from them), so
--- each kind must be allowed for both and one question names both. Kinds on
--- Never are left out (an X-Ray entry to draw is required, so Never refuses).
function ImageGenerator._askAndRun(provider, description, config_table, settings, book_info, opts)
    local PromptWriter = require("koassistant.images.prompt_writer")
    local Gates = require("koassistant.request.privacy_gates")
    local features = (config_table and config_table.features) or {}
    local plugin = opts.plugin
    local writer_on = features.image_gen_writer ~= false
    local writer_provider, writer_model
    if writer_on then
        writer_provider, writer_model = PromptWriter.target(features,
            (config_table and config_table.provider) or require("koassistant.core.config_helper").mainProvider(features))
        if not writer_provider then writer_on = false end
    end
    local recipients = { provider }
    if writer_on and writer_provider ~= provider then recipients = { writer_provider, provider } end
    local path = book_info and book_info.file
    -- The book's own installed X-Ray: the entries the passage or the reader's
    -- note names (the writer reads them, D10; B535: "this is X" brings X), or
    -- the reader's list from the picture popup (B537), or the entry to draw;
    -- stored material, judged by the kinds it was built from. Its carried
    -- entries count too, but none from a book whose text is Never for a
    -- provider here (a pick made before the provider changed included)
    local picture_data, xray = ImageGenerator.pictureXray(path, features, recipients, opts.ui)
    local entries = {}
    if writer_on and not opts.entry and xray then
        entries = PromptWriter.entriesFor(description, picture_data, nil, opts.note, opts.picked)
    end
    -- B486: what the picture shows, recorded with it (the entry drawn, or the
    -- entries the writer read; with the writer off, the ones the passage and
    -- the note name: a record on this device, nothing sent)
    local about
    if opts.entry then
        about = { opts.entry.name }
    elseif xray then
        about = {}
        local list = writer_on and entries
            or PromptWriter.entriesFor(description, picture_data, nil, opts.note)
        for _idx, e in ipairs(list) do about[#about + 1] = e.name end
    end
    local stored = (#entries > 0) and xray.entry or nil
    if opts.entry then
        -- the entry to draw is stored material whatever happens: no stamps
        -- known reads as made from the book's text (the legacy rule)
        stored = (xray and xray.entry) or {}
    end
    -- The text around, as it would go: the side after the selection cut by
    -- Context Direction and the spoiler clamp first, so nothing is asked for
    -- text that would not be sent
    local window
    if features.image_gen_frame_context ~= false and not opts.entry and type(opts.window) == "table" then
        local prev = type(opts.window.prev) == "string" and opts.window.prev or ""
        local nxt = require("koassistant.request.scope_resolver").limitAfter(
            type(opts.window.next) == "string" and opts.window.next or "", opts.after_limit)
        if prev:match("%S") or nxt:match("%S") then window = { prev = prev, next = nxt } end
    end
    local kinds, amounts = {}, {}
    if window then
        kinds[#kinds + 1] = "nearby_text"
        amounts.nearby_text = _("the text around the passage")
    end
    if stored then
        local stamped = Gates.stampedKinds(stored)
        for _idx, kind in ipairs({ "book_text", "highlights", "annotations" }) do
            if stamped[kind] then kinds[#kinds + 1] = kind end
        end
        if opts.entry then
            amounts.book_text = _("this entry's description from the book's X-Ray (made from its text)")
        else
            local names, carried = {}, false
            for _idx, e in ipairs(entries) do
                names[#names + 1] = e.name
                carried = carried or e.carried == true
            end
            amounts.book_text = carried
                and T(_("the X-Ray descriptions of %1 (made from the text of this book and of the books they are carried from)"),
                    table.concat(names, ", "))
                or T(_("the X-Ray descriptions of %1 (made from the book's text)"), table.concat(names, ", "))
        end
        amounts.highlights = _("X-Ray descriptions made with your highlights")
        amounts.annotations = _("X-Ray descriptions made with your notes on highlights")
    end
    -- The run's own features: an Allow once lands here, never on the shared config
    local run_features = {}
    for k, v in pairs(features) do run_features[k] = v end
    run_features._data_once = nil
    local st = {
        provider = provider, description = description, config_table = config_table, settings = settings,
        book_info = book_info, opts = opts, features = run_features, writer_on = writer_on,
        writer_provider = writer_provider, writer_model = writer_model, recipients = recipients,
        entries = entries, stored = stored, window = window, path = path, about = about,
    }
    if #kinds == 0 then
        ImageGenerator._run(st)
        return
    end
    local who
    if #recipients == 2 then
        who = T(_("%1, to write the prompt, and to %2, to draw it"),
            ImageGenerator.providerName(writer_provider, plugin), ImageGenerator.providerName(provider, plugin))
    elseif writer_on then
        who = T(_("%1, to write the prompt and to draw it"), ImageGenerator.providerName(provider, plugin))
    else
        who = ImageGenerator.providerName(provider, plugin)
    end
    require("koassistant.ui.data_access").withAccess(plugin, nil, {
        features = run_features, kinds = kinds, providers = recipients,
        -- the entry to draw cannot go without its description; the rest can,
        -- and declining them is for this picture only (a book-wide Never for
        -- book text would also stop the book's X-Ray updates)
        required = opts.entry ~= nil, decline_once = true,
        path = path, ui = opts.ui,
        action_name = opts.entry and _("Illustrate") or _("Generate Image"),
        provider_name = who, amounts = amounts,
    }, function()
        -- the answer runs from the dialog's callback, outside generate()'s pcall
        local ok, err = pcall(ImageGenerator._run, st)
        if not ok then
            logger.err("KOAssistant: image generation error:", err)
            showNotice(T(_("Image generation error:\n\n%1"), tostring(err)))
        end
    end)
end

--- The written or framed prompt for a run whose material the question
--- settled, then the picture. One status window and one Stop for both
--- requests; a writer that fails leaves the framed prompt, said in one line.
function ImageGenerator._run(st)
    local UIManager = require("ui/uimanager")
    local PromptWriter = require("koassistant.images.prompt_writer")
    local Gates = require("koassistant.request.privacy_gates")
    local features = st.features
    local opts = st.opts
    local provider = st.provider
    local description = st.description
    local book_info = st.book_info
    local settings = st.settings
    local endpoint = IMAGE_ENDPOINTS[provider]
    local api_key = resolveApiKey(provider, settings)
    local resolved_model = resolveImageModel(provider, features)
    local Screen = require("device").screen
    local screen = { w = Screen:getWidth(), h = Screen:getHeight() }

    -- What may go: every kind allowed for every provider it reaches (the
    -- question's answer is on the run's features, or the book's own values,
    -- read again here)
    local book_values = st.path and Gates.bookOverrides(st.path, opts.ui) or opts.book_privacy
    if st.fixed_prompt then
        -- a recorded prompt drawn again (S7): the kinds it carries, each
        -- allowed for every provider it goes to (the image provider, and the
        -- writer's when it restyles, S9), or nothing goes
        for _idx, kind in ipairs(st.kinds or {}) do
            for _p, p in ipairs(st.recipients or { provider }) do
                if not Gates.allows(kind, { features = features, provider = p, book = book_values,
                        once = Gates.onceFor(features, st.path) }) then
                    showNotice(_("This picture's prompt can't be sent: it carries data your privacy settings keep from this provider."))
                    return
                end
            end
        end
    end
    local allowed = ImageGenerator.allowedMaterial({
        features = features, recipients = st.recipients, path = st.path,
        book = book_values, window = st.window ~= nil, stored = st.stored,
    })
    local left_out = {}
    local around_ok = allowed.around
    if st.window and not around_ok then left_out[#left_out + 1] = _("the text around the passage") end
    local stored_ok = allowed.stored
    if st.stored then
        if not stored_ok then
            if opts.entry then
                -- the subject itself cannot go (a refusal the question missed)
                showNotice(_("This entry's description can't be sent: its X-Ray was made from data your privacy settings keep from these providers."))
                return
            end
            left_out[#left_out + 1] = _("the X-Ray descriptions")
        end
    end
    local entries = stored_ok and st.entries or {}

    -- The kinds the prompt carries, recorded with the picture (S7); a prompt
    -- drawn again keeps its source's
    local function kindsSent(written)
        if st.fixed_prompt then return st.kinds end
        return ImageGenerator.kindsSent({
            around = around_ok and st.window ~= nil, stored = stored_ok and st.stored or nil,
            entry = opts.entry ~= nil, written = written, entries = #entries,
        })
    end

    -- The framed prompt: the writer's fallback, and the prompt itself with the
    -- writer off (S1's frame; the style and the note as lines)
    local frame_opts = {
        book_metadata = opts.book_metadata, after_limit = opts.after_limit,
        book_info_level = opts.book_info_level, note = opts.note,
        window = around_ok and st.window or nil,
    }
    local function framedPrompt()
        if opts.entry then
            return ImageGenerator.buildEntryPrompt(opts.entry, frame_opts, features)
        end
        return ImageGenerator.buildPrompt(description, frame_opts, features)
    end

    -- Progress window: the tool-status dialog (setText handle + Stop button)
    -- avoids InfoMessage's fire-dismiss_callback-on-any-close trap and gives
    -- the user elapsed-time feedback during the long blocking POST
    local StreamHandler = require("koassistant.request.stream_handler")
    local cancelled = false
    local active_pid  -- reassigned per fork; Stop kills whichever is live
    local writer_cancel  -- the writer request's cancel, while it runs
    local start_ts = os.time()
    local phase_text = ""
    local status, stop_tick
    -- The waiting line at the chat window's pace (koassistant/ui/waiting.lua):
    -- an Onyx Boox stopped waking KOReader about 10 s into a picture while
    -- this window redrew every 5 s (frozen until a tap, the picture waiting in
    -- the pipe); the chat and quiz windows, redrawn every 0.4 s, never froze
    -- (B709, #126: such a device sleeps about 5 s after a screen update)
    local Waiting = require("koassistant.ui.waiting")
    local dots = Waiting.dots()
    local function statusText()
        return phase_text .. "\n\n" .. Waiting.line(os.time() - start_ts, dots.getNextFrame())
    end
    local function stopTicker()
        if stop_tick then
            stop_tick()
            stop_tick = nil
        end
    end
    local function cancelRequest()
        cancelled = true
        stopTicker()
        if writer_cancel then pcall(writer_cancel) end
        if active_pid then
            ffiutil.terminateSubProcess(active_pid)
        end
        if status then status.close() end
    end
    local function setPhase(text)
        phase_text = text
        if status then
            status.setText(statusText())
            return
        end
        status = StreamHandler.showToolStatusDialog({
            settings = { large_stream_dialog = false, response_font_size = features.markdown_font_size },
            title = opts.entry and _("Illustrating") or _("Generating image"),
            initial_text = statusText(),
            on_stop = cancelRequest,
        })
        stop_tick = Waiting.tick(function() status.setText(statusText()) end)
    end

    -- pollSubprocess callbacks run from the UI task queue, outside generate()'s
    -- pcall — guard them so a parsing bug can't crash KOReader
    local function guarded(fn)
        return function(...)
            local cb_ok, cb_err = pcall(fn, ...)
            if not cb_ok then
                stopTicker()
                if status then status.close() end
                logger.err("KOAssistant: image generation callback error:", cb_err)
                showNotice(T(_("Image generation error:\n\n%1"), tostring(cb_err)))
            end
        end
    end

    -- Close the status window and report an error
    local function fail(msg)
        stopTicker()
        if status then status.close() end
        showNotice(msg)
    end

    -- The picture: the request as the provider takes it (OpenAI-style images
    -- API, or Gemini's generateContent with image output); Fit my screen fits
    -- the screen as it is held now. note = a line above the phase (the
    -- writer's failure); kinds = what the prompt carries, written = the
    -- writer wrote it, style = its style in the prompt's words, for the index
    local function draw(final_prompt, provenance, note, kinds, written, style)
        local meta = { provider = provider, model = resolved_model, kinds = kinds, written = written, style = style,
            entries = st.about }
        -- The answer in hand: the picture is decoded, saved and shown on the UI
        -- thread, a few seconds on a slow reader while the clock cannot tick,
        -- so the window says so first
        local function saveAndShow(bytes)
            stopTicker()
            setPhase(_("Saving the picture…"))
            UIManager:forceRePaint()
            local time = require("ui/time")
            local t0 = time.now()
            status.close()
            showImage(bytes, description, opts.on_viewer_close, book_info, final_prompt, provenance, meta, opts.on_saved)
            logger.dbg("KOAssistant: image saved and shown in", time.to_ms(time.now() - t0), "ms")
        end
        local request = ImageGenerator.buildRequest(provider, resolved_model, final_prompt, features, screen)
        local request_body_str = BaseHandler.encodeBody(request.body)
        setPhase((note and (note .. "\n\n") or "")
            .. T(_("Generating image with %1 / %2…"), ImageGenerator.providerName(provider), resolved_model))
        logger.dbg("KOAssistant: image gen request:", provider, resolved_model, "prompt", #final_prompt, "bytes")
        local bg_fn = makeBackgroundFn(request.url, api_key, request_body_str, endpoint, request.headers)
        local pid, parent_read_fd = ffiutil.runInSubProcess(bg_fn, true)
        if not pid then
            fail(_("Failed to start image generation subprocess."))
            return
        end
        active_pid = pid
        pollSubprocess(pid, parent_read_fd, guarded(function(raw)
            logger.dbg("KOAssistant: image gen result:", raw and #raw or 0, "bytes; head:", raw and raw:sub(1, 120) or "<empty>")
            if cancelled then return end
            if not raw or raw == "" then
                fail(_("Empty response from image generation API."))
                return
            end
            -- Check for error prefix
            if raw:sub(1, 4) == "ERR:" then
                fail(T(_("Image generation failed:\n\n%1"), raw:sub(5)))
                return
            end
            if raw:sub(1, 3) ~= "OK:" then
                -- Subprocess died mid-write; show what we got
                fail(T(_("Image generation failed:\n\n%1"), raw:sub(1, 200)))
                return
            end
            -- Strip "OK:" prefix and read the answer: the image's bytes, a link
            -- to it, or the reason there is none
            local result, parse_err = ImageGenerator.parseResponse(provider, raw:sub(4))
            if not result then
                fail(parse_err)
                return
            end
            if result.bytes then
                saveAndShow(result.bytes)
                return
            end
            -- Download phase: same window, same elapsed clock
            setPhase(_("Downloading generated image…"))
            local dl_pid, dl_fd = ffiutil.runInSubProcess(makeDownloadFn(result.url), true)
            if not dl_pid then
                fail(_("Failed to download generated image."))
                return
            end
            active_pid = dl_pid
            pollSubprocess(dl_pid, dl_fd, guarded(function(dl_raw)
                if cancelled then return end
                if not dl_raw or dl_raw:sub(1, 4) == "ERR:" then
                    fail(T(_("Image download failed:\n\n%1"), dl_raw and dl_raw:sub(5) or ""))
                    return
                end
                if dl_raw:sub(1, 3) ~= "OK:" or #dl_raw <= 3 then
                    fail(_("Image download failed."))
                    return
                end
                -- "OK:" prefix + binary
                saveAndShow(dl_raw:sub(4))
            end))
        end))
    end

    -- One request to the prompt writer (S5, and S9's restyle): its own
    -- system text and material, the phase naming it; on_done(prompt, failure,
    -- model) once (the answer made a prompt by finish(), or the failure)
    local function askWriter(w_provider, w_model, system, material, phase_fmt, on_done)
        local cfg, model_id = ImageGenerator.writerConfig(st.config_table, w_provider, w_model, system)
        cfg._register_cancel = function(fn) writer_cancel = fn end
        setPhase(T(phase_fmt, ImageGenerator.providerName(w_provider, opts.plugin), model_id or "?"))
        logger.dbg("KOAssistant: image prompt writer:", w_provider, model_id, "material", #material, "bytes")
        local history = require("koassistant.request.message_history"):new()
        history:addUserMessage(material)
        -- OpenCode wants its session header, OpenRouter a session id: the
        -- writer's request is a conversation of its own
        cfg.conversation_id = history.conversation_id
        local settled = false
        local function settle(prompt, failure)
            if settled then return end
            settled = true
            writer_cancel = nil
            if cancelled then return end
            on_done(prompt, failure, model_id)
        end
        local ok_query, query_err = pcall(require("koassistant.request.gpt_query").query, history:getMessages(), cfg,
            guarded(function(success, answer, err)
                if success and type(answer) == "string" and not answer:match("^Error:") then
                    settle(PromptWriter.finish(answer))
                else
                    local msg = err or answer
                    settle(nil, type(msg) == "string" and msg:gsub("%s+", " "):sub(1, 120) or nil)
                end
            end), settings)
        if not ok_query then settle(nil, tostring(query_err):sub(1, 120)) end
    end

    -- The style a new picture is drawn in, as the prompt says it (recorded, S9)
    local style_now = (PromptWriter.styleText(features))

    if st.fixed_prompt then
        local function provenanceWith(line)
            return ImageGenerator.regeneratedProvenance(st.fixed_head, line, st.fixed_source)
        end
        local r = st.restyle
        if not r then
            draw(st.fixed_prompt, provenanceWith(nil), nil, kindsSent(), st.fixed_written, st.fixed_style)
            return
        end
        -- a written prompt in another style: the writer rewrites its look (S9)
        askWriter(r.provider, r.model, PromptWriter.restyleSystemText(r.style),
            PromptWriter.restyleMaterial(st.fixed_prompt), _("Restyling the prompt with %1 / %2…"),
            function(prompt, failure, model_id)
                if prompt then
                    draw(prompt, provenanceWith(T(_("Prompt restyled by %1."), model_id or "?")), nil, kindsSent(),
                        true, r.style)
                    return
                end
                local why = PromptWriter.failureText(failure)
                logger.warn("KOAssistant: image prompt restyle failed:", tostring(failure))
                draw(ImageGenerator.restyleFramed(st.fixed_prompt, r.style, r.default),
                    provenanceWith(T(_("The prompt writer failed (%1), so the style was added as a line."), why)),
                    T(_("The prompt writer failed (%1); the style is added as a line."), why),
                    kindsSent(), true, r.style)
            end)
        return
    end
    if not st.writer_on then
        draw(framedPrompt(), nil, nil, kindsSent(false), false, style_now)
        return
    end

    -- The prompt writer (S5): the material the question settled, in tagged
    -- blocks; the title and author per the Book info level and the identity
    -- toggle, the book's Background, the style and the shape
    local meta = (features.image_gen_frame_identity ~= false) and opts.book_metadata or nil
    if opts.book_info_level == "none" then meta = nil end
    local book, book_said
    if meta and type(meta.title) == "string" and meta.title ~= "" then
        local with_author = opts.book_info_level ~= "title" and type(meta.author) == "string" and meta.author ~= ""
        book = { title = meta.title, author = with_author and meta.author or nil }
        book_said = with_author and "both" or "title"
    end
    local shape = features.image_gen_shape or "fit"
    local okc, color = pcall(function() return Screen:isColorEnabled() end)
    local grayscale = okc and color == false
    local around
    if around_ok then
        around = { before = st.window.prev, after = st.window.next }
    end
    local background = type(opts.background) == "string" and opts.background:match("%S") and opts.background or nil
    local note = type(opts.note) == "string" and opts.note:match("%S") and opts.note or nil
    local material = PromptWriter.material({
        passage = not opts.entry and description or nil,
        entry = opts.entry,
        note = note,
        around = around,
        entries = entries,
        book = book,
        background = background,
        style = style_now,
        shape = PromptWriter.shapeLine(shape, ImageGenerator.shapeRatio(shape, screen), grayscale),
    })
    askWriter(st.writer_provider, st.writer_model,
        PromptWriter.systemText({ subject = opts.entry and "entry" or "passage", spoiler = opts.spoiler }),
        material, _("Writing the prompt with %1 / %2…"),
        function(prompt, failure, writer_model)
            if prompt then
                draw(prompt, PromptWriter.provenance({
                    model = writer_model, entry = opts.entry, around = around ~= nil, entries = entries,
                    book = book_said, background = background ~= nil, note = note ~= nil, left_out = left_out,
                }), nil, kindsSent(true), true, style_now)
                return
            end
            local why = PromptWriter.failureText(failure)
            logger.warn("KOAssistant: image prompt writer failed:", tostring(failure))
            draw(framedPrompt(), PromptWriter.provenance({ failed = why, entry = opts.entry, left_out = left_out }),
                opts.entry and T(_("The prompt writer failed (%1); drawing from the entry's description."), why)
                    or T(_("The prompt writer failed (%1); drawing from the passage as framed."), why),
                kindsSent(false), false, style_now)
        end)
end

--- The request config for the prompt writer: a copy of the configuration on
--- the writer's provider and model, its own system text, no web, no tools, no
--- streaming, reasoning off (D8), its loading dialog left to the image's
--- status window. Returns the config and the model id it sends.
function ImageGenerator.writerConfig(configuration, provider, model, system_text)
    local ModelConstraints = require("koassistant.request.model_constraints")
    local ReasoningPrefs = require("koassistant.request.reasoning_prefs")
    local cfg = {}
    for k, v in pairs(configuration or {}) do cfg[k] = v end
    cfg.features = {}
    for k, v in pairs((configuration and configuration.features) or {}) do cfg.features[k] = v end
    if provider and provider ~= cfg.provider then
        cfg.provider = provider
        cfg.model = nil
    end
    if model then
        cfg.model = model
        -- the per-provider table is shared with the configuration: clone it
        cfg.provider_settings = {}
        for k, v in pairs((configuration and configuration.provider_settings) or {}) do cfg.provider_settings[k] = v end
        local ps = {}
        for k, v in pairs(cfg.provider_settings[cfg.provider] or {}) do ps[k] = v end
        ps.model = model
        cfg.provider_settings[cfg.provider] = ps
    end
    cfg.system = { text = system_text, enable_caching = false }
    cfg.api_params = {}
    cfg.enable_web_search = false
    cfg.features.enable_web_search = false
    cfg.features.enable_streaming = false
    cfg.features._tools_active = false
    cfg.features._suppress_loading_dialog = true
    -- the dictionary popup a lookup came from rides the shared features; the
    -- request's copy has no use for its widget graph
    cfg.features._source_widget = nil
    local sent = ModelConstraints.dispatchModel({ provider = cfg.provider, model = cfg.model, features = cfg.features })
    local decision = ModelConstraints.resolveReasoning(cfg.provider, sent, {
        global_stance = ReasoningPrefs.getStance(cfg.features),
        model_pref = ReasoningPrefs.getModelPref(cfg.features, cfg.provider, sent),
        action_override = { force = "off" },
    })
    cfg.api_params._reasoning = decision
    ModelConstraints.applyReasoningParams(cfg.provider, cfg.api_params, decision)
    return cfg, sent
end

return ImageGenerator
