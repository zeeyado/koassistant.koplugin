--[[
The font of right-to-left text in the Markdown view (B558).

KOReader's MuPDF is built without built-in fonts: every family a style sheet
names must be a file it can open, and the only per-script fallback it installs
is the CJK font, with FreeSerif as the last resort. Our viewer CSS names
'Noto Sans', which has no Arabic, Persian or Hebrew letters, so right-to-left
answers in the Markdown view were drawn in FreeSerif. The direction pass
(koassistant/ui/bidi.lua) marks every right-to-left block with class="koa-rtl";
this module writes the @font-face rules of the chosen family under one CSS
family name and the rule that puts it on that class, with 'Noto Sans' after it
so a missing file falls back to the window's own font, never to Times.

Nothing is bundled: KOReader ships Noto Naskh Arabic (the default here, the
face its own fallback list gives Arabic books) and Noto Sans Arabic UI (the
face of its plain-text widgets) in its fonts folder, and any font KOReader
knows can be picked (resolved through crengine, as KOReader's footnote popup
does for the book's font). Every weight and style is registered, a repeated
file included, so MuPDF synthesizes bold and italic for a family that has
none (probed 2026-10-28, docs/research/2026-10-28/arabic-font.md).

The setting: features.rtl_font = nil (the default, Noto Naskh Arabic), a
family name KOReader knows, or false (no rule: the window's font, FreeSerif
for the letters it lacks).
]]

local RtlFont = {}

RtlFont.FAMILY = "KOA RTL"            -- the CSS family name every rule registers
RtlFont.DEFAULT = "Noto Naskh Arabic"
RtlFont.CLASS = "koa-rtl"             -- what the direction pass writes on a right-to-left block

-- The two faces KOReader ships, by file: no font engine is needed for them
RtlFont.SHIPPED = {
    { family = "Noto Naskh Arabic", regular = "noto/NotoNaskhArabic-Regular.ttf", bold = "noto/NotoNaskhArabic-Bold.ttf" },
    { family = "Noto Sans Arabic UI", regular = "noto/NotoSansArabicUI-Regular.ttf", bold = "noto/NotoSansArabicUI-Bold.ttf" },
}

-- Seams the tests replace: where KOReader's fonts live, whether a file exists,
-- and the crengine module (nil where there is none)
function RtlFont._fontsDir()
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

function RtlFont._fileExists(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then return false end
    return lfs.attributes(path, "mode") == "file"
end

function RtlFont._cre()
    local ok, CreDocument = pcall(require, "document/credocument")
    if not ok or type(CreDocument) ~= "table" or type(CreDocument.engineInit) ~= "function" then return nil end
    local ok_init, cre = pcall(CreDocument.engineInit, CreDocument)
    if ok_init and type(cre) == "table" then return cre end
    return nil
end

--- The family in effect: nil = no rule (the window's font).
function RtlFont.family(features)
    local v = features and features.rtl_font
    if v == false then return nil end
    if type(v) == "string" and v ~= "" then return v end
    return RtlFont.DEFAULT
end

function RtlFont.shipped(family)
    for _idx, face in ipairs(RtlFont.SHIPPED) do
        if face.family == family then return face end
    end
    return nil
end

--- The four files of a family as { path, bold, italic } in that order (regular,
--- italic, bold, bold italic), or nil when the family resolves to no file. A
--- style the family has no file for takes the nearest file (the regular for
--- italic, the bold for bold italic) and MuPDF synthesizes the rest.
function RtlFont.faces(family)
    if type(family) ~= "string" or family == "" then return nil end
    local shipped = RtlFont.shipped(family)
    if shipped then
        local dir = RtlFont._fontsDir()
        local regular = dir .. "/" .. shipped.regular
        if not RtlFont._fileExists(regular) then return nil end
        local bold = dir .. "/" .. shipped.bold
        if not RtlFont._fileExists(bold) then bold = regular end
        return {
            { path = regular, bold = false, italic = false },
            { path = regular, bold = false, italic = true },
            { path = bold, bold = true, italic = false },
            { path = bold, bold = true, italic = true },
        }
    end
    local cre = RtlFont._cre()
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

local memo = {}

--- The CSS fragment for a features table: the @font-face rules of the family
--- in effect and the rule for the right-to-left blocks, or "" when there is no
--- family or its files are not there. Memoized per family (fonts are
--- registered once per KOReader start).
function RtlFont.css(features)
    local family = RtlFont.family(features)
    if not family then return "" end
    local cached = memo[family]
    if cached ~= nil then return cached end
    local faces = RtlFont.faces(family)
    local css = ""
    if faces then
        local rules = {}
        for _idx, face in ipairs(faces) do
            rules[#rules + 1] = string.format("@font-face { font-family: '%s'; src: url('%s');%s%s }",
                RtlFont.FAMILY, face.path,
                face.bold and " font-weight: bold;" or "",
                face.italic and " font-style: italic;" or "")
        end
        rules[#rules + 1] = string.format(".%s { font-family: '%s', 'Noto Sans'; }", RtlFont.CLASS, RtlFont.FAMILY)
        css = "\n" .. table.concat(rules, "\n") .. "\n"
    end
    memo[family] = css
    return css
end

function RtlFont.reset()
    memo = {}
end

--- The label of the Settings row: the family, "None" without one, "(not
--- found)" when the family resolves to no file.
function RtlFont.label(features)
    local _ = require("koassistant.core.gettext")
    local T = require("ffi/util").template
    local family = RtlFont.family(features)
    if not family then return _("None (the window's font)") end
    if RtlFont.css(features) == "" then return T(_("%1 (not found)"), family) end
    return family
end

--- The rows of the Settings row's sub-menu: the two shipped faces, None, then
--- every font KOReader knows, each drawn in its own face where KOReader's menus
--- can (TouchMenu's font_func), a tap writing features.rtl_font.
function RtlFont.menuItems(plugin)
    local _ = require("koassistant.core.gettext")
    local function current()
        local f = plugin.settings:readSetting("features") or {}
        return RtlFont.family(f)
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
            local faces = RtlFont.faces(family)
            local ok, Font = pcall(require, "ui/font")
            if faces and ok and Font and Font.getFace then
                local ok_face, face = pcall(Font.getFace, Font, faces[1].path, size)
                if ok_face then return face end
            end
            return nil
        end
    end
    local items = {}
    for _idx, face in ipairs(RtlFont.SHIPPED) do
        items[#items + 1] = {
            text = face.family,
            radio = true,
            checked_func = function() return current() == face.family end,
            callback = function()
                if face.family == RtlFont.DEFAULT then pick(nil) else pick(face.family) end
            end,
            font_func = faceFunc(face.family),
            keep_menu_open = true,
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
    local cre = RtlFont._cre()
    local families = {}
    if cre and type(cre.getFontFaces) == "function" then
        local ok, list = pcall(cre.getFontFaces)
        if ok and type(list) == "table" then
            for _idx, name in ipairs(list) do
                if type(name) == "string" and not RtlFont.shipped(name) then families[#families + 1] = name end
            end
        end
    end
    table.sort(families)
    for _idx, name in ipairs(families) do
        items[#items + 1] = {
            text = name,
            radio = true,
            checked_func = function() return current() == name end,
            callback = function() pick(name) end,
            font_func = faceFunc(name),
            keep_menu_open = true,
        }
    end
    return items
end

return RtlFont
