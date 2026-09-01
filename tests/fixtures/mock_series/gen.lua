--[[
Mock X-Ray fixture GENERATOR (#90, docs/xray_cross_book_lookup_plan.md §6.2).

Builds seven tiny invented EPUBs plus their KOAssistant sidecar data (X-Ray
caches with carried-entity ledgers, a built-ahead ladder rung, a ring archive,
a section X-Ray, a user-alias file, per-book DocSettings keys) so every
cross-book lookup surface can be exercised on a device or the desktop KOReader
in minutes — no real X-Ray runs, no API calls. Runs OFFLINE under the unit-test
mocks and writes through the REAL ActionCache APIs, so the files on disk are
byte-authentic.

Usage (from the repo root; needs `zip` on PATH):

    lua tests/fixtures/mock_series/gen.lua --out <dir> [--base <target dir>]

  --out   Where to write the folders (Mock Series/, Mock Project/, Mock Shelf/).
  --base  The path where those folders will LIVE when tested (defaults to
          --out). Pass it when generating for a device: cross-book provenance
          is path identity, so stub `file` fields must match the device paths.
          Example for a Kobo:
            lua tests/fixtures/mock_series/gen.lua \
                --out /tmp/koamock --base /mnt/onboard/Books
          then copy /tmp/koamock/* to /mnt/onboard/Books/.

Sidecars are written side-by-side (`Book.sdr/` next to `Book.epub`, KOReader's
default "doc" location) and travel with the folder copy. Re-running into the
same --out regenerates the plugin sidecar files from scratch (they are fixture
output, not user data). The three GROUPS are created by hand on the target with
"New group from folder…" — group creation is itself an entry point under test.

After writing, everything is read back through the real loaders and parsed with
the real XrayParser; the script exits non-zero if any piece fails.
]]

-- ------------------------------------------------------------- paths + mocks
local script_dir
local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    script_dir = script_path:match("(.+)/[^/]+$") or "."
    local fixtures_dir = script_dir:match("(.+)/[^/]+$") or "."
    local tests_dir = fixtures_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/?/init.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end
setupPaths()

-- ---------------------------------------------------------------------- args
local OUT, BASE
do
    local i = 1
    while i <= #arg do
        if arg[i] == "--out" then
            OUT = arg[i + 1]; i = i + 2
        elseif arg[i] == "--base" then
            BASE = arg[i + 1]; i = i + 2
        else
            io.stderr:write("Unknown argument: " .. tostring(arg[i]) .. "\n")
            os.exit(1)
        end
    end
end
if not OUT or OUT == "" then
    io.stderr:write("Usage: lua tests/fixtures/mock_series/gen.lua --out <dir> [--base <target dir>]\n")
    os.exit(1)
end
OUT = OUT:gsub("/+$", "")
BASE = (BASE and BASE ~= "") and BASE:gsub("/+$", "") or OUT
assert(not BASE:find('"'), "--base must not contain a double quote (it is embedded in JSON)")
assert(not BASE:find("\\"), "--base must not contain a backslash (it is embedded in JSON)")

if os.execute("command -v zip >/dev/null 2>&1") ~= 0 and os.execute("command -v zip >/dev/null 2>&1") ~= true then
    io.stderr:write("The `zip` tool is required on PATH.\n")
    os.exit(1)
end

-- Mock KOReader environment, then point DocSettings sidecar resolution at OUT
-- while the plants are addressed by their BASE (target) paths.
require("mock_koreader")
_G.G_reader_settings = {
    _store = {},
    readSetting = function(self, key, default)
        local v = self._store[key]
        if v == nil then return default end
        return v
    end,
    saveSetting = function(self, key, value) self._store[key] = value end,
    flush = function() end,
}
local function sidecarDirFor(doc_path)
    assert(doc_path:sub(1, #BASE) == BASE,
        "document path outside --base: " .. doc_path)
    local rel = doc_path:sub(#BASE + 1)
    local trunk = rel:match("(.*)%.") or rel
    return OUT .. trunk .. ".sdr"
end
package.loaded["docsettings"] = {
    getSidecarDir = function(_self, doc_path, _force) return sidecarDirFor(doc_path) end,
    isHashLocationEnabled = function() return false end,
}
package.loaded["util"] = {
    makePath = function(dir) os.execute(string.format("mkdir -p %q", dir)) end,
}
package.loaded["luasettings"] = {
    open = function() return { readSetting = function() return nil end, close = function() end } end,
}

local ActionCache = require("koassistant_action_cache")
local XrayParser = require("koassistant_xray_parser")

local spec = dofile(script_dir .. "/spec.lua")

-- ------------------------------------------------------------------- helpers
local function fail(msg)
    io.stderr:write("FAIL: " .. msg .. "\n")
    os.exit(1)
end

local function writeFile(path, content)
    local dir = path:match("(.*/)")
    if dir then os.execute(string.format("mkdir -p %q", dir)) end
    local f, err = io.open(path, "w")
    if not f then fail("cannot write " .. path .. ": " .. tostring(err)) end
    f:write(content)
    f:close()
end

local function xmlEscape(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- Final (target) path of book n in the spec array
local function targetPath(n)
    local b = spec.books[n]
    return BASE .. "/" .. b.folder .. "/" .. b.filename
end

local function fillJSON(json)
    return (json:gsub("__PATH:(%d+)__", function(n)
        return targetPath(tonumber(n))
    end))
end

-- --------------------------------------------------------------- EPUB writer
local function buildEpub(book)
    local build = OUT .. "/.build"
    os.execute(string.format("rm -rf %q", build))
    os.execute(string.format("mkdir -p %q", build .. "/META-INF"))
    os.execute(string.format("mkdir -p %q", build .. "/OEBPS"))

    writeFile(build .. "/mimetype", "application/epub+zip")
    writeFile(build .. "/META-INF/container.xml", [[<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
]])

    local uid = "koamock-" .. book.filename:gsub("%W", ""):lower()
    local manifest, spine, navpoints = {}, {}, {}
    local filler_i = 0
    for i, chap in ipairs(book.chapters) do
        local id = string.format("ch%02d", i)
        local paras = { "    <p>" .. xmlEscape(chap.text) .. "</p>" }
        for _n = 1, (chap.filler or 3) do
            filler_i = filler_i % #spec.filler + 1
            paras[#paras + 1] = "    <p>" .. xmlEscape(spec.filler[filler_i]) .. "</p>"
        end
        writeFile(build .. "/OEBPS/" .. id .. ".xhtml", table.concat({
            '<?xml version="1.0" encoding="UTF-8"?>',
            '<html xmlns="http://www.w3.org/1999/xhtml">',
            "  <head><title>" .. xmlEscape(chap.title) .. "</title></head>",
            "  <body>",
            "    <h2>" .. xmlEscape(chap.title) .. "</h2>",
            table.concat(paras, "\n"),
            "  </body>",
            "</html>",
            "",
        }, "\n"))
        manifest[#manifest + 1] = string.format(
            '    <item id="%s" href="%s.xhtml" media-type="application/xhtml+xml"/>', id, id)
        spine[#spine + 1] = string.format('    <itemref idref="%s"/>', id)
        navpoints[#navpoints + 1] = table.concat({
            string.format('    <navPoint id="nav%02d" playOrder="%d">', i, i),
            "      <navLabel><text>" .. xmlEscape(chap.title) .. "</text></navLabel>",
            string.format('      <content src="%s.xhtml"/>', id),
            "    </navPoint>",
        }, "\n")
    end

    writeFile(build .. "/OEBPS/content.opf", table.concat({
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uid" version="2.0">',
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">',
        "    <dc:title>" .. xmlEscape(book.title) .. "</dc:title>",
        "    <dc:creator>" .. xmlEscape(book.author) .. "</dc:creator>",
        '    <dc:identifier id="uid">' .. uid .. "</dc:identifier>",
        "    <dc:language>en</dc:language>",
        "  </metadata>",
        "  <manifest>",
        '    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
        table.concat(manifest, "\n"),
        "  </manifest>",
        '  <spine toc="ncx">',
        table.concat(spine, "\n"),
        "  </spine>",
        "</package>",
        "",
    }, "\n"))

    writeFile(build .. "/OEBPS/toc.ncx", table.concat({
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">',
        "  <head>",
        '    <meta name="dtb:uid" content="' .. uid .. '"/>',
        '    <meta name="dtb:depth" content="1"/>',
        "  </head>",
        "  <docTitle><text>" .. xmlEscape(book.title) .. "</text></docTitle>",
        "  <navMap>",
        table.concat(navpoints, "\n"),
        "  </navMap>",
        "</ncx>",
        "",
    }, "\n"))

    local epub = OUT .. "/" .. book.folder .. "/" .. book.filename
    os.execute(string.format("mkdir -p %q", OUT .. "/" .. book.folder))
    os.remove(epub)
    local cmd = string.format(
        "cd %q && zip -X -q -0 %q mimetype && zip -X -q -9 -r %q META-INF OEBPS",
        build, epub, epub)
    local ok = os.execute(cmd)
    if ok ~= 0 and ok ~= true then fail("zip failed for " .. book.filename) end
    os.execute(string.format("rm -rf %q", build))
end

-- ------------------------------------------------------------------ planting
local SIDECAR_FILES = {
    "koassistant_cache.lua", "koassistant_user_aliases.lua",
    ActionCache.XRAY_LADDER_FILE, ActionCache.XRAY_CHECKPOINTS_FILE,
}

local function serializeSidecarValue(v)
    if type(v) == "string" then return string.format("%q", v) end
    return tostring(v)
end

local function plantBook(n)
    local book = spec.books[n]
    local target = targetPath(n)
    local sdr = sidecarDirFor(target)

    -- Regeneration wipes ONLY the plugin fixture files (never the EPUB's
    -- KOReader metadata beyond our own): fixture output, not user data.
    for _idx, name in ipairs(SIDECAR_FILES) do
        os.remove(sdr .. "/" .. name)
    end

    if book.xray then
        local json = fillJSON(book.xray.json)
        if not XrayParser.parse(json) then fail(book.filename .. ": live JSON does not parse") end
        if not ActionCache.set(target, "xray", json, book.xray.progress, book.xray.meta) then
            fail(book.filename .. ": ActionCache.set failed")
        end
    end
    for _idx, sec in ipairs(book.sections or {}) do
        local json = fillJSON(sec.json)
        if not XrayParser.parse(json) then fail(book.filename .. ": section JSON does not parse") end
        local key = ActionCache.SECTION_PREFIXES.xray .. sec.label
        if not ActionCache.set(target, key, json, 1.0, {
            model = "mock", used_book_text = true, source_mode = "book_text",
            timestamp = sec.timestamp, scope_label = sec.label,
            scope_start_page = sec.start_page, scope_end_page = sec.end_page,
        }) then fail(book.filename .. ": section set failed") end
    end
    for _idx, rung in ipairs(book.ladder or {}) do
        local json = fillJSON(rung.json)
        if not XrayParser.parse(json) then fail(book.filename .. ": rung JSON does not parse") end
        if not ActionCache.pushXrayLadderRung(target, {
            result = json, progress_decimal = rung.progress, timestamp = rung.timestamp,
            model = rung.model, used_book_text = rung.used_book_text,
            source_mode = rung.source_mode,
        }) then fail(book.filename .. ": ladder push failed") end
    end
    for _idx, cp in ipairs(book.ring or {}) do
        local json = fillJSON(cp.json)
        if not XrayParser.parse(json) then fail(book.filename .. ": ring JSON does not parse") end
        if not ActionCache.pushXrayCheckpoint(target, {
            result = json, progress_decimal = cp.progress, timestamp = cp.timestamp,
            model = cp.model, used_book_text = cp.used_book_text,
            source_mode = cp.source_mode,
        }) then fail(book.filename .. ": ring push failed") end
    end
    if book.aliases then
        if not ActionCache.setUserAliases(target, book.aliases) then
            fail(book.filename .. ": setUserAliases failed")
        end
    end
    if book.sidecar then
        local lines = { "-- KOAssistant mock fixture (gen.lua); KOReader merges its own keys on first open", "return {" }
        local keys = {}
        for k in pairs(book.sidecar) do keys[#keys + 1] = k end
        table.sort(keys)
        for _idx, k in ipairs(keys) do
            lines[#lines + 1] = string.format("    [%q] = %s,", k, serializeSidecarValue(book.sidecar[k]))
        end
        lines[#lines + 1] = "}"
        lines[#lines + 1] = ""
        os.execute(string.format("mkdir -p %q", sdr))
        local ext = book.filename:match("%.([^.]+)$") or "_"
        writeFile(sdr .. "/metadata." .. ext .. ".lua", table.concat(lines, "\n"))
    end
end

-- ---------------------------------------------------------------- loadback
local function getEntry(target, action_id)
    if ActionCache.get then return ActionCache.get(target, action_id) end
    local ok, cache = pcall(dofile, ActionCache.getPath(target))
    return ok and type(cache) == "table" and cache[action_id] or nil
end

local function verifyBook(n)
    local book = spec.books[n]
    local target = targetPath(n)
    local notes = {}
    if book.xray then
        local entry = getEntry(target, "xray")
        if not entry then fail(book.filename .. ": live entry did not load back") end
        local parsed = XrayParser.parse(entry.result)
        if not parsed then fail(book.filename .. ": live entry did not re-parse") end
        local ledger = parsed[XrayParser.DORMANT_KEY]
        notes[#notes + 1] = string.format("live %d%%", math.floor((entry.progress_decimal or 0) * 100 + 0.5))
        if ledger then notes[#notes + 1] = string.format("%d carried", #ledger) end
    end
    local ladder = ActionCache.getXrayLadder(target)
    if book.ladder and #ladder ~= #book.ladder then fail(book.filename .. ": ladder count mismatch") end
    if #ladder > 0 then
        for _idx, rung in ipairs(ladder) do
            if not XrayParser.parse(rung.result) then fail(book.filename .. ": rung did not re-parse") end
        end
        notes[#notes + 1] = string.format("%d rung(s)", #ladder)
    end
    local ring = ActionCache.getXrayCheckpoints(target)
    if book.ring and #ring ~= #book.ring then fail(book.filename .. ": ring count mismatch") end
    if #ring > 0 then notes[#notes + 1] = string.format("%d archived", #ring) end
    for _idx, sec in ipairs(book.sections or {}) do
        if not getEntry(target, ActionCache.SECTION_PREFIXES.xray .. sec.label) then
            fail(book.filename .. ": section entry did not load back")
        end
        notes[#notes + 1] = "1 section"
    end
    if book.aliases then
        local back = ActionCache.getUserAliases(target)
        if not next(back) then fail(book.filename .. ": aliases did not load back") end
        notes[#notes + 1] = "aliases"
    end
    local epub = OUT .. "/" .. book.folder .. "/" .. book.filename
    local f = io.open(epub, "r")
    if not f then fail(book.filename .. ": EPUB missing") end
    f:close()
    print(string.format("  %-38s %s", book.filename, table.concat(notes, ", ")))
end

-- ----------------------------------------------------------------------- run
print("Mock X-Ray fixture -> " .. OUT)
if BASE ~= OUT then print("Target base (path identity in the data): " .. BASE) end
for n, book in ipairs(spec.books) do
    buildEpub(book)
    plantBook(n)
end
print("")
for n = 1, #spec.books do
    verifyBook(n)
end
print([[

Done. Next, on the target:
  1. If --base differs from --out, copy the three folders to the base path.
  2. Create the groups by hand (group creation is an entry point under test):
     KOAssistant menu > Groups > "New group from folder...", once per folder,
     picking the kind when asked:
       Mock Series  -> kind Series
       Mock Project -> kind Project
       Mock Shelf   -> kind Plain
  3. Open "Mock Series 3 - The Orchard" and follow the device steps in
     docs/xray_cross_book_lookup_plan.md section 6.2.
]])
os.exit(0)
