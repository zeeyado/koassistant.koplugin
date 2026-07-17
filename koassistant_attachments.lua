--[[--
Attach chip engine (attach_plan.md v1): staging list helpers, per-type char
budgets with honest truncation notes, and the framed wire message.

Staged entries live MODULE-RESIDENT (dialog lifetime — cleared on fresh dialog
open, survives refresh via the _session_keep_scope marker, same lifetime rules
as the Scope chip). Deliberately NOT on configuration.features like the other
session transients: configuration.features shares identity with the persisted
settings table (main.lua updateConfigFromSettings assigns it by reference), so
any saveSetting("features")+flush while attachments are staged would write up
to ~150KB of private notebook/chat text into settings on disk. A require()'d
module table gives the same shared-state semantics with zero flush exposure.
Entry shape:
  { type = "notebook"|"artifact"|"chat"|"file"|"note",
    label = <UI label for the manage list>,
    text  = <already budget-truncated content>,
    note  = <truncation note string or nil>,
    name/title/filename/book_title = per-type framing fields }

Wire framing is deliberately untranslated (model-facing prose, same convention
as "[Context]" / section labels in message_builder). UI strings are translated.
]]

local _ = require("koassistant_gettext")

local Attachments = {}

-- Per-type char budgets (attach_plan.md §4: notebook/artifact generous, chats
-- tighter). Notes/typed input capped defensively.
Attachments.BUDGETS = {
    notebook = 30000,
    artifact = 30000,
    chat = 15000,
    file = 30000,
    note = 8000,
}

-- UTF-8 safety: don't cut inside a multi-byte sequence. Single bounded
-- backward scan (max 4 bytes — the longest UTF-8 sequence); malformed input
-- passes through unchanged rather than triggering unbounded rescans.
local function utf8TrimTail(s)
    local n = #s
    if n == 0 then return s end
    if s:byte(n) < 0x80 then return s end -- ASCII tail: clean
    local i = n
    while i > 0 and n - i < 4 do
        local b = s:byte(i)
        if b >= 0xC0 then
            -- Found the sequence's lead byte: keep it only if complete
            local need = b >= 0xF0 and 4 or b >= 0xE0 and 3 or 2
            if n - i + 1 >= need then return s end
            return s:sub(1, i - 1)
        elseif b < 0x80 then
            return s -- ASCII followed by stray continuation bytes: malformed, keep
        end
        i = i - 1
    end
    return s -- no lead byte within 4 bytes: malformed, keep
end

local function utf8TrimHead(s)
    -- Drop leading continuation bytes (we may have started mid-sequence)
    local i = 1
    while i <= #s do
        local b = s:byte(i)
        if b < 0x80 or b >= 0xC0 then break end
        i = i + 1
    end
    return s:sub(i)
end

--- Truncate text to a budget. keep = "head" (default) keeps the beginning,
--- "tail" keeps the end (notebook/chat: recent material matters more).
--- total_override: real source size when `text` is itself a partial read
--- (makeFile reads only budget+1 bytes) so the note reports honest numbers.
--- @return string text, string|nil note (wire-facing truncation note)
function Attachments.truncate(text, budget, keep, total_override)
    if type(text) ~= "string" then return "", nil end
    if #text <= budget then return text, nil end
    local total = total_override or #text
    local out, note
    if keep == "tail" then
        out = utf8TrimHead(text:sub(total - budget + 1))
        -- Start at the next line break when one is near, so we don't open mid-line
        local nl = out:find("\n", 1, true)
        if nl and nl < 200 then out = out:sub(nl + 1) end
        note = string.format(
            "[Attachment truncated: showing the most recent %d of %d characters]",
            #out, total)
    else
        out = utf8TrimTail(text:sub(1, budget))
        -- End at the previous line break when one is near, so we don't cut mid-line
        local last_nl = out:match("()\n[^\n]*$")
        if last_nl and (#out - last_nl) < 200 then out = out:sub(1, last_nl - 1) end
        note = string.format(
            "[Attachment truncated: showing the first %d of %d characters]",
            #out, total)
    end
    return out, note
end

-- ---------------------------------------------------------------- staging ---

-- Module-resident staging list (see header for why NOT features-resident).
-- require() caching makes this the same shared state everywhere, matching the
-- shared module-level `configuration` semantics the chips already rely on.
local staged = {}

function Attachments.getList()
    return #staged > 0 and staged or nil
end

function Attachments.count()
    return #staged
end

function Attachments.add(entry)
    if entry then table.insert(staged, entry) end
end

function Attachments.remove(idx)
    table.remove(staged, idx)
end

function Attachments.clear()
    if #staged > 0 then staged = {} end
end

--- Same trusted-provider bypass as the Scope chip / extractor gates.
function Attachments.isTrustedProvider(features, provider)
    if not features or not provider then return false end
    if type(features.trusted_providers) ~= "table" then return false end
    for _idx, tp in ipairs(features.trusted_providers) do
        if tp == provider then return true end
    end
    return false
end

-- --------------------------------------------------------------- builders ---

--- Notebook (this book). Privacy: caller must have checked
--- enable_notebook_sharing == true OR trusted provider (same gate as
--- use_notebook) — this builder only loads and shapes.
function Attachments.makeNotebook(document_path)
    local ok, Notebook = pcall(require, "koassistant_notebook")
    if not ok then return nil, _("Notebook module unavailable.") end
    local content = Notebook.read(document_path)
    if not content or content:gsub("%s", "") == "" then
        return nil, _("No notebook for this book yet.")
    end
    local text, note = Attachments.truncate(content, Attachments.BUDGETS.notebook, "tail")
    return {
        type = "notebook",
        label = _("Notebook (this book)"),
        text = text,
        note = note,
    }
end

--- Quiz artifacts are stored as machine JSON — refuse them honestly instead
--- of attaching garbage. Authoritative identifiers come from ActionCache
--- (ARTIFACT_KEYS entry "quiz", SECTION_PREFIXES.quiz "quiz_section:");
--- literals kept as fallback so the module stays loadable standalone.
function Attachments.isQuizKey(key, section_type)
    local k = tostring(key or "")
    if tostring(section_type or "") == "quiz" or k == "quiz" then return true end
    local quiz_prefix = "quiz_section:"
    local okc, ActionCache = pcall(require, "koassistant_action_cache")
    if okc and ActionCache.SECTION_PREFIXES and ActionCache.SECTION_PREFIXES.quiz then
        quiz_prefix = ActionCache.SECTION_PREFIXES.quiz
    end
    return k:sub(1, #quiz_prefix) == quiz_prefix
end

--- Resolve a cache entry's attachable text. X-Ray JSON is rendered to
--- markdown (same as the viewer) so the model gets prose, not raw JSON.
function Attachments.artifactText(key, data, book_title)
    local result = data and data.result
    if type(result) ~= "string" or result == "" then return nil end
    local k = tostring(key or "")
    local is_xray = k == "_xray_cache" or k:find("_xray_section:", 1, true) == 1
    if is_xray then
        local ok, XrayParser = pcall(require, "koassistant_xray_parser")
        if ok and XrayParser.isJSON(result) then
            local parsed = XrayParser.parse(result)
            if parsed and not parsed.error then
                local progress = data.full_document and "Complete"
                    or (data.progress_decimal
                        and (math.floor(data.progress_decimal * 100 + 0.5) .. "%"))
                    or ""
                local okr, rendered = pcall(XrayParser.renderToMarkdown,
                    parsed, book_title or "", progress)
                if okr and rendered then result = rendered end
            end
        end
    end
    return result
end

--- Saved artifact (per-action cache, doc cache, section entry, AI Wiki).
function Attachments.makeArtifact(name, key, data, book_title, section_type)
    if Attachments.isQuizKey(key, section_type) then
        return nil, _("Quiz artifacts can't be attached (they are stored as quiz data, not text).")
    end
    local content = Attachments.artifactText(key, data, book_title)
    if not content then return nil, _("This artifact has no attachable text.") end
    local display_name = name or _("Artifact")
    local text, note = Attachments.truncate(content, Attachments.BUDGETS.artifact, "head")
    return {
        type = "artifact",
        name = display_name,
        book_title = book_title,
        label = display_name,
        text = text,
        note = note,
    }
end

--- Pinned artifact (user-curated chat response).
function Attachments.makePinned(pin)
    local content = pin and pin.result
    if type(content) ~= "string" or content == "" then
        return nil, _("This artifact has no attachable text.")
    end
    local name = pin.name or pin.action_text or _("Pinned artifact")
    local text, note = Attachments.truncate(content, Attachments.BUDGETS.artifact, "head")
    return {
        type = "artifact",
        name = name,
        book_title = pin.book_title,
        label = name,
        text = text,
        note = note,
    }
end

--- Saved chat: formatted as visible turns only (is_context messages are the
--- plugin's own context dumps — skipping them is what makes chats attachable
--- at a sane size). Tail-kept on truncation: later turns carry the conclusions.
function Attachments.makeChat(chat, doc_title)
    if not chat or type(chat.messages) ~= "table" then
        return nil, _("This chat has no messages.")
    end
    local turns = {}
    for _idx, msg in ipairs(chat.messages) do
        if not msg.is_context and msg.content and msg.content ~= "" then
            local role = msg.role == "assistant" and "Assistant" or "Reader"
            table.insert(turns, role .. ": " .. msg.content)
        end
    end
    if #turns == 0 then return nil, _("This chat has no messages.") end
    local content = table.concat(turns, "\n\n")
    local title = chat.title or _("Untitled chat")
    local text, note = Attachments.truncate(content, Attachments.BUDGETS.chat, "tail")
    return {
        type = "chat",
        title = title,
        book_title = doc_title,
        label = title,
        text = text,
        note = note,
    }
end

--- Text file (.txt/.md). Reads only budget+1 bytes — attaching from a huge
--- file must not stall an e-ink device.
function Attachments.makeFile(path)
    if type(path) ~= "string" or path == "" then return nil, _("No file selected.") end
    local f = io.open(path, "rb")
    if not f then return nil, _("Couldn't read the file.") end
    local total = f:seek("end") or 0
    f:seek("set", 0)
    local budget = Attachments.BUDGETS.file
    local data = f:read(budget + 1) or ""
    f:close()
    if data:gsub("%s", "") == "" then return nil, _("The file is empty.") end
    -- Pass the real file size — truncate() only saw the budget+1-byte window
    local text, note = Attachments.truncate(data, budget, "head",
        total > #data and total or nil)
    local filename = path:match("([^/]+)$") or path
    return {
        type = "file",
        filename = filename,
        label = filename,
        text = text,
        note = note,
    }
end

--- Free-text note (2026-07-17): typed session context. No privacy gate —
--- typing it is the consent.
function Attachments.makeNote(note_text)
    if type(note_text) ~= "string" or note_text:gsub("%s", "") == "" then
        return nil, _("Type a note first.")
    end
    local text, note = Attachments.truncate(note_text, Attachments.BUDGETS.note, "head")
    local label = text:match("[^\n]+") or _("Note")
    if #label > 40 then label = utf8TrimTail(label:sub(1, 40)) .. "…" end
    return {
        type = "note",
        label = label,
        text = text,
        note = note,
    }
end

-- ------------------------------------------------------- previous results ---

--- Action-scoped history stopgap (action_history_plan.md v0.5): build the
--- {previous_results} block for an action from its own recent saved runs.
--- Pure: takes the already-loaded chat list (ChatHistoryManager:getGeneralChats
--- order — newest first) and the action's display text. Matching by display
--- text is safe for CUSTOM actions (their `text` is user-authored, never
--- translated); built-ins get stable IDs with the full feature. Keeps only
--- assistant turns (never earlier context blocks or user questions). Output
--- runs oldest→newest with tail-keep truncation, so the newest run survives.
--- @param chats table array of chat entries, newest first
--- @param action_text string the action's display text (= chat.prompt_action)
--- @param max_runs number how many recent runs to include
--- @return string|nil block text, nil when there are no usable previous runs
function Attachments.buildPreviousResults(chats, action_text, max_runs)
    if type(chats) ~= "table" or type(action_text) ~= "string"
            or action_text == "" then
        return nil
    end
    max_runs = max_runs or 3
    local runs = {}
    for _idx, chat in ipairs(chats) do
        if #runs >= max_runs then break end
        if type(chat) == "table" and chat.prompt_action == action_text
                and type(chat.messages) == "table" then
            local replies = {}
            for _midx, msg in ipairs(chat.messages) do
                if msg.role == "assistant" and not msg.is_context
                        and type(msg.content) == "string" and msg.content ~= "" then
                    table.insert(replies, msg.content)
                end
            end
            if #replies > 0 then
                local header = type(chat.timestamp) == "number"
                    and os.date("Result from %Y-%m-%d:", chat.timestamp)
                    or "Earlier result:"
                table.insert(runs, header .. "\n" .. table.concat(replies, "\n\n"))
            end
        end
    end
    if #runs == 0 then return nil end
    -- Reverse to oldest→newest so tail-keep truncation drops the oldest first
    local ordered = {}
    for i = #runs, 1, -1 do
        table.insert(ordered, runs[i])
    end
    local text, note = Attachments.truncate(
        table.concat(ordered, "\n\n---\n\n"), Attachments.BUDGETS.chat, "tail")
    if note then
        text = "[Older results truncated]\n" .. text
    end
    return text
end

-- ------------------------------------------------------------------- wire ---

local function frameHeader(entry)
    if entry.type == "notebook" then
        return "[Attached: the reader's own notebook for this book]"
    elseif entry.type == "artifact" then
        local h = string.format('[Attached: a saved AI artifact — "%s"', entry.name or "Artifact")
        if entry.book_title and entry.book_title ~= "" then
            h = h .. string.format(' (about "%s")', entry.book_title)
        end
        return h .. "]"
    elseif entry.type == "chat" then
        local h = string.format(
            '[Attached: an earlier conversation between the reader and the assistant — "%s"',
            entry.title or "Untitled")
        if entry.book_title and entry.book_title ~= "" then
            h = h .. string.format(' (about "%s")', entry.book_title)
        end
        return h .. "]"
    elseif entry.type == "file" then
        return string.format("[Attached file: %s]", entry.filename or "file")
    end
    return "[Note from the reader]"
end

--- Build the is_context wire message from a staged list. One framed section
--- per attachment (attach_plan.md §4). Returns nil when there is nothing.
function Attachments.buildMessage(list)
    if type(list) ~= "table" or #list == 0 then return nil end
    local sections = {}
    for _idx, entry in ipairs(list) do
        local parts = { frameHeader(entry), entry.text }
        if entry.note then table.insert(parts, entry.note) end
        table.insert(sections, table.concat(parts, "\n"))
    end
    return table.concat(sections, "\n\n")
end

return Attachments
