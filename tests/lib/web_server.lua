--- WebServer: Simple HTTP server using LuaSocket
-- Serves the Request Inspector Web UI
-- @module web_server

local socket = require("socket")
local json = require("dkjson")

local WebServer = {}
WebServer.__index = WebServer

--- Create a new WebServer instance
function WebServer:new()
    local o = setmetatable({}, WebServer)
    o.running = false
    o.handlers = {}
    return o
end

--- Register a route handler
-- @param method string: HTTP method (GET, POST, etc.)
-- @param path string: URL path (e.g., "/api/build")
-- @param handler function: Handler function(headers, body) -> status, content_type, response_body
function WebServer:route(method, path, handler)
    self.handlers[method .. " " .. path] = handler
end

--- Parse HTTP request from client
-- @param client socket: Client socket
-- @return method, path, headers, body
function WebServer:parseRequest(client)
    -- Read request line
    local request_line = client:receive("*l")
    if not request_line then
        return nil
    end

    local method, path = request_line:match("^(%w+) ([^ ]+)")
    if not method then
        return nil
    end

    -- Read headers
    local headers = {}
    repeat
        local line = client:receive("*l")
        if line and line ~= "" then
            local key, value = line:match("^([^:]+):%s*(.+)$")
            if key then
                headers[key:lower()] = value
            end
        end
    until not line or line == ""

    -- Read body if Content-Length present
    local body = nil
    if headers["content-length"] then
        local length = tonumber(headers["content-length"])
        if length and length > 0 then
            body = client:receive(length)
        end
    end

    return method, path, headers, body
end

--- Send HTTP response to client
-- @param client socket: Client socket
-- @param status string: HTTP status (e.g., "200 OK")
-- @param content_type string: Content-Type header
-- @param body string: Response body
function WebServer:sendResponse(client, status, content_type, body)
    local response = string.format(
        "HTTP/1.1 %s\r\n" ..
        "Content-Type: %s\r\n" ..
        "Content-Length: %d\r\n" ..
        "Access-Control-Allow-Origin: *\r\n" ..
        "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" ..
        "Access-Control-Allow-Headers: Content-Type\r\n" ..
        "Connection: close\r\n" ..
        "\r\n%s",
        status, content_type, #body, body
    )
    client:send(response)
end

--- Handle a single client request
-- @param client socket: Client socket
function WebServer:handleClient(client)
    client:settimeout(5)

    local method, path, headers, body = self:parseRequest(client)
    if not method then
        self:sendResponse(client, "400 Bad Request", "text/plain", "Bad Request")
        return
    end

    -- Handle CORS preflight
    if method == "OPTIONS" then
        self:sendResponse(client, "204 No Content", "text/plain", "")
        return
    end

    -- Find handler
    local handler = self.handlers[method .. " " .. path]

    -- Try path prefix matching for API routes
    if not handler then
        for route, h in pairs(self.handlers) do
            local route_method, route_path = route:match("^(%w+) (.+)$")
            if route_method == method and path:sub(1, #route_path) == route_path then
                handler = h
                break
            end
        end
    end

    -- Default to root handler for unknown GET requests (serve index.html)
    if not handler and method == "GET" then
        handler = self.handlers["GET /"]
    end

    if handler then
        local ok, status, content_type, response_body = pcall(handler, headers, body, path)
        if ok then
            self:sendResponse(client, status or "200 OK", content_type or "text/plain", response_body or "")
        else
            -- Handler error
            local error_msg = json.encode({ error = tostring(status) })
            self:sendResponse(client, "500 Internal Server Error", "application/json", error_msg)
        end
    else
        local error_msg = json.encode({ error = "Not Found: " .. path })
        self:sendResponse(client, "404 Not Found", "application/json", error_msg)
    end
end

--- Start the server
-- @param port number: Port to listen on (default: 8080)
function WebServer:start(port)
    port = port or 8080

    local server = socket.tcp()
    server:setoption("reuseaddr", true)

    local ok, err = server:bind("127.0.0.1", port)
    if not ok then
        print("Error binding to port " .. port .. ": " .. tostring(err))
        return false
    end

    server:listen(5)
    server:settimeout(0.5) -- Non-blocking accept for graceful shutdown

    self.running = true
    self.server = server

    print("")
    print("================================================================================")
    print("  KOAssistant Request Inspector - Web UI")
    print("================================================================================")
    print("")
    print("  Server running at: http://localhost:" .. port)
    print("")
    print("  Press Ctrl+C to stop")
    print("")
    print("================================================================================")
    print("")

    while self.running do
        local client = server:accept()
        if client then
            self:handleClient(client)
            client:close()
        end
    end

    server:close()
    print("\nServer stopped.")
    return true
end

--- Stop the server
function WebServer:stop()
    self.running = false
end

return WebServer
