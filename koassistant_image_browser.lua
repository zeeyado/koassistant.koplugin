--[[--
KOAssistant Generated Images browser (PR #96 polish).

Lists images produced by koassistant_image_generator.lua — kept in
data_dir/koassistant_images, filenames carry the metadata (date + prompt
snippet). Tap = view, hold = delete (confirm), title-bar menu = delete all.
]]

local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local Screen = require("device").screen
local lfs = require("libs/libkoreader-lfs")
local ImageGenerator = require("koassistant_image_generator")
local _ = require("koassistant_gettext")
local T = require("ffi/util").template

local ImageBrowser = {}

local function listImages()
    local dir = ImageGenerator.getImagesDir()
    local files = {}
    if not lfs.attributes(dir, "mode") then return files end
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local path = dir .. "/" .. entry
            local attr = lfs.attributes(path)
            if attr and attr.mode == "file" then
                table.insert(files, {
                    name = entry,
                    path = path,
                    mtime = attr.modification or 0,
                    size = attr.size or 0,
                })
            end
        end
    end
    table.sort(files, function(a, b) return a.mtime > b.mtime end)
    return files
end

local function viewImage(path)
    local ok, ImageViewer = pcall(require, "ui/widget/imageviewer")
    if not ok then return end
    UIManager:show(ImageViewer:new{
        file = path,
        with_title_bar = true,
        title_text = path:match("([^/]+)%.%w+$") or path:match("([^/]+)$"),
        is_doc_page = false,
    })
end

function ImageBrowser.show()
    local files = listImages()
    if #files == 0 then
        UIManager:show(InfoMessage:new{ text = _("No generated images yet.") })
        return
    end

    local menu
    local items = {}
    for _idx, f in ipairs(files) do
        local display = f.name:gsub("%.png$", "")
        table.insert(items, {
            text = display,
            mandatory = string.format("%d KB", math.floor(f.size / 1024 + 0.5)),
            mandatory_dim = true,
            callback = function() viewImage(f.path) end,
            hold_callback = function()
                UIManager:show(ConfirmBox:new{
                    text = T(_("Delete this image?\n\n%1"), display),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        os.remove(f.path)
                        UIManager:close(menu)
                        ImageBrowser.show()
                    end,
                })
            end,
        })
    end

    menu = Menu:new{
        title = T(_("Generated Images (%1)"), #files),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            UIManager:show(ConfirmBox:new{
                text = T(_("Delete all %1 generated images?"), #files),
                ok_text = _("Delete all"),
                ok_callback = function()
                    for _idx, f in ipairs(files) do
                        os.remove(f.path)
                    end
                    UIManager:close(menu)
                    UIManager:show(InfoMessage:new{ text = _("All generated images deleted.") })
                end,
            })
        end,
        -- Item tap/hold dispatch (same pattern as the notebook browser)
        onMenuSelect = function(_self_menu, item)
            if item and item.callback then item.callback() end
            return true
        end,
        onMenuHold = function(_self_menu, item)
            if item and item.hold_callback then item.hold_callback() end
            return true
        end,
        multilines_show_more_text = true,
        items_max_lines = 2,
        single_line = false,
        multilines_forced = true,
        items_font_size = 18,
        items_mandatory_font_size = 14,
    }
    UIManager:show(menu)
end

return ImageBrowser
