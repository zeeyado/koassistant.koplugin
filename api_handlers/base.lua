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

--- Background request function for streaming responses
--- This function is used to make a request in the background (subprocess),
--- and write the response to a pipe for real-time processing.
--- @param url string: The URL to make the request to
--- @param headers table: HTTP headers for the request
--- @param body string: Request body (JSON encoded)
--- @return function: A function to be run in subprocess via ffiutil.runInSubProcess
function BaseHandler:backgroundRequest(url, headers, body)
    -- Warmup: Make a quick TCP connection in parent before fork
    -- This fixes macOS-specific issues where subprocess connections hang intermittently
    -- The warmup establishes DNS/connection state that persists across fork
    if string.sub(url, 1, 8) == "https://" then
        local parent_socket = require("socket")
        local host = url:match("https://([^/:]+)")
        if host then
            pcall(function()
                local sock = parent_socket.tcp()
                sock:settimeout(5)
                sock:connect(host, 443)
                sock:close()
            end)
        end
    end

    return function(pid, child_write_fd)
        if not pid or not child_write_fd then
            logger.warn("Invalid parameters for background request")
            return
        end

        -- Wrap subprocess body in pcall to catch any initialization errors
        local subprocess_ok, subprocess_err = pcall(function()
            -- Re-require socket modules in subprocess after fork
            -- CRITICAL: Must re-require base socket module, not just http/https
            local subprocess_socket = require("socket")
            local subprocess_http = require("socket.http")
            local subprocess_https = require("ssl.https")

            -- Longer timeout for reasoning models (they can take 60+ seconds)
            if string.sub(url, 1, 8) == "https://" then
                subprocess_https.TIMEOUT = 180  -- 3 minutes for reasoning models
            end

            local pipe_w = wrap_fd(child_write_fd)
            local request = {
                url = url,
                method = "POST",
                headers = headers or {},
                source = ltn12.source.string(body or ""),
                sink = ltn12.sink.file(pipe_w),
            }

            -- Use https.request for HTTPS URLs, http.request for HTTP
            local request_func = string.sub(url, 1, 8) == "https://" and subprocess_https.request or subprocess_http.request

            local ok, code, resp_headers, status
            ok, code, resp_headers, status = pcall(function()
                return subprocess_socket.skip(1, request_func(request))
            end)

            if not ok then
                -- pcall failed - likely a connection or SSL error
                local err_msg = tostring(code)
                logger.warn("Background request error:", err_msg, "url:", url)
                ffiutil.writeToFD(child_write_fd,
                    string.format("\r\n%sConnection error: %s\n\n",
                        self.PROTOCOL_NON_200, err_msg))
            elseif code ~= 200 then
                logger.warn("Background request non-200:", code, "status:", status, "url:", url)
                local status_text = status and status:match("^HTTP/%S+%s+%d+%s+(.+)$") or status or "Request failed"
                ffiutil.writeToFD(child_write_fd,
                    string.format("\r\n%sError %d: %s\n\n",
                        self.PROTOCOL_NON_200, code or 0, status_text))
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
