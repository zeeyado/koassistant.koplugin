-- Generates the code-derived tables of wiki/Providers-and-Models.md from
-- koassistant/request/model_lists.lua (B434): every curated provider's default and
-- built-in list, the community hosts' built-in lists, and the tier picks. The
-- page keeps each table between "<!-- generated: name -->" and
-- "<!-- /generated: name -->" markers; this script rewrites those blocks in
-- place, and tests/unit/test_wiki_pages.lua fails when a block differs from
-- this output, so a model refresh is followed by:
--   lua tests/tools/gen_provider_tables.lua     (from the repository root)
-- As a module: Gen.generate(ModelLists) -> { name = markdown }, Gen.apply(text,
-- blocks) -> new text + the names whose markers are missing, Gen.NAMES, Gen.ORDER.
local Gen = {}

-- The brand names the pages use (the code's getProviderDisplayName capitalizes
-- ids, B425). Every id ModelLists.getAllProviders() returns must be here; the
-- test fails on a new provider until it is named.
Gen.NAMES = {
    anthropic = "Anthropic", openai = "OpenAI", openai_codex = "OpenAI Subscription", deepseek = "DeepSeek",
    gemini = "Gemini", ollama = "Ollama", groq = "Groq", fireworks = "Fireworks", sambanova = "SambaNova",
    together = "Together", mistral = "Mistral", xai = "xAI", openrouter = "OpenRouter", requesty = "Requesty",
    cohere = "Cohere", qwen = "Qwen", kimi = "Kimi", doubao = "Doubao", zai = "Z.AI", perplexity = "Perplexity",
    nvidia = "NVIDIA", cerebras = "Cerebras", minimax = "MiniMax", deepinfra = "DeepInfra", novita = "Novita AI",
    hyperbolic = "Hyperbolic", nebius = "Nebius AI Studio", chutes = "Chutes", featherless = "Featherless",
    vercel = "Vercel AI Gateway", opencode = "OpenCode Zen", opencode_go = "OpenCode Go", a2agent = "A2Agent",
    cheaperinference = "Cheaper Inference",
}
-- The order the tables list providers in: the curated set, then the community set.
Gen.ORDER = {
    "anthropic", "openai", "openai_codex", "deepseek", "gemini", "groq", "mistral", "xai", "openrouter",
    "perplexity", "zai", "cohere", "kimi", "qwen", "ollama", "fireworks", "nvidia", "opencode", "opencode_go",
    "a2agent", "together", "sambanova", "requesty", "doubao", "cerebras", "minimax", "deepinfra", "novita",
    "hyperbolic", "nebius", "chutes", "featherless", "vercel", "cheaperinference",
}
Gen.BLOCKS = { "defaults", "community", "tiers" }
Gen.LIST_CAP = 8 -- ids shown per list cell; the rest is counted

local TIERS = { "frontier", "flagship", "standard", "fast", "ultrafast" }

local function code(id)
    return "`" .. id .. "`"
end

local function listCell(list, from)
    local parts, n = {}, 0
    for i = from, #list do
        n = n + 1
        if n <= Gen.LIST_CAP then parts[#parts + 1] = code(list[i]) end
    end
    if n == 0 then return "(none)" end
    local s = table.concat(parts, ", ")
    if n > Gen.LIST_CAP then s = s .. " and " .. (n - Gen.LIST_CAP) .. " more" end
    return s
end

local function providers(ML, community)
    local out = {}
    for _idx, id in ipairs(Gen.ORDER) do
        if type(ML[id]) == "table" and ML.isCommunity(id) == community then out[#out + 1] = id end
    end
    return out
end

local function name(id)
    return "**" .. (Gen.NAMES[id] or id) .. "**"
end

function Gen.generate(ML)
    ML = ML or require("koassistant.request.model_lists")
    local blocks = {}

    local rows = { "| Provider | Default | Also listed |", "|----------|---------|-------------|" }
    for _idx, id in ipairs(providers(ML, false)) do
        local list = ML[id]
        rows[#rows + 1] = string.format("| %s | %s | %s |", name(id), code(list[1]), listCell(list, 2))
    end
    blocks.defaults = table.concat(rows, "\n") .. "\n"

    rows = { "| Provider | Built-in list |", "|----------|---------------|" }
    for _idx, id in ipairs(providers(ML, true)) do
        rows[#rows + 1] = string.format("| %s | %s |", name(id), listCell(ML[id], 1))
    end
    blocks.community = table.concat(rows, "\n") .. "\n"

    rows = { "| Provider | Frontier | Flagship | Standard | Fast | Ultrafast |", "|----------|----------|----------|----------|------|-----------|" }
    for _idx, id in ipairs(Gen.ORDER) do
        local cells, any = {}, false
        for _t, tier in ipairs(TIERS) do
            local m = ML._tiers[tier] and ML._tiers[tier][id]
            if m then
                any = true
                cells[#cells + 1] = code(m)
            else
                cells[#cells + 1] = ""
            end
        end
        if any then rows[#rows + 1] = "| " .. name(id) .. " | " .. table.concat(cells, " | ") .. " |" end
    end
    blocks.tiers = table.concat(rows, "\n") .. "\n"

    return blocks
end

-- Replaces the content of every marked block in text; returns the new text and
-- the names of the blocks whose markers are missing.
function Gen.apply(text, blocks)
    local missing = {}
    for _idx, block in ipairs(Gen.BLOCKS) do
        local open = "<!-- generated: " .. block .. " -->\n"
        local close = "<!-- /generated: " .. block .. " -->"
        local s = text:find(open, 1, true)
        local e = s and text:find(close, s + #open, true)
        if s and e then
            text = text:sub(1, s + #open - 1) .. blocks[block] .. text:sub(e)
        else
            missing[#missing + 1] = block
        end
    end
    return text, missing
end

-- The content of one marked block as the page holds it, or nil.
function Gen.extract(text, block)
    local open = "<!-- generated: " .. block .. " -->\n"
    local close = "<!-- /generated: " .. block .. " -->"
    local s = text:find(open, 1, true)
    local e = s and text:find(close, s + #open, true)
    if not (s and e) then return nil end
    return text:sub(s + #open, e - 1)
end

Gen.PAGE = "wiki/Providers-and-Models.md"

local function thisScript()
    local src = debug.getinfo(1, "S").source
    return src and src:match("^@?(.*)$") or ""
end

if arg and arg[0] and arg[0]:match("gen_provider_tables") then
    local script = thisScript()
    if script:sub(1, 1) ~= "/" then script = (os.getenv("PWD") or ".") .. "/" .. script end
    local tools_dir = script:match("(.+)/[^/]+$")
    local plugin_dir = tools_dir:match("(.+)/[^/]+$"):match("(.+)/[^/]+$")
    package.path = table.concat({ plugin_dir .. "/?.lua", plugin_dir .. "/tests/?.lua", plugin_dir .. "/tests/lib/?.lua", package.path }, ";")
    require("mock_koreader")
    local path = plugin_dir .. "/" .. Gen.PAGE
    local f = assert(io.open(path, "r"))
    local text = f:read("*a")
    f:close()
    local new_text, missing = Gen.apply(text, Gen.generate())
    if #missing > 0 then
        io.stderr:write("markers missing in " .. Gen.PAGE .. ": " .. table.concat(missing, ", ") .. "\n")
        os.exit(1)
    end
    f = assert(io.open(path, "w"))
    f:write(new_text)
    f:close()
    print(path)
end

return Gen
