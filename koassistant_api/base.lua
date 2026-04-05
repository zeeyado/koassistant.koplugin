local json = require("json")
local logger = require("logger")
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

--- Resolve hostname to IP in the parent process (before fork).
--- Uses a quick TCP connect + getpeername to resolve via the system DNS.
--- @param url string HTTPS URL to resolve
--- @return string|nil resolved_ip, string|nil hostname, number port
function BaseHandler.resolveForSubprocess(url)
    if ffi.os ~= "OSX" or string.sub(url, 1, 8) ~= "https://" then
        return nil
    end
    local host = url:match("https://([^/:]+)")
    local port = tonumber(url:match("https://[^/:]+:(%d+)")) or 443
    if not host then return nil end

    local resolved_ip
    pcall(function()
        local sock = socket.tcp()
        sock:settimeout(2)
        sock:connect(host, port)
        resolved_ip = sock:getpeername()
        sock:close()
    end)
    return resolved_ip, host, port
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
--- @return number|nil status_code, boolean is_chunked
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

    -- Read response headers
    local is_chunked = false
    while true do
        local line = ssl_sock:receive("*l")
        if not line or line == "" then break end
        if line:lower():match("^transfer%-encoding:%s*chunked") then
            is_chunked = true
        end
    end

    return status_code, is_chunked
end

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

                local ssl_sock = BaseHandler.connectSSLInSubprocess(resolved_ip, parsed_host, parsed_port, 180)
                local status_code, is_chunked = sendRequestAndReadHeaders(
                    ssl_sock, "POST", parsed_path, parsed_host, headers, body)

                if status_code and status_code ~= 200 then
                    local err_body = readFullBody(ssl_sock, is_chunked)
                    ffiutil.writeToFD(child_write_fd,
                        string.format("\r\n%s%s\n\n", self.PROTOCOL_NON_200, err_body))
                else
                    streamBodyToPipe(ssl_sock, is_chunked, child_write_fd)
                end

                ssl_sock:close()
            else
                -- Non-macOS or non-HTTPS: use standard http.request path
                local su_ok, socketutil = pcall(require, "socketutil")
                if su_ok and socketutil then
                    socketutil:set_timeout(180, -1)
                elseif is_https then
                    https.TIMEOUT = 180
                end

                local pipe_w = wrap_fd(child_write_fd)
                local request = {
                    url = url,
                    method = "POST",
                    headers = headers or {},
                    source = ltn12.source.string(body or ""),
                    sink = ltn12.sink.file(pipe_w),
                }

                local ok, code, _headers, status
                ok, code, _headers, status = pcall(function()
                    return socket.skip(1, http.request(request))
                end)

                if not ok then
                    local err_msg = tostring(code)
                    logger.warn("Background request error:", err_msg, "url:", url)
                    ffiutil.writeToFD(child_write_fd,
                        string.format("\r\n%sConnection error: %s\n\n",
                            self.PROTOCOL_NON_200, err_msg))
                elseif code ~= 200 then
                    logger.warn("Background request non-200:", code, "status:", status, "url:", url)
                    local status_text = status and status:match("^HTTP/%S+%s+%d+%s+(.+)$") or status or "Request failed"
                    local numeric_code = tonumber(code) or 0
                    ffiutil.writeToFD(child_write_fd,
                        string.format("\r\n%sError %d: %s\n\n",
                            self.PROTOCOL_NON_200, numeric_code, status_text))
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
    end
end

return BaseHandler
