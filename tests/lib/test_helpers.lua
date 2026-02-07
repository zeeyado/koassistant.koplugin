-- Shared test helpers for integration tests
--
-- Provides utilities needed when running plugin code outside KOReader's runtime.

local TestHelpers = {}

--- Monkey-patch a handler's backgroundRequest to make synchronous HTTP calls
--- instead of creating subprocess closures (which require KOReader's ffi layer).
--- Call this after loading a handler and before calling handler:query().
function TestHelpers.patchHandlerForSync(handler)
    handler.backgroundRequest = function(_self, url, headers, body)
        local http = require("socket.http")
        local https = require("ssl.https")
        local ltn12 = require("ltn12")
        local response_parts = {}
        local request = {
            url = url,
            method = "POST",
            headers = headers,
            source = ltn12.source.string(body or ""),
            sink = ltn12.sink.table(response_parts),
        }
        local request_func = url:sub(1, 8) == "https://" and https.request or http.request
        local _, code = request_func(request)
        return {
            _sync_response = table.concat(response_parts),
            _status_code = code,
        }
    end
end

--- Handle query() result that may be a string, function, or _non_streaming table.
--- Returns: success, text, elapsed
function TestHelpers.handleQueryResult(ok, result, elapsed)
    if not ok then
        return false, "Exception: " .. tostring(result), elapsed
    end

    if type(result) == "string" then
        if result:match("^Error:") then
            return false, result, elapsed
        else
            return true, result, elapsed
        end
    elseif type(result) == "function" then
        return false, "Handler returned streaming function (streaming should be disabled)", elapsed
    elseif type(result) == "table" and result._non_streaming and result._response_parser then
        local bg_result = result._background_fn
        if type(bg_result) ~= "table" or not bg_result._sync_response then
            return false, "Background request failed (no sync response)", elapsed
        end
        if bg_result._status_code ~= 200 then
            return false, "HTTP " .. tostring(bg_result._status_code) .. ": " .. bg_result._sync_response:sub(1, 200), elapsed
        end
        local json = require("json")
        local response = json.decode(bg_result._sync_response)
        if not response then
            return false, "Failed to parse response JSON", elapsed
        end
        local parse_ok, text = result._response_parser(response)
        if not parse_ok then
            return false, text, elapsed
        end
        return true, text, elapsed
    else
        return false, "Unexpected result type: " .. type(result), elapsed
    end
end

return TestHelpers
