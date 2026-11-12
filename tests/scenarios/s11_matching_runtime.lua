--[[
The X-Ray matcher on KOReader's real runtime: its utf8proc case fold, which
the unit suite's mocks replace with string.lower, so none of this can be seen
there. No book is opened: the parser's own functions on strings.

From the audit of 2026-11-12 (the matching reviewer, each one reproduced on
this runtime before its fix):
- text that is not valid UTF-8 (a held word of a PDF or DjVu text layer, a
  name with half an escape pair) reaching the fold ended the app with a
  segfault: KOReader's utf8proc wrapper passes a NULL result to ffi.string.
  One call that still crashed would end this scenario with no summary;
- a name set to capitals only whose first letter is the dotted capital I or
  a full-width capital stopped matching: the aligned copy took the letter's
  lowercase fold;
- Armenian and Ethiopic names before their script's own comma or full stop
  no longer matched: those marks counted as letters;
- a Chinese name in a PDF lost every mention: the engine hands each
  character back as its own word, joined by spaces;
- "Look up in X-Ray" on a name with a typeset apostrophe said "No results".
]]
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
local XrayParser = require("koassistant.xray.xray_parser")
local ScopeResolver = require("koassistant.request.scope_resolver")

-- the real fold is in use here (the unit suite's is string.lower)
S.check(XrayParser.foldCase("\208\144\208\157\208\157\208\144") == "\208\176\208\189\208\189\208\176",
    "this runtime folds Cyrillic capitals (utf8proc is loaded)")

-- ── Text that is not valid UTF-8 ────────────────────────────────────────────
local BAD = "Ann\255a"
local HALF = "Ann\237\160\189a"   -- half an escape pair, as KOReader's JSON decoder leaves it
local data = { characters = { { name = "Anna Vale", aliases = { "Anna" }, description = "A sailor." } } }
local survived = 0
for _i, text in ipairs({ BAD, HALF, "\192\175", "caf\195", "\237\160\189\237\180\141" }) do
    XrayParser.foldCase(text)
    XrayParser.matchNormalize(text)
    XrayParser.matchNormalizeKeepCase(text)
    XrayParser.exactQueryKeys(text)
    XrayParser.normalizeHandle(text)
    XrayParser.searchAll(data, text, { skip_description = true })
    XrayParser.searchAll(data, text, { exact = true })
    XrayParser.hitInsideHandle("said " .. text, "Vale", "went", { "anna vale" })
    XrayParser.alignedKeepCase(text .. " and Anna", XrayParser.matchNormalize(text .. " and Anna"))
    local set = {}
    XrayParser.foldExactHandles(data, set)
    XrayParser.matchExactHandle(set, text)
    survived = survived + 1
end
S.check(survived == 5, "invalid bytes pass through every fold site without ending the app (5 texts, 11 calls each)")
S.check(ScopeResolver.utf8Mask(BAD) == "Ann?a" and #ScopeResolver.utf8Mask(HALF) == #HALF,
    "they are masked one byte for one byte, so positions hold")
S.check(ScopeResolver.utf8Mask("caf\195\169 \228\184\173") == "caf\195\169 \228\184\173", "valid text is left as it is")
local BookTools = require("koassistant.tools.book_tools")
S.check(type(BookTools._lowercase) == "function" and BookTools._lowercase(BAD .. " \208\144") ~= nil
    and BookTools._lowercase(HALF .. " \208\144") ~= nil, "the book tools' fold takes them too")

-- ── A capital whose fold changes its length ─────────────────────────────────
local function capsOk(text, name)
    local norm = XrayParser.matchNormalize(text)
    local keep = XrayParser.alignedKeepCase(text, norm)
    local needle = XrayParser.matchNormalize(name)
    local s, e = norm:find(needle, 1, true)
    if not s then return nil, "the name is not in the folded text" end
    local required = XrayParser.capsRequired(XrayParser.matchNormalizeKeepCase(name), false)
    return XrayParser.spanCapsOk(norm, keep, s, e, required), #keep == #norm
end
local ok_i, aligned_i = capsOk("Dün \196\176lkay geldi.", "\196\176lkay")
S.check(aligned_i == true, "a page with the dotted capital I is aligned to its fold")
S.check(ok_i == true, "\196\176lkay, capitalized in the text, passes the capitals-only rule")
local evidence_text = "Dün \196\176lkay geldi."
local norm_e = XrayParser.matchNormalize(evidence_text)
local keep_e = XrayParser.alignedKeepCase(evidence_text, norm_e)
local s_e, e_e = norm_e:find(XrayParser.matchNormalize("\196\176lkay"), 1, true)
S.check(s_e ~= nil and XrayParser.capsMask(keep_e:sub(s_e, e_e)) == 1,
    "and its capital is read as a capital, not as lowercase")
local ok_low = capsOk("d\195\188n ilkay geldi.", "\196\176lkay")
S.note("lowercase ilkay against the capitals-only İlkay:", tostring(ok_low))
local ok_fw, aligned_fw = capsOk("He flew to \239\188\180okyo today.", "Tokyo")
S.check(aligned_fw == true and ok_fw == true, "a full-width capital T keeps its capital too")

-- ── The marks of Armenian and Ethiopic are no letters ───────────────────────
local function hits(text, name)
    local set = XrayParser.matchTermSet({ name = name }, "all")
    local norm = XrayParser.matchNormalize(text)
    return #XrayParser.occurrencesIn(norm, set)
end
local ARM = "\212\177\214\128\214\130\213\189\213\181\213\161\213\175"          -- Արուսյակ
S.check(hits(ARM .. "\214\137 " .. ARM .. "\213\157 " .. ARM .. " " .. ARM .. ".", ARM) == 4,
    "an Armenian name before its full stop and its comma matches (4 of 4)")
local ETH = "\225\138\160\225\137\160\225\137\160"                              -- አበበ
S.check(hits(ETH .. "\225\141\163 " .. ETH .. "\225\141\162 " .. ETH, ETH) == 3,
    "an Ethiopic name before its comma and its full stop matches (3 of 3)")
S.check(hits(ARM .. "\213\171\214\129", ARM) == 0, "a longer Armenian word still does not count as the name")

-- ── A Chinese name in a PDF ─────────────────────────────────────────────────
local XrayBrowser = require("koassistant.xray.xray_browser")
local pdfWholeWord = XrayBrowser._pdfWholeWord
S.check(pdfWholeWord("\230\158\151 \233\187\155 \231\142\137", "\230\158\151\233\187\155\231\142\137") == true,
    "a Chinese name whose characters the PDF engine spaced apart keeps its mention")
S.check(pdfWholeWord("Hannah", "Ann") == false and pdfWholeWord("Anna Vale", "Anna Vale") == true,
    "a Latin name is still held to whole words")

-- ── A typeset apostrophe in a lookup ────────────────────────────────────────
local typeset = { characters = { { name = "O'Brannagh", description = "A pilot." } } }
local found = XrayParser.searchAll(typeset, "O\226\128\153Brannagh", { skip_description = true })
S.check(type(found) == "table" and #found == 1, "a lookup with a typeset apostrophe finds the entry written with a plain one")
found = XrayParser.searchAll({ characters = { { name = "R2\226\128\145D9", description = "A machine." } } },
    "R2-D9", { skip_description = true })
S.check(type(found) == "table" and #found == 1, "and a plain hyphen finds a name written with a non-breaking one")

S.finish()
