--[[--
KOAssistant Image Generator

Generates an image from a text description using the currently configured
AI provider's image-generation endpoint and displays the result in
KOReader's full-screen ImageViewer.

Currently supported providers and their image-generation endpoints:
  • openai     → https://api.openai.com/v1/images/generations   (dall-e-3)
  • xai        → https://api.x.ai/v1/images/generations         (grok-2-image)

All other providers fall back to a "not supported" notice.  The entry
point is the single public function:

  ImageGenerator.generate(word, configuration, settings)

where `word` is the selected text / description, `configuration` is the
global config table (provider + api_key resolved by main.lua), and
`settings` is the LuaSettings instance (for GUI-entered API keys).
]]

local json   = require("json")
local ffi    = require("ffi")
local ffiutil = require("ffi/util")
local https   = require("ssl.https")
local ltn12   = require("ltn12")
local BaseHandler = require("koassistant_api.base")
local _ = require("koassistant_gettext")

local ImageGenerator = {}

-- ---------------------------------------------------------------------------
-- Provider image-generation endpoint table
-- ---------------------------------------------------------------------------

--[[
 Provider entries:
   url        - base URL (OpenAI-style) or base URL for Gemini model interpolation
   model      - default image model for this provider
   key_header - HTTP header used for authentication
   is_gemini  - when true, use Gemini's generateContent protocol instead of OpenAI images API

 Gemini ("Nano Banana") note:
   Models gemini-3.1-flash-image / gemini-3-pro-image use the standard generateContent
   endpoint with responseModalities=["IMAGE","TEXT"] and return images as inlineData
   base64 parts in candidates[] -- not the OpenAI images response shape.
]]
local IMAGE_ENDPOINTS = {
    openai = {
        url        = "https://api.openai.com/v1/images/generations",
        model      = "dall-e-3",
        key_header = "Authorization",  -- "Bearer <key>"
    },
    xai = {
        url        = "https://api.x.ai/v1/images/generations",
        model      = "grok-2-image",
        key_header = "Authorization",
    },
    gemini = {
        -- Base URL; model is appended as: <base>/<model>:generateContent
        url        = "https://generativelanguage.googleapis.com/v1beta/models",
        model      = "gemini-3.1-flash-image",
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

--- Show a simple error / informational notice.
local function showNotice(text)
    local UIManager  = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = text })
end

--- Show the generated image in KOReader's ImageViewer.
--- `image_data` is the raw PNG/JPEG binary string.
local function showImage(image_data, description, on_close)
    local UIManager  = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")

    -- Write image to a temporary file
    local tmp_dir = DataStorage:getDataDir() .. "/koassistant_images"
    if not lfs.attributes(tmp_dir, "mode") then
        lfs.mkdir(tmp_dir)
    end
    local tmp_path = tmp_dir .. "/generated_" .. os.time() .. ".png"
    local f = io.open(tmp_path, "wb")
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
        showNotice(_("Image saved to:") .. "\n" .. tmp_path)
        if on_close then on_close() end
        return
    end

    local viewer = ImageViewer:new{
        file = tmp_path,
        with_title_bar = true,
        title_text = description and
            (_('"') .. description:sub(1, 60) .. (description:len() > 60 and "…" or "") .. _('"')) or
            _("Generated image"),
        is_doc_page = false,
    }
    -- Clean up temp file when viewer is dismissed
    local orig_onClose = viewer.onClose
    viewer.onClose = function(self_v, ...)
        -- Remove temp file
        os.remove(tmp_path)
        if orig_onClose then orig_onClose(self_v, ...) end
        if on_close then on_close() end
    end
    UIManager:show(viewer)
end

-- ---------------------------------------------------------------------------
-- Background subprocess: make the HTTPS POST, stream result to pipe
-- ---------------------------------------------------------------------------

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
                    ffiutil.writeToFD(child_write_fd, "ERR:HTTP " .. tostring(status_code) .. ": " .. body:sub(1, 200))
                else
                    ffiutil.writeToFD(child_write_fd, "OK:" .. body)
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
                    ffiutil.writeToFD(child_write_fd,
                        "ERR:HTTP " .. tostring(code) .. " " .. tostring(status) .. ": " .. body:sub(1, 200))
                else
                    ffiutil.writeToFD(child_write_fd, "OK:" .. body)
                end
            end
        end)

        if not ok then
            ffiutil.writeToFD(child_write_fd, "ERR:Subprocess error: " .. tostring(err))
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
                    ffiutil.writeToFD(child_write_fd, "ERR:HTTP " .. tostring(status_code))
                else
                    -- prefix + binary body
                    ffiutil.writeToFD(child_write_fd, "OK:")
                    local body = table.concat(chunks)
                    ffiutil.writeToFD(child_write_fd, body)
                end
            else
                local chunks_t = {}
                local _, code = https.request{
                    url  = image_url,
                    sink = ltn12.sink.table(chunks_t),
                }
                if tonumber(code) ~= 200 then
                    ffiutil.writeToFD(child_write_fd, "ERR:HTTP " .. tostring(code))
                else
                    ffiutil.writeToFD(child_write_fd, "OK:")
                    ffiutil.writeToFD(child_write_fd, table.concat(chunks_t))
                end
            end
        end)
        if not ok then
            ffiutil.writeToFD(child_write_fd, "ERR:Download subprocess error: " .. tostring(err))
        end
        ffi.C.close(child_write_fd)
        pcall(function() ffi.C._exit(0) end)
    end
end

-- ---------------------------------------------------------------------------
-- Base64 decode (pure Lua, no external dependency)
-- ---------------------------------------------------------------------------

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64index = {}
for i = 1, #b64chars do b64index[b64chars:sub(i,i)] = i - 1 end

local function b64decode(s)
    s = s:gsub("[^A-Za-z0-9+/=]", "")
    local out = {}
    local i = 1
    while i <= #s do
        local c1 = b64index[s:sub(i,i)]   or 0
        local c2 = b64index[s:sub(i+1,i+1)] or 0
        local c3 = b64index[s:sub(i+2,i+2)] or 0
        local c4 = b64index[s:sub(i+3,i+3)] or 0
        local n = (c1 * 262144) + (c2 * 4096) + (c3 * 64) + c4
        table.insert(out, string.char(math.floor(n / 65536) % 256))
        if s:sub(i+2,i+2) ~= "=" then
            table.insert(out, string.char(math.floor(n / 256) % 256))
        end
        if s:sub(i+3,i+3) ~= "=" then
            table.insert(out, string.char(n % 256))
        end
        i = i + 4
    end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Poll helper: read subprocess pipe until EOF
-- ---------------------------------------------------------------------------

local function pollSubprocess(pid, parent_read_fd, on_done)
    local UIManager = require("ui/uimanager")
    local bit = require("bit")
    local flags = ffi.C.fcntl(parent_read_fd, 3)  -- F_GETFL
    if flags >= 0 then
        ffi.C.fcntl(parent_read_fd, 4, bit.bor(flags, 2048))  -- F_SETFL + O_NONBLOCK
    end

    local chunksize = 1024 * 64
    local buf = ffi.new("char[?]", chunksize, {0})
    local buf_ptr = ffi.cast("void*", buf)
    local response_parts = {}
    local poll_task

    poll_task = function()
        while true do
            local bytes = ffi.C.read(parent_read_fd, buf_ptr, chunksize)
            if bytes > 0 then
                table.insert(response_parts, ffi.string(buf_ptr, bytes))
            elseif bytes == 0 then
                -- EOF
                ffi.C.close(parent_read_fd)
                on_done(table.concat(response_parts))
                return
            else
                local errno = ffi.errno()
                if errno == 11 or errno == 35 then  -- EAGAIN / EWOULDBLOCK
                    UIManager:scheduleIn(0.15, poll_task)
                    return
                else
                    ffi.C.close(parent_read_fd)
                    on_done(table.concat(response_parts))
                    return
                end
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
        -- Write to a log file so the user can retrieve it
        local DataStorage = require("datastorage")
        local log_path = DataStorage:getDataDir() .. "/koassistant_image_error.log"
        local f = io.open(log_path, "a")
        if f then
            f:write(os.date("%Y-%m-%d %H:%M:%S") .. " ERROR: " .. tostring(err) .. "\n")
            f:close()
        end
        -- Show visibly on screen
        local UIManager   = require("ui/uimanager")
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text = "[KOA Image Generator Error]\n\n" .. tostring(err) ..
                   "\n\n(Also saved to koreader/koassistant_image_error.log)",
        })
    end
end

--- Internal implementation — called via pcall from generate() for error catching.
function ImageGenerator._generateImpl(word, config_table, settings)
    local UIManager   = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")

    -- Determine provider
    local features = settings and settings:readSetting("features") or {}
    local provider = features.provider or (config_table and config_table.provider) or "openai"

    local endpoint = IMAGE_ENDPOINTS[provider]
    if not endpoint then
        showNotice(_(
            "Image generation is not supported for the current provider.\n\n" ..
            "Supported providers: OpenAI (DALL-E 3), xAI (Grok), Gemini (Nano Banana)."
        ))
        return
    end

    local api_key = resolveApiKey(provider, settings)
    if not api_key then
        showNotice(_(
            "No API key found for provider: ") .. provider .. _(".\n\n" ..
            "Please add your key in KOAssistant Settings → API Keys."
        ))
        return
    end

    -- Resolve selected model from settings or config
    local selected_model
    local prov_settings = features.provider_settings or {}
    if prov_settings[provider] and prov_settings[provider].model then
        selected_model = prov_settings[provider].model
    end
    if not selected_model or selected_model == "" or selected_model == "default" then
        selected_model = features.model
    end
    if (not selected_model or selected_model == "" or selected_model == "default") and config_table then
        local config_prov_settings = config_table.provider_settings or {}
        if config_prov_settings[provider] and config_prov_settings[provider].model then
            selected_model = config_prov_settings[provider].model
        end
        if not selected_model or selected_model == "" or selected_model == "default" then
            selected_model = config_table.model
        end
    end

    -- Map selected model to a valid image-generation model for the provider
    local resolved_model = endpoint.model
    if selected_model and selected_model ~= "" and selected_model ~= "default" then
        if provider == "gemini" then
            if selected_model:find("-image", 1, true) then
                resolved_model = selected_model
            else
                local lower = selected_model:lower()
                if lower:find("pro", 1, true) then
                    resolved_model = "gemini-3-pro-image"
                else
                    resolved_model = "gemini-3.1-flash-image"
                end
            end
        elseif provider == "openai" then
            if selected_model:find("dall-e", 1, true) then
                resolved_model = selected_model
            end
        elseif provider == "xai" then
            if selected_model:find("image", 1, true) then
                resolved_model = selected_model
            end
        end
    end

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
        -- OpenAI-style images/generations request
        local request_body = {
            model  = resolved_model,
            prompt = description,
            n      = 1,
            size   = "1024x1024",
            -- Request b64_json so we avoid a second HTTP round-trip for URL-based responses
            -- (falls back gracefully if provider doesn't support it)
            response_format = "b64_json",
        }
        request_body_str = json.encode(request_body)
    end

    -- Show loading dialog
    local loading_dialog = InfoMessage:new{
        text = _("Generating image…\n\n") ..
               string.upper(provider:sub(1,1)) .. provider:sub(2) ..
               " / " .. resolved_model,
        dismissable = false,
    }
    UIManager:show(loading_dialog)
    UIManager:forceRePaint()

    -- Build the actual request URL (Gemini interpolates the model into the path)
    local request_url = endpoint.url
    if endpoint.is_gemini then
        request_url = endpoint.url .. "/" .. resolved_model .. ":generateContent"
    end

    -- Launch subprocess
    local bg_fn = makeBackgroundFn(request_url, api_key, request_body_str, endpoint)
    local pid, parent_read_fd = ffiutil.runInSubProcess(bg_fn, true)

    if not pid then
        UIManager:close(loading_dialog)
        showNotice(_("Failed to start image generation subprocess."))
        return
    end

    -- Poll for result
    pollSubprocess(pid, parent_read_fd, function(raw)
        UIManager:close(loading_dialog)

        if raw == "" or not raw then
            showNotice(_("Empty response from image generation API."))
            return
        end

        -- Check for error prefix
        if raw:sub(1, 4) == "ERR:" then
            local err_msg = raw:sub(5)
            showNotice(_("Image generation failed:\n\n") .. err_msg)
            return
        end

        -- Strip "OK:" prefix
        local body = raw:sub(4)

        -- Parse JSON response
        local ok_parse, resp = pcall(json.decode, body)
        if not ok_parse or type(resp) ~= "table" then
            showNotice(_("Failed to parse image generation response."))
            return
        end

        -- Check for API-level error (both providers may return { error: {...} })
        if resp.error then
            local err_msg = (type(resp.error) == "table" and resp.error.message) or tostring(resp.error)
            showNotice(_("Image generation API error:\n\n") .. err_msg)
            return
        end

        -- Gemini returns images as inlineData parts inside candidates[].content.parts
        if endpoint.is_gemini then
            local candidates = resp.candidates
            if not candidates or not candidates[1] then
                showNotice(_("No candidates in Gemini image response."))
                return
            end
            local parts = candidates[1].content and candidates[1].content.parts
            if not parts then
                showNotice(_("No content parts in Gemini image response."))
                return
            end
            -- Find the first IMAGE part (mimeType starts with "image/")
            for _, part in ipairs(parts) do
                if part.inlineData and part.inlineData.mimeType
                        and part.inlineData.mimeType:sub(1, 6) == "image/" then
                    local image_bytes = b64decode(part.inlineData.data or "")
                    showImage(image_bytes, description)
                    return
                end
            end
            showNotice(_("No image part found in Gemini response."))
            return
        end

        -- OpenAI-style response: data[1].b64_json or data[1].url
        local image_data_entry = resp.data and resp.data[1]
        if not image_data_entry then
            showNotice(_("No image data in response."))
            return
        end

        -- b64_json response (preferred)
        if image_data_entry.b64_json and image_data_entry.b64_json ~= "" then
            local image_bytes = b64decode(image_data_entry.b64_json)
            showImage(image_bytes, description)
            return
        end

        -- url response fallback: download the image
        local image_url = image_data_entry.url
        if not image_url or image_url == "" then
            showNotice(_("No image URL in response."))
            return
        end

        -- Show secondary loading for download
        local dl_dialog = InfoMessage:new{
            text = _("Downloading generated image…"),
            dismissable = false,
        }
        UIManager:show(dl_dialog)
        UIManager:forceRePaint()

        local dl_fn = makeDownloadFn(image_url)
        local dl_pid, dl_fd = ffiutil.runInSubProcess(dl_fn, true)
        if not dl_pid then
            UIManager:close(dl_dialog)
            showNotice(_("Failed to download generated image."))
            return
        end

        pollSubprocess(dl_pid, dl_fd, function(dl_raw)
            UIManager:close(dl_dialog)
            if dl_raw:sub(1, 4) == "ERR:" then
                showNotice(_("Image download failed:\n\n") .. dl_raw:sub(5))
                return
            end
            -- "OK:" prefix + binary
            local image_bytes = dl_raw:sub(4)
            showImage(image_bytes, description)
        end)
    end)
end

--- Return whether image generation is supported for the given provider.
--- Used by the dict-button logic to decide whether to show the button.
function ImageGenerator.isSupported(provider)
    return IMAGE_ENDPOINTS[provider] ~= nil
end

return ImageGenerator
