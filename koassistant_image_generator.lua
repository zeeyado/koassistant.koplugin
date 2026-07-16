--[[--
KOAssistant Image Generator

Generates an image from a text description using the currently configured
AI provider's image-generation endpoint and displays the result in
KOReader's full-screen ImageViewer.

Currently supported providers and their image-generation endpoints:
  • openai     → https://api.openai.com/v1/images/generations   (gpt-image family)
  • xai        → https://api.x.ai/v1/images/generations         (grok-imagine-image)
  • gemini     → generateContent with IMAGE modality             (gemini-*-image)

Model inventory lives in koassistant_model_lists.lua (`_image_models`);
this file holds only wire/endpoint facts. Generated images are kept in
data_dir/koassistant_images (filename = date + prompt snippet); the
Generated Images browser (koassistant_image_browser.lua) manages them.

Public API:
  ImageGenerator.generate(word, configuration, settings)
      `word` = selected text / description; `configuration` = global config
      table (resolved by updateConfigFromSettings); `settings` = LuaSettings
      instance (for GUI-entered API keys).
  ImageGenerator.effectiveProvider(features, main_provider, settings)
      → provider|nil, reason — the button-visibility / dispatch gate.
  ImageGenerator.getImagesDir()
]]

local json   = require("json")
local ffi    = require("ffi")
local ffiutil = require("ffi/util")
local https   = require("ssl.https")
local ltn12   = require("ltn12")
local logger = require("logger")
local mime   = require("mime")
local BaseHandler = require("koassistant_api.base")
local ModelLists = require("koassistant_model_lists")
local _ = require("koassistant_gettext")
local T = ffiutil.template

local ImageGenerator = {}

-- ---------------------------------------------------------------------------
-- Provider image-generation endpoint table
-- ---------------------------------------------------------------------------

--[[
 Provider entries (wire/endpoint facts ONLY — model inventory lives in
 koassistant_model_lists.lua `_image_models`, first entry = default):
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
}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Resolve the API key for the active provider.
--- Mirrors the priority used in koassistant_gpt_query.lua:
---   1. GUI-entered keys (features.api_keys[provider])
---   2. apikeys.lua file
local function resolveApiKey(provider, settings)
    -- GUI-entered key (highest priority)
    if settings then
        local features = settings:readSetting("features") or {}
        local gui_keys = features.api_keys or {}
        if gui_keys[provider] and gui_keys[provider] ~= "" then
            return gui_keys[provider]:match("^%s*(.-)%s*$")
        end
    end
    -- apikeys.lua fallback
    local ok, apikeys = pcall(function() return require("apikeys") end)
    if ok and apikeys and apikeys[provider] and apikeys[provider] ~= "" then
        local k = apikeys[provider]:match("^%s*(.-)%s*$")
        local upper = k:upper()
        local is_placeholder = upper:find("YOUR_", 1, true)
            or upper:find("_HERE", 1, true)
            or upper:find("API_KEY", 1, true)
        if not is_placeholder then
            return k
        end
    end
    return nil
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

--- Resolve the image model: explicit per-provider setting > list default.
local function resolveImageModel(provider, features)
    local m = features and features["image_gen_model_" .. provider]
    if type(m) == "string" and m ~= "" and m ~= "default" then
        return m
    end
    return ModelLists.getDefaultImageModel(provider)
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

--- Filesystem-safe fragment from the prompt (FAT-safe: device storage).
local function sanitizeForFilename(s)
    s = s:gsub("[%c/\\:*?\"<>|%.]", " "):gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
    if #s > 40 then
        -- Byte-truncate, then drop a possibly split trailing UTF-8 sequence
        s = require("util").fixUtf8(s:sub(1, 40), ""):match("^%s*(.-)%s*$") or ""
    end
    return s
end

--- Show the generated image in KOReader's ImageViewer.
--- `image_data` is the raw PNG/JPEG binary string. Images are KEPT
--- (maintainer decision 2026-07-16): the filename carries the metadata
--- (date + prompt snippet) and the Generated Images browser handles deletion.
local function showImage(image_data, description, on_close)
    local UIManager  = require("ui/uimanager")
    local lfs = require("libs/libkoreader-lfs")

    local dir = ImageGenerator.getImagesDir()
    if not lfs.attributes(dir, "mode") then
        lfs.mkdir(dir)
    end
    local snippet = description and sanitizeForFilename(description) or ""
    if snippet == "" then snippet = "image" end
    local base = string.format("%s/%s %s", dir, os.date("%Y-%m-%d %H.%M.%S"), snippet)
    local path = base .. ".png"
    local n = 1
    while lfs.attributes(path, "mode") do
        n = n + 1
        path = string.format("%s (%d).png", base, n)
    end
    local f = io.open(path, "wb")
    if not f then
        showNotice(_("Failed to save generated image to disk."))
        return
    end
    f:write(image_data)
    f:close()

    -- Try to load KOReader's ImageViewer
    local ok, ImageViewer = pcall(require, "ui/widget/imageviewer")
    if not ok then
        -- Older KOReader builds may not have ImageViewer — offer a save notice
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

    local viewer = ImageViewer:new{
        file = path,
        with_title_bar = true,
        title_text = title_text,
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
-- Background subprocess: make the HTTPS POST, stream result to pipe
-- ---------------------------------------------------------------------------

--- Write the whole buffer to a pipe fd. ffiutil.writeToFD is a single
--- unlooped write(2), and pipe writes larger than the pipe buffer may
--- return short — multi-MB image responses arrived truncated on device
--- (json parse failures). Loops until done, retrying on EINTR.
local function writeAllToFD(fd, data)
    local ptr = ffi.cast("const char*", data)
    local total = #data
    local written = 0
    while written < total do
        local n = tonumber(ffi.C.write(fd, ptr + written, total - written))
        if not n or n < 0 then
            if ffi.errno() == 4 then -- EINTR: interrupted, nothing written; retry
                n = 0
            else
                return false
            end
        end
        written = written + n
    end
    return true
end

--- Build and return a background function suitable for ffiutil.runInSubProcess.
--- The subprocess writes either:
---   "OK:<base64-json>" (the full response body) on success, or
---   "ERR:<message>"   on failure.
--- We write the raw JSON body; the parent decodes it.
--- @param endpoint table: IMAGE_ENDPOINTS entry (used for key_header and is_gemini flag)
local function makeBackgroundFn(url, api_key, request_body_str, endpoint)
    -- Pre-resolve DNS in parent (needed on macOS after fork)
    local resolved_ip = BaseHandler.resolveForSubprocess(url)

    -- Build auth header value
    local auth_header_name  = (endpoint and endpoint.key_header) or "Authorization"
    local auth_header_value = (auth_header_name == "Authorization")
        and ("Bearer " .. api_key)
        or api_key

    local headers = {
        ["Content-Type"]         = "application/json",
        [auth_header_name]       = auth_header_value,
        ["Content-Length"]       = tostring(#request_body_str),
    }

    return function(pid, child_write_fd)
        if not pid or not child_write_fd then return end

        local ok, err = pcall(function()
            local is_https = url:sub(1, 8) == "https://"
            if is_https and ffi.os == "OSX" then
                -- macOS: bypass getaddrinfo via raw SSL
                local host = url:match("https://([^/:]+)")
                local port = tonumber(url:match("https://[^/:]+:(%d+)")) or 443
                local path = url:match("https://[^/]+(.*)") or "/"

                local ssl_sock = BaseHandler.connectSSLInSubprocess(resolved_ip, host, port, 120)

                local req_lines = {
                    string.format("POST %s HTTP/1.1", path),
                    string.format("Host: %s", host),
                    "Content-Type: application/json",
                    string.format("%s: %s", auth_header_name, auth_header_value),
                    string.format("Content-Length: %d", #request_body_str),
                    "Connection: close",
                    "", "",
                }
                ssl_sock:send(table.concat(req_lines, "\r\n"))
                ssl_sock:send(request_body_str)

                -- Read status + headers
                local status_line = ssl_sock:receive("*l")
                local status_code = status_line and tonumber(status_line:match("HTTP/%S+%s+(%d+)"))
                local is_chunked = false
                while true do
                    local line = ssl_sock:receive("*l")
                    if not line or line == "" then break end
                    if line:lower():match("^transfer%-encoding:%s*chunked") then
                        is_chunked = true
                    end
                end

                -- Read body
                local chunks = {}
                if is_chunked then
                    while true do
                        local sz_line = ssl_sock:receive("*l")
                        if not sz_line then break end
                        local csz = tonumber(sz_line:match("^%s*(%x+)"), 16)
                        if not csz or csz == 0 then break end
                        local chunk = ssl_sock:receive(csz)
                        if chunk then table.insert(chunks, chunk) end
                        ssl_sock:receive("*l")
                    end
                else
                    while true do
                        local chunk, eof, partial = ssl_sock:receive(8192)
                        if chunk then table.insert(chunks, chunk)
                        elseif partial and #partial > 0 then table.insert(chunks, partial) end
                        if eof then break end
                    end
                end
                ssl_sock:close()
                local body = table.concat(chunks)

                if status_code ~= 200 then
                    writeAllToFD(child_write_fd, "ERR:HTTP " .. tostring(status_code) .. ": " .. body:sub(1, 200))
                else
                    writeAllToFD(child_write_fd, "OK:" .. body)
                end
            else
                -- Standard path
                local su_ok, socketutil = pcall(require, "socketutil")
                if su_ok and socketutil then
                    socketutil:set_timeout(120, -1)
                else
                    https.TIMEOUT = 120
                end

                local response_body = {}
                local _, code, _, status = https.request{
                    url     = url,
                    method  = "POST",
                    headers = headers,
                    source  = ltn12.source.string(request_body_str),
                    sink    = ltn12.sink.table(response_body),
                }
                local body = table.concat(response_body)
                local numeric_code = tonumber(code) or 0
                if numeric_code ~= 200 then
                    writeAllToFD(child_write_fd,
                        "ERR:HTTP " .. tostring(code) .. " " .. tostring(status) .. ": " .. body:sub(1, 200))
                else
                    writeAllToFD(child_write_fd, "OK:" .. body)
                end
            end
        end)

        if not ok then
            writeAllToFD(child_write_fd, "ERR:Subprocess error: " .. tostring(err))
        end

        ffi.C.close(child_write_fd)
        pcall(function() ffi.C._exit(0) end)
    end
end

-- ---------------------------------------------------------------------------
-- Download image bytes from URL (used for b64 + url response formats)
-- ---------------------------------------------------------------------------

--- Fetch binary content from a URL in a subprocess.
--- Returns a background function whose pipe carries "OK:<binary>" or "ERR:<msg>".
local function makeDownloadFn(image_url)
    local resolved_ip = BaseHandler.resolveForSubprocess(image_url)

    return function(pid, child_write_fd)
        if not pid or not child_write_fd then return end
        local ok, err = pcall(function()
            local is_https = image_url:sub(1, 8) == "https://"
            if is_https and ffi.os == "OSX" then
                local host = image_url:match("https://([^/:]+)")
                local port = tonumber(image_url:match("https://[^/:]+:(%d+)")) or 443
                local path = image_url:match("https://[^/]+(.*)") or "/"
                local ssl_sock = BaseHandler.connectSSLInSubprocess(resolved_ip, host, port, 60)
                local req_lines = {
                    string.format("GET %s HTTP/1.1", path),
                    string.format("Host: %s", host),
                    "Connection: close",
                    "", "",
                }
                ssl_sock:send(table.concat(req_lines, "\r\n"))
                local status_line = ssl_sock:receive("*l")
                local status_code = status_line and tonumber(status_line:match("HTTP/%S+%s+(%d+)"))
                local is_chunked = false
                while true do
                    local line = ssl_sock:receive("*l")
                    if not line or line == "" then break end
                    if line:lower():match("^transfer%-encoding:%s*chunked") then is_chunked = true end
                end
                local chunks = {}
                if is_chunked then
                    while true do
                        local sz_line = ssl_sock:receive("*l")
                        if not sz_line then break end
                        local csz = tonumber(sz_line:match("^%s*(%x+)"), 16)
                        if not csz or csz == 0 then break end
                        local chunk = ssl_sock:receive(csz)
                        if chunk then table.insert(chunks, chunk) end
                        ssl_sock:receive("*l")
                    end
                else
                    while true do
                        local chunk, eof, partial = ssl_sock:receive(8192)
                        if chunk then table.insert(chunks, chunk)
                        elseif partial and #partial > 0 then table.insert(chunks, partial) end
                        if eof then break end
                    end
                end
                ssl_sock:close()
                if status_code ~= 200 then
                    writeAllToFD(child_write_fd, "ERR:HTTP " .. tostring(status_code))
                else
                    -- prefix + binary body
                    writeAllToFD(child_write_fd, "OK:")
                    local body = table.concat(chunks)
                    writeAllToFD(child_write_fd, body)
                end
            else
                local chunks_t = {}
                local _, code = https.request{
                    url  = image_url,
                    sink = ltn12.sink.table(chunks_t),
                }
                if tonumber(code) ~= 200 then
                    writeAllToFD(child_write_fd, "ERR:HTTP " .. tostring(code))
                else
                    writeAllToFD(child_write_fd, "OK:")
                    writeAllToFD(child_write_fd, table.concat(chunks_t))
                end
            end
        end)
        if not ok then
            writeAllToFD(child_write_fd, "ERR:Download subprocess error: " .. tostring(err))
        end
        ffi.C.close(child_write_fd)
        pcall(function() ffi.C._exit(0) end)
    end
end

-- ---------------------------------------------------------------------------
-- Poll helper: read subprocess pipe until EOF, then reap the child
-- ---------------------------------------------------------------------------

--- Non-blocking polling via ffiutil.getNonBlockingReadSize (portable — raw
--- O_NONBLOCK constants differ between Linux and macOS).
local function pollSubprocess(pid, parent_read_fd, on_done)
    local UIManager = require("ui/uimanager")
    local chunksize = 1024 * 64
    local buf = ffi.new("char[?]", chunksize)
    local buf_ptr = ffi.cast("void*", buf)
    local response_parts = {}
    local poll_task

    local function finish()
        ffi.C.close(parent_read_fd)
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
                UIManager:scheduleIn(0.15, poll_task)
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
function ImageGenerator.generate(word, config_table, settings)
    local ok, err = pcall(function()
        ImageGenerator._generateImpl(word, config_table, settings)
    end)
    if not ok then
        logger.err("KOAssistant: image generation error:", err)
        showNotice(T(_("Image generation error:\n\n%1"), tostring(err)))
    end
end

--- Internal implementation — called via pcall from generate() for error catching.
function ImageGenerator._generateImpl(word, config_table, settings)
    local UIManager = require("ui/uimanager")

    -- Effective provider (maintainer decision 2026-07-16): explicit
    -- image_gen_provider > image-capable main provider; never fall back to a
    -- merely-keyed provider. Model: per-provider setting > list default.
    local features = (config_table and config_table.features) or {}
    local provider, unavailable = ImageGenerator.effectiveProvider(
        features, config_table and config_table.provider, settings)
    if not provider then
        if unavailable == "no_key" then
            showNotice(_("No API key found for the image generation provider.\n\nPlease add your key in KOAssistant settings."))
        else
            showNotice(_("Image generation is not available for the current provider.\n\nSupported: OpenAI, xAI (Grok), Gemini. You can also pick a dedicated image provider in KOAssistant settings (Advanced)."))
        end
        return
    end
    local endpoint = IMAGE_ENDPOINTS[provider]
    local api_key = resolveApiKey(provider, settings)
    local resolved_model = resolveImageModel(provider, features)

    -- Trim and validate description
    local description = word:match("^%s*(.-)%s*$")
    if description == "" then
        showNotice(_("No description selected."))
        return
    end

    -- Build request JSON (provider-specific format)
    local request_body_str
    if endpoint.is_gemini then
        -- Gemini generateContent request with image output modality
        local request_body = {
            contents = {
                {
                    role  = "user",
                    parts = {{ text = description }},
                }
            },
            generationConfig = {
                responseModalities = { "IMAGE", "TEXT" },
            },
        }
        request_body_str = json.encode(request_body)
    else
        -- OpenAI-style images/generations request. Parameter support diverges
        -- (verified live 2026-07-16): OpenAI's gpt-image models reject
        -- response_format (b64_json is their default output); xAI rejects
        -- size/quality/style but honors response_format.
        local request_body = {
            model  = resolved_model,
            prompt = description,
            n      = 1,
        }
        if provider == "openai" then
            -- "default"/nil = omit the param and let the API decide
            local size = str(features.image_gen_size)
            if size and size ~= "default" then request_body.size = size end
            local quality = str(features.image_gen_quality)
            if quality and quality ~= "default" then request_body.quality = quality end
        else
            request_body.response_format = "b64_json"
            if provider == "xai" then
                local aspect = str(features.image_gen_aspect)
                if aspect and aspect ~= "default" then request_body.aspect_ratio = aspect end
            end
        end
        request_body_str = json.encode(request_body)
    end

    -- Progress window: the tool-status dialog (setText handle + Stop button)
    -- avoids InfoMessage's fire-dismiss_callback-on-any-close trap and gives
    -- the user elapsed-time feedback during the long blocking POST
    local StreamHandler = require("stream_handler")
    local cancelled = false
    local active_pid  -- reassigned per fork; Stop kills whichever is live
    local start_ts = os.time()
    local provider_label = string.upper(provider:sub(1,1)) .. provider:sub(2)
    local phase_text = T(_("Generating image with %1 / %2…"), provider_label, resolved_model)
    local status, tick
    local ticking = false
    local function statusText()
        return phase_text .. "\n\n" .. T(_("Elapsed: %1 s"), os.time() - start_ts)
    end
    local function stopTicker()
        if ticking then
            UIManager:unschedule(tick)
            ticking = false
        end
    end
    tick = function()
        if not ticking then return end
        status.setText(statusText())
        UIManager:scheduleIn(5, tick)
    end
    local function cancelRequest()
        cancelled = true
        stopTicker()
        if active_pid then
            ffiutil.terminateSubProcess(active_pid)
        end
        if status then status.close() end
    end
    local function openStatus(text)
        if status then status.close() end
        phase_text = text
        status = StreamHandler.showToolStatusDialog({
            settings = { large_stream_dialog = false, response_font_size = features.response_font_size },
            title = _("Generating image"),
            initial_text = statusText(),
            on_stop = cancelRequest,
        })
        ticking = true
        UIManager:scheduleIn(5, tick)
    end
    openStatus(phase_text)

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

    -- Build the actual request URL (Gemini interpolates the model into the path)
    local request_url = endpoint.url
    if endpoint.is_gemini then
        request_url = endpoint.url .. "/" .. resolved_model .. ":generateContent"
    end

    -- Launch subprocess
    logger.info("KOAssistant: image gen request:", provider, resolved_model)
    local bg_fn = makeBackgroundFn(request_url, api_key, request_body_str, endpoint)
    local pid, parent_read_fd = ffiutil.runInSubProcess(bg_fn, true)

    if not pid then
        stopTicker()
        status.close()
        showNotice(_("Failed to start image generation subprocess."))
        return
    end
    active_pid = pid

    -- Close the status window and report an error
    local function fail(msg)
        stopTicker()
        status.close()
        showNotice(msg)
    end

    -- Poll for result
    pollSubprocess(pid, parent_read_fd, guarded(function(raw)
        stopTicker()
        logger.info("KOAssistant: image gen result:", raw and #raw or 0, "bytes; head:", raw and raw:sub(1, 120) or "<empty>")
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

        -- Strip "OK:" prefix
        local body = raw:sub(4)

        -- Parse JSON response
        local ok_parse, resp = pcall(json.decode, body)
        if not ok_parse or type(resp) ~= "table" then
            fail(_("Failed to parse image generation response."))
            return
        end

        -- API-level error ({ error = {...} } or { error = "..." }); type-checked
        -- so a JSON null (truthy sentinel) doesn't trip this on a success response
        if type(resp.error) == "table" or type(resp.error) == "string" then
            local err_msg = str(resp.error)
                or (type(resp.error) == "table" and str(resp.error.message))
                or _("Unknown API error")
            fail(T(_("Image generation API error:\n\n%1"), err_msg))
            return
        end

        -- Gemini returns images as inlineData parts inside candidates[].content.parts
        if endpoint.is_gemini then
            local candidates = type(resp.candidates) == "table" and resp.candidates or nil
            local first = candidates and type(candidates[1]) == "table" and candidates[1] or nil
            local content = first and type(first.content) == "table" and first.content or nil
            local parts = content and type(content.parts) == "table" and content.parts or nil
            if not parts then
                fail(_("No image data in Gemini response."))
                return
            end
            -- Find the first IMAGE part (mimeType starts with "image/")
            for _idx, part in ipairs(parts) do
                if type(part) == "table" and type(part.inlineData) == "table" then
                    local mime_type = str(part.inlineData.mimeType)
                    local data_b64 = str(part.inlineData.data)
                    if mime_type and mime_type:sub(1, 6) == "image/" and data_b64 then
                        local image_bytes = mime.unb64(data_b64)
                        if not image_bytes or image_bytes == "" then
                            fail(_("Failed to decode image data."))
                            return
                        end
                        status.close()
                        showImage(image_bytes, description)
                        return
                    end
                end
            end
            fail(_("No image part found in Gemini response."))
            return
        end

        -- OpenAI-style response: data[1].b64_json or data[1].url
        local data_list = type(resp.data) == "table" and resp.data or nil
        local image_data_entry = data_list and type(data_list[1]) == "table" and data_list[1] or nil
        if not image_data_entry then
            fail(_("No image data in response."))
            return
        end

        -- b64_json response (preferred)
        local b64 = str(image_data_entry.b64_json)
        if b64 and b64 ~= "" then
            local image_bytes = mime.unb64(b64)
            if not image_bytes or image_bytes == "" then
                fail(_("Failed to decode image data."))
                return
            end
            status.close()
            showImage(image_bytes, description)
            return
        end

        -- url response fallback: download the image
        local image_url = str(image_data_entry.url)
        if not image_url or image_url == "" then
            fail(_("No image URL in response."))
            return
        end

        -- Download phase: fresh status window, same elapsed clock
        openStatus(_("Downloading generated image…"))

        local dl_fn = makeDownloadFn(image_url)
        local dl_pid, dl_fd = ffiutil.runInSubProcess(dl_fn, true)
        if not dl_pid then
            fail(_("Failed to download generated image."))
            return
        end
        active_pid = dl_pid

        pollSubprocess(dl_pid, dl_fd, guarded(function(dl_raw)
            stopTicker()
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
            status.close()
            showImage(dl_raw:sub(4), description)
        end))
    end))
end

return ImageGenerator
