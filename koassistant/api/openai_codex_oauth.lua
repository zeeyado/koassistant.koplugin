local json = require("json")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local BaseHandler = require("koassistant.api.base")
local _ = require("koassistant.core.gettext")

local OAuth = {}
local unpackValues = table.unpack or unpack

OAuth.CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
OAuth.SETTINGS_KEY = "openai_codex_oauth"
OAuth.USER_CODE_URL = "https://auth.openai.com/api/accounts/deviceauth/usercode"
OAuth.DEVICE_TOKEN_URL = "https://auth.openai.com/api/accounts/deviceauth/token"
OAuth.OAUTH_TOKEN_URL = "https://auth.openai.com/oauth/token"
OAuth.REDIRECT_URI = "https://auth.openai.com/deviceauth/callback"
OAuth.VERIFICATION_URL = "https://auth.openai.com/codex/device"
OAuth.REFRESH_SKEW_SECONDS = 300
OAuth.FLOW_TIMEOUT_SECONDS = 15 * 60

local AUTH_CLAIM = "https://api.openai.com/auth"

local function str(value)
    return type(value) == "string" and value ~= "" and value or nil
end

local function number(value)
    if type(value) == "number" then return value end
    if type(value) == "string" then return tonumber(value) end
    return nil
end

local function urlEncode(value)
    return (tostring(value or ""):gsub("([^%w%-%._~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
end

local FORM_ORDER = { "grant_type", "client_id", "code", "redirect_uri", "code_verifier", "refresh_token" }
local function formEncode(values)
    local parts = {}
    for _idx, key in ipairs(FORM_ORDER) do
        if values[key] ~= nil then
            parts[#parts + 1] = urlEncode(key) .. "=" .. urlEncode(values[key])
        end
    end
    return table.concat(parts, "&")
end

local function b64urlDecode(segment)
    if not str(segment) then return nil end
    local encoded = segment:gsub("-", "+"):gsub("_", "/")
    local remainder = #encoded % 4
    if remainder == 2 then encoded = encoded .. "=="
    elseif remainder == 3 then encoded = encoded .. "="
    elseif remainder == 1 then return nil end

    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    if encoded:find("[^A-Za-z0-9+/=]") then return nil end
    local bits = encoded:gsub(".", function(char)
        if char == "=" then return "" end
        local value = (alphabet:find(char, 1, true) or 1) - 1
        local out = ""
        for i = 6, 1, -1 do
            out = out .. ((value % 2^i - value % 2^(i - 1) > 0) and "1" or "0")
        end
        return out
    end)
    return bits:gsub("%d%d%d?%d?%d?%d?%d?%d?", function(byte)
        if #byte ~= 8 then return "" end
        local value = 0
        for i = 1, 8 do
            if byte:sub(i, i) == "1" then value = value + 2^(8 - i) end
        end
        return string.char(value)
    end)
end

function OAuth.parseJwtPayload(token)
    if type(token) ~= "string" then return nil end
    local payload_segment = token:match("^[^.]+%.([^.]+)%.[^.]+$")
    if not payload_segment then return nil end
    local raw = b64urlDecode(payload_segment)
    local ok, payload = pcall(json.decode, raw or "")
    if not ok or type(payload) ~= "table" then return nil end
    local auth = type(payload[AUTH_CLAIM]) == "table" and payload[AUTH_CLAIM] or {}
    return {
        exp = number(payload.exp),
        chatgpt_account_id = str(auth.chatgpt_account_id),
        raw = payload,
    }
end

function OAuth.normalizeTokenSet(token_set, fallback_refresh_token, now)
    if type(token_set) ~= "table" then return nil end
    now = now or os.time()
    local normalized = {
        access_token = str(token_set.access_token),
        refresh_token = str(token_set.refresh_token) or str(fallback_refresh_token),
        token_type = str(token_set.token_type) or "Bearer",
        scope = str(token_set.scope),
        updated_at = now,
    }
    local payload = OAuth.parseJwtPayload(normalized.access_token)
    normalized.expires_at = payload and payload.exp
        or number(token_set.expires_at)
        or (number(token_set.expires_in) and now + number(token_set.expires_in))
    normalized.chatgpt_account_id = payload and payload.chatgpt_account_id
        or str(token_set.chatgpt_account_id)
    return normalized
end

function OAuth.shouldRefresh(auth, now, skew)
    now = now or os.time()
    skew = skew or OAuth.REFRESH_SKEW_SECONDS
    if type(auth) ~= "table" or not str(auth.access_token) then return true end
    local expires_at = number(auth.expires_at)
    return not expires_at or expires_at <= now + skew
end

local function jsonRequest(url, body)
    return {
        url = url,
        method = "POST",
        headers = { ["Content-Type"] = "application/json" },
        body = json.encode(body),
    }
end

function OAuth.buildUserCodeRequest()
    return jsonRequest(OAuth.USER_CODE_URL, { client_id = OAuth.CLIENT_ID })
end

function OAuth.buildPollRequest(device_auth_id, user_code)
    return jsonRequest(OAuth.DEVICE_TOKEN_URL, {
        device_auth_id = device_auth_id,
        user_code = user_code,
    })
end

function OAuth.buildTokenExchangeRequest(authorization_code, code_verifier)
    return {
        url = OAuth.OAUTH_TOKEN_URL,
        method = "POST",
        headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
        body = formEncode({
            grant_type = "authorization_code",
            client_id = OAuth.CLIENT_ID,
            code = authorization_code,
            redirect_uri = OAuth.REDIRECT_URI,
            code_verifier = code_verifier,
        }),
    }
end

function OAuth.buildRefreshRequest(refresh_token)
    return {
        url = OAuth.OAUTH_TOKEN_URL,
        method = "POST",
        headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
        body = formEncode({
            grant_type = "refresh_token",
            client_id = OAuth.CLIENT_ID,
            refresh_token = refresh_token,
        }),
    }
end

local function decodeBody(body)
    if not str(body) then return nil end
    local ok, decoded = pcall(json.decode, body)
    return ok and type(decoded) == "table" and decoded or nil
end

local function errorMessage(status_code, body)
    local decoded = decodeBody(body)
    if decoded then
        if type(decoded.error) == "table" and str(decoded.error.message) then return decoded.error.message end
        if str(decoded.error_description) then return decoded.error_description end
        if str(decoded.error) then return decoded.error end
        if str(decoded.message) then return decoded.message end
    end
    -- Do not surface raw OAuth bodies: token endpoints can contain credential
    -- material and UI errors may be captured in screenshots or logs.
    return string.format("HTTP %s", tostring(status_code))
end

function OAuth.classifyPollResponse(status_code, body)
    if status_code == 403 or status_code == 404 then return { status = "pending" } end
    if status_code == 429 then return { status = "slow_down" } end
    local decoded = decodeBody(body)
    if status_code == 200 and decoded then
        local authorization_code = str(decoded.authorization_code)
        local code_verifier = str(decoded.code_verifier)
        if authorization_code and code_verifier then
            return {
                status = "authorized",
                authorization_code = authorization_code,
                code_verifier = code_verifier,
            }
        end
    end
    return { status = "error", error = errorMessage(status_code, body) }
end

local function httpRequestSync(request)
    local headers = {}
    for key, value in pairs(request.headers or {}) do headers[key] = value end
    if request.body then headers["Content-Length"] = tostring(#request.body) end
    return BaseHandler.fetchInSubprocess(request.url, {
        method = request.method,
        headers = headers,
        body = request.body,
        resolved_ip = request.resolved_ip or BaseHandler.resolveForSubprocess(request.url),
        timeout = request.timeout or 30,
    })
end


function OAuth.readAuth(settings)
    if not settings then return nil end
    local features = settings:readSetting("features") or {}
    return type(features[OAuth.SETTINGS_KEY]) == "table" and features[OAuth.SETTINGS_KEY] or nil
end

function OAuth.saveAuth(settings, auth)
    if not settings or type(auth) ~= "table" then return false end
    local features = settings:readSetting("features") or {}
    features[OAuth.SETTINGS_KEY] = auth
    settings:saveSetting("features", features)
    settings:flush()
    return true
end

function OAuth.clearAuth(settings)
    if not settings then return false end
    local features = settings:readSetting("features") or {}
    features[OAuth.SETTINGS_KEY] = nil
    settings:saveSetting("features", features)
    settings:flush()
    return true
end

function OAuth.isConfigured(settings)
    local auth = OAuth.readAuth(settings)
    return type(auth) == "table" and str(auth.refresh_token) ~= nil
        and str(auth.chatgpt_account_id) ~= nil
end


local function makePipeFetchFn(request)
    return function(pid, child_write_fd)
        if not pid or not child_write_fd then return end
        local ok, status_code, body = pcall(httpRequestSync, request)
        local payload = ok
            and json.encode({ status_code = status_code, body = body or "" })
            or json.encode({ status_code = 0, body = tostring(status_code) })
        BaseHandler.writeAllToFD(child_write_fd, payload)
        ffi.C.close(child_write_fd)
        pcall(function() ffi.C._exit(0) end)
    end
end

local function pollSubprocess(pid, read_fd, on_done)
    local UIManager = require("ui/uimanager")
    local chunk_size = 65536
    local buffer = ffi.new("char[?]", chunk_size)
    -- The reads below take the buffer itself: a pointer cast from it keeps
    -- nothing alive, and the poll runs long after this function returned,
    -- when the buffer's own variable is gone and LuaJIT may have freed it
    -- (the child's bytes then land in memory that is in use: B769)
    local parts = {}

    local function finish()
        ffi.C.close(read_fd)
        on_done(table.concat(parts))
    end

    local function poll()
        while true do
            local available = ffiutil.getNonBlockingReadSize(read_fd) or 0
            if available > 0 then
                local bytes = tonumber(ffi.C.read(read_fd, buffer, chunk_size))
                if bytes and bytes > 0 then parts[#parts + 1] = ffi.string(buffer, bytes)
                else finish() return end
            elseif ffiutil.isSubProcessDone(pid) then
                while true do
                    local bytes = tonumber(ffi.C.read(read_fd, buffer, chunk_size))
                    if not bytes or bytes <= 0 then break end
                    parts[#parts + 1] = ffi.string(buffer, bytes)
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
end

local function runAsync(request, on_done)
    -- DNS/libc resolution is unsafe after fork on macOS. Resolve in the parent,
    -- matching BaseHandler's subprocess contract.
    request.resolved_ip = BaseHandler.resolveForSubprocess(request.url)
    local pid, read_fd = ffiutil.runInSubProcess(makePipeFetchFn(request), true)
    if not pid then on_done(nil, _("Failed to start OAuth subprocess.")); return nil end
    pollSubprocess(pid, read_fd, function(raw)
        local decoded = decodeBody(raw)
        if not decoded then on_done(nil, _("Failed to parse OAuth subprocess response.")); return end
        on_done(decoded)
    end)
    return pid
end

local asyncRunner = runAsync
function OAuth._setAsyncRunnerForTests(runner)
    asyncRunner = runner or runAsync
end

function OAuth.resolveAccessTokenAsync(settings, on_done)
    local auth = OAuth.readAuth(settings)
    if not auth then
        on_done(nil, _("OpenAI Subscription is not connected."))
        return nil
    end
    if not OAuth.shouldRefresh(auth) then
        on_done(auth)
        return nil
    end

    local ok, pid_or_err = pcall(function()
        return asyncRunner(OAuth.buildRefreshRequest(auth.refresh_token), function(result, transport_err)
            if transport_err then
                on_done(nil, transport_err)
                return
            end
            if not result or result.status_code ~= 200 then
                on_done(nil, errorMessage(result and result.status_code, result and result.body))
                return
            end
            local refreshed = OAuth.normalizeTokenSet(decodeBody(result.body), auth.refresh_token)
            if not (refreshed and refreshed.access_token and refreshed.refresh_token and refreshed.chatgpt_account_id) then
                on_done(nil, _("Refresh response was incomplete."))
                return
            end
            OAuth.saveAuth(settings, refreshed)
            on_done(refreshed)
        end)
    end)
    if not ok or not pid_or_err then
        on_done(nil, ok and _("Failed to start OAuth refresh subprocess.") or tostring(pid_or_err))
        return nil
    end
    return pid_or_err
end

local function selectProviderIfFirst(plugin)
    if not (plugin and plugin.settings) then return end
    local features = plugin.settings:readSetting("features") or {}
    local Base = require("koassistant.api.base")
    local ModelLists = require("koassistant.request.model_lists")
    local has_key = false
    for _idx, provider in ipairs(ModelLists.getAllProviders()) do
        if provider ~= "openai_codex" and Base.getApiKey(provider, plugin.settings) then
            has_key = true
            break
        end
    end
    if not has_key then
        features.provider = "openai_codex"
        features.model = nil
        plugin.settings:saveSetting("features", features)
        plugin.settings:flush()
    end
end

function OAuth.showManageDialog(plugin)
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local Notification = require("ui/widget/notification")
    local auth = OAuth.readAuth(plugin and plugin.settings)
    local connected = OAuth.isConfigured(plugin and plugin.settings)
    local dialog
    local buttons = {}
    buttons[#buttons + 1] = {{
        text = connected and _("Reconnect") or _("Connect"),
        callback = function()
            UIManager:close(dialog)
            OAuth.startInteractiveConnect(plugin)
        end,
    }}
    if connected then
        buttons[#buttons + 1] = {{
            text = _("Disconnect"),
            callback = function()
                OAuth.clearAuth(plugin.settings)
                if plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
                UIManager:close(dialog)
                UIManager:show(Notification:new{ text = _("OpenAI Subscription disconnected"), timeout = 2 })
            end,
        }}
    end
    buttons[#buttons + 1] = {{ text = _("Close"), callback = function() UIManager:close(dialog) end }}
    dialog = ButtonDialog:new{
        title = connected and _("OpenAI Subscription · Connected") or _("OpenAI Subscription · Not connected"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function OAuth.buildDeviceDialogText(user_code, status_message)
    local lines = {
        _("Unofficial integration. It may stop working if OpenAI changes the Codex service."),
        "",
        _("Open this URL on another device:"),
        OAuth.VERIFICATION_URL,
        "",
        _("Enter this code:"),
        tostring(user_code or ""),
        "",
        _("The code expires in 15 minutes."),
    }
    if status_message and status_message ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = status_message
    end
    return table.concat(lines, "\n")
end

local function showConnectEntryError(message)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{
        text = _("OpenAI Subscription connection failed.") .. "\n\n" .. tostring(message),
        timeout = 5,
    })
end

local function startInteractiveConnectOnline(plugin, on_done)
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local Notification = require("ui/widget/notification")
    local Device = require("device")

    local active_pid
    local stopped = false
    local in_flight = false
    local device
    local dialog

    local function closeDialog()
        if dialog then
            UIManager:close(dialog)
            dialog = nil
        end
    end

    local function cancel()
        if stopped then return end
        stopped = true
        if active_pid then
            ffiutil.terminateSubProcess(active_pid)
            active_pid = nil
        end
        closeDialog()
        if on_done then on_done(false) end
    end

    local function guarded(fn)
        return function(...)
            if stopped then return end
            local args = { ... }
            local ok, err = xpcall(function() fn(unpackValues(args)) end, debug.traceback)
            if not ok then
                cancel()
                showConnectEntryError(err)
            end
        end
    end

    local function request(req, callback)
        if stopped or in_flight then return false end
        in_flight = true
        local ok, pid_or_err = pcall(function()
            return asyncRunner(req, guarded(function(result, err)
                active_pid = nil
                in_flight = false
                if err then
                    cancel()
                    showConnectEntryError(err)
                else
                    callback(result)
                end
            end))
        end)
        if not ok or not pid_or_err then
            in_flight = false
            cancel()
            showConnectEntryError(ok and _("Failed to start OAuth subprocess.") or pid_or_err)
            return false
        end
        active_pid = pid_or_err
        return true
    end

    local showDeviceDialog
    local function showStatus(message)
        if stopped then return end
        if dialog and dialog.setTitle and device then
            dialog:setTitle(OAuth.buildDeviceDialogText(device.user_code, message))
        else
            closeDialog()
            showDeviceDialog(message)
        end
    end

    local function exchange(state)
        showStatus(_("Authorization received. Connecting…"))
        request(OAuth.buildTokenExchangeRequest(state.authorization_code, state.code_verifier), function(exchange_result)
            if exchange_result.status_code ~= 200 then
                showStatus(errorMessage(exchange_result.status_code, exchange_result.body))
                return
            end
            local auth = OAuth.normalizeTokenSet(decodeBody(exchange_result.body))
            if not (auth and auth.access_token and auth.refresh_token and auth.chatgpt_account_id) then
                showStatus(_("OpenAI Subscription connection returned incomplete tokens."))
                return
            end
            OAuth.saveAuth(plugin.settings, auth)
            selectProviderIfFirst(plugin)
            if plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
            stopped = true
            closeDialog()
            UIManager:show(Notification:new{ text = _("OpenAI Subscription connected"), timeout = 3 })
            if on_done then on_done(true) end
        end)
    end

    local function checkAuthorization()
        if stopped or in_flight or not device then return end
        if os.time() >= device.expires_at then
            showStatus(_("This device code has expired. Cancel and connect again."))
            return
        end
        showStatus(_("Checking authorization…"))
        request(OAuth.buildPollRequest(device.device_auth_id, device.user_code), function(result)
            local state = OAuth.classifyPollResponse(result.status_code, result.body)
            if state.status == "pending" then
                showStatus(_("Not authorized yet. Complete the browser steps, then check again."))
            elseif state.status == "slow_down" then
                showStatus(_("Please wait a few seconds before checking again."))
            elseif state.status == "authorized" then
                exchange(state)
            else
                showStatus(state.error or _("Authorization check failed."))
            end
        end)
    end

    showDeviceDialog = function(status_message)
        if stopped or not device then return end
        local buttons = {
            {
                {
                    text = _("Copy code"),
                    callback = guarded(function()
                        if Device and Device.input and Device.input.setClipboardText then
                            Device.input.setClipboardText(device.user_code)
                            UIManager:show(Notification:new{ text = _("Device code copied"), timeout = 2 })
                        else
                            UIManager:show(Notification:new{ text = _("Clipboard is not available on this device."), timeout = 2 })
                        end
                    end),
                },
                {
                    text = _("Check authorization"),
                    callback = guarded(checkAuthorization),
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = cancel,
                },
            },
        }
        dialog = ButtonDialog:new{
            title = OAuth.buildDeviceDialogText(device.user_code, status_message),
            buttons = buttons,
            -- ButtonDialog has no title-bar close callback. Requiring the explicit
            -- Cancel button prevents a tap-outside/back dismissal from leaving a
            -- subprocess alive and later resurrecting the dialog from its callback.
            dismissable = false,
        }
        UIManager:show(dialog)
    end

    dialog = ButtonDialog:new{
        title = _("Requesting an OpenAI device code…"),
        buttons = {{ { text = _("Cancel"), callback = cancel } }},
        dismissable = false,
    }
    UIManager:show(dialog)

    request(OAuth.buildUserCodeRequest(), function(result)
        if result.status_code ~= 200 then
            cancel()
            local message = result.status_code == 404
                and _("Device-code login is not enabled for this account or workspace.")
                or errorMessage(result.status_code, result.body)
            showConnectEntryError(message)
            return
        end
        local payload = decodeBody(result.body)
        device = payload and {
            device_auth_id = str(payload.device_auth_id),
            user_code = str(payload.user_code) or str(payload.usercode),
            interval = math.max(3, number(payload.interval) or 5),
            expires_at = os.time() + OAuth.FLOW_TIMEOUT_SECONDS,
        }
        if not (device and device.device_auth_id and device.user_code) then
            cancel()
            showConnectEntryError(_("Device authorization response was incomplete."))
            return
        end
        closeDialog()
        showDeviceDialog()
    end)
end

-- on_done(connected) runs once the flow ends (the wizard's chain goes on).
function OAuth.startInteractiveConnect(plugin, on_done)
    if not (plugin and plugin.settings) then return end
    local ok, err = xpcall(function()
        local NetworkMgr = require("ui/network/manager")
        NetworkMgr:runWhenConnected(function()
            local online_ok, online_err = xpcall(function()
                startInteractiveConnectOnline(plugin, on_done)
            end, debug.traceback)
            if not online_ok then showConnectEntryError(online_err) end
        end)
    end, debug.traceback)
    if not ok then showConnectEntryError(err) end
end

return OAuth
