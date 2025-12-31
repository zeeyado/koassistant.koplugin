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
    return function(pid, child_write_fd)
        if not pid or not child_write_fd then
            logger.warn("Invalid parameters for background request")
            return
        end

        -- Disable SSL certificate verification for https URLs
        if string.sub(url, 1, 8) == "https://" then
            https.cert_verify = false
        end

        local pipe_w = wrap_fd(child_write_fd)  -- wrap the write end of the pipe
        local request = {
            url = url,
            method = "POST",
            headers = headers or {},
            source = ltn12.source.string(body or ""),
            sink = ltn12.sink.file(pipe_w),  -- response body writes to pipe
        }

        local code, resp_headers, status = socket.skip(1, http.request(request))

        if code ~= 200 then
            logger.warn("Background request non-200:", code, "status:", status, "url:", url)
            -- Write error marker to pipe so parent can detect non-200 response
            ffiutil.writeToFD(child_write_fd,
                string.format("\r\n%s [%s %s] URL:%s\n\n",
                    self.PROTOCOL_NON_200, status or "", code or "", url))
        end

        ffi.C.close(child_write_fd)  -- close the write end of the pipe
    end
end

return BaseHandler
