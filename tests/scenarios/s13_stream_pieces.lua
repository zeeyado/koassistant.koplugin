--[[
Markdown while streaming converts an answer piece by piece: the part that is
finished is converted once and kept, and each drawing converts what came
after (koassistant/request/stream_markdown.lua, safeCut and convert). The
pieces must give the HTML the whole conversion gives, at every moment of a
stream, or the window would show something else than the finished chat.

On the app's own runtime (its Markdown library behaves otherwise on another
Lua), no book opened:
- every sample of tests/lib/markdown_samples.lua streamed byte by byte, and
  400 documents put together from their blocks at random, streamed in random
  steps: the kept conversion equals the whole one at every step;
- a table and a link streamed byte by byte: no line of pipes and no address
  is shown while they arrive (healTail);
- every rule of the cut taken out in turn (a changed copy of the module's
  source, never the file): the same check must then find differences, so no
  rule is left without a sample that needs it.
Run: sh tests/scenarios/run.sh <scratch dir> s13_stream_pieces
]]
local PLUGIN = os.getenv("KOA_PLUGIN")
local S = dofile(PLUGIN .. "/tests/scenarios/boot.lua")
local Viewer = require("koassistant.ui.chatgptviewer")
local SM = require("koassistant.request.stream_markdown")
local samples = dofile(PLUGIN .. "/tests/lib/markdown_samples.lua")

-- A sample the Markdown library fails on is converted whole and logged at
-- every step; thousands of those lines would bury this scenario's own
local plugin_logger = require("koassistant.core.logger")
local real_warn = plugin_logger.warn
plugin_logger.warn = function() end

local OPTS = { features = {}, text_align = "auto" }

local blocks = {}
for _i, s in ipairs(samples) do
    for block in (s.text .. "\n\n"):gmatch("(.-)\n\n+") do
        if block:find("%S") then blocks[#blocks + 1] = block end
    end
end

--- Every sample in steps of `sample_step` bytes and `documents` random
--- documents in random steps, each step compared with the whole conversion.
--- Returns the steps, the ones that differ, the first of them, and how many
--- bytes of how many were kept at the streams' ends.
local function compare(sample_step, documents, seed)
    local steps, bad, first, kept_bytes, all_bytes = 0, 0, nil, 0, 0
    local function stream(name, text, step_of)
        local kept = { text = "", html = "" }
        local at = 0
        while at < #text do
            at = math.min(#text, at + step_of())
            -- never inside a character (the stream handler joins the pieces of one)
            while at < #text and text:byte(at + 1) >= 128 and text:byte(at + 1) < 192 do at = at + 1 end
            local prefix = text:sub(1, at)
            local ok, a = pcall(SM.convert, kept, prefix, OPTS)
            local b = Viewer.markdownHtml(SM.healTail(prefix), OPTS)
            steps = steps + 1
            if not ok or a ~= b then
                bad = bad + 1
                first = first or (name .. ", byte " .. at)
            end
        end
        kept_bytes, all_bytes = kept_bytes + #kept.text, all_bytes + #text
    end
    for _i, s in ipairs(samples) do
        stream(s.name, s.text, function() return sample_step end)
    end
    local function rnd(n)
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed % n + 1
    end
    for doc = 1, documents do
        local parts = {}
        for _b = 1, 4 + rnd(8) do
            parts[#parts + 1] = blocks[rnd(#blocks)]
            local sep = rnd(10)
            parts[#parts + 1] = sep <= 7 and "\n\n" or (sep <= 9 and "\n" or "\n\n\n")
        end
        stream("random document " .. doc, table.concat(parts), function() return rnd(24) end)
    end
    return steps, bad, first, kept_bytes, all_bytes
end

-- ── The pieces give the whole conversion's HTML ─────────────────────────────
local steps, bad, first, kept_bytes, all_bytes = compare(1, 400, 12345)
S.check(bad == 0, string.format("the kept conversion equals the whole one at every step (%d steps, %d differ%s)",
    steps, bad, first and ("; first: " .. first) or ""))
S.check(kept_bytes * 3 > all_bytes, string.format("and it does keep: %d of %d bytes were converted once", kept_bytes, all_bytes))

-- ── What is still arriving is not shown raw ─────────────────────────────────
-- (healTail: a table's row waits until it is whole, a link shows its words
-- while its address arrives; the samples hold no pipe and no address of
-- their own outside the marks)
local function everyStep(text, shown_right)
    local kept = { text = "", html = "" }
    local bad, first = 0, nil
    for at = 1, #text do
        if not shown_right(SM.convert(kept, text:sub(1, at), OPTS)) then
            bad = bad + 1
            first = first or at
        end
    end
    return bad, first
end
local TABLE = "Here is the comparison:\n\n| Device | Screen | Battery |\n|--------|:------:|--------:|\n"
    .. "| Kobo Clara | 6 inch | weeks |\n| Kindle | 6.8 inch | weeks |\n\nThat is the table.\n"
local bad_rows, first_row = everyStep(TABLE, function(html) return not html:find("|", 1, true) end)
S.check(bad_rows == 0, string.format("a table streamed byte by byte never shows a line of pipes (%d steps do%s)",
    bad_rows, first_row and (", first at byte " .. first_row) or ""))
S.check(SM.convert({ text = "", html = "" }, TABLE, OPTS):find("<td[^>]*>Kindle</td>") ~= nil, "and the whole table is there at the end")
local LINK = "Read [the guide](https://example.org/guides/which-one) and [another](https://example.org/b) too.\n"
local bad_links, first_link = everyStep(LINK, function(html)
    return not html:gsub('href="[^"]*"', ""):find("example", 1, true) and not html:find("&#93;(", 1, true)
end)
S.check(bad_links == 0, string.format("a link never shows its address while it arrives (%d steps do%s)",
    bad_links, first_link and (", first at byte " .. first_link) or ""))

-- ── Every rule of the cut is needed ─────────────────────────────────────────
-- name, the source text of the rule, what replaces it
local RULES = {
    { "a cut needs a blank line before it", "if after_blank and not in_fence", "if not in_fence" },
    { "none inside a code fence", "if after_blank and not in_fence and (prev_at_margin", "if after_blank and (prev_at_margin" },
    { "none inside a list's indented content", "(prev_at_margin or (nl and atMargin(line)", "(true or (nl and atMargin(line)" },
    -- (a rule left 2026-11-17: "after indented content the next line is no
    -- list item". Lists that only white space separates are joined when the
    -- pieces are finished, so a piece that starts with a list item gives the
    -- whole conversion's HTML; this scenario found no sample that needed it)
    { "after indented content the next line is at the margin", "(nl and atMargin(line)", "(nl and true" },
    { "nothing open before a cut", "if marksClosed(text, first, found[i + 1], cut, math) then return cut end",
        "if true then return cut end" },
    { "the math pass has nothing open", "if math and not mathClosed(text:sub(stretch, cut - 1)) then return false end", "" },
    { "no code span open", "if rest:find(\"`\", 1, true) then return false end", "" },
    { "no $$ display open", "if rest:find(\"$$\", 1, true) then return false end", "" },
    { "no \\[ display open", "if rest:find(\"\\\\[\", 1, true) then return false end", "" },
    { "no \\( span open", "return not rest:find(\"\\\\(\", 1, true)", "return true" },
    { "the math pass pairs between code fences", "stretch = nl + 1", "stretch = stretch" },
    { "brackets as the math pass leaves them", "if math then piece = math(piece) end", "" },
    { "no bracket open", "if piece:find(\"%[[^%]]*$\") then return false end", "" },
    { "no link's parentheses open", "if not piece:find(\"^%b()\", e) then return false end", "" },
    { "no odd $$ left", "return not piece:find(\"$$\", 1, true) or count(piece, \"$$\") % 2 == 0", "return true" },
}
local f = assert(io.open(PLUGIN .. "/koassistant/request/stream_markdown.lua", "r"))
local source = f:read("*a")
f:close()
local real_cut = SM.safeCut
for _i, rule in ipairs(RULES) do
    local a, b = source:find(rule[2], 1, true)
    if not a then
        S.check(false, "the rule's source text was not found (update this scenario with the rule): " .. rule[1])
    else
        local chunk, err = loadstring(source:sub(1, a - 1) .. rule[3] .. source:sub(b + 1), "a changed copy")
        if not chunk then
            S.check(false, rule[1] .. ": the changed copy does not load: " .. tostring(err))
        else
            local loaded = package.loaded["koassistant.request.stream_markdown"]
            local changed = chunk()
            package.loaded["koassistant.request.stream_markdown"] = loaded
            SM.safeCut = changed.safeCut
            local _steps, differ, where = compare(3, 150, 777)
            SM.safeCut = real_cut
            S.check(differ > 0, string.format("without the rule \"%s\" the pieces differ (%d steps%s)", rule[1], differ,
                where and (", first: " .. where) or ""))
        end
    end
end
local _steps, differ = compare(3, 150, 777)
S.check(differ == 0, "and with every rule in place the same streams do not (" .. differ .. ")")

plugin_logger.warn = real_warn
S.finish()
