local json = require("json")
local logger = require("koassistant_logger")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local https = require("ssl.https")
local ffi = require("ffi")
local ffiutil = require("ffi/util")

local BaseHandler = {
    trap_widget = nil,  -- widget to trap the request (for dismissable requests)
}

-- Protocol markers for inter-process communication
BaseHandler.CODE_CANCELLED = "USER_CANCELED"
BaseHandler.CODE_NETWORK_ERROR = "NETWORK_ERROR"
BaseHandler.PROTOCOL_NON_200 = "X-NON-200-STATUS:"
-- Per-minute admission limits (docs/tpm_admission_plan.md): the fetch child forwards
-- the provider's rate-limit response headers to the parent as one marker line, same
-- shape as PROTOCOL_NON_200, so the parent can size answer budgets to the plan.
local RateLimits = require("koassistant_rate_limits")
BaseHandler.PROTOCOL_RATELIMIT = RateLimits.PROTOCOL_MARKER

--- Format a non-200 HTTP error body into a SINGLE-LINE message.
--- The streaming reader consumes the PROTOCOL_NON_200 marker line-by-line, so a
--- multi-line JSON body (e.g. Gemini's {\n "error": {...}}) would be truncated to
--- just "{". Collapsing to one line — and extracting error.message when the body
--- is JSON — lets the full message survive to the UI. Works for any provider.
--- @param code number|string HTTP status code
--- @param err_body string Raw response body
--- @return string Single-line "Error <code>: <message>"
function BaseHandler.formatNon200(code, err_body)
    local msg = err_body
    if type(err_body) == "string" and err_body ~= "" then
        local ok, j = pcall(json.decode, err_body)
        if ok and type(j) == "table" then
            local e = j.error or (type(j[1]) == "table" and j[1].error)
            if type(e) == "table" then
                msg = e.message or e.status or err_body
                -- The machine code rides with the sentence (see RateLimits.withErrorCode):
                -- this line is what the macOS streaming path shows and classifies.
                if type(e.message) == "string" then msg = RateLimits.withErrorCode(e.message, e) end
            elseif type(e) == "string" then
                msg = e
            end
        end
    end
    msg = tostring(msg or ""):gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
    if msg == "" then msg = "Request failed" end
    return string.format("HTTP %s: %s", tostring(code), msg)
end

function BaseHandler:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function BaseHandler:setTrapWidget(trap_widget)
    self.trap_widget = trap_widget
end

function BaseHandler:resetTrapWidget()
    self.trap_widget = nil
end

function BaseHandler:handleApiResponse(success, code, responseBody, provider)
    if not success then
        -- Use consistent error format for connection failures
        return false, string.format("Error: Failed to connect to %s API - %s", provider, tostring(code))
    end

    -- Handle empty response body
    if not responseBody or #responseBody == 0 then
        return false, string.format("Error: Empty response from %s API", provider)
    end

    -- Try to decode JSON response
    local responseText = table.concat(responseBody)
    local decode_success, response = pcall(json.decode, responseText)

    if not decode_success then
        -- Use consistent error format for invalid responses
        return false, string.format("Error: Invalid JSON response from %s API: %s",
                                   provider, responseText:sub(1, 100))
    end

    -- Check HTTP status codes in the response (some APIs return errors with 200 OK)
    if code >= 400 then
        local error_msg = "Unknown error"
        if response and response.error then
            error_msg = response.error.message or response.error.type or json.encode(response.error)
        end
        return false, string.format("Error: %s API returned status %d: %s", provider, code, error_msg)
    end

    return true, response
end

function BaseHandler:query(message_history)
    -- To be implemented by specific handlers
    error("query method must be implemented")
end

--- Wrap a file descriptor into a Lua file-like object
--- that has :write() and :close() methods, suitable for ltn12.
--- @param fd integer file descriptor
--- @return table file-like object
local function wrap_fd(fd)
    local file_object = {}
    function file_object:write(chunk)
        ffiutil.writeToFD(fd, chunk)
        return self
    end

    function file_object:close()
        -- null close op,
        -- we need to use the fd later, then close manually
        return true
    end

    return file_object
end

-- ============================================================================
-- macOS subprocess networking helpers
-- ============================================================================
-- After fork() on macOS, DNS resolution via getaddrinfo() hangs for ~75s because
-- mDNSResponder communicates via Mach ports which are invalidated by fork().
-- LuaSocket's connect() always calls getaddrinfo, even for numeric IP addresses.
-- Additionally, LuaSec's tcp() factory interacts badly with socketutil's
-- monkey-patched socket.tcp after fork.
--
-- Solution: resolve DNS in the parent process (where getaddrinfo works), pass
-- the IP to the subprocess, and use raw SSL sockets with FFI connect (bypassing
-- getaddrinfo entirely) instead of http.request.
-- ============================================================================

--- Resolve hostname to IPv4 in the parent process (before fork).
--- Must return IPv4 because connectSSLInSubprocess uses inet_aton (IPv4-only).
--- On dual-stack hosts, getpeername() may return IPv6, which inet_aton silently
--- rejects — leaving sin_addr as 0.0.0.0 and the subprocess connecting to
--- localhost (ECONNREFUSED).
--- Covers plain http URLs too (2026-08-15): the forked child must NEVER call
--- getaddrinfo on macOS — libinfo's si_destination_compare runs a pthread_once
--- init that calls os_log_create on torn post-fork state and SIGSEGVs the
--- child (one crash report per failed ollama request; intermittent because a
--- parent-side resolve pre-completes the once-init, which the child inherits).
--- http children keep http.request but connect by this pre-resolved IP via
--- urlWithResolvedIP below.
--- @param url string HTTP(S) URL to resolve
--- @return string|nil resolved_ip, string|nil hostname, number port
function BaseHandler.resolveForSubprocess(url)
    if ffi.os ~= "OSX" then
        return nil
    end
    local scheme = url:match("^(https?)://")
    if not scheme then
        return nil
    end
    local host = url:match("^https?://([^/:]+)")
    local port = tonumber(url:match("^https?://[^/:]+:(%d+)"))
        or (scheme == "https" and 443 or 80)
    if not host then return nil end

    local resolved_ip

    -- Prefer getaddrinfo, picking the first IPv4 entry.
    pcall(function()
        local addrs = socket.dns.getaddrinfo(host)
        if addrs then
            for _idx, a in ipairs(addrs) do
                if a.family == "inet" and a.addr and not a.addr:find(":") then
                    resolved_ip = a.addr
                    return
                end
            end
        end
    end)

    -- Fallback: TCP connect + getpeername (filtered to IPv4).
    if not resolved_ip then
        pcall(function()
            local sock = socket.tcp()
            sock:settimeout(2)
            sock:connect(host, port)
            local ip = sock:getpeername()
            sock:close()
            if ip and not ip:find(":") then
                resolved_ip = ip
            end
        end)
    end

    return resolved_ip, host, port
end

--- Rewrite a URL to connect by a parent-resolved IP, keeping the original
--- hostname for the Host header. The http.request path in a forked child must
--- not trigger DNS (see resolveForSubprocess) — connecting by IP avoids
--- getaddrinfo entirely while the Host header keeps name-based routing
--- (reverse proxies in front of custom local providers) working.
--- @param url string Original URL
--- @param resolved_ip string|nil Parent-resolved IPv4 (nil = no rewrite)
--- @return string url_to_use, string|nil host_header ("host[:port]" when rewritten)
function BaseHandler.urlWithResolvedIP(url, resolved_ip)
    if not resolved_ip then return url, nil end
    local scheme, host, port, rest = url:match("^(https?)://([^/:]+)(:?%d*)(.*)$")
    if not scheme or host == resolved_ip then return url, nil end
    return scheme .. "://" .. resolved_ip .. (port or "") .. (rest or ""),
        host .. (port or "")
end

--- Create a connected SSL socket in a subprocess, bypassing getaddrinfo.
--- Uses FFI to create an IPv4 socket and connect directly to the pre-resolved IP.
--- @param resolved_ip string|nil IP address resolved in parent (nil = fallback to LuaSocket)
--- @param hostname string Hostname for SNI and Host header
--- @param port number TCP port
--- @param timeout number Socket timeout in seconds
--- @return table ssl_sock Connected SSL socket
function BaseHandler.connectSSLInSubprocess(resolved_ip, hostname, port, timeout)
    timeout = timeout or 180

    -- Reset socketutil timeouts (monkey-patches socket.tcp)
    local su_ok, socketutil = pcall(require, "socketutil")
    if su_ok and socketutil then
        socketutil:set_timeout(timeout, -1)
    end

    local ssl = require("ssl")
    local raw_sock = socket.tcp()
    raw_sock:settimeout(timeout)

    if resolved_ip then
        -- FFI direct connect: bypass getaddrinfo entirely.
        -- Create a connected IPv4 socket via FFI, then inject its fd
        -- into the LuaSocket object.
        require("ffi/posix_h")
        pcall(ffi.cdef, "int connect(int, const struct sockaddr *, unsigned int);")

        local ffi_fd = ffi.C.socket(ffi.C.AF_INET, 1, 0)  -- 1 = SOCK_STREAM
        if ffi_fd < 0 then
            error("socket() failed: " .. ffi.string(ffi.C.strerror(ffi.errno())))
        end

        local addr = ffi.new("struct sockaddr_in")
        addr.sin_family = ffi.C.AF_INET
        addr.sin_port = ffi.C.htons(port)
        ffi.C.inet_aton(resolved_ip, addr.sin_addr)
        local ret = ffi.C.connect(ffi_fd, ffi.cast("const struct sockaddr *", addr), ffi.sizeof(addr))
        if ret ~= 0 then
            ffi.C.close(ffi_fd)
            error("connect() failed: " .. ffi.string(ffi.C.strerror(ffi.errno())))
        end

        -- LuaSocket creates sockets lazily (fd = -1 until connect), so use setfd
        raw_sock:setfd(ffi_fd)
    else
        -- Fallback: use LuaSocket connect (may hang on macOS after fork)
        raw_sock:connect(hostname, port)
    end

    -- SSL wrap + handshake
    local ssl_sock = ssl.wrap(raw_sock, {
        mode = "client",
        protocol = "any",
        options = {"all", "no_sslv2", "no_sslv3", "no_tlsv1"},
        verify = "none",
    })
    ssl_sock:sni(hostname)
    ssl_sock:settimeout(timeout)
    ssl_sock:dohandshake()

    return ssl_sock
end

--- Read HTTP response body with chunked TE support, writing to pipe fd.
--- @param ssl_sock table Connected SSL socket (after headers consumed)
--- @param is_chunked boolean Whether Transfer-Encoding is chunked
--- @param child_write_fd integer Pipe fd to write body data to
local function streamBodyToPipe(ssl_sock, is_chunked, child_write_fd)
    if is_chunked then
        while true do
            local size_line = ssl_sock:receive("*l")
            if not size_line then break end
            local chunk_size = tonumber(size_line:match("^%s*(%x+)"), 16)
            if not chunk_size or chunk_size == 0 then break end
            local chunk_data = ssl_sock:receive(chunk_size)
            if chunk_data then
                ffiutil.writeToFD(child_write_fd, chunk_data)
            end
            ssl_sock:receive("*l")  -- trailing CRLF
        end
    else
        while true do
            local chunk, err, partial = ssl_sock:receive(8192)
            if chunk then
                ffiutil.writeToFD(child_write_fd, chunk)
            elseif partial and #partial > 0 then
                ffiutil.writeToFD(child_write_fd, partial)
            end
            if err then break end
        end
    end
end

--- Read full HTTP response body with chunked TE support, returning as string.
--- @param ssl_sock table Connected SSL socket (after headers consumed)
--- @param is_chunked boolean Whether Transfer-Encoding is chunked
--- @return string body
local function readFullBody(ssl_sock, is_chunked)
    local chunks = {}
    if is_chunked then
        while true do
            local size_line = ssl_sock:receive("*l")
            if not size_line then break end
            local chunk_size = tonumber(size_line:match("^%s*(%x+)"), 16)
            if not chunk_size or chunk_size == 0 then break end
            local chunk_data = ssl_sock:receive(chunk_size)
            if chunk_data then table.insert(chunks, chunk_data) end
            ssl_sock:receive("*l")  -- trailing CRLF
        end
    else
        while true do
            local chunk, err, partial = ssl_sock:receive(8192)
            if chunk then table.insert(chunks, chunk)
            elseif partial and #partial > 0 then table.insert(chunks, partial) end
            if err then break end
        end
    end
    return table.concat(chunks)
end

--- Send HTTP request and read response headers on a connected SSL socket.
--- @param ssl_sock table Connected SSL socket
--- @param method string HTTP method (GET, POST)
--- @param path string Request path
--- @param hostname string Host header value
--- @param headers table|nil Additional request headers
--- @param body string|nil Request body
--- @return number|nil status_code, boolean is_chunked, table headers (lower-cased keys)
local function sendRequestAndReadHeaders(ssl_sock, method, path, hostname, headers, body)
    local req_lines = {
        string.format("%s %s HTTP/1.1", method, path),
        string.format("Host: %s", hostname),
    }
    for k, v in pairs(headers or {}) do
        table.insert(req_lines, string.format("%s: %s", k, v))
    end
    if body and (not headers or (not headers["Content-Length"] and not headers["content-length"])) then
        table.insert(req_lines, string.format("Content-Length: %d", #body))
    end
    table.insert(req_lines, "Connection: close")
    table.insert(req_lines, "")
    table.insert(req_lines, "")
    ssl_sock:send(table.concat(req_lines, "\r\n"))
    if body then
        ssl_sock:send(body)
    end

    -- Read status line
    local status_line = ssl_sock:receive("*l")
    local status_code = status_line and tonumber(status_line:match("HTTP/%S+%s+(%d+)"))

    -- Read response headers (kept, lower-cased: the rate-limit family rides
    -- the pipe as a marker line — see RateLimits.encodeMarker)
    local is_chunked = false
    local resp_headers = {}
    while true do
        local line = ssl_sock:receive("*l")
        if not line or line == "" then break end
        if line:lower():match("^transfer%-encoding:%s*chunked") then
            is_chunked = true
        end
        local hk, hv = line:match("^([^:]+):%s*(.-)%s*$")
        if hk then resp_headers[hk:lower()] = hv end
    end

    return status_code, is_chunked, resp_headers
end

--- Detect unfilled sample placeholders from apikeys.lua.sample
--- (e.g. "YOUR_DEEPSEEK_API_KEY") so we never send them to a provider,
--- which would echo back a confusing 401 (issue #82).
function BaseHandler.isPlaceholderKey(key)
    if not key or key == "" then return true end
    local upper = key:upper()
    return upper:find("YOUR_", 1, true) ~= nil
        or upper:find("_HERE", 1, true) ~= nil
        or upper:find("API_KEY", 1, true) ~= nil
end

--- Masked fingerprint of a key, e.g. "AIz...x3Fq:39:189406354" (first 3 + last 4 +
--- length + djb2 hash of the whole key). Used as the stored selection handle
--- (features.api_key_selected) — the full key never needs to be written outside
--- its own store. The hash matters: same-provider keys share prefix and length
--- (every Google key starts "AIza" at 39 chars), so mask+length alone can collide
--- and silently select the wrong key (caught by test_api_keys).
function BaseHandler.keyFingerprint(key)
    if type(key) ~= "string" or key == "" then return "" end
    local mask
    if #key <= 8 then
        mask = string.rep("*", #key)
    else
        mask = key:sub(1, 3) .. "..." .. key:sub(-4)
    end
    local h = 5381
    for i = 1, #key do
        h = (h * 33 + key:byte(i)) % 4294967296
    end
    return mask .. ":" .. #key .. ":" .. h
end

--- Reduce a user-supplied key to the bytes an HTTP auth header can carry:
--- printable ASCII, no whitespace anywhere. Anything else came from the way the
--- key was ENTERED, never from the provider.
---
--- Kindle is the recurring case (discussion #54): the device has no system
--- clipboard, so users copy the key out of a text file opened in KOReader, and a
--- key long enough to wrap picks up the line break in the MIDDLE of the string.
--- The 2026-03 fix only trimmed the ENDS, and only ASCII `%s` at that, so an
--- interior break (or a NBSP / zero-width space / BOM anywhere) sailed through
--- and the pasted key 401s while the same key in apikeys.lua works.
function BaseHandler.sanitizeKey(key)
    if type(key) ~= "string" then return "" end
    return (key:gsub("[^\33-\126]", ""))
end

-- Fold one provider's store value (legacy string, array of strings, or array of
-- { key, alias } tables) into `out` as { key, alias, source } entries. Keys are
-- sanitized on READ (so a key already saved with junk in it heals itself on the
-- next request, with no migration) and placeholders dropped.
local function foldKeyEntries(out, value, source)
    local function addOne(key, alias)
        if type(key) ~= "string" then return end
        key = BaseHandler.sanitizeKey(key)
        if key == "" or BaseHandler.isPlaceholderKey(key) then return end
        out[#out + 1] = { key = key, alias = alias, source = source }
    end
    if type(value) == "string" then
        addOne(value)
    elseif type(value) == "table" then
        for _idx, entry in ipairs(value) do
            if type(entry) == "string" then
                addOne(entry)
            elseif type(entry) == "table" then
                addOne(entry.key, type(entry.alias) == "string" and entry.alias or nil)
            end
        end
    end
end

--- Enumerate a provider's configured keys in resolution order: GUI entries first,
--- then apikeys.lua entries (matching the long-standing GUI-overrides-file rule).
--- @return table array of { key, alias|nil, source = "gui"|"file" }
function BaseHandler.listApiKeys(provider, settings)
    local out = {}
    if settings then
        local features = settings:readSetting("features") or {}
        foldKeyEntries(out, (features.api_keys or {})[provider], "gui")
    end
    local success, apikeys = pcall(function() return require("apikeys") end)
    if success and type(apikeys) == "table" then
        foldKeyEntries(out, apikeys[provider], "file")
    end
    return out
end

--- Resolve a provider's API key. A stored selection (features.api_key_selected
--- [provider] = fingerprint, written by the key manager) wins when it still
--- matches a configured key; otherwise the first configured key in GUI-then-file
--- order — exactly the pre-multi-key behavior. Shared by the query router,
--- provider tests and image generation, so a selection reaches every request.
function BaseHandler.getApiKey(provider, settings)
    local keys = BaseHandler.listApiKeys(provider, settings)
    if #keys == 0 then return nil end
    if settings then
        local features = settings:readSetting("features") or {}
        local selected = (features.api_key_selected or {})[provider]
        if selected and selected ~= "" then
            for _idx, entry in ipairs(keys) do
                if BaseHandler.keyFingerprint(entry.key) == selected then
                    logger.dbg("KOAssistant: api key for", provider, "= selected",
                        entry.source, "entry, length", #entry.key)
                    return entry.key
                end
            end
            -- Stale selection (key deleted / file edited): fall through to default.
        end
    end
    -- Source + LENGTH only, never the key: a wrong length in a user's crash.log
    -- is what tells GUI-entry corruption apart from a genuinely wrong key.
    logger.dbg("KOAssistant: api key for", provider, "= first", keys[1].source,
        "entry of", #keys, "length", #keys[1].key)
    return keys[1].key
end

--- Write the whole buffer to a pipe fd. ffiutil.writeToFD is a single
--- unlooped write(2): pipe writes larger than the pipe buffer may return
--- short (truncated multi-MB image responses on device). Loops until done,
--- retrying on EINTR.
function BaseHandler.writeAllToFD(fd, data)
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

--- Complete (non-streaming) HTTP(S) fetch for use INSIDE a subprocess.
--- Chooses the macOS raw-SSL path (http.request hangs after fork on macOS)
--- or the standard http.request path. Pre-resolve DNS in the PARENT with
--- resolveForSubprocess(url) and pass it as opts.resolved_ip.
--- @param url string
--- @param opts table: { method = "GET"|"POST" (default GET), headers = table,
---                      body = string|nil, resolved_ip = string|nil,
---                      timeout = seconds (default 120) }
--- @return number|nil status_code (nil = transport error), string body_or_error
function BaseHandler.fetchInSubprocess(url, opts)
    opts = opts or {}
    local method = opts.method or "GET"
    local timeout = opts.timeout or 120
    local is_https = url:sub(1, 8) == "https://"
    if is_https and ffi.os == "OSX" then
        local host = url:match("https://([^/:]+)")
        local port = tonumber(url:match("https://[^/:]+:(%d+)")) or 443
        local path = url:match("https://[^/]+(.*)") or "/"
        local ssl_sock = BaseHandler.connectSSLInSubprocess(opts.resolved_ip, host, port, timeout)
        local status_code, is_chunked, resp_headers = sendRequestAndReadHeaders(
            ssl_sock, method, path, host, opts.headers, opts.body)
        local resp_body = readFullBody(ssl_sock, is_chunked)
        ssl_sock:close()
        return status_code, resp_body, resp_headers
    end
    local su_ok, socketutil = pcall(require, "socketutil")
    if su_ok and socketutil then
        socketutil:set_timeout(timeout, -1)
    elseif is_https then
        https.TIMEOUT = timeout
    end
    -- Forked-child callers that pass opts.resolved_ip get the macOS
    -- DNS-in-child crash protection on plain http too (see urlWithResolvedIP);
    -- in-parent callers without it are unaffected. https stays un-rewritten
    -- here (an IP URL would break SNI on the LuaSec fallback path).
    local rw_ip = nil
    if not is_https then rw_ip = opts.resolved_ip end
    local request_url, host_header = BaseHandler.urlWithResolvedIP(url, rw_ip)
    local req_headers = opts.headers
    if host_header then
        req_headers = {}
        for k, v in pairs(opts.headers or {}) do req_headers[k] = v end
        req_headers["Host"] = host_header
    end
    local chunks = {}
    local request = {
        url = request_url,
        method = method,
        headers = req_headers,
        sink = ltn12.sink.table(chunks),
    }
    if opts.body then
        request.source = ltn12.source.string(opts.body)
    end
    local ok, code, resp_headers = pcall(function()
        return socket.skip(1, http.request(request))
    end)
    if not ok then
        return nil, tostring(code)
    end
    return tonumber(code), table.concat(chunks), resp_headers
end

--- Non-blocking one-shot HTTP(S) fetch: fetchInSubprocess forked into a child,
--- with the parent polling the pipe on the UI loop (the openai_codex_oauth
--- pattern, generalized so other parent-side fetches — web-search backends —
--- share one implementation instead of hand-copying the poll loop).
--- The child ships {status_code, body} through the pipe as JSON.
--- @param url string
--- @param opts table: same fields as fetchInSubprocess (method, headers, body,
---                    timeout); resolved_ip is filled here (parent-side DNS —
---                    a forked child must NEVER resolve on macOS)
--- @param on_done function(status_code|nil, body_or_error) — called once on the
---        UI loop; never called after cancel. May be called synchronously when
---        the subprocess cannot start.
--- @return function|nil cancel: terminates the subprocess and suppresses on_done
function BaseHandler.fetchAsync(url, opts, on_done)
    opts = opts or {}
    local resolved_ip = BaseHandler.resolveForSubprocess(url)
    local fetch_fn = function(pid, child_write_fd)
        if not pid or not child_write_fd then return end
        local ok, status_code, body = pcall(BaseHandler.fetchInSubprocess, url, {
            method = opts.method,
            headers = opts.headers,
            body = opts.body,
            timeout = opts.timeout,
            resolved_ip = resolved_ip,
        })
        local payload = ok
            and json.encode({ status_code = status_code, body = body or "" })
            or json.encode({ status_code = 0, body = tostring(status_code) })
        BaseHandler.writeAllToFD(child_write_fd, payload)
        ffi.C.close(child_write_fd)
        pcall(function() ffi.C._exit(0) end)
    end
    local pid, read_fd = ffiutil.runInSubProcess(fetch_fn, true)
    if not pid then
        on_done(nil, "failed to start fetch subprocess")
        return nil
    end

    local UIManager = require("ui/uimanager")
    local cancelled = false
    local chunk_size = 65536
    local buffer = ffi.new("char[?]", chunk_size)
    local pointer = ffi.cast("void*", buffer)
    local parts = {}

    local function finish()
        ffi.C.close(read_fd)
        if cancelled then return end
        local raw = table.concat(parts)
        local ok, decoded = pcall(json.decode, raw)
        if ok and type(decoded) == "table" then
            -- luajson decodes JSON null to a truthy sentinel — type-check both fields.
            local status = type(decoded.status_code) == "number" and decoded.status_code or nil
            local body = type(decoded.body) == "string" and decoded.body or ""
            -- The child encodes a transport error as status 0 + message body.
            if status == 0 then status = nil end
            on_done(status, body)
        else
            on_done(nil, "failed to parse fetch subprocess response")
        end
    end

    local function poll()
        if cancelled then
            ffi.C.close(read_fd)
            return
        end
        while true do
            local available = ffiutil.getNonBlockingReadSize(read_fd) or 0
            if available > 0 then
                local bytes = tonumber(ffi.C.read(read_fd, pointer, chunk_size))
                if bytes and bytes > 0 then parts[#parts + 1] = ffi.string(pointer, bytes)
                else finish() return end
            elseif ffiutil.isSubProcessDone(pid) then
                while true do
                    local bytes = tonumber(ffi.C.read(read_fd, pointer, chunk_size))
                    if not bytes or bytes <= 0 then break end
                    parts[#parts + 1] = ffi.string(pointer, bytes)
                end
                finish()
                return
            else
                UIManager:scheduleIn(0.15, poll)
                return
            end
        end
    end
    UIManager:scheduleIn(0.15, poll)

    return function()
        if cancelled then return end
        cancelled = true
        pcall(ffiutil.terminateSubProcess, pid)
    end
end

--- Socket read timeout for the request subprocess, in seconds (maintainer
--- 2026-08-18). This is a BLOCK timeout — LuaSocket's set_timeout(block, -1)
--- caps a single read, not the whole request — and a NON-streaming request is
--- one long silent read: nothing arrives until the model has finished. The old
--- 180 killed a 384-second X-Ray update that had already returned HTTP 200,
--- wasting the whole paid request. Killing a slow request is worse than
--- letting it run: the reader can cancel from the loading dialog, close the
--- book, or exit, and the ladder records the stop either way.
BaseHandler.SUBPROCESS_READ_TIMEOUT = 900

--- Background request function for streaming responses
--- This function is used to make a request in the background (subprocess),
--- and write the response to a pipe for real-time processing.
--- @param url string: The URL to make the request to
--- @param headers table: HTTP headers for the request
--- @param body string: Request body (JSON encoded)
--- @return function: A function to be run in subprocess via ffiutil.runInSubProcess
function BaseHandler:backgroundRequest(url, headers, body)
    -- Pre-resolve DNS in parent process (macOS only)
    local resolved_ip = BaseHandler.resolveForSubprocess(url)

    return function(pid, child_write_fd)
        if not pid or not child_write_fd then
            logger.warn("Invalid parameters for background request")
            return
        end

        -- Wrap subprocess body in pcall to catch any initialization errors
        local subprocess_ok, subprocess_err = pcall(function()
            local is_https = string.sub(url, 1, 8) == "https://"
            if is_https and ffi.os == "OSX" then
                -- macOS: use raw SSL to bypass http.request which hangs after fork
                local parsed_host = url:match("https://([^/:]+)")
                local parsed_port = tonumber(url:match("https://[^/:]+:(%d+)")) or 443
                local parsed_path = url:match("https://[^/]+(.*)") or "/"

                local ssl_sock = BaseHandler.connectSSLInSubprocess(resolved_ip, parsed_host,
                    parsed_port, BaseHandler.SUBPROCESS_READ_TIMEOUT)
                local status_code, is_chunked, resp_headers = sendRequestAndReadHeaders(
                    ssl_sock, "POST", parsed_path, parsed_host, headers, body)
                -- Rate-limit headers first (also on a non-200: a refusal's own headers
                -- name the plan's allowance)
                local rl_marker = RateLimits.encodeMarker(resp_headers)
                if rl_marker then ffiutil.writeToFD(child_write_fd, rl_marker) end

                if status_code and status_code ~= 200 then
                    local err_body = readFullBody(ssl_sock, is_chunked)
                    -- Collapse to one line so the streaming reader captures the whole
                    -- message (a multi-line JSON body would be truncated to "{").
                    ffiutil.writeToFD(child_write_fd,
                        string.format("\r\n%s%s\n\n", self.PROTOCOL_NON_200,
                            BaseHandler.formatNon200(status_code, err_body)))
                else
                    streamBodyToPipe(ssl_sock, is_chunked, child_write_fd)
                end

                ssl_sock:close()
            else
                -- Non-macOS or non-HTTPS: use standard http.request path
                local su_ok, socketutil = pcall(require, "socketutil")
                if su_ok and socketutil then
                    socketutil:set_timeout(BaseHandler.SUBPROCESS_READ_TIMEOUT, -1)
                elseif is_https then
                    https.TIMEOUT = BaseHandler.SUBPROCESS_READ_TIMEOUT
                end

                -- macOS http (ollama, custom local providers): connect by the
                -- parent-resolved IP — getaddrinfo in the forked child SIGSEGVs
                -- (see resolveForSubprocess). resolved_ip is nil off-macOS.
                local request_url, host_header =
                    BaseHandler.urlWithResolvedIP(url, resolved_ip)
                local req_headers = headers or {}
                if host_header then
                    local h = {}
                    for k, v in pairs(req_headers) do h[k] = v end
                    h["Host"] = host_header
                    req_headers = h
                end

                local pipe_w = wrap_fd(child_write_fd)
                local request = {
                    url = request_url,
                    method = "POST",
                    headers = req_headers,
                    source = ltn12.source.string(body or ""),
                    sink = ltn12.sink.file(pipe_w),
                }

                local ok, code, _headers, status
                ok, code, _headers, status = pcall(function()
                    return socket.skip(1, http.request(request))
                end)

                -- Rate-limit headers: on this path the body has already streamed into
                -- the pipe, so the marker trails it; both parents accept it anywhere
                if ok then
                    local rl_marker = RateLimits.encodeMarker(_headers)
                    if rl_marker then ffiutil.writeToFD(child_write_fd, rl_marker) end
                end

                if not ok then
                    local err_msg = tostring(code)
                    logger.warn("Background request error:", err_msg, "url:", url)
                    ffiutil.writeToFD(child_write_fd,
                        string.format("\r\n%sConnection error: %s\n\n",
                            self.PROTOCOL_NON_200, err_msg))
                elseif code ~= 200 then
                    logger.warn("Background request non-200:", code, "status:", status, "url:", url)
                    local numeric_code = tonumber(code)
                    if not numeric_code then
                        -- luasocket signals a transport failure as nil + an error
                        -- STRING, and socket.skip shifts that string into `code`.
                        -- Coercing it to 0 turned "connection refused" into
                        -- "Error 0: Request failed" on screen, hiding the only
                        -- fact that mattered (device 2026-08-20: a stopped local
                        -- server was indistinguishable from a broken request).
                        -- The address goes with it: for a local provider, WHICH
                        -- server is unreachable is half the diagnosis.
                        ffiutil.writeToFD(child_write_fd,
                            string.format("\r\n%sCannot reach %s: %s\n\n",
                                self.PROTOCOL_NON_200, tostring(url), tostring(code)))
                    else
                        local status_text = status and status:match("^HTTP/%S+%s+%d+%s+(.+)$")
                            or status or "Request failed"
                        ffiutil.writeToFD(child_write_fd,
                            string.format("\r\n%sError %d: %s\n\n",
                                self.PROTOCOL_NON_200, numeric_code, status_text))
                    end
                end
            end
        end)

        -- If the subprocess body threw an error, write it to the pipe
        if not subprocess_ok then
            local err_msg = tostring(subprocess_err)
            ffiutil.writeToFD(child_write_fd,
                string.format("\r\nX-NON-200-STATUS:Subprocess error: %s\n\n", err_msg))
        end

        ffi.C.close(child_write_fd)

        -- #87: exit raw to skip __cxa_finalize (SIGSEGV in the Adreno GL driver on some
        -- Boox/Android devices). No-op where KOReader core already _exits. This single
        -- child closure is forked for BOTH streaming and non-streaming requests.
        pcall(function() ffi.C._exit(0) end)
    end
end

return BaseHandler
