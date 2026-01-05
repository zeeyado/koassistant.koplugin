-- Terminal Formatter for Request Inspector
-- Provides ANSI colors, box drawing, and table rendering

local TerminalFormatter = {}

-- ANSI color codes
TerminalFormatter.colors = {
    reset = "\27[0m",
    bold = "\27[1m",
    dim = "\27[2m",

    -- Foreground colors
    red = "\27[31m",
    green = "\27[32m",
    yellow = "\27[33m",
    blue = "\27[34m",
    magenta = "\27[35m",
    cyan = "\27[36m",
    white = "\27[37m",
    gray = "\27[90m",

    -- Background colors
    bg_red = "\27[41m",
    bg_green = "\27[42m",
    bg_yellow = "\27[43m",
    bg_blue = "\27[44m",
}

local c = TerminalFormatter.colors

-- Box drawing characters
TerminalFormatter.box = {
    -- Single line
    h = "─",      -- horizontal
    v = "│",      -- vertical
    tl = "┌",     -- top left
    tr = "┐",     -- top right
    bl = "└",     -- bottom left
    br = "┘",     -- bottom right
    lt = "├",     -- left tee
    rt = "┤",     -- right tee
    tt = "┬",     -- top tee
    bt = "┴",     -- bottom tee
    cross = "┼",  -- cross

    -- Tree
    branch = "├─",
    last = "└─",
    pipe = "│ ",
}

local box = TerminalFormatter.box

-- Helper: Get visible length of string (ignoring ANSI codes)
function TerminalFormatter.visibleLength(str)
    if not str then return 0 end
    return #str:gsub("\27%[[%d;]*m", "")
end

-- Helper: Pad string to width
function TerminalFormatter.pad(str, width, align)
    local visible = TerminalFormatter.visibleLength(str)
    local padding = width - visible
    if padding <= 0 then return str end

    align = align or "left"
    if align == "right" then
        return string.rep(" ", padding) .. str
    elseif align == "center" then
        local left = math.floor(padding / 2)
        local right = padding - left
        return string.rep(" ", left) .. str .. string.rep(" ", right)
    else
        return str .. string.rep(" ", padding)
    end
end

-- Helper: Truncate string to max width
function TerminalFormatter.truncate(str, max_width)
    if not str then return "" end
    local visible = TerminalFormatter.visibleLength(str)
    if visible <= max_width then return str end

    -- Simple truncation (doesn't handle ANSI codes perfectly)
    return str:sub(1, max_width - 3) .. "..."
end

-- Helper: Word wrap text
function TerminalFormatter.wordWrap(text, width)
    if not text then return {} end

    local lines = {}
    for line in text:gmatch("[^\n]+") do
        while #line > width do
            local break_at = width
            -- Try to break at a space
            local space = line:sub(1, width):match(".*()%s")
            if space and space > width * 0.5 then
                break_at = space
            end
            table.insert(lines, line:sub(1, break_at))
            line = line:sub(break_at + 1):gsub("^%s+", "")
        end
        if #line > 0 then
            table.insert(lines, line)
        end
    end
    return lines
end

-- Print a colored header line
function TerminalFormatter.header(title, width)
    width = width or 80
    local line = string.rep("=", width)
    print("")
    print(c.bold .. c.cyan .. line .. c.reset)
    print(c.bold .. c.cyan .. "  " .. title .. c.reset)
    print(c.bold .. c.cyan .. line .. c.reset)
end

-- Print a section header
function TerminalFormatter.section(title, width)
    width = width or 80
    local line = string.rep("-", width)
    print("")
    print(c.dim .. line .. c.reset)
    print(c.bold .. "  " .. title .. c.reset)
    print(c.dim .. line .. c.reset)
end

-- Print a boxed content block
function TerminalFormatter.box_content(content, width, indent)
    width = width or 76
    indent = indent or 2
    local prefix = string.rep(" ", indent)

    local lines = TerminalFormatter.wordWrap(content, width - 4)

    -- Top border
    print(prefix .. c.dim .. box.tl .. string.rep(box.h, width - 2) .. box.tr .. c.reset)

    -- Content lines
    for _, line in ipairs(lines) do
        local padded = TerminalFormatter.pad(line, width - 4)
        print(prefix .. c.dim .. box.v .. c.reset .. " " .. padded .. " " .. c.dim .. box.v .. c.reset)
    end

    -- Bottom border
    print(prefix .. c.dim .. box.bl .. string.rep(box.h, width - 2) .. box.br .. c.reset)
end

-- Print a key-value tree (for config summary)
function TerminalFormatter.tree(items, indent)
    indent = indent or 2
    local prefix = string.rep(" ", indent)

    for i, item in ipairs(items) do
        local branch = (i == #items) and box.last or box.branch
        local key = item[1]
        local value = item[2]
        local color = item[3] or ""

        print(prefix .. c.dim .. branch .. c.reset .. " " ..
              c.bold .. key .. ":" .. c.reset .. "  " ..
              color .. tostring(value) .. c.reset)
    end
end

-- Print a comparison table
function TerminalFormatter.table(headers, rows, col_widths)
    if not col_widths then
        -- Auto-calculate widths
        col_widths = {}
        for i, h in ipairs(headers) do
            col_widths[i] = TerminalFormatter.visibleLength(h)
        end
        for _, row in ipairs(rows) do
            for i, cell in ipairs(row) do
                local len = TerminalFormatter.visibleLength(tostring(cell))
                if len > (col_widths[i] or 0) then
                    col_widths[i] = len
                end
            end
        end
        -- Add padding
        for i = 1, #col_widths do
            col_widths[i] = col_widths[i] + 2
        end
    end

    local function row_sep(left, mid, right, fill)
        local parts = {}
        for i, w in ipairs(col_widths) do
            table.insert(parts, string.rep(fill, w))
        end
        print("  " .. c.dim .. left .. table.concat(parts, mid) .. right .. c.reset)
    end

    local function row_content(cells, is_header)
        local parts = {}
        for i, cell in ipairs(cells) do
            local padded = TerminalFormatter.pad(tostring(cell), col_widths[i] - 2, "left")
            table.insert(parts, " " .. padded .. " ")
        end
        local content = table.concat(parts, c.dim .. box.v .. c.reset)
        if is_header then
            print("  " .. c.dim .. box.v .. c.reset .. c.bold .. content .. c.reset .. c.dim .. box.v .. c.reset)
        else
            print("  " .. c.dim .. box.v .. c.reset .. content .. c.dim .. box.v .. c.reset)
        end
    end

    -- Top border
    row_sep(box.tl, box.tt, box.tr, box.h)

    -- Header row
    row_content(headers, true)

    -- Header separator
    row_sep(box.lt, box.cross, box.rt, box.h)

    -- Data rows
    for _, row in ipairs(rows) do
        row_content(row, false)
    end

    -- Bottom border
    row_sep(box.bl, box.bt, box.br, box.h)
end

-- Print JSON with syntax highlighting
function TerminalFormatter.json(data, indent_level)
    indent_level = indent_level or 0
    local json_module = require("json")

    local function highlight_json(str)
        -- Keys
        str = str:gsub('"([^"]+)":', c.cyan .. '"%1":' .. c.reset)
        -- String values (not keys)
        str = str:gsub(': "([^"]*)"', ': ' .. c.green .. '"%1"' .. c.reset)
        -- Numbers
        str = str:gsub(': (%d+%.?%d*)', ': ' .. c.yellow .. '%1' .. c.reset)
        -- Booleans
        str = str:gsub(': (true)', ': ' .. c.magenta .. '%1' .. c.reset)
        str = str:gsub(': (false)', ': ' .. c.magenta .. '%1' .. c.reset)
        -- Null
        str = str:gsub(': (null)', ': ' .. c.dim .. '%1' .. c.reset)
        return str
    end

    local json_str = json_module.encode(data)
    -- Pretty print
    local pretty = ""
    local indent = 0
    local in_string = false

    for i = 1, #json_str do
        local char = json_str:sub(i, i)

        if char == '"' and json_str:sub(i-1, i-1) ~= '\\' then
            in_string = not in_string
        end

        if not in_string then
            if char == '{' or char == '[' then
                indent = indent + 1
                pretty = pretty .. char .. "\n" .. string.rep("  ", indent)
            elseif char == '}' or char == ']' then
                indent = indent - 1
                pretty = pretty .. "\n" .. string.rep("  ", indent) .. char
            elseif char == ',' then
                pretty = pretty .. char .. "\n" .. string.rep("  ", indent)
            elseif char == ':' then
                pretty = pretty .. ": "
            else
                pretty = pretty .. char
            end
        else
            pretty = pretty .. char
        end
    end

    -- Add base indentation
    local base_indent = string.rep("  ", indent_level)
    for line in pretty:gmatch("[^\n]+") do
        print(base_indent .. highlight_json(line))
    end
end

-- Print a labeled value
function TerminalFormatter.labeled(label, value, label_width)
    label_width = label_width or 16
    local padded_label = TerminalFormatter.pad(label .. ":", label_width)
    print("  " .. c.dim .. padded_label .. c.reset .. tostring(value))
end

-- Print success/fail/skip status
function TerminalFormatter.status(text, status)
    local icon, color
    if status == "pass" or status == "success" then
        icon = "✓"
        color = c.green
    elseif status == "fail" or status == "error" then
        icon = "✗"
        color = c.red
    elseif status == "skip" then
        icon = "⊘"
        color = c.yellow
    else
        icon = "•"
        color = c.dim
    end

    print("  " .. color .. icon .. " " .. text .. c.reset)
end

-- Print a divider
function TerminalFormatter.divider(width, char)
    width = width or 80
    char = char or "─"
    print(c.dim .. string.rep(char, width) .. c.reset)
end

return TerminalFormatter
