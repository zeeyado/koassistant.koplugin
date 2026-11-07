--[[
The fonts of the scripts the window's own font lacks, in the Markdown view
(B558; extended 2026-11-07 to runs inside any block, Hebrew, Devanagari,
Bengali and emoji, when the plain-text switches for right-to-left text left).

KOReader's MuPDF is built without built-in fonts: every family a style sheet
names must be a file it can open, and the only per-glyph fallback it installs
is the CJK font, with FreeSerif as the last resort. Our viewer CSS names
'Noto Sans', which has no Arabic, Hebrew, Devanagari or Bengali letters and no
emoji, so those came out in FreeSerif, emoji as boxes. A font applies per
ELEMENT, never per letter, so this module does two things:

  * css(features) writes the @font-face rules of each face under one CSS
    family name and the rule that puts it on a class;
  * markRuns(html) wraps every run of such a script, and every emoji, in a
    span carrying that class, in every block (a right-to-left paragraph, an
    Arabic word inside an English sentence, a table cell, a code span). It
    runs last in the viewer's pipeline, after the direction pass and the
    page breaks, which match the HTML by its text.

The Arabic face is the reader's pick (features.rtl_font: nil = Noto Naskh
Arabic, the face KOReader's own fallback list gives Arabic books; a family
KOReader knows, resolved through crengine as KOReader's footnote popup does
for the book's font; false = none). The other faces are fixed: the files
KOReader's own interface falls back to for those scripts (frontend/ui/font.lua:
Noto Sans Devanagari UI, Noto Sans Bengali UI; FreeSans for Hebrew) and the
Noto Emoji file this plugin bundles for its menu icons, read from the plugin's
own folder, so emoji draw with no install. A face whose file is missing gets
no rule and its spans are inert (the window as before). Every weight and
style is registered, a repeated file included, so MuPDF synthesizes bold and
italic for a family that has none (probed 2026-10-28 and 2026-11-07,
docs/research/2026-10-28/arabic-font.md).
]]

local ScriptFonts = {}

ScriptFonts.FAMILY = "KOA RTL"            -- the CSS family name of the Arabic face
ScriptFonts.DEFAULT = "Noto Naskh Arabic"
ScriptFonts.CLASS = "koa-arab"            -- the class of an Arabic-script run
ScriptFonts.EMOJI_CLASS = "koa-emoji"

-- The two Arabic faces KOReader ships, by file: no font engine is needed for them
ScriptFonts.SHIPPED = {
    { family = "Noto Naskh Arabic", regular = "noto/NotoNaskhArabic-Regular.ttf", bold = "noto/NotoNaskhArabic-Bold.ttf" },
    { family = "Noto Sans Arabic UI", regular = "noto/NotoSansArabicUI-Regular.ttf", bold = "noto/NotoSansArabicUI-Bold.ttf" },
}

-- The fixed faces: KOReader's own files under its fonts folder, the emoji
-- font from this plugin's folder (`plugin` = relative to the plugin root)
ScriptFonts.FIXED = {
    { class = "koa-hebr", family = "KOA Hebrew", regular = "freefont/FreeSans.ttf" },
    { class = "koa-deva", family = "KOA Devanagari", regular = "noto/NotoSansDevanagariUI-Regular.ttf", bold = "noto/NotoSansDevanagariUI-Bold.ttf" },
    { class = "koa-beng", family = "KOA Bengali", regular = "noto/NotoSansBengaliUI-Regular.ttf", bold = "noto/NotoSansBengaliUI-Bold.ttf" },
    { class = ScriptFonts.EMOJI_CLASS, family = "KOA Emoji", plugin = "fonts/NotoEmoji-Regular.ttf" },
}

-- Seams the tests replace: where KOReader's fonts live, this plugin's folder,
-- whether a file exists, and the crengine module (nil where there is none)
function ScriptFonts._fontsDir()
    local dir = "./fonts"
    local ok, FontList = pcall(require, "fontlist")
    if ok and type(FontList) == "table" and type(FontList.fontdir) == "string" then
        dir = FontList.fontdir
    end
    if dir:sub(1, 2) == "./" then
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        local cwd = ok_lfs and lfs.currentdir and lfs.currentdir()
        if type(cwd) == "string" and cwd ~= "" then dir = cwd .. dir:sub(2) end
    end
    return dir
end

function ScriptFonts._pluginDir()
    local ok, Paths = pcall(require, "koassistant.core.paths")
    if ok and type(Paths) == "table" and type(Paths.ROOT) == "string" then
        return (Paths.ROOT:gsub("/$", ""))
    end
    return "."
end

function ScriptFonts._fileExists(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then return false end
    return lfs.attributes(path, "mode") == "file"
end

function ScriptFonts._cre()
    local ok, CreDocument = pcall(require, "document/credocument")
    if not ok or type(CreDocument) ~= "table" or type(CreDocument.engineInit) ~= "function" then return nil end
    local ok_init, cre = pcall(CreDocument.engineInit, CreDocument)
    if ok_init and type(cre) == "table" then return cre end
    return nil
end

--- The Arabic family in effect: nil = no rule (the window's font).
function ScriptFonts.family(features)
    local v = features and features.rtl_font
    if v == false then return nil end
    if type(v) == "string" and v ~= "" then return v end
    return ScriptFonts.DEFAULT
end

function ScriptFonts.shipped(family)
    for _idx, face in ipairs(ScriptFonts.SHIPPED) do
        if face.family == family then return face end
    end
    return nil
end

-- The four combos of a regular file and an optional bold one: a style the
-- family has no file for takes the nearest file (the regular for italic, the
-- bold for bold italic) and MuPDF synthesizes the rest
local function facesFromFiles(regular, bold)
    if not regular or not ScriptFonts._fileExists(regular) then return nil end
    if not bold or not ScriptFonts._fileExists(bold) then bold = regular end
    return {
        { path = regular, bold = false, italic = false },
        { path = regular, bold = false, italic = true },
        { path = bold, bold = true, italic = false },
        { path = bold, bold = true, italic = true },
    }
end

--- The four files of the Arabic family as { path, bold, italic } in that
--- order (regular, italic, bold, bold italic), or nil when the family
--- resolves to no file.
function ScriptFonts.faces(family)
    if type(family) ~= "string" or family == "" then return nil end
    local shipped = ScriptFonts.shipped(family)
    if shipped then
        local dir = ScriptFonts._fontsDir()
        return facesFromFiles(dir .. "/" .. shipped.regular, dir .. "/" .. shipped.bold)
    end
    local cre = ScriptFonts._cre()
    if not cre or type(cre.getFontFaceFilenameAndFaceIndex) ~= "function" then return nil end
    local out = {}
    for i = 1, 4 do
        local bold = i >= 3
        local italic = i == 2 or i == 4
        local ok, path = pcall(cre.getFontFaceFilenameAndFaceIndex, family, bold, italic)
        if not ok or type(path) ~= "string" or path == "" then
            -- crengine gives the regular file for a style it synthesizes;
            -- nothing at all means the family is gone from KOReader's folders
            if i == 1 then return nil end
            path = out[bold and 3 or 1].path
        end
        out[i] = { path = path, bold = bold, italic = italic }
    end
    return out
end

--- The four files of a fixed face (an entry of FIXED), or nil without its file.
function ScriptFonts.fixedFaces(entry)
    local regular, bold
    if entry.plugin then
        regular = ScriptFonts._pluginDir() .. "/" .. entry.plugin
    else
        local dir = ScriptFonts._fontsDir()
        regular = dir .. "/" .. entry.regular
        bold = entry.bold and (dir .. "/" .. entry.bold) or nil
    end
    return facesFromFiles(regular, bold)
end

-- The rules of one face: four @font-face lines under its family name and the
-- class rule, 'Noto Sans' after the family so a file that goes missing falls
-- back to the window's font, never to Times
local function rulesFor(family, class, faces)
    local rules = {}
    for _idx, face in ipairs(faces) do
        rules[#rules + 1] = string.format("@font-face { font-family: '%s'; src: url('%s');%s%s }",
            family, face.path,
            face.bold and " font-weight: bold;" or "",
            face.italic and " font-style: italic;" or "")
    end
    rules[#rules + 1] = string.format(".%s { font-family: '%s', 'Noto Sans'; }", class, family)
    return table.concat(rules, "\n")
end

local memo = {}         -- the Arabic rules per family
local fixed_memo = nil  -- the fixed faces' rules, once

local function fixedCSS()
    if fixed_memo ~= nil then return fixed_memo end
    local parts = {}
    for _idx, entry in ipairs(ScriptFonts.FIXED) do
        local faces = ScriptFonts.fixedFaces(entry)
        if faces then parts[#parts + 1] = rulesFor(entry.family, entry.class, faces) end
    end
    fixed_memo = table.concat(parts, "\n")
    return fixed_memo
end

--- The Arabic face's rules alone, "" without a family or its files (the
--- Settings row's "(not found)" reads this).
function ScriptFonts.arabicCSS(features)
    local family = ScriptFonts.family(features)
    if not family then return "" end
    local cached = memo[family]
    if cached ~= nil then return cached end
    local faces = ScriptFonts.faces(family)
    local css = faces and rulesFor(ScriptFonts.FAMILY, ScriptFonts.CLASS, faces) or ""
    memo[family] = css
    return css
end

--- The CSS fragment for a features table: the Arabic face's rules and the
--- fixed faces', each only with its files there; "" when none. Memoized
--- (fonts are registered once per KOReader start).
function ScriptFonts.css(features)
    local parts = {}
    local arabic = ScriptFonts.arabicCSS(features)
    if arabic ~= "" then parts[#parts + 1] = arabic end
    local fixed = fixedCSS()
    if fixed ~= "" then parts[#parts + 1] = fixed end
    if #parts == 0 then return "" end
    return "\n" .. table.concat(parts, "\n") .. "\n"
end

function ScriptFonts.reset()
    memo = {}
    fixed_memo = nil
end

--- The label of the Settings row: the family, "None" without one, "(not
--- found)" when the family resolves to no file.
function ScriptFonts.label(features)
    local _ = require("koassistant.core.gettext")
    local T = require("ffi/util").template
    local family = ScriptFonts.family(features)
    if not family then return _("None (the window's font)") end
    if ScriptFonts.arabicCSS(features) == "" then return T(_("%1 (not found)"), family) end
    return family
end

--- The rows of the Settings row's sub-menu: the two shipped faces, None, then
--- every font KOReader knows, each drawn in its own face where KOReader's menus
--- can (TouchMenu's font_func), a tap writing features.rtl_font.
function ScriptFonts.menuItems(plugin)
    local _ = require("koassistant.core.gettext")
    local function current()
        local f = plugin.settings:readSetting("features") or {}
        return ScriptFonts.family(f)
    end
    local function pick(value)
        local f = plugin.settings:readSetting("features") or {}
        f.rtl_font = value
        plugin.settings:saveSetting("features", f)
        plugin.settings:flush()
        plugin:updateConfigFromSettings()
    end
    local function faceFunc(family)
        return function(size)
            local faces = ScriptFonts.faces(family)
            local ok, Font = pcall(require, "ui/font")
            if faces and ok and Font and Font.getFace then
                local ok_face, face = pcall(Font.getFace, Font, faces[1].path, size)
                if ok_face then return face end
            end
            return nil
        end
    end
    local items = {}
    for _idx, face in ipairs(ScriptFonts.SHIPPED) do
        items[#items + 1] = {
            text = face.family,
            radio = true,
            checked_func = function() return current() == face.family end,
            callback = function()
                if face.family == ScriptFonts.DEFAULT then pick(nil) else pick(face.family) end
            end,
            keep_menu_open = true,
            font_func = faceFunc(face.family),
        }
    end
    items[#items + 1] = {
        text = _("None (the window's font)"),
        radio = true,
        checked_func = function() return current() == nil end,
        callback = function() pick(false) end,
        keep_menu_open = true,
        separator = true,
    }
    local cre = ScriptFonts._cre()
    local names = {}
    if cre and type(cre.getFontFaces) == "function" then
        local ok, faces = pcall(cre.getFontFaces)
        if ok and type(faces) == "table" then
            for _idx, name in ipairs(faces) do
                if type(name) == "string" and not ScriptFonts.shipped(name) then names[#names + 1] = name end
            end
        end
    end
    table.sort(names)
    for _idx, name in ipairs(names) do
        items[#items + 1] = {
            text = name,
            radio = true,
            checked_func = function() return current() == name end,
            callback = function() pick(name) end,
            keep_menu_open = true,
            font_func = faceFunc(name),
        }
    end
    return items
end

-- ---------------------------------------------------------------------------
-- The run pass: spans around the runs of a script and around emoji
-- ---------------------------------------------------------------------------

-- The scripts, by the UTF-8 byte patterns of their letters: Arabic
-- (U+0600-06FF, U+0880-08FF, the presentation forms U+FB50-FDFF and
-- U+FE70-FEFF), Hebrew (U+0590-05FF, U+FB1D-FB4F), Devanagari (U+0900-097F),
-- Bengali (U+0980-09FF). A token's class is the first script found in it.
local SCRIPTS = {
    { class = ScriptFonts.CLASS, patterns = {
        "[\216-\219][\128-\191]", "\224[\162-\163][\128-\191]",
        "\239\173[\144-\191]", "\239[\174-\183][\128-\191]",
        "\239\185[\176-\191]", "\239[\186-\187][\128-\191]",
    } },
    { class = "koa-hebr", patterns = { "\214[\144-\191]", "\215[\128-\191]", "\239\172[\157-\191]", "\239\173[\128-\143]" } },
    { class = "koa-deva", patterns = { "\224[\164-\165][\128-\191]" } },
    { class = "koa-beng", patterns = { "\224[\166-\167][\128-\191]" } },
}
-- The lead bytes those letters start with: one find rules most text out
local SCRIPT_LEAD = "[\214-\219\224\239]"

local function classOf(token)
    if not token:find(SCRIPT_LEAD) then return nil end
    for _idx, script in ipairs(SCRIPTS) do
        for _jdx, p in ipairs(script.patterns) do
            if token:find(p) then return script.class end
        end
    end
    return nil
end

-- Emoji. The supplementary characters (U+1F000-1FAFF: faces, objects, flags'
-- letters, skin tones) are emoji as they stand; among the three-byte symbols
-- only the ones Unicode presents as emoji by default count on their own
-- (⚡ ✅ ❌ ⭐ and the others below), the rest of U+2300-2BFF, © and ® only
-- with the emoji variation selector (U+FE0F) after them, so a check mark, an
-- arrow or a bullet keeps the window's font. A keycap is a digit, # or *
-- with U+20E3 after it. A sequence continues through the variation selector,
-- the joiner (U+200D) and what follows it, a keycap, a tag character
-- (U+E0020-E007F) and any adjacent emoji.
local VS16 = "\239\184\143"
local ZWJ = "\226\128\141"
local KEYCAP = "\226\131\163"
local DEFAULT_EMOJI = {}
do
    local function add(cp)
        DEFAULT_EMOJI[string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)] = true
    end
    for _idx, cp in ipairs({
        0x231A, 0x231B, 0x23E9, 0x23EA, 0x23EB, 0x23EC, 0x23F0, 0x23F3, 0x25FD, 0x25FE,
        0x2614, 0x2615, 0x267F, 0x2693, 0x26A1, 0x26AA, 0x26AB, 0x26BD, 0x26BE, 0x26C4, 0x26C5,
        0x26CE, 0x26D4, 0x26EA, 0x26F2, 0x26F3, 0x26F5, 0x26FA, 0x26FD, 0x2705, 0x270A, 0x270B,
        0x2728, 0x274C, 0x274E, 0x2753, 0x2754, 0x2755, 0x2757, 0x2795, 0x2796, 0x2797, 0x27B0,
        0x27BF, 0x2B1B, 0x2B1C, 0x2B50, 0x2B55,
    }) do add(cp) end
    for cp = 0x2648, 0x2653 do add(cp) end   -- the zodiac
end
-- One find says whether a text can hold an emoji at all
local function mayHoldEmoji(s)
    return s:find("\240\159", 1, true) or s:find(VS16, 1, true) or s:find(KEYCAP, 1, true)
        or s:find("\226[\140-\143\151-\158\172-\173]")
end

-- The length of the emoji that starts at byte i, or nil
local function emojiStart(s, i)
    local b = s:byte(i)
    if not b then return nil end
    if b == 0xF0 then
        if s:byte(i + 1) == 0x9F then return 4 end
        return nil
    end
    if b == 0xE2 then
        if DEFAULT_EMOJI[s:sub(i, i + 2)] then return 3 end
        if s:sub(i + 3, i + 5) == VS16 then return 3 end
        return nil
    end
    if b == 0xC2 and (s:byte(i + 1) == 0xA9 or s:byte(i + 1) == 0xAE) and s:sub(i + 2, i + 4) == VS16 then
        return 2
    end
    if (b >= 48 and b <= 57) or b == 35 or b == 42 then
        if s:sub(i + 1, i + 3) == KEYCAP then return 1 end
        if s:sub(i + 1, i + 3) == VS16 and s:sub(i + 4, i + 6) == KEYCAP then return 1 end
    end
    return nil
end

-- The end byte of the emoji sequence that starts at i with a start of length n
local function emojiEnd(s, i, n)
    local j = i + n
    while true do
        local three = s:sub(j, j + 2)
        if three == VS16 or three == KEYCAP then
            j = j + 3
        elseif three == ZWJ then
            local m = emojiStart(s, j + 3)
            if not m then break end
            j = j + 3 + m
        elseif s:byte(j) == 0xF3 and s:byte(j + 1) == 0xA0 and (s:byte(j + 2) == 0x80 or s:byte(j + 2) == 0x81) then
            j = j + 4   -- a tag character
        else
            local m = emojiStart(s, j)
            if not m then break end
            j = j + m
        end
    end
    return j - 1
end

local EMOJI_OPEN = '<span class="' .. ScriptFonts.EMOJI_CLASS .. '">'

-- Every emoji sequence of a token in its span
local function markEmoji(token)
    if not mayHoldEmoji(token) then return token end
    local out, pos, n = {}, 1, #token
    while pos <= n do
        local c = token:find("[\240\226\194#%*0-9]", pos)
        if not c then break end
        local len = emojiStart(token, c)
        if len then
            local e = emojiEnd(token, c, len)
            out[#out + 1] = token:sub(pos, c - 1)
            out[#out + 1] = EMOJI_OPEN .. token:sub(c, e) .. "</span>"
            pos = e + 1
        else
            out[#out + 1] = token:sub(pos, c)
            pos = c + 1
        end
    end
    if #out == 0 then return token end
    out[#out + 1] = token:sub(pos)
    return table.concat(out)
end

-- One text node (the text between two tags): the runs of a script in their
-- spans, adjacent tokens of one script merged across the whitespace between
-- them, the gaps between runs left in the block's font; emoji each in their
-- own span (the emoji face's space is wide)
local function markNode(text)
    local has_script = text:find(SCRIPT_LEAD) ~= nil
    local has_emoji = mayHoldEmoji(text) ~= nil
    if not has_script and not has_emoji then return text end
    local out = {}
    local run, run_class = {}, nil
    local function flush()
        if run_class then
            out[#out + 1] = '<span class="' .. run_class .. '">' .. table.concat(run) .. "</span>"
            run, run_class = {}, nil
        end
    end
    local pos, n = 1, #text
    while pos <= n do
        local ws = ""
        local ws_s, ws_e = text:find("^%s+", pos)
        if ws_s then
            ws = text:sub(ws_s, ws_e)
            pos = ws_e + 1
        end
        local tok_s, tok_e = text:find("^%S+", pos)
        local tok = tok_s and text:sub(tok_s, tok_e) or ""
        if tok_s then pos = tok_e + 1 end
        local cls = has_script and tok ~= "" and classOf(tok) or nil
        if has_emoji and tok ~= "" then tok = markEmoji(tok) end
        if cls and cls == run_class then
            run[#run + 1] = ws .. tok
        else
            flush()
            out[#out + 1] = ws
            if cls then
                run_class = cls
                run[1] = tok
            else
                out[#out + 1] = tok
            end
        end
    end
    flush()
    return table.concat(out)
end

--- The HTML with every run of Arabic, Hebrew, Devanagari or Bengali letters
--- and every emoji wrapped in a span of its class (tags and their attributes
--- untouched). Returns the same string when nothing in it needs a span.
function ScriptFonts.markRuns(html)
    if type(html) ~= "string" or html == "" then return html end
    if not html:find(SCRIPT_LEAD) and not mayHoldEmoji(html) then return html end
    local out, pos, n = {}, 1, #html
    while pos <= n do
        local ts = html:find("<", pos, true)
        if not ts then
            out[#out + 1] = markNode(html:sub(pos))
            break
        end
        if ts > pos then out[#out + 1] = markNode(html:sub(pos, ts - 1)) end
        local te = html:find(">", ts, true)
        if not te then
            out[#out + 1] = html:sub(ts)
            break
        end
        out[#out + 1] = html:sub(ts, te)
        pos = te + 1
    end
    return table.concat(out)
end

return ScriptFonts
