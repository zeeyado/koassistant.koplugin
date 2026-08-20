--- Stream handler module for handling streaming AI responses
--- Based on assistant.koplugin's streaming implementation
--- Uses polling approach to avoid coroutine yield issues on some platforms
local _ = require("koassistant_gettext")
local InputText = require("ui/widget/inputtext")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local Font = require("ui/font")
local Size = require("ui/size")
local Device = require("device")
local Screen = Device.screen
local logger = require("koassistant_logger")
local json = require("json")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local T = require("ffi/util").template
local UIConstants = require("koassistant_ui.constants")
local Constants = require("koassistant_constants")

--- Extract a clean API error message from a raw/partial response buffer.
--- Handles object {"error":{...}} and array [{"error":{...}}] shapes (any provider),
--- with a regex fallback for truncated/multi-chunk bodies. Returns nil if no error.
local function extractApiError(text)
    if not text or text == "" then return nil end
    if not text:find('"error"', 1, true) then return nil end
    local ok, j = pcall(json.decode, text)
    if ok and type(j) == "table" then
        local err = j.error or (type(j[1]) == "table" and j[1].error)
        if type(err) == "table" then
            local msg = err.message or (err.code and ("API error " .. tostring(err.code))) or err.status
            -- A 429 body carries the quota facts (which bucket, what limit, retry delay)
            -- in error.details[] — without them error.message can't tell a per-minute
            -- speed bump from a daily wall. Cold path: inline require keeps this file's
            -- big closures away from the 60-upvalue cap.
            if type(msg) == "string" and msg ~= "" then
                -- Wrap `err` rather than passing `j`: Gemini also answers in the array
                -- shape ([{"error":{...}}]), where the details live under j[1].error.
                local detail = require("model_constraints").formatQuotaDetails({ error = err })
                if detail then return msg .. "\n\n" .. detail end
            end
            return msg
        elseif type(err) == "string" then
            return err
        end
    end
    -- Decode failed (partial body) — fall back to patterns
    local msg = text:match('"message"%s*:%s*"([^"]+)"')
    if msg and msg ~= "" then return msg end
    local code = text:match('"code"%s*:%s*(%d+)')
    if code then return "API error " .. code end
    return nil
end

--- Harvest web-search source URLs/queries from a streaming event into `prov`
--- ({ sources = {}, queries = {}, seen = {} }). Feeds the "Show Sources" viewer;
--- passive — the web_search_used flag logic in the poll loop is unchanged.
--- Everything is type-checked: luajson decodes JSON null to a truthy sentinel.
local function harvestWebSources(event, prov)
    local function addSource(url, title)
        if type(url) ~= "string" or url == "" or prov.seen[url] then return end
        prov.seen[url] = true
        table.insert(prov.sources, {
            url = url,
            title = (type(title) == "string" and title ~= "") and title or nil,
        })
    end
    local function addQuery(q)
        if type(q) ~= "string" or q == "" or prov.seen["q:" .. q] then return end
        prov.seen["q:" .. q] = true
        table.insert(prov.queries, q)
    end

    -- Anthropic: web_search_tool_result blocks arrive complete in content_block_start
    -- (search queries stream as partial input_json deltas and are not captured here)
    if event.type == "content_block_start" and type(event.content_block) == "table"
        and event.content_block.type == "web_search_tool_result"
        and type(event.content_block.content) == "table" then
        for _idx, item in ipairs(event.content_block.content) do
            if type(item) == "table" then
                addSource(item.url, item.title)
            end
        end
    end

    -- Gemini: groundingMetadata carries queries + grounding chunks with web URIs
    local gm = event.candidates and event.candidates[1]
        and event.candidates[1].groundingMetadata
    if type(gm) == "table" then
        if type(gm.webSearchQueries) == "table" then
            for _idx, q in ipairs(gm.webSearchQueries) do
                addQuery(q)
            end
        end
        if type(gm.groundingChunks) == "table" then
            for _idx, chunk in ipairs(gm.groundingChunks) do
                local web = type(chunk) == "table" and type(chunk.web) == "table" and chunk.web
                if web then
                    addSource(web.uri, web.title)
                end
            end
        end
    end

    -- OpenRouter: url_citation annotations ride choices[1].delta.annotations
    local delta = event.choices and event.choices[1] and event.choices[1].delta
    if type(delta) == "table" and type(delta.annotations) == "table" then
        for _idx, annotation in ipairs(delta.annotations) do
            if type(annotation) == "table" and annotation.type == "url_citation"
                and type(annotation.url_citation) == "table" then
                addSource(annotation.url_citation.url, annotation.url_citation.title)
            end
        end
    end

    -- Perplexity: search_results (title+url; preferred over the bare citations array,
    -- which the poll loop captures separately as the legacy footnote source)
    if type(event.search_results) == "table" then
        for _idx, item in ipairs(event.search_results) do
            if type(item) == "table" then
                addSource(item.url, item.title)
            end
        end
    end

    -- Z.AI: web_search results array ({link, title, content, refer, ...}) rides the
    -- FINAL chunk of a streamed response (alongside usage) — harvested once at end
    if type(event.web_search) == "table" then
        for _idx, item in ipairs(event.web_search) do
            if type(item) == "table" then
                addSource(item.link or item.url, item.title)
            end
        end
    end

    -- OpenAI Responses API: url_citation annotations stream as their own events…
    if event.type == "response.output_text.annotation.added"
        and type(event.annotation) == "table"
        and event.annotation.type == "url_citation" then
        addSource(event.annotation.url, event.annotation.title)
    end
    -- …and the terminal event carries the full response object — sweep it for
    -- search queries + any annotations the per-event path missed (addSource/
    -- addQuery dedupe via prov.seen)
    if (event.type == "response.completed" or event.type == "response.incomplete")
        and type(event.response) == "table" and type(event.response.output) == "table" then
        for _idx, item in ipairs(event.response.output) do
            if type(item) == "table" then
                if item.type == "web_search_call" and type(item.action) == "table" then
                    addQuery(item.action.query)
                elseif item.type == "message" and type(item.content) == "table" then
                    for _j, part in ipairs(item.content) do
                        if type(part) == "table" and type(part.annotations) == "table" then
                            for _k, ann in ipairs(part.annotations) do
                                if type(ann) == "table" and ann.type == "url_citation" then
                                    addSource(ann.url, ann.title)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

--- Compact "Found: <domains>" line for the live web-search status (better live output,
--- 2026-07-22): turns harvested sources into a short, deduped domain list so the wait
--- shows what's turning up, not just the query. Google/Vertex redirect blobs are opaque,
--- so those fall back to their title. Display-only; the full source list rides provenance
--- ("Show Sources"). Returns nil until something usable is harvested.
local function webSourcesFoundLine(prov, enable_emoji)
    if not prov or type(prov.sources) ~= "table" or #prov.sources == 0 then return nil end
    local labels, seen = {}, {}
    for _idx, src in ipairs(prov.sources) do
        local label
        local url = src.url
        if type(url) == "string" and not url:find("^https://vertexaisearch%.cloud%.google%.com/") then
            label = url:match("^https?://([^/]+)")
            if label then label = label:gsub("^www%.", "") end
        end
        label = label or src.title  -- redirect blob or no host: use the title instead
        if type(label) == "string" and label ~= "" and not seen[label] then
            seen[label] = true
            table.insert(labels, label)
        end
    end
    if #labels == 0 then return nil end
    local shown = {}
    for i = 1, math.min(#labels, 6) do shown[i] = labels[i] end
    local text = table.concat(shown, ", ")
    if #labels > 6 then
        text = T(_("%1 (+%2 more)"), text, #labels - 6)
    end
    return Constants.getEmojiText("\u{1F517}", T(_("Found: %1"), text), enable_emoji)
end

--- Close the current prose segment when a web search starts (report 3(b) decision,
--- 2026-07-12): substantive prose the model wrote before searching is KEPT behind an
--- inline marker (it is a completed text block the model composed knowing it stays
--- visible — post-search text often references it); only short filler ("Let me
--- search the web.") is dropped. Mirrors the non-streaming Anthropic assembly.
--- Mutates `buffer` (entries from segment_start on are the current segment) and
--- returns the next segment's start index.
local function closeWebSearchSegment(buffer, segment_start)
    local ResponseParser = require("koassistant_api.response_parser")
    local segment = table.concat(buffer, "", segment_start, #buffer)
    local trimmed = segment:gsub("^%s+", ""):gsub("%s+$", "")
    if #trimmed < ResponseParser.WEB_PRESEARCH_FILLER_CHARS then
        -- Filler (or nothing): drop the segment, no marker
        while #buffer >= segment_start do
            table.remove(buffer)
        end
    else
        table.insert(buffer, "\n\n" .. ResponseParser.WEB_SEARCH_MARKER .. "\n\n")
    end
    return #buffer + 1
end

local StreamHandler = {
    interrupt_stream = nil,      -- function to interrupt the stream query
    user_interrupted = false,    -- flag to indicate if the stream was interrupted
}

--- Index of the "}" matching the "{" at `open`, honoring strings and escapes
--- (a brace inside an error message must not close the object).
--- @return number|nil
local function matchBrace(text, open)
    local depth, i, n = 0, open, #text
    local in_string, escaped = false, false
    while i <= n do
        local c = text:sub(i, i)
        if in_string then
            if escaped then escaped = false
            elseif c == "\\" then escaped = true
            elseif c == '"' then in_string = false end
        elseif c == '"' then in_string = true
        elseif c == "{" then depth = depth + 1
        elseif c == "}" then
            depth = depth - 1
            if depth == 0 then return i end
        end
        i = i + 1
    end
    return nil
end

--- Locate a provider error object appended to the END of a stream buffer.
---
--- The old gate was '"error"%s*:%s*{%s*"code"' — `code` first inside the object,
--- which is Gemini's shape and only Gemini's. OpenAI and OpenRouter put `message`
--- first, Anthropic wraps as {"type":"error","error":{"type":...}}, so a mid-stream
--- error from any of those was never detected: the raw error JSON just stayed glued
--- to the end of the answer, unlabelled.
---
--- Matching any '"error": {' would instead truncate answers that merely DISCUSS
--- JSON, so the discriminator is POSITION, not key order: the object must be the
--- last thing in the buffer. A provider error appended mid-stream ends the stream;
--- an error body quoted inside model prose has more prose after it.
--- ("Does the rewrapped tail decode?" was tried first and is NOT a discriminator —
--- KOReader's json decodes a valid prefix and ignores trailing garbage.)
--- @param text string Accumulated stream buffer
--- @return number|nil Byte offset of the `"error"` key, nil if no trailing error
function StreamHandler._findTrailingApiError(text)
    if type(text) ~= "string" or text == "" then return nil end
    local from = 1
    while true do
        local key_pos, brace_pos = text:find('"error"%s*:%s*{', from)
        if not key_pos then return nil end
        local close = matchBrace(text, brace_pos)
        -- Nothing but the enclosing wrapper's own punctuation may follow.
        if close and text:sub(close + 1):match("^[%s%]}]*$")
            and pcall(json.decode, "{" .. text:sub(key_pos, close) .. "}") then
            return key_pos
        end
        from = key_pos + 1
    end
end

-- Exposed for unit testing (the locals above are the canonical implementations).
StreamHandler.extractApiError = extractApiError
StreamHandler.harvestWebSources = harvestWebSources
StreamHandler.closeWebSearchSegment = closeWebSearchSegment

function StreamHandler:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

--- Custom InputText class for showing streaming responses
--- Uses fast e-ink refresh mode and ignores all input events
local StreamText = InputText:extend{}

function StreamText:addChars(chars)
    self.readonly = false                           -- widget is inited with `readonly = true`
    InputText.addChars(self, chars)                 -- can only add text by our method
end

function StreamText:initTextBox(text, char_added)
    self.for_measurement_only = true                -- trick the method from super class
    InputText.initTextBox(self, text, char_added)   -- skips `UIManager:setDirty`
    -- use our own method of refresh, `fast` is suitable for stream responding
    UIManager:setDirty(self.parent, function() return "fast", self.dimen end)
    self.for_measurement_only = false
end

function StreamText:onCloseWidget()
    -- fast mode makes screen dirty, clean it with `flashui`
    UIManager:setDirty(self.parent, function() return "flashui", self.dimen end)
    return InputText.onCloseWidget(self)
end

-- Export StreamText class
StreamHandler.StreamText = StreamText


--- Create a bouncing dot animation for waiting state
function StreamHandler:createWaitingAnimation()
    local frames = { ".", "..", "...", "..", "." }
    local currentIndex = 1

    return {
        getNextFrame = function()
            local frame = frames[currentIndex]
            currentIndex = currentIndex + 1
            if currentIndex > #frames then
                currentIndex = 1
            end
            return frame
        end,
        reset = function()
            currentIndex = 1
        end
    }
end

--- Keep an expanded-mode stream dialog clear of the status bar and aligned with
--- the viewer that replaces it. InputDialog centres itself in a CenterContainer
--- sized to the whole screen and re-derives screen_height in its own init, so
--- the band can only be narrowed afterwards; CenterContainer reads self.dimen at
--- paintTo, so poking it before the show is enough. Standard mode is a no-op.
local function clampDialogToChatRegion(dialog)
    local reserve = UIConstants.FOOTER_RESERVE()
    if reserve <= 0 then return end
    local container = dialog and dialog[1]
    if container and container.dimen then
        container.dimen.h = container.dimen.h - reserve
    end
end

--- Lightweight status dialog for the gather phase of tool workflows: same geometry and
--- look as the streaming dialog, but with externally-pushed text (no subprocess of its
--- own). The tool runner updates it per lookup round, closes it, and the phase-2 streamed
--- request then opens the real stream dialog in the same place.
--- @param opts table: { settings = {large_stream_dialog, response_font_size, enable_emoji_icons},
---                      initial_text = string, on_stop = function, on_skip = function,
---                      on_quick = function,
---                      title = string (optional; defaults to "AI is responding") }
--- on_skip (optional) adds a "Skip lookups" button: stop gathering but continue the
--- request with whatever was collected (vs Stop, which kills the whole request).
--- on_quick (optional) adds a ⚡ button: abandon gathering and resend with quick posture
--- (a plain fast answer, ignoring the book work — vs Skip, which answers with it).
--- @return table handle: { setText = fn(text), close = fn() } (close is idempotent)
function StreamHandler.showToolStatusDialog(opts)
    opts = opts or {}
    local settings = opts.settings or {}

    -- Mirror the stream dialog's sizing (chrome: title bar + 1 button row + padding)
    local chrome_height = Screen:scaleBySize(120)
    local large_dialog = settings.large_stream_dialog ~= false
    local width = UIConstants.CHAT_WIDTH({ compact = not large_dialog })
    local text_height = (large_dialog and UIConstants.CHAT_HEIGHT()
        or UIConstants.COMPACT_DIALOG_HEIGHT()) - chrome_height
    local font_size = settings.response_font_size or 20

    local closed = false
    local dialog
    local function stop()
        if opts.on_stop then opts.on_stop() end
    end
    local button_row = {
        {
            text = _("Stop"),
            id = "close",
            callback = stop,
        },
    }
    if opts.on_skip then
        table.insert(button_row, {
            text = _("Skip lookups"),
            id = "skip_lookups",
            callback = function() opts.on_skip() end,
        })
    end
    -- Quick-answer retry (input safety net S3, gather-⚡): abandon the book gathering and
    -- resend with quick posture. The runner's on_quick cancels the in-flight lookup and
    -- finishes with the sentinel that drives the resend; here we just give the tap
    -- immediate feedback. Only present when the run is quick-eligible.
    if opts.on_quick then
        table.insert(button_row, {
            text = settings.enable_emoji_icons and "\u{26A1}" or _("Quick"),
            id = "quick_retry",
            callback = function()
                UIManager:show(require("ui/widget/infomessage"):new{
                    text = _("Quick answer, resending..."),
                    timeout = 2,
                })
                opts.on_quick()
            end,
        })
    end
    dialog = InputDialog:new{
        title = opts.title or _("AI is responding"),
        inputtext_class = StreamText,
        input_face = Font:getFace("infofont", font_size),
        width = width,
        text_height = text_height,
        is_movable = not large_dialog,
        readonly = true,
        fullscreen = false,
        allow_newline = true,
        add_nav_bar = false,
        cursor_at_end = false,
        add_scroll_buttons = true,
        condensed = true,
        auto_para_direction = true,
        scroll_by_pan = true,
        buttons = { button_row },
    }
    dialog.title_bar.close_callback = stop
    dialog.title_bar:init()
    if large_dialog then clampDialogToChatRegion(dialog) end
    UIManager:show(dialog)

    local handle = {}
    function handle.setText(text)
        if closed then return end
        if dialog and dialog._input_widget then
            dialog._input_widget:setText(text or "", true)
        end
    end
    function handle.close()
        if closed then return end
        closed = true
        UIManager:close(dialog)
    end
    handle.setText(opts.initial_text or "")
    return handle
end

--- Show streaming dialog and process the stream using polling
--- This function returns immediately; use the callback to get results
--- @param backgroundQueryFunc function: The background request function from handler
--- @param provider_name string: Name of the provider (for display)
--- @param model string: Model name (for display)
--- @param settings table: Plugin settings (optional)
--- @param on_complete function: Callback with (success, content, error) when stream completes
function StreamHandler:showStreamDialog(backgroundQueryFunc, provider_name, model, settings, on_complete)
    self.user_interrupted = false
    local streamDialog
    local animation_task = nil
    local poll_task = nil
    local ui_update_task = nil  -- Forward declaration for display throttling
    local first_content_received = false

    -- Stream processing state
    local pid, parent_read_fd = nil, nil
    local partial_data = ""
    local result_buffer = {}
    local reasoning_buffer = {}  -- Capture reasoning content during stream
    local error_body_lines = {}  -- raw unrecognized lines (e.g. a non-200 JSON error body
                                 -- streamed before the PROTOCOL_NON_200 marker on non-macOS);
                                 -- kept OUT of result_buffer so fragments never reach the viewer
    local non200 = false
    local stream_error = nil  -- set by SSE/NDJSON error events; finishStream owns the single error report
    local completed = false
    local in_reasoning_phase = false  -- Track if we're currently showing reasoning
    local in_web_search_phase = false  -- Track if web search tool is executing
    local web_search_status = nil  -- Display-only "Searching the web…" line, rendered as a
                                   -- suffix by scheduleUIUpdate; never enters result_buffer
    local web_found_status = nil   -- Display-only "Found: <domains>" line, refreshed from
                                   -- web_prov.sources as they harvest; cleared with the phase
    local web_query_block_idx = nil  -- Anthropic server_tool_use block streaming the query
    local web_query_parts = nil      -- Accumulated input_json_delta fragments for it
    -- Accumulated search queries this phase (2026-07-22): providers can issue many
    -- searches per question (OpenAI especially, uncapped) -- show them piling up instead
    -- of a single line that flashes and replaces itself. web_current_query is the
    -- in-progress Anthropic query (streams incrementally), committed to web_queries on
    -- content_block_stop; OpenAI queries arrive complete and append directly.
    local web_queries = {}
    local web_current_query = nil
    local function rebuildWebSearchStatus()
        local emoji = settings and settings.enable_emoji_icons
        local lines, seen = {}, {}
        for _idx, q in ipairs(web_queries) do
            if not seen[q] then seen[q] = true; table.insert(lines, "• " .. q) end
        end
        if type(web_current_query) == "string" and web_current_query ~= "" and not seen[web_current_query] then
            table.insert(lines, "• " .. web_current_query)
        end
        if #lines > 0 then
            web_search_status = Constants.getEmojiText("🔍", _("Searching the web:"), emoji)
                .. "\n" .. table.concat(lines, "\n")
        else
            web_search_status = Constants.getEmojiText("🔍", _("Searching the web..."), emoji)
        end
    end
    local web_search_used = false  -- Track if web search was ever used during this stream
    local segment_start_idx = 1  -- First result_buffer index of the current prose segment
    local perplexity_citations = nil  -- Capture Perplexity citations from SSE events
    local web_prov = { sources = {}, queries = {}, seen = {} }  -- Web-search provenance ("Show Sources")
    local was_truncated = false  -- Track if response was truncated (max tokens)
    -- INPUT truncation, the mirror of the above: the server cut the PROMPT to
    -- fit its context window and answered from the remainder. Ollama reports
    -- the prompt tokens it actually evaluated, so this is proof, not a guess.
    local input_truncation = nil

    -- A prompt longer than the server's context window is not refused, it is
    -- trimmed from the front and answered from what is left, which reads exactly
    -- like a complete answer (device 2026-08-20: a recap of a whole book came
    -- back confident and built on a third of it). Ollama's done chunk reports
    -- prompt_eval_count, so compare it with what the request actually carried.
    -- The chars/6 threshold sits well below any real tokenizer ratio (that same
    -- log measured 4.4 chars per token), so only provable cuts are reported.
    local function noteInputTruncation(event)
        local evaluated = tonumber(event and event.prompt_eval_count)
        local chars = tonumber(settings and settings.prompt_chars)
        if not (evaluated and chars) or chars <= 0 then return end
        if evaluated >= chars / 6 then return end
        input_truncation = { evaluated = evaluated, chars = chars }
        -- Teach the handler what this server actually allows, so the NEXT
        -- oversized request is warned about before it is sent instead of after
        -- it has streamed for minutes.
        if (settings and settings.provider_name) == "ollama" then
            local ok, OllamaHandler = pcall(require, "koassistant_api.ollama")
            if ok and OllamaHandler and OllamaHandler.recordObservedContext then
                OllamaHandler.recordObservedContext(model, evaluated)
            end
        end
        logger.warn(string.format(
            "KOAssistant: the server evaluated only %d prompt tokens of ~%d characters sent"
            .. " — the prompt was truncated to fit its context window",
            evaluated, chars))
    end

    -- Said out loud, and left on screen: this is the difference between an
    -- answer the reader can trust and one they cannot, so it does not expire on
    -- a timeout the way a toast does. Unattended work (background X-Ray builds,
    -- hidden streams) logs it and stays quiet.
    local function showInputTruncationNotice()
        if not input_truncation then return end
        if settings and settings.hidden_streaming then return end
        local est_tokens = math.max(1, math.floor(input_truncation.chars / 4.4))
        local pct = math.max(1, math.floor((input_truncation.evaluated / est_tokens) * 100 + 0.5))
        local text
        if (settings and settings.provider_name) == "ollama" then
            text = T(_([[Only part of this request reached the model.

Ollama read about %1% of it (%2 tokens) and answered from that part. The rest, usually the earliest book text, was cut to fit the context window.

To send more, raise Ollama's context window: set OLLAMA_CONTEXT_LENGTH on the server, or add PARAMETER num_ctx to the model. KOAssistant can also size it per request (model menu, "Context window"). A larger window uses more memory on the machine running Ollama.]]),
                tostring(pct), tostring(input_truncation.evaluated))
        else
            text = T(_([[Only part of this request reached the model.

The provider read about %1% of it (%2 tokens) and answered from that part. The rest was cut to fit the model's context window. Try a smaller scope, or a model with a larger context.]]),
                tostring(pct), tostring(input_truncation.evaluated))
        end
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = text })  -- no timeout: tap to dismiss
    end
    local interrupted_detail    -- Provider error that ended the stream early (not a token limit)
    -- Hidden streaming: accumulate data but show placeholder (for quiz etc.)
    local hidden_streaming = settings and settings.hidden_streaming
    -- The placeholder was hardcoded quiz wording, so every other hidden-output
    -- action (X-Ray merges since round 25) announced itself as "Generating
    -- quiz" (device report). Callers name their own work; quiz stays default.
    local hidden_label = (settings and settings.hidden_streaming_label)
        or _("Generating quiz")
    local hidden_note = settings and settings.hidden_streaming_note
    if hidden_note == nil then hidden_note = _("Output hidden to avoid spoilers.") end
    local function hiddenPlaceholder(frame)
        local text = hidden_label .. (frame or "...")
        if hidden_note ~= "" then text = text .. "\n\n" .. hidden_note end
        return text
    end
    local hidden_output_visible = false  -- Toggle: user pressed "Show" to reveal
    local has_streamed_content = false  -- Track if real content (not error text) was extracted
    local usage_data = nil  -- Track token usage from SSE events
    -- State for <think> tag parsing (R1-style models: groq, together, fireworks, sambanova, ollama, perplexity)
    local think_tag_active = false   -- Currently inside <think> block
    local think_tag_checked = false  -- Already determined if response starts with <think>
    local think_tag_partial = ""     -- Buffer for partial tag detection at start

    local chunksize = 1024 * 16
    local buffer = ffi.new('char[?]', chunksize, {0})
    local buffer_ptr = ffi.cast('void*', buffer)
    local PROTOCOL_NON_200 = "X-NON-200-STATUS:"
    -- Poll interval from settings (default 125ms), converted to seconds
    local poll_interval_ms = settings and settings.poll_interval_ms or 125
    local check_interval_sec = poll_interval_ms / 1000

    --- Process streamed content through <think> tag state machine.
    --- R1-style models (groq, together, fireworks, sambanova, ollama, perplexity)
    --- wrap reasoning in <think>...</think> inline in content. This splits
    --- that into separate reasoning and content streams.
    --- @param content string: Raw streamed content chunk
    --- @param reasoning string|nil: Reasoning already extracted by extractContentFromSSE
    --- @return string|nil content, string|nil reasoning
    local function processThinkTags(content, reasoning)
        -- Skip if provider already returned native reasoning (DeepSeek, Anthropic, Gemini, Z.AI)
        if reasoning then return content, reasoning end
        if not content or #content == 0 then return content, nil end

        if not think_tag_checked then
            -- Accumulate start of response to detect <think> prefix
            think_tag_partial = think_tag_partial .. content
            local trimmed = think_tag_partial:gsub("^%s+", "")
            if trimmed:match("^<[Tt]hink>") then
                -- Response starts with <think> — enter thinking mode
                think_tag_active = true
                think_tag_checked = true
                content = trimmed:gsub("^<[Tt]hink>", "")
                think_tag_partial = ""
            elseif #trimmed >= 7 or (trimmed ~= "" and not trimmed:match("^<")) then
                -- Long enough to know it's not <think>, or doesn't start with <
                think_tag_checked = true
                content = think_tag_partial
                think_tag_partial = ""
                return content, nil  -- Normal content
            else
                -- Still accumulating (e.g., just "<" or "<th")
                return nil, nil
            end
        end

        if think_tag_active then
            -- Look for </think> closing tag
            local s, e = content:find("</[Tt]hink>")
            if s then
                think_tag_active = false
                local think_part = content:sub(1, s - 1)
                local content_part = content:sub(e + 1):gsub("^%s*\n?", "")
                return (#content_part > 0 and content_part or nil),
                       (#think_part > 0 and think_part or nil)
            else
                -- All content is reasoning
                return nil, content
            end
        end

        return content, nil
    end

    local function cleanup()
        if animation_task then
            UIManager:unschedule(animation_task)
            animation_task = nil
        end
        if poll_task then
            UIManager:unschedule(poll_task)
            poll_task = nil
        end
        if pid then
            ffiutil.terminateSubProcess(pid)
            -- Schedule cleanup of subprocess
            local collect_and_clean
            collect_and_clean = function()
                if ffiutil.isSubProcessDone(pid) then
                    if parent_read_fd then
                        ffiutil.readAllFromFD(parent_read_fd)
                    end
                    logger.dbg("collected previously dismissed subprocess")
                else
                    if parent_read_fd and ffiutil.getNonBlockingReadSize(parent_read_fd) ~= 0 then
                        ffiutil.readAllFromFD(parent_read_fd)
                        parent_read_fd = nil
                    end
                    UIManager:scheduleIn(5, collect_and_clean)
                    logger.dbg("previously dismissed subprocess not yet collectable")
                end
            end
            UIManager:scheduleIn(5, collect_and_clean)
        end
    end

    -- Reading-position carry: assigned after the autoscroll state exists (locals
    -- below finishStream in file order can't be captured here directly)
    local captureReadPosition

    local function finishStream()
        -- Capture the reader's spot BEFORE the dialog closes: if they paused the
        -- follow and were reading mid-response, the completion viewer lands there.
        -- Captured always, handed over only on the success path below.
        local read_pos_snippet, read_pos_occurrence
        if captureReadPosition then
            read_pos_snippet, read_pos_occurrence = captureReadPosition()
        end
        cleanup()
        -- Clear streaming flag immediately (all exit paths)
        _G.KOAssistantStreaming = nil

        -- Cancel pending UI update if any
        if ui_update_task then
            UIManager:unschedule(ui_update_task)
            ui_update_task = nil
        end
        UIManager:close(streamDialog)

        -- If unrecognized lines were buffered but no error marker fired, this was a
        -- genuine (if unusual) content stream — flush them so nothing is lost.
        if not non200 and #error_body_lines > 0 then
            for _idx = 1, #error_body_lines do
                table.insert(result_buffer, error_body_lines[_idx])
            end
            for _idx = #error_body_lines, 1, -1 do error_body_lines[_idx] = nil end
        end

        local result = table.concat(result_buffer):match("^%s*(.-)%s*$") or "" -- trim
        -- A search with no prose after it leaves a dangling trailing marker
        do
            local marker = require("koassistant_api.response_parser").WEB_SEARCH_MARKER
            if #result >= #marker and result:sub(-#marker) == marker then
                result = result:sub(1, #result - #marker):match("^%s*(.-)%s*$") or ""
            end
        end

        if self.user_interrupted then
            if on_complete then on_complete(false, nil, _("Request cancelled by user.")) end
            return
        end

        if stream_error then
            -- An SSE/NDJSON error event set this; report it once, here, so error branches
            -- don't call on_complete a second time (double-handling / stacked popups).
            if on_complete then on_complete(false, nil, stream_error) end
            return
        end

        if non200 then
            -- Try to parse error from JSON in result
            -- The opening '{' may have been consumed by the NDJSON branch
            -- (it tries json.decode("{") which fails, silently dropping the line),
            -- so try prepending '{' if result doesn't start with it
            local json_candidate = result
            if result:sub(1, 1) ~= '{' then
                json_candidate = '{' .. result
            end

            local endPos = json_candidate:reverse():find("}")
            if endPos and endPos > 0 then
                local ok, j = pcall(json.decode, json_candidate:sub(1, #json_candidate - endPos + 1))
                if ok and type(j) == "table" then
                    -- Type-checked: luajson decodes JSON null to a truthy sentinel.
                    local err = (type(j.error) == "table" and type(j.error.message) == "string"
                            and j.error.message)
                        or (type(j.message) == "string" and j.message)
                        or nil
                    if err and err ~= "" then
                        -- Quota facts (bucket, limit, retry delay) live in error.details[].
                        local detail = require("model_constraints").formatQuotaDetails(j)
                        if detail then err = err .. "\n\n" .. detail end
                        if on_complete then on_complete(false, nil, err) end
                        return
                    end
                end
            end

            -- Pattern match fallback: extract "message" value from raw text
            local msg = result:match('"message"%s*:%s*"([^"]+)"')
            if msg then
                if on_complete then on_complete(false, nil, msg) end
                return
            end

            if on_complete then on_complete(false, nil, result) end
            return
        end

        -- Check for empty result - this can happen if the stream completed
        -- but no content was received (e.g., API returned empty response or error)
        if result == "" then
            -- Log partial_data which might contain error info
            if partial_data and #partial_data > 0 then
                logger.warn("Stream ended with no content but partial_data:", partial_data:sub(1, 500))
                -- Try to extract error from partial data
                if partial_data:sub(1, 1) == "{" then
                    local ok, j = pcall(json.decode, partial_data)
                    if ok and j and j.error then
                        local err_msg = j.error.message or j.error.code or json.encode(j.error)
                        if on_complete then on_complete(false, nil, err_msg) end
                        return
                    end
                end
            end
            -- Reasoning-only completion (#98): the model streamed thinking but the
            -- stream ended before any answer text. Say so instead of dumping the
            -- raw tail — and distinguish the token-exhaustion case (the thinking
            -- consumed the whole max_tokens budget) from an abnormal stream end.
            if #reasoning_buffer > 0 then
                local err
                if was_truncated then
                    err = _("The model spent its entire response limit on reasoning and never started the answer. Try again, or lower the reasoning effort.")
                else
                    err = _("The model produced only reasoning and no answer text. Try again.")
                end
                if on_complete then on_complete(false, nil, err) end
                return
            end
            if partial_data and #partial_data > 0 then
                if on_complete then on_complete(false, nil, _("No response received. Raw: ") .. partial_data:sub(1, 200)) end
                return
            end
            if on_complete then on_complete(false, nil, _("No response received from AI")) end
            return
        end

        -- Detect mid-stream API errors (e.g., Gemini 500 arriving as raw multi-line JSON)
        -- Error text from unrecognized lines may be appended to result_buffer.
        -- Case 1: No real content was streamed — report as failure
        -- Case 2: Real content was streamed then error appended — strip error, mark truncated
        if not has_streamed_content then
            -- Whole response is an API error (e.g. 429 quota, 400) — surface the
            -- real message instead of dumping the raw JSON body ("Error: {").
            local apierr = extractApiError(result) or extractApiError(partial_data)
            if apierr then
                if on_complete then on_complete(false, nil, apierr) end
                return
            end
        else
            -- Provider-shape-agnostic (see _findTrailingApiError): the gate and the
            -- split position are now the SAME match, so an earlier '"error":' that
            -- is not an object can no longer send the split to the wrong offset.
            local error_pos = StreamHandler._findTrailingApiError(result)
            if error_pos then
                -- Content before the error key, minus any dangling brace/bracket
                -- that actually belongs to the error JSON (avoids leaving "{").
                local before = result:sub(1, error_pos - 1):match("^(.-)%s*$") or ""
                if before:match("^[%s{%[]*$") then
                    -- No real content preceded the error — it was a pure error response
                    local apierr = extractApiError(result) or extractApiError(partial_data)
                    if on_complete then on_complete(false, nil, apierr or _("API error")) end
                    return
                end
                -- Real content streamed then error appended — strip the error and
                -- mark the answer as PROVIDER-interrupted, not token-truncated.
                -- Extract before overwriting `result`: the error body lives in the
                -- tail we are about to discard.
                interrupted_detail = extractApiError(result) or extractApiError(partial_data) or true
                result = before
                logger.warn("Mid-stream API error detected after content, treating as interrupted:",
                    type(interrupted_detail) == "string" and interrupted_detail or "no detail")
            end
        end

        -- Append the incomplete-response notice, naming the actual cause
        if interrupted_detail then
            local ResponseParser = require("koassistant_api.response_parser")
            result = result .. ResponseParser.interruptedNotice(
                type(interrupted_detail) == "string" and interrupted_detail or nil)
        elseif was_truncated then
            local ResponseParser = require("koassistant_api.response_parser")
            result = result .. ResponseParser.TRUNCATION_NOTICE
        end

        -- Append Perplexity citation footnotes (captured during streaming)
        if perplexity_citations then
            local ResponseParser = require("koassistant_api.response_parser")
            result = result .. ResponseParser.formatCitations(perplexity_citations)
        end

        -- Debug: Print token usage from accumulated SSE events
        if settings and settings.debug and usage_data then
            local DebugUtils = require("koassistant_debug_utils")
            print(string.format("[%s] Token usage: %s", provider_name or "Stream",
                DebugUtils.formatUsage(usage_data)))
        end

        -- Pass reasoning content as 4th arg, web_search_used as 5th, usage as 6th.
        local reasoning_content = #reasoning_buffer > 0 and table.concat(reasoning_buffer) or nil
        -- Web-search slot: provenance table when source details were captured, else
        -- plain true (legacy shape). Bare Perplexity citation URLs are folded in only
        -- when no titled search_results arrived for the same response.
        local search_used = nil
        if web_search_used then
            if #web_prov.sources == 0 and perplexity_citations then
                for _idx, url in ipairs(perplexity_citations) do
                    if type(url) == "string" and url ~= "" and not web_prov.seen[url] then
                        web_prov.seen[url] = true
                        table.insert(web_prov.sources, { url = url })
                    end
                end
            end
            if #web_prov.sources > 0 or #web_prov.queries > 0 then
                search_used = {
                    web_search = true,
                    sources = #web_prov.sources > 0 and web_prov.sources or nil,
                    queries = #web_prov.queries > 0 and web_prov.queries or nil,
                }
            else
                search_used = true
            end
        end
        -- Reading-position carry hand-over (success only): module slot, consumed
        -- once by the completion viewer's landing (TTL-guarded there — a stream
        -- that completes into a non-chat surface never consumes it).
        if read_pos_snippet then
            StreamHandler.pending_read_position = { snippet = read_pos_snippet,
                occurrence = read_pos_occurrence, ts = os.time() }
            logger.dbg("KOAssistant: stream read-position captured,", #read_pos_snippet,
                "bytes, occurrence:", read_pos_occurrence or 1)
        end
        if on_complete then on_complete(true, result, nil, reasoning_content, search_used, usage_data) end

        showInputTruncationNotice()

        -- Show any pending update popup (deferred during streaming)
        local ok, UpdateChecker = pcall(require, "koassistant_update_checker")
        if ok and UpdateChecker and UpdateChecker.showPendingUpdate then
            UpdateChecker.showPendingUpdate()
        end
    end

    local function _closeStreamDialog()
        self.user_interrupted = true
        finishStream()
    end

    -- Dialog size configuration (uses UIConstants for consistency)
    local width, text_height, is_movable
    local large_dialog = settings and settings.large_stream_dialog ~= false
    if large_dialog then
        -- Large streaming dialog (95% of screen)
        -- Streaming dialog chrome: title bar (~50px), 1 button row (~50px), borders/padding (~20px)
        local chrome_height = Screen:scaleBySize(120)
        width = UIConstants.CHAT_WIDTH()
        text_height = UIConstants.CHAT_HEIGHT() - chrome_height
        is_movable = false
    else
        -- Compact streaming dialog (same size as compact chat view)
        local chrome_height = Screen:scaleBySize(120)
        width = UIConstants.CHAT_WIDTH({ compact = true })
        text_height = UIConstants.COMPACT_DIALOG_HEIGHT() - chrome_height
        is_movable = true
    end

    local font_size = (settings and settings.response_font_size) or 20
    local auto_scroll = settings and settings.stream_auto_scroll ~= false

    -- Auto-scroll state: starts based on setting, can be toggled by user
    local auto_scroll_active = auto_scroll
    local page_scroll = settings and settings.stream_page_scroll ~= false  -- default true
    local page_top_line = 1  -- Top line of current auto-scroll page (page-based mode only)

    -- Display throttling for performance (affects both auto-scroll and manual modes)
    local display_interval_sec = ((settings and settings.display_interval_ms) or 250) / 1000
    local pending_ui_update = false

    -- Apply page-based scroll: advance page if overflowed, pad text to fill page, scroll
    -- Must be called after iw:setText(display, true) so widget dimensions are available.
    -- Uses scrollToBottom() instead of directly setting virtual_line_num, so the
    -- ScrollTextWidget's scroll indicator and position tracking stay in sync.
    -- This works because padding aligns text to the page boundary, making "bottom"
    -- equal to the correct page position.
    local function applyPageScroll(iw, display)
        local stw = iw.text_widget  -- ScrollTextWidget
        local inner = stw and stw.text_widget  -- TextBoxWidget
        if not inner or not inner.lines_per_page or inner.lines_per_page <= 0 then return end
        local lpp = inner.lines_per_page
        local total_lines = #(inner.vertical_string_list or {})

        -- Check if content overflowed current page
        if total_lines > page_top_line + lpp - 1 then
            while total_lines > page_top_line + lpp - 1 do
                page_top_line = page_top_line + lpp
            end
        end

        -- Pad text with empty lines to fill the current page.
        -- This creates the blank space for text to stream into.
        local page_end = page_top_line + lpp - 1
        if total_lines < page_end then
            iw:setText(display .. string.rep("\n", page_end - total_lines), true)
        end

        -- Scroll to current page via scrollToBottom (padding makes bottom = page position).
        -- Goes through InputText → ScrollTextWidget → TextBoxWidget chain,
        -- keeping scroll indicator and position tracking in sync.
        iw:scrollToBottom()
    end

    -- Paused in page mode: keep padding the CURRENT page — no page advance, no
    -- scroll. Without this, the paused tick's unpadded setText re-init hits
    -- TextBoxWidget's no-blank-at-end clamp (scrollViewToCharPos,
    -- max_empty_lines = 0) and yanks the frozen view up by however much of the
    -- page was still blank — "pressing Autoscroll OFF moves you up almost a
    -- whole page" (2026-08-15 device round). The reader's page stays put; text
    -- keeps filling it, and once real content passes the page end the padding
    -- condition stops applying by itself.
    local function holdPageScroll(iw, display, keep_charpos, keep_top)
        local stw = iw.text_widget
        local inner = stw and stw.text_widget
        if not inner or not inner.lines_per_page or inner.lines_per_page <= 0 then return end
        local lpp = inner.lines_per_page
        local total_lines = #(inner.vertical_string_list or {})
        local page_end = page_top_line + lpp - 1
        if total_lines < page_end then
            -- The unpadded setText that just ran clamp-yanked the view AND
            -- initTextBox's trailing resyncPos ("Get back possibly modified
            -- charpos and virtual_line_num") wrote the yanked position back
            -- onto the InputText — restore the reader's pre-tick position
            -- first, or the padded re-init below re-reads the yank and the
            -- freeze fails exactly as before (2026-08-15 second report)
            if keep_top then
                iw.charpos, iw.top_line_num = keep_charpos, keep_top
            end
            iw:setText(display .. string.rep("\n", page_end - total_lines), true)
        end
    end

    -- Reading-position carry (forward-declared above finishStream): when the
    -- reader paused the follow (setting off, button, or by scrolling) and the
    -- stream ends, capture the response text at the TOP of their current view.
    -- The completion viewer lands on that text instead of the reply anchor. A
    -- raw snippet is enough — the viewer extracts a render-safe anchor from it
    -- (this display is raw source text; the viewer may render markdown).
    -- Skipped while following (they're at the tail — the normal landing is
    -- right), before any content, in hidden streams, and during reasoning
    -- (that transcript isn't part of the final answer text).
    local keep_read_position = settings and settings.stream_keep_read_position ~= false
    captureReadPosition = function()
        if not keep_read_position or auto_scroll_active then return nil end
        if not first_content_received or hidden_streaming or in_reasoning_phase then return nil end
        local iw = streamDialog and streamDialog._input_widget
        local stw = iw and iw.text_widget
        local tb = stw and stw.text_widget
        local vsl = tb and tb.vertical_string_list
        local line = vsl and tb.virtual_line_num and vsl[tb.virtual_line_num]
        local charlist = tb and tb.charlist
        if not (line and line.offset and charlist and line.offset <= #charlist) then return nil end
        -- Reader never left the top (autoscroll off, or paused at line 1):
        -- there is no position to keep — the completion viewer opens at the
        -- top anyway, and a carried first-words anchor just breaks the page
        -- under any viewer-only prefix (recon 2b, 2026-08-16)
        if tb.virtual_line_num == 1 then return nil end
        -- offsets are CHAR indices into charlist (page padding sits at the end,
        -- so a real top line always points into content). The snippet starts at
        -- the EXACT top visible line: the completion viewer splits the holding
        -- paragraph at this very text (round 15c), so the landed page starts
        -- with the same words the reader had at the top of their view — a
        -- block-start snap here would cost paragraph-granularity ("misses by
        -- some lines", logged device round).
        local snippet = table.concat(charlist, "", line.offset, math.min(#charlist, line.offset + 320))
        if snippet:match("^%s*$") then return nil end
        -- Occurrence ordinal (2026-08-15): short anchors (Arabic especially)
        -- can repeat inside the reply — count how many times the anchor the
        -- viewer will extract from this snippet already occurred BEFORE the
        -- reader's line, so the completion viewer splits at THEIR occurrence
        -- instead of blindly at the first after the reply marker. Shared
        -- extractor (viewer export) so both sides count the same text.
        local occurrence
        local ok_v, Viewer = pcall(require, "koassistant_chatgptviewer")
        local anchor = ok_v and Viewer.extractCarryAnchor
            and Viewer.extractCarryAnchor(snippet) or nil
        if anchor and line.offset > 1 then
            local prefix = table.concat(charlist, "", 1, line.offset - 1)
            occurrence = 1
            local from = 1
            while true do
                local s = prefix:find(anchor, from, true)
                if not s then break end
                occurrence = occurrence + 1
                from = s + 1
            end
        end
        return snippet, occurrence
    end

    -- Hidden streaming: build placeholder text with animated dots
    local hidden_animation = hidden_streaming and self:createWaitingAnimation()
    local hidden_animation_task = nil
    -- B2 (spoiler_posture_plan): the hidden display is a STABLE header (label +
    -- animated dots + note) with the reasoning transcript below it while reasoning
    -- streams (round 26: reasoning is let through -- it is not the output the
    -- hiding protects). Every writer composes this same shape, so repaints differ
    -- only in the dots frame and newly arrived reasoning -- no more
    -- placeholder/transcript alternation. The dots frame is owned by the 0.4s
    -- animation timer ALONE; chunk-driven repaints reuse the current frame, so
    -- the cadence stays steady no matter how chunks arrive.
    local hidden_frame = "."
    local function hiddenDisplay()
        local text = hiddenPlaceholder(hidden_frame)
        if in_reasoning_phase and #reasoning_buffer > 0 then
            text = text .. "\n\n" .. table.concat(reasoning_buffer)
        end
        return text
    end
    -- Phase-transition blank (reasoning->answer, web->answer, first content):
    -- swaps the visible buffer in normal mode. In hidden mode the header must
    -- never blank -- the wipe showed as a flash until the next throttled repaint.
    local function clearStreamDisplay()
        if hidden_streaming and not hidden_output_visible then return end
        streamDialog._input_widget:setText("", true)
    end
    -- First real content: stop the waiting animation -- except in hidden mode,
    -- where the timer chain keeps running as the placeholder's single frame owner.
    local function stopWaitingAnimation()
        if hidden_streaming then return end
        if animation_task then
            UIManager:unschedule(animation_task)
            animation_task = nil
        end
    end

    -- Throttled UI update function - batches multiple chunks into single display refresh
    local function scheduleUIUpdate()
        if pending_ui_update or completed then return end
        pending_ui_update = true
        ui_update_task = UIManager:scheduleIn(display_interval_sec, function()
            pending_ui_update = false
            ui_update_task = nil
            if not completed and streamDialog and streamDialog._input_widget then
                local iw = streamDialog._input_widget
                local keep_charpos, keep_top
                if not auto_scroll_active then
                    -- Preserve user's manual scroll position
                    iw:resyncPos()
                    -- Capture NOW: the unpadded setText below clamp-yanks the
                    -- view once the page padding vanishes (no-blank-at-end),
                    -- and initTextBox's trailing resyncPos writes the YANKED
                    -- position back onto the InputText — holdPageScroll
                    -- restores from these before re-initing with padding
                    keep_charpos, keep_top = iw.charpos, iw.top_line_num
                end
                local display
                if hidden_streaming and not hidden_output_visible then
                    -- Stable header with the reasoning transcript below it (B2,
                    -- composed in hiddenDisplay); the dots frame is not advanced
                    -- here -- the animation timer owns the cadence.
                    display = hiddenDisplay()
                else
                    -- During a web search, base the display on the answer so far rather
                    -- than the reasoning transcript — a search right after thinking shows
                    -- the clean status line, not reasoning with a status stuck to it
                    display = (in_reasoning_phase and not in_web_search_phase)
                        and table.concat(reasoning_buffer) or table.concat(result_buffer)
                    if in_web_search_phase and web_search_status then
                        -- Keep the search status visible across throttled repaints
                        -- (display-only suffix; result_buffer is never touched). The
                        -- "Found: <domains>" line hangs under the query line.
                        local status_suffix = web_search_status
                        if web_found_status then
                            status_suffix = status_suffix .. "\n" .. web_found_status
                        end
                        display = #display > 0 and (display .. "\n\n" .. status_suffix)
                            or status_suffix
                    end
                end
                iw:setText(display, true)

                if not (hidden_streaming and not hidden_output_visible) then
                    if auto_scroll_active then
                        if page_scroll then
                            applyPageScroll(iw, display)
                        else
                            iw:scrollToBottom()
                        end
                    elseif page_scroll then
                        holdPageScroll(iw, display, keep_charpos, keep_top)
                    end
                end
            end
        end)
    end

    -- Functions to toggle auto-scroll (forward declarations)
    local turnOffAutoScroll, turnOnAutoScroll

    turnOffAutoScroll = function(cause)
        if auto_scroll_active then
            auto_scroll_active = false
            logger.dbg("KOAssistant: stream autoscroll paused —", cause or "toggle")
            -- Update button to show current state (OFF)
            local btn = streamDialog.button_table:getButtonById("scroll_control")
            if btn then
                btn:setText(_("Autoscroll OFF ↓"), btn.width)
                btn.callback = turnOnAutoScroll
                UIManager:setDirty(streamDialog, "ui")
            end
        end
    end

    turnOnAutoScroll = function()
        auto_scroll_active = true
        logger.dbg("KOAssistant: stream autoscroll resumed — toggle")
        local iw = streamDialog._input_widget
        if iw then
            if page_scroll then
                -- Page-based: jump to the last page of content. Compose the
                -- hidden shape when a hidden stream's output is concealed —
                -- painting the raw buffers here flashed the concealed output
                -- (quiz answers) until the next throttled repaint re-hid it.
                local display
                if hidden_streaming and not hidden_output_visible then
                    display = hiddenDisplay()
                else
                    display = in_reasoning_phase and table.concat(reasoning_buffer) or table.concat(result_buffer)
                end
                iw:setText(display, true)
                local stw = iw.text_widget
                local inner = stw and stw.text_widget
                if inner and inner.lines_per_page and inner.lines_per_page > 0 then
                    local total_lines = #(inner.vertical_string_list or {})
                    if total_lines > inner.lines_per_page then
                        local pages = math.ceil(total_lines / inner.lines_per_page)
                        page_top_line = (pages - 1) * inner.lines_per_page + 1
                    else
                        page_top_line = 1
                    end
                else
                    page_top_line = 1
                end
                applyPageScroll(iw, display)
            else
                -- Bottom-scroll: just scroll to bottom
                iw:scrollToBottom()
            end
        end
        -- Update button to show current state (ON)
        local btn = streamDialog.button_table:getButtonById("scroll_control")
        if btn then
            btn:setText(_("Autoscroll ON ↓"), btn.width)
            btn.callback = turnOffAutoScroll
            UIManager:setDirty(streamDialog, "ui")
        end
    end

    -- Build buttons - always include Autoscroll toggle
    local dialog_buttons = {
        {
            {
                text = _("Stop"),
                id = "close",
                callback = _closeStreamDialog,
            },
            {
                -- Button shows current state, click toggles
                text = auto_scroll and _("Autoscroll ON ↓") or _("Autoscroll OFF ↓"),
                id = "scroll_control",
                callback = auto_scroll and turnOffAutoScroll or turnOnAutoScroll,
            },
        }
    }

    -- Quick-answer retry (input safety net S3): abandon this streamed answer and resend
    -- with quick posture (reasoning off / web off / tools off / preset model). Always
    -- present when a retry is possible; the ONLY disable is when the run is ALREADY quick
    -- (nothing to speed up). The resend itself is handled by queryChatGPT, which reads
    -- self.quick_retry_requested off this handler instance when the stream finishes.
    if settings and settings.quick_retry_available then
        table.insert(dialog_buttons[1], {
            text = settings.enable_emoji_icons and "\u{26A1}" or _("Quick"),
            id = "quick_retry",
            enabled = not settings.quick_already_active,
            callback = function()
                self.quick_retry_requested = true
                UIManager:show(require("ui/widget/infomessage"):new{
                    text = _("Quick answer, resending..."),
                    timeout = 2,
                })
                _closeStreamDialog()
            end,
        })
    end

    -- Add Show/Hide toggle for hidden streaming actions (e.g. quiz)
    if hidden_streaming then
        table.insert(dialog_buttons[1], 2, {
            text = _("Show"),
            id = "hidden_toggle",
            callback = function()
                hidden_output_visible = not hidden_output_visible
                local btn = streamDialog.button_table:getButtonById("hidden_toggle")
                if btn then
                    btn:setText(hidden_output_visible and _("Hide") or _("Show"), btn.width)
                    UIManager:setDirty(streamDialog, "ui")
                end
                -- Force immediate display update
                if streamDialog and streamDialog._input_widget then
                    local iw = streamDialog._input_widget
                    local display
                    if hidden_output_visible then
                        display = in_reasoning_phase and table.concat(reasoning_buffer) or table.concat(result_buffer)
                    else
                        display = hiddenDisplay()
                    end
                    iw:setText(display, true)
                    if hidden_output_visible and auto_scroll_active then
                        iw:scrollToBottom()
                    end
                end
            end,
        })
    end

    streamDialog = InputDialog:new{
        title = _("AI is responding"),
        inputtext_class = StreamText,
        input_face = Font:getFace("infofont", font_size),

        -- size parameters
        width = width,
        text_height = text_height,
        is_movable = is_movable,

        -- behavior parameters
        readonly = true,
        fullscreen = false,
        allow_newline = true,
        add_nav_bar = false,
        cursor_at_end = true,
        add_scroll_buttons = true,
        condensed = true,
        auto_para_direction = true,
        scroll_by_pan = true,
        buttons = dialog_buttons,
    }

    -- Add close button to title bar
    streamDialog.title_bar.close_callback = _closeStreamDialog
    streamDialog.title_bar:init()
    if large_dialog then clampDialogToChatRegion(streamDialog) end
    UIManager:show(streamDialog)

    -- Hook into scroll callbacks to auto-pause when user scrolls.
    -- Installed UNCONDITIONALLY (not only when the setting starts ON): the
    -- Autoscroll button can turn following on mid-stream, and without the hooks
    -- that state fought the reader — every repaint yanked the view back to the
    -- tail with no way to pause by scrolling. turnOffAutoScroll no-ops while
    -- following is already off, so the hooks are inert until it matters.
    --
    -- Directional rule: an UPWARD step input (button, key, swipe) while
    -- FOLLOWING pauses in place and is CONSUMED — "stop the page where it is"
    -- (maintainer 2026-08-15); looking back is the NEXT press, which scrolls
    -- normally once following is off. A DOWNWARD scroll pauses only when the
    -- view actually moved: page-down while sitting at the tail moves nothing,
    -- and silently stopping the follow there left the stream stalled exactly
    -- where the reader wanted it. Pan/drag is direct manipulation — it pauses
    -- AND honors the dragged position, never consumed.
    do
        local function innerLineNum(stw)
            local tb = stw and stw.text_widget
            return tb and tb.virtual_line_num
        end

        -- Hook scroll buttons on InputText (the dialog's △/▽ buttons call
        -- ScrollTextWidget:scrollUp/scrollDown directly, not scrollText, so the
        -- inner hooks below never see them).
        local original_scrollUp = streamDialog._input_widget.scrollUp
        streamDialog._input_widget.scrollUp = function(self_widget, ...)
            if auto_scroll_active then
                -- First upward press while following: freeze in place, eat the scroll
                turnOffAutoScroll("scroll-up button")
                return
            end
            return original_scrollUp(self_widget, ...)
        end

        local original_scrollDown = streamDialog._input_widget.scrollDown
        streamDialog._input_widget.scrollDown = function(self_widget, ...)
            local before = innerLineNum(self_widget.text_widget)
            local res = original_scrollDown(self_widget, ...)
            if innerLineNum(self_widget.text_widget) ~= before then
                turnOffAutoScroll("scroll-down button")
            end
            return res
        end

        -- Hook the inner ScrollTextWidget for swipe, device key, and pan scrolling.
        -- Swipes and device keys dispatch directly to the inner widget (bypassing
        -- InputText), calling scrollText(). Pan/drag calls onPanReleaseText().
        -- The inner widget is recreated on every setText(), so we hook initTextBox
        -- to re-apply hooks to each new instance.
        local function hookInnerWidget(input_widget)
            local inner = input_widget.text_widget
            if not inner then return end

            local orig_scrollText = inner.scrollText
            if orig_scrollText then
                inner.scrollText = function(self_w, direction, ...)
                    if direction and direction < 0 then
                        if auto_scroll_active then
                            -- First upward step while following: freeze in place
                            turnOffAutoScroll("swipe/key up")
                            return
                        end
                        return orig_scrollText(self_w, direction, ...)
                    end
                    local before = innerLineNum(self_w)
                    local res = orig_scrollText(self_w, direction, ...)
                    if innerLineNum(self_w) ~= before then
                        turnOffAutoScroll("swipe/key down")
                    end
                    return res
                end
            end

            -- Pan has no direction argument here; movement is the signal (an
            -- upward pan that can't move — already at the top — stays a no-op).
            local orig_onPanRelease = inner.onPanReleaseText
            if orig_onPanRelease then
                inner.onPanReleaseText = function(self_w, ...)
                    local before = innerLineNum(self_w)
                    local res = orig_onPanRelease(self_w, ...)
                    if innerLineNum(self_w) ~= before then
                        turnOffAutoScroll("pan")
                    end
                    return res
                end
            end

            -- Hook onScrollUp to catch page-up key when content fits on one page.
            -- ScrollTextWidget.onScrollUp() only calls scrollText() when virtual_line_num > 1,
            -- so on page 1 the scrollText hook above never fires — and upward
            -- pauses even without movement.
            local orig_onScrollUp = inner.onScrollUp
            if orig_onScrollUp then
                inner.onScrollUp = function(self_w, ...)
                    if auto_scroll_active then
                        -- First upward key while following: freeze in place,
                        -- consume the event (true = handled, no propagation)
                        turnOffAutoScroll("page-up")
                        return true
                    end
                    return orig_onScrollUp(self_w, ...)
                end
            end
        end

        local original_initTextBox = streamDialog._input_widget.initTextBox
        streamDialog._input_widget.initTextBox = function(self_widget, ...)
            original_initTextBox(self_widget, ...)
            hookInnerWidget(self_widget)
        end
        hookInnerWidget(streamDialog._input_widget)
    end

    -- Set up waiting animation
    local animation = self:createWaitingAnimation()
    local function getWaitingText()
        if hidden_streaming and not hidden_output_visible then
            hidden_frame = hidden_animation:getNextFrame()
            return hiddenDisplay()
        end
        return animation:getNextFrame()
    end
    streamDialog._input_widget:setText(getWaitingText(), true)
    local function updateAnimation()
        if completed then return end
        if not first_content_received then
            streamDialog._input_widget:setText(getWaitingText(), true)
            animation_task = UIManager:scheduleIn(0.4, updateAnimation)
        elseif hidden_streaming then
            -- Sole frame owner for the hidden placeholder (B2). Keep ticking even
            -- while the output is revealed (Show pressed) so the dots resume
            -- moving when the user hides it again; only paint when hidden.
            hidden_frame = hidden_animation:getNextFrame()
            if not hidden_output_visible then
                streamDialog._input_widget:setText(hiddenDisplay(), true)
            end
            animation_task = UIManager:scheduleIn(0.4, updateAnimation)
        end
    end
    animation_task = UIManager:scheduleIn(0.4, updateAnimation)

    -- Mark streaming as active (for update checker to defer popups)
    _G.KOAssistantStreaming = true

    -- Start the subprocess
    pid, parent_read_fd = ffiutil.runInSubProcess(backgroundQueryFunc, true)

    if not pid then
        logger.warn("Failed to start background query process.")
        _G.KOAssistantStreaming = nil  -- Clear flag on subprocess failure
        cleanup()
        UIManager:close(streamDialog)
        if on_complete then on_complete(false, nil, _("Failed to start subprocess for request")) end
        return
    end

    -- Polling function to check for data
    local function pollForData()
        if completed or self.user_interrupted then
            return
        end

        local readsize = ffiutil.getNonBlockingReadSize(parent_read_fd)
        if readsize > 0 then
            local bytes_read = tonumber(ffi.C.read(parent_read_fd, buffer_ptr, chunksize))
            if bytes_read < 0 then
                local err = ffi.errno()
                logger.warn("readAllFromFD() error: " .. ffi.string(ffi.C.strerror(err)))
                completed = true
                finishStream()
                return
            elseif bytes_read == 0 then
                completed = true
                finishStream()
                return
            else
                local data_chunk = ffi.string(buffer, bytes_read)
                -- Split lines with a position index over one immutable string:
                -- re-slicing partial_data per line copies the shrinking remainder
                -- every iteration — O(n²) when a 16KB chunk holds many SSE lines.
                -- partial_data gets the unconsumed tail at EVERY exit from this
                -- loop (break + each early return) — finishStream reads it for
                -- error diagnostics.
                local data = partial_data .. data_chunk
                local pos = 1

                -- Process complete lines
                while true do
                    local line_end = data:find("[\r\n]", pos)
                    if not line_end then
                        partial_data = data:sub(pos)
                        break
                    end

                    local line = data:sub(pos, line_end - 1)
                    -- Handle both \r\n and \n line endings
                    pos = line_end + 1
                    if data:sub(line_end, line_end) == "\r" and
                       data:sub(line_end + 1, line_end + 1) == "\n" then
                        pos = line_end + 2  -- Skip both \r and \n
                    end

                    -- Parse SSE data line (handle both "data: " and "data:" formats)
                    local data_prefix_len = nil
                    if line:sub(1, 6) == "data: " then
                        data_prefix_len = 6
                    elseif line:sub(1, 5) == "data:" then
                        data_prefix_len = 5
                    end

                    if data_prefix_len then
                        local json_str = line:sub(data_prefix_len + 1):match("^%s*(.-)%s*$") -- trim
                        if json_str == '[DONE]' then
                            partial_data = data:sub(pos)
                            completed = true
                            finishStream()
                            return
                        end

                        local ok, event = pcall(json.decode, json_str)
                        if ok and event then
                            -- Debug: Log SSE event structure (first few events only)
                            if settings and settings.debug and not first_content_received then
                                local preview = json_str:sub(1, 200)
                                if #json_str > 200 then preview = preview .. "..." end
                                print("SSE event:", preview)
                            end

                            -- Check for error response in SSE data (OpenRouter/OpenAI format)
                            if event.error then
                                local err_message = event.error.message or event.error.type or json.encode(event.error)
                                logger.warn("SSE error event received:", err_message)
                                partial_data = data:sub(pos)
                                completed = true
                                stream_error = err_message  -- finishStream reports it once
                                finishStream()
                                return
                            elseif event.type == "error"
                                    and (type(event.message) == "string" or type(event.code) == "string") then
                                -- OpenAI Responses flat error event ({type:"error", code, message};
                                -- Anthropic's {type:"error", error:{…}} hits the branch above)
                                local err_message = event.message or event.code
                                logger.warn("Responses stream error event:", err_message)
                                partial_data = data:sub(pos)
                                completed = true
                                stream_error = err_message
                                finishStream()
                                return
                            elseif event.type == "response.failed"
                                    and type(event.response) == "table"
                                    and type(event.response.error) == "table" then
                                -- OpenAI Responses terminal failure carrying the response object
                                local rerr = event.response.error
                                local err_message = rerr.message or rerr.code or "Request failed"
                                logger.warn("Responses stream failed:", err_message)
                                partial_data = data:sub(pos)
                                completed = true
                                stream_error = err_message
                                finishStream()
                                return
                            end

                            -- Check for truncation before extracting content
                            if self:checkIfTruncated(event) then
                                was_truncated = true
                            end

                            -- Capture token usage from SSE events (provider-specific)
                            local DebugUtils = require("koassistant_debug_utils")
                            local event_usage = DebugUtils.extractUsage(event)
                            if event_usage then
                                -- Merge: later events may have more complete data
                                usage_data = usage_data or {}
                                if event_usage.input_tokens then usage_data.input_tokens = event_usage.input_tokens end
                                if event_usage.output_tokens then usage_data.output_tokens = event_usage.output_tokens end
                                if event_usage.total_tokens then usage_data.total_tokens = event_usage.total_tokens end
                                -- Round 26: reasoning_tokens was dropped here, so the
                                -- debug line never showed thinking on a streamed request
                                if event_usage.reasoning_tokens then usage_data.reasoning_tokens = event_usage.reasoning_tokens end
                                if event_usage.cache_read then usage_data.cache_read = event_usage.cache_read end
                                if event_usage.cache_creation then usage_data.cache_creation = event_usage.cache_creation end
                            end

                            local content, reasoning = self:extractContentFromSSE(event)

                            -- Process <think> tags from R1-style models
                            content, reasoning = processThinkTags(content, reasoning)

                            -- Check for Gemini groundingMetadata (web search indicator)
                            -- Only set web_search_used if metadata contains actual search results
                            local gm = event.candidates and event.candidates[1] and event.candidates[1].groundingMetadata
                            if gm then
                                -- Check if search was actually performed (not just enabled)
                                if (gm.webSearchQueries and #gm.webSearchQueries > 0) or
                                   (gm.groundingChunks and #gm.groundingChunks > 0) or
                                   (gm.groundingSupports and #gm.groundingSupports > 0) then
                                    web_search_used = true
                                end
                            end

                            -- Capture Perplexity citations (top-level array in SSE events)
                            if event.citations and type(event.citations) == "table" and #event.citations > 0 then
                                perplexity_citations = event.citations
                                web_search_used = true
                            end

                            -- Z.AI: web_search results array on the final chunk
                            if type(event.web_search) == "table" and #event.web_search > 0 then
                                web_search_used = true
                            end

                            -- Capture web-search source details for "Show Sources".
                            -- When a new source lands, refresh the live "Found: <domains>"
                            -- line and repaint so the wait shows what is turning up.
                            local prev_source_count = #web_prov.sources
                            harvestWebSources(event, web_prov)
                            if #web_prov.sources ~= prev_source_count then
                                web_found_status = webSourcesFoundLine(web_prov, settings and settings.enable_emoji_icons)
                                if in_web_search_phase then scheduleUIUpdate() end
                            end

                            -- Anthropic streams the search query as input_json_delta
                            -- fragments on the server_tool_use block: accumulate them and
                            -- upgrade the generic status line to show the live query.
                            -- Display-only; other providers never emit these events.
                            if event.type == "content_block_start" and event.content_block
                                    and event.content_block.type == "server_tool_use"
                                    and event.content_block.name == "web_search" then
                                web_query_block_idx = event.index
                                web_query_parts = {}
                            elseif web_query_block_idx and event.index == web_query_block_idx then
                                if event.type == "content_block_delta" and event.delta
                                        and event.delta.type == "input_json_delta"
                                        and type(event.delta.partial_json) == "string" then
                                    table.insert(web_query_parts, event.delta.partial_json)
                                    -- Tolerant extract: matches once the closing quote of the
                                    -- query value has streamed in; show it as the in-progress
                                    -- query (committed to the accumulated list on block-stop)
                                    local query = table.concat(web_query_parts):match('"query"%s*:%s*"(.-)"%s*[,}]')
                                    if query and #query > 0 then
                                        web_current_query = query
                                        rebuildWebSearchStatus()
                                        if in_web_search_phase then scheduleUIUpdate() end
                                    end
                                elseif event.type == "content_block_stop" then
                                    -- Commit the finished query to the accumulated list
                                    if type(web_current_query) == "string" and web_current_query ~= "" then
                                        table.insert(web_queries, web_current_query)
                                        web_current_query = nil
                                        rebuildWebSearchStatus()
                                    end
                                    web_query_block_idx = nil
                                    web_query_parts = nil
                                end
                            end

                            -- OpenAI Responses: the completed web_search_call item carries
                            -- its query — append it to the accumulated list (display-only)
                            if event.type == "response.output_item.done"
                                    and type(event.item) == "table"
                                    and event.item.type == "web_search_call"
                                    and type(event.item.action) == "table"
                                    and type(event.item.action.query) == "string"
                                    and event.item.action.query ~= "" then
                                table.insert(web_queries, event.item.action.query)
                                rebuildWebSearchStatus()
                                if in_web_search_phase then scheduleUIUpdate() end
                            end

                            -- Handle reasoning content (displayed with header, saved separately)
                            if type(reasoning) == "string" and #reasoning > 0 then
                                table.insert(reasoning_buffer, reasoning)

                                -- Update UI with reasoning
                                if not first_content_received then
                                    first_content_received = true
                                    stopWaitingAnimation()
                                    in_reasoning_phase = true
                                    clearStreamDisplay()
                                    if auto_scroll_active then page_top_line = 1 end
                                end

                                scheduleUIUpdate()
                            end

                            -- Handle regular content
                            if type(content) == "string" and #content > 0 then
                                -- Check for web search marker
                                if content == "__WEB_SEARCH_START__" then
                                    if not in_web_search_phase then
                                        -- Close the current prose segment: substantive
                                        -- pre-search text is kept behind an inline marker,
                                        -- short filler dropped (see closeWebSearchSegment)
                                        segment_start_idx = closeWebSearchSegment(result_buffer, segment_start_idx)
                                    end
                                    in_web_search_phase = true
                                    web_search_used = true
                                    if not first_content_received then
                                        first_content_received = true
                                        stopWaitingAnimation()
                                    end
                                    -- Display-only status, rendered as a suffix by scheduleUIUpdate
                                    -- so throttled repaints keep it visible (never enters
                                    -- result_buffer). Shows the accumulated query list (the
                                    -- provider handlers above append each search); this just
                                    -- ensures the header appears the moment a search starts.
                                    rebuildWebSearchStatus()
                                    scheduleUIUpdate()
                                else
                                    -- If transitioning from web search or reasoning to answer, clear display
                                    if in_web_search_phase then
                                        in_web_search_phase = false
                                        web_search_status = nil
                                        web_found_status = nil
                                        web_queries = {}
                                        web_current_query = nil
                                        clearStreamDisplay()
                                        if auto_scroll_active then page_top_line = 1 end
                                    end
                                    if in_reasoning_phase then
                                        in_reasoning_phase = false
                                        -- Clear the reasoning display and show answer
                                        clearStreamDisplay()
                                        if auto_scroll_active then page_top_line = 1 end
                                    end

                                    table.insert(result_buffer, content)
                                    has_streamed_content = true

                                    -- Update UI
                                    if not first_content_received then
                                        first_content_received = true
                                        stopWaitingAnimation()
                                        clearStreamDisplay()
                                        if auto_scroll_active then page_top_line = 1 end
                                    end

                                    scheduleUIUpdate()
                                end
                            end
                        else
                            logger.warn("Failed to parse JSON from SSE data:", json_str)
                        end
                    elseif line:sub(1, 7) == "event: " then
                        -- Ignore SSE event lines
                    elseif line:sub(1, 1) == ":" then
                        -- SSE comment/keep-alive
                    elseif line:sub(1, 1) == "{" then
                        -- Raw JSON line (NDJSON format - used by Ollama)
                        local ok, event = pcall(json.decode, line)
                        if ok and event then
                            -- Check for truncation
                            if self:checkIfTruncated(event) then
                                was_truncated = true
                            end

                            -- Capture token usage from NDJSON events
                            local DebugUtils = require("koassistant_debug_utils")
                            local event_usage = DebugUtils.extractUsage(event)
                            if event_usage then
                                usage_data = usage_data or {}
                                if event_usage.input_tokens then usage_data.input_tokens = event_usage.input_tokens end
                                if event_usage.output_tokens then usage_data.output_tokens = event_usage.output_tokens end
                                if event_usage.total_tokens then usage_data.total_tokens = event_usage.total_tokens end
                                -- Round 26: reasoning_tokens was dropped here, so the
                                -- debug line never showed thinking on a streamed request
                                if event_usage.reasoning_tokens then usage_data.reasoning_tokens = event_usage.reasoning_tokens end
                                if event_usage.cache_read then usage_data.cache_read = event_usage.cache_read end
                                if event_usage.cache_creation then usage_data.cache_creation = event_usage.cache_creation end
                            end

                            -- Check for error response
                            if event.error then
                                -- Route the NDJSON error to the error path (like the SSE branch);
                                -- appending it to result_buffer would render it as the AI's answer
                                -- and save it to chat history. Ollama's event.error is usually a
                                -- plain string, but tolerate a table form (extract message/type).
                                local err_message = event.error
                                if type(err_message) == "table" then
                                    err_message = err_message.message or err_message.type or json.encode(err_message)
                                end
                                partial_data = data:sub(pos)
                                completed = true
                                stream_error = tostring(err_message)
                                finishStream()
                                return
                            -- Check for Ollama done signal
                            elseif event.done == true then
                                -- done_reason "length" = generation hit num_predict or the
                                -- context window (#98: Gemma-class models can spend the whole
                                -- window thinking — the truncation-aware empty-result message
                                -- needs this flag)
                                if event.done_reason == "length" then
                                    was_truncated = true
                                end
                                noteInputTruncation(event)
                                partial_data = data:sub(pos)
                                completed = true
                                finishStream()
                                return
                            else
                                -- Try to extract streaming content
                                local content, reasoning = self:extractContentFromSSE(event)

                                -- Process <think> tags from R1-style models
                                content, reasoning = processThinkTags(content, reasoning)

                                -- Check for Gemini groundingMetadata (web search indicator)
                                if event.candidates and event.candidates[1] and event.candidates[1].groundingMetadata then
                                    web_search_used = true
                                end

                                -- Handle reasoning content (same logic as SSE handling)
                                if type(reasoning) == "string" and #reasoning > 0 then
                                    table.insert(reasoning_buffer, reasoning)

                                    if not first_content_received then
                                        first_content_received = true
                                        stopWaitingAnimation()
                                        in_reasoning_phase = true
                                        clearStreamDisplay()
                                        if auto_scroll_active then page_top_line = 1 end
                                    end

                                    scheduleUIUpdate()
                                end

                                -- Handle regular content
                                if type(content) == "string" and #content > 0 then
                                    if in_reasoning_phase then
                                        in_reasoning_phase = false
                                        clearStreamDisplay()
                                        if auto_scroll_active then page_top_line = 1 end
                                    end

                                    table.insert(result_buffer, content)
                                    has_streamed_content = true

                                    if not first_content_received then
                                        first_content_received = true
                                        stopWaitingAnimation()
                                        clearStreamDisplay()
                                        if auto_scroll_active then page_top_line = 1 end
                                    end

                                    scheduleUIUpdate()
                                end
                            end
                        else
                            logger.warn("Failed to parse NDJSON line:", line)
                        end
                    elseif line:sub(1, #PROTOCOL_NON_200) == PROTOCOL_NON_200 then
                        non200 = true
                        -- Prefer the clean message from the JSON error body that streamed in
                        -- before the marker (non-macOS path); mirrors the non-streaming consumer
                        -- in koassistant_gpt_query.lua. macOS sends only the marker (no body), so
                        -- error_body_lines is empty and we fall back to the marker text, which is
                        -- already clean ("HTTP <code>: <message>" from BaseHandler.formatNon200).
                        local marker_text = line:sub(#PROTOCOL_NON_200 + 1)
                        local body = table.concat(error_body_lines):match("^%s*(.-)%s*$") or ""
                        local clean = (#body > 0 and extractApiError(body)) or marker_text:match("^%s*(.-)%s*$")
                        if not clean or clean == "" then clean = "Request failed" end
                        -- result_buffer must hold ONLY the clean message. Clear in place
                        -- (closures hold this upvalue by reference).
                        for _idx = #result_buffer, 1, -1 do result_buffer[_idx] = nil end
                        for _idx = #error_body_lines, 1, -1 do error_body_lines[_idx] = nil end
                        table.insert(result_buffer, clean)
                        partial_data = data:sub(pos)
                        completed = true
                        finishStream()
                        return
                    else
                        if #line:match("^%s*(.-)%s*$") > 0 then
                            -- Buffer separately, NOT into result_buffer. On non-macOS a non-200
                            -- JSON error body streams in as "unrecognized" lines before the
                            -- PROTOCOL_NON_200 marker; inserting it into result_buffer dumps
                            -- garbled JSON fragments into the viewer.
                            table.insert(error_body_lines, line)
                            logger.warn("Unrecognized line format:", line)
                        end
                    end
                end
            end
        elseif readsize == 0 then
            -- No data available, check if subprocess is done
            if ffiutil.isSubProcessDone(pid) then
                completed = true
                finishStream()
                return
            end
        else
            -- Error reading
            local err = ffi.errno()
            logger.warn("Error reading from parent_read_fd:", err, ffi.string(ffi.C.strerror(err)))
            completed = true
            finishStream()
            return
        end

        -- Schedule next poll
        poll_task = UIManager:scheduleIn(check_interval_sec, pollForData)
    end

    -- Start polling
    poll_task = UIManager:scheduleIn(check_interval_sec, pollForData)
end

--- Check if an SSE event indicates the response was truncated (max tokens)
--- @param event table: Parsed JSON event
--- @return boolean truncated
function StreamHandler:checkIfTruncated(event)
    -- OpenAI/DeepSeek format: finish_reason = "length"
    local choice = event.choices and event.choices[1]
    if choice and choice.finish_reason == "length" then
        return true
    end

    -- Anthropic format: message_stop event with stop_reason = "max_tokens"
    if event.type == "message_stop" or event.type == "message_delta" then
        if event.delta and event.delta.stop_reason == "max_tokens" then
            return true
        end
    end

    -- OpenAI Responses format: terminal event carries the full response object;
    -- status "incomplete" with reason max_output_tokens = output cap hit
    local resp = event.response
    if type(resp) == "table" and resp.status == "incomplete"
            and type(resp.incomplete_details) == "table"
            and resp.incomplete_details.reason == "max_output_tokens" then
        return true
    end

    -- Gemini format: finishReason = "MAX_TOKENS"
    local gemini_candidate = event.candidates and event.candidates[1]
    if gemini_candidate and gemini_candidate.finishReason == "MAX_TOKENS" then
        return true
    end

    return false
end

--- Extract content from SSE event based on provider format
--- @param event table: Parsed JSON event
--- @return string|nil content, string|nil reasoning_content
--- Returns: (content, nil) for regular content
---          (nil, reasoning) for reasoning-only chunks
---          (content, reasoning) if both present in same event
function StreamHandler:extractContentFromSSE(event)
    -- OpenAI Responses API (/v1/responses): semantic event types; `delta` is a
    -- STRING here (Chat Completions' delta is a table, so the branches below
    -- would silently miss these). Only three event types carry displayable
    -- signal; every other lifecycle event returns nothing.
    local ev_type = event.type
    if type(ev_type) == "string" and ev_type:sub(1, 9) == "response." then
        if ev_type == "response.output_text.delta" then
            if type(event.delta) == "string" and event.delta ~= "" then
                return event.delta, nil
            end
            return nil, nil
        end
        if ev_type == "response.reasoning_summary_text.delta" then
            -- Summaries are not requested in R1/R2; supported for forward-compat
            if type(event.delta) == "string" and event.delta ~= "" then
                return nil, event.delta
            end
            return nil, nil
        end
        if ev_type == "response.output_item.added" and type(event.item) == "table"
                and event.item.type == "web_search_call" then
            return "__WEB_SEARCH_START__", nil
        end
        return nil, nil
    end

    -- OpenAI/DeepSeek/xAI format: choices[0].delta.content
    local choice = event.choices and event.choices[1]
    if choice then
        -- Check for actual stop reasons (not just truthy - JSON null can be truthy in some parsers)
        local finish = choice.finish_reason
        if finish and type(finish) == "string" and finish ~= "" then
            return nil, nil
        end
        local delta = choice.delta
        if type(delta) == "table" then
            -- Check for web search tool calls (OpenAI/xAI)
            -- xAI uses "live_search" type
            if type(delta.tool_calls) == "table" then
                for _idx, tool_call in ipairs(delta.tool_calls) do
                    if tool_call.type == "web_search" or tool_call.type == "live_search" or
                       (tool_call["function"] and (tool_call["function"].name == "web_search" or tool_call["function"].name == "live_search")) then
                        return "__WEB_SEARCH_START__", nil
                    end
                end
            end

            -- Check for OpenRouter web search annotations (url_citation)
            -- OpenRouter uses Exa search via :online suffix, annotations appear in delta
            if type(delta.annotations) == "table" then
                for _idx, annotation in ipairs(delta.annotations) do
                    if annotation.type == "url_citation" then
                        return "__WEB_SEARCH_START__", nil
                    end
                end
            end

            -- DeepSeek/OpenRouter: reasoning_content or reasoning comes alongside regular content
            local reasoning = delta.reasoning_content or delta.reasoning
            local content = delta.content
            -- llama.cpp streams "content": null in its role-priming chunk; luajson
            -- decodes JSON null to a truthy function sentinel (issue #93)
            if type(reasoning) ~= "string" then reasoning = nil end
            if type(content) ~= "string" and type(content) ~= "table" then content = nil end

            -- Handle structured content blocks (Mistral Magistral)
            if type(content) == "table" then
                local text_parts, think_parts = {}, {}
                for _idx, block in ipairs(content) do
                    if type(block) == "table" then
                        if block.type == "thinking" and block.thinking then
                            for _j, t in ipairs(block.thinking) do
                                if t.text then table.insert(think_parts, t.text) end
                            end
                        elseif block.type == "text" and block.text then
                            table.insert(text_parts, block.text)
                        elseif block.text then
                            table.insert(text_parts, block.text)
                        end
                    end
                end
                content = #text_parts > 0 and table.concat(text_parts) or nil
                local think = #think_parts > 0 and table.concat(think_parts) or nil
                if content or think then return content, think end
            end

            if reasoning or content then
                return content, reasoning
            end
        end
    end

    -- Anthropic format: Check for thinking block start (no content yet, just marker)
    if event.type == "content_block_start" and event.content_block then
        if event.content_block.type == "thinking" then
            -- Initial thinking text might be in the block
            local text = event.content_block.thinking
            return nil, text  -- May be nil, that's okay
        end
        -- Web search tool use indicator
        -- Note: Anthropic uses "server_tool_use" for built-in tools like web_search,
        -- and "tool_use" for user-defined tools
        local block_type = event.content_block.type
        if block_type == "tool_use" or block_type == "server_tool_use" then
            if event.content_block.name == "web_search" then
                return "__WEB_SEARCH_START__", nil
            end
        end
    end

    -- Anthropic format: content_block_stop indicates tool finished executing
    if event.type == "content_block_stop" then
        -- This could be end of tool execution; caller tracks state
        -- Return nil, nil - the next content_block_start with type="text" will clear search phase
    end

    -- Anthropic format: delta.text or delta.thinking
    local anthropic_delta = event.delta
    if anthropic_delta then
        if anthropic_delta.thinking then
            -- This is thinking/reasoning content
            return nil, anthropic_delta.thinking
        end
        if anthropic_delta.text then
            return anthropic_delta.text, nil
        end
    end

    -- Anthropic message event: content[0].text or content[0].thinking
    local anthropic_content = event.content and event.content[1]
    if anthropic_content then
        if anthropic_content.type == "thinking" and anthropic_content.thinking then
            return nil, anthropic_content.thinking
        end
        if anthropic_content.text then
            return anthropic_content.text, nil
        end
    end

    -- Gemini format: candidates[0].content.parts[0].text
    -- Parts with thought=true are thinking/reasoning
    local gemini_candidate = event.candidates and event.candidates[1]
    if gemini_candidate then
        local parts = gemini_candidate.content and gemini_candidate.content.parts

        -- Check for Google Search grounding (web search indicator)
        -- Only show search indicator if metadata contains actual search results
        -- and no content in this chunk (to not lose text)
        local gm = gemini_candidate.groundingMetadata
        if gm then
            -- Check if search was actually performed
            local search_used = (gm.webSearchQueries and #gm.webSearchQueries > 0) or
                               (gm.groundingChunks and #gm.groundingChunks > 0) or
                               (gm.groundingSupports and #gm.groundingSupports > 0)
            if search_used then
                local has_content = false
                if parts then
                    for _idx, part in ipairs(parts) do
                        if part.text and part.text ~= "" then
                            has_content = true
                            break
                        end
                    end
                end
                if not has_content then
                    return "__WEB_SEARCH_START__", nil
                end
            end
        end

        if parts then
            local content_text = nil
            local reasoning_text = nil

            for _idx, part in ipairs(parts) do
                if part.text then
                    if part.thought then
                        -- Thinking/reasoning part
                        reasoning_text = (reasoning_text or "") .. part.text
                    else
                        -- Regular content part
                        content_text = (content_text or "") .. part.text
                    end
                end
            end

            if content_text or reasoning_text then
                return content_text, reasoning_text
            end
        end
    end

    -- Ollama format: message.content (NDJSON streaming). Models run with the
    -- native think API deliver reasoning in message.thinking instead of inline
    -- <think> tags — capture it so a thinking-only stream isn't invisible (#98).
    -- Type-checked: luajson decodes JSON null to a truthy sentinel.
    local ollama_message = event.message
    if ollama_message then
        local o_content = ollama_message.content
        if type(o_content) ~= "string" or o_content == "" then o_content = nil end
        local o_thinking = ollama_message.thinking
        if type(o_thinking) ~= "string" or o_thinking == "" then o_thinking = nil end
        if o_content or o_thinking then
            return o_content, o_thinking
        end
    end

    return nil, nil
end

return StreamHandler
