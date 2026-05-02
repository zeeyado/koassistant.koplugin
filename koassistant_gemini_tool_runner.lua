local BookTools = require("koassistant_book_tools")
local ConfigHelper = require("koassistant_config_helper")

local GeminiToolRunner = {}

local MAX_TOOL_TURNS = 4
local MAX_TOOL_CALLS = 8

local TOOL_INSTRUCTIONS = [[

When answering questions about the current book, use the local book tools when you need evidence from the text. The tools can only read pages up to the user's current reading position. Prefer search_book for specific phrases, character names, objects, or events; read_around for nearby context; and toc for chapter structure. Do not claim access to unread pages.]]

local FINAL_INSTRUCTIONS = [[

Use the gathered local book tool results to answer the user's question. Do not claim access to unread pages.]]

local FUNCTION_DECLARATIONS = {
    {
        name = "search_book",
        description = "Search the book text up to the current reading position. Supports exact, case-insensitive, token, and fuzzy matching.",
        parameters = {
            type = "object",
            properties = {
                query = {
                    type = "string",
                    description = "Phrase, name, event, or detail to search for.",
                },
                max_results = {
                    type = "integer",
                    description = "Maximum number of hits to return. Defaults to 8 and is capped at 12.",
                },
                fuzzy = {
                    type = "boolean",
                    description = "Use fuzzy matching for likely typos or approximate names. Defaults to true.",
                },
                case_sensitive = {
                    type = "boolean",
                    description = "Require exact casing. Defaults to false.",
                },
            },
            required = { "query" },
        },
    },
    {
        name = "read_around",
        description = "Read surrounding text near a search hit or page number, capped to a small spoiler-safe range before the current page.",
        parameters = {
            type = "object",
            properties = {
                hit_id = {
                    type = "string",
                    description = "A hit_id returned by search_book, such as p42:3.",
                },
                page = {
                    type = "integer",
                    description = "Page to read around when no hit_id is available.",
                },
                before_pages = {
                    type = "integer",
                    description = "Number of pages before the target page. Defaults to 1.",
                },
                after_pages = {
                    type = "integer",
                    description = "Number of pages after the target page. Defaults to 1.",
                },
            },
        },
    },
    {
        name = "toc",
        description = "List table-of-contents entries up to the current reading position, with short snippets from each chapter start.",
        parameters = {
            type = "object",
            properties = {
                max_snippet_chars = {
                    type = "integer",
                    description = "Maximum snippet length per entry. Defaults to 300 and is capped at 800.",
                },
                max_entries = {
                    type = "integer",
                    description = "Maximum number of TOC entries. Defaults to 120.",
                },
            },
        },
    },
}

local function appendListItem(items, text)
    if text and text ~= "" then
        table.insert(items, "- " .. text)
    end
end

local function copyMessages(messages)
    local copy = {}
    for _, msg in ipairs(messages or {}) do
        table.insert(copy, ConfigHelper:deepCopy(msg))
    end
    return copy
end

local function buildToolConfig(config, final_only)
    local tool_config = ConfigHelper:deepCopy(config or {})
    tool_config.features = tool_config.features or {}
    tool_config.features.enable_streaming = false
    tool_config.features.enable_web_search = false
    tool_config.enable_web_search = false

    if not final_only then
        tool_config.gemini_tools = {
            function_declarations = FUNCTION_DECLARATIONS,
            mode = "AUTO",
        }
    else
        tool_config.gemini_tools = nil
    end

    tool_config.system = tool_config.system or {}
    tool_config.system.text = (tool_config.system.text or "") .. (final_only and FINAL_INSTRUCTIONS or TOOL_INSTRUCTIONS)
    return tool_config
end

local function buildToolSettings(features)
    features = features or {}
    return {
        enable_book_text_extraction = features.enable_book_text_extraction == true,
        max_book_text_chars = features.max_book_text_chars,
        max_pdf_pages = features.max_pdf_pages,
    }
end

local function summarizeToolCall(call, result)
    local name = call and call.name or "tool"
    result = result or {}
    if name == "search_book" then
        local pages = {}
        if result.results then
            for i, hit in ipairs(result.results) do
                if i > 3 then break end
                table.insert(pages, tostring(hit.page))
            end
        end
        local suffix = #pages > 0 and (" on pp. " .. table.concat(pages, ", ")) or ""
        return string.format("search_book: %d result(s) for %q%s", result.result_count or 0, (call.args and call.args.query) or "", suffix)
    elseif name == "read_around" then
        local range = result.range or {}
        return string.format("read_around: pp. %s-%s", tostring(range.start_page or "?"), tostring(range.end_page or "?"))
    elseif name == "toc" then
        return string.format("toc: %d entries", result.entry_count or 0)
    end
    return name
end

local function appendTrace(answer, trace)
    if type(answer) ~= "string" or #trace == 0 then return answer end
    local lines = { "", "---", "**Lookups used:**" }
    for _, item in ipairs(trace) do
        appendListItem(lines, item)
    end
    return answer .. "\n" .. table.concat(lines, "\n")
end

local function makeFunctionResponsePart(call, result)
    local response = {
        name = call.name,
        response = result,
    }
    if call.id then
        response.id = call.id
    end
    return {
        functionResponse = response,
    }
end

local function appendModelContent(messages, model_content)
    if not model_content or not model_content.parts then return end
    table.insert(messages, {
        role = model_content.role or "model",
        parts = model_content.parts,
    })
end

function GeminiToolRunner.shouldUse(config, ui)
    local features = config and config.features or {}
    local provider = config and (config.provider or config.default_provider)
    return provider == "gemini"
        and features.is_book_context == true
        and features.is_library_context ~= true
        and features.is_general_context ~= true
        and features.enable_book_text_extraction == true
        and ui ~= nil
        and ui.document ~= nil
end

function GeminiToolRunner.run(params)
    params = params or {}
    local query_fn = params.query_fn
    local on_complete = params.on_complete
    if not query_fn then
        if on_complete then on_complete(false, nil, "Gemini tool runner missing query function") end
        return nil
    end

    local messages = copyMessages(params.messages)
    local config = params.config or {}
    local features = config.features or {}
    local tools = BookTools:new(params.ui, buildToolSettings(features))
    local trace = {}
    local tool_turns = 0
    local tool_calls = 0
    local completed = false

    local function finish(success, answer, err, reasoning, web_search_used)
        if completed then return end
        completed = true
        if success and type(answer) == "string" then
            answer = appendTrace(answer, trace)
        end
        if on_complete then
            on_complete(success, answer, err, reasoning, web_search_used)
        end
    end

    local function requestFinal()
        local final_config = buildToolConfig(config, true)
        final_config.features.loading_message = "Gemini book tools\nPreparing answer..."
        table.insert(messages, {
            role = "user",
            content = "Answer the user's question using the gathered tool results. Do not call more tools.",
        })
        return query_fn(messages, final_config, function(success, answer, err, reasoning, web_search_used)
            finish(success, answer, err, reasoning, web_search_used)
        end, params.settings)
    end

    local step
    step = function()
        if completed then return nil end
        if tool_turns >= MAX_TOOL_TURNS or tool_calls >= MAX_TOOL_CALLS then
            return requestFinal()
        end

        local tool_config = buildToolConfig(config, false)
        tool_config.features.loading_message = tool_turns == 0
            and "Gemini book tools\nThinking..."
            or "Gemini book tools\nReading..."

        return query_fn(messages, tool_config, function(success, answer, err, reasoning, web_search_used)
            if not success then
                finish(false, nil, err, reasoning, web_search_used)
                return
            end

            if type(answer) ~= "table" or answer._gemini_function_calls ~= true then
                finish(true, answer, nil, reasoning, web_search_used)
                return
            end

            local calls = answer.calls or {}
            if #calls == 0 then
                finish(false, nil, "Gemini returned an empty tool call")
                return
            end

            tool_turns = tool_turns + 1
            appendModelContent(messages, answer.model_content)

            local response_parts = {}
            for _, call in ipairs(calls) do
                if tool_calls >= MAX_TOOL_CALLS then break end
                tool_calls = tool_calls + 1
                local result = tools:execute(call.name, call.args or {})
                table.insert(trace, summarizeToolCall(call, result))
                table.insert(response_parts, makeFunctionResponsePart(call, result))
            end

            if #response_parts > 0 then
                table.insert(messages, {
                    role = "tool",
                    parts = response_parts,
                })
            end

            step()
        end, params.settings)
    end

    return step()
end

GeminiToolRunner.function_declarations = FUNCTION_DECLARATIONS

return GeminiToolRunner
