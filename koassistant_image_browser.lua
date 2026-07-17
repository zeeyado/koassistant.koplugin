--[[--
KOAssistant Generated Images browser (PR #96 polish).

Lists images produced by koassistant_image_generator.lua — kept in
data_dir/koassistant_images, filenames carry the metadata (date + prompt
snippet). Tap = view, hold = delete (confirm), title-bar menu = delete all.

show(opts): opts.book_file (+ opts.book_title for the title) filters to
images generated for that book, via the generator's book-association index
(per-book entry from the artifact browser). Deletion keeps the index in
sync; "Delete all" respects the active filter.
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

local function listImages(book_file)
    local dir = ImageGenerator.getImagesDir()
    local files = {}
    if not lfs.attributes(dir, "mode") then return files end
    local index = book_file and ImageGenerator.readIndex() or nil
    -- LuaSettings:flush() also leaves a "<index>.old" backup — skip both
    local idx_name = ImageGenerator.getIndexFilename()
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." and entry ~= idx_name
            and entry ~= idx_name .. ".old" then
            local path = dir .. "/" .. entry
            local attr = lfs.attributes(path)
            local include = attr and attr.mode == "file"
            if include and index then
                local ie = index[entry]
                include = type(ie) == "table" and ie.book_file == book_file
            end
            if include then
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

--- Show the gallery. opts (optional): { book_file, book_title } filters to
--- images generated for that book.
function ImageBrowser.show(opts)
    local book_file = opts and opts.book_file
    local files = listImages(book_file)
    if #files == 0 then
        UIManager:show(InfoMessage:new{
            text = book_file and _("No generated images for this document.")
                or _("No generated images yet.") })
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
                        ImageGenerator.removeIndexEntries({ f.name })
                        UIManager:close(menu)
                        ImageBrowser.show(opts)
                    end,
                })
            end,
        })
    end

    local title
    if book_file then
        local book_label = (opts and opts.book_title)
            or book_file:match("([^/]+)$") or book_file
        title = T(_("Generated Images: %1 (%2)"), book_label, #files)
    else
        title = T(_("Generated Images (%1)"), #files)
    end

    menu = Menu:new{
        title = title,
        item_table = items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            UIManager:show(ConfirmBox:new{
                text = book_file and T(_("Delete all %1 images for this document?"), #files)
                    or T(_("Delete all %1 generated images?"), #files),
                ok_text = _("Delete all"),
                ok_callback = function()
                    local names = {}
                    for _idx, f in ipairs(files) do
                        os.remove(f.path)
                        table.insert(names, f.name)
                    end
                    ImageGenerator.removeIndexEntries(names)
                    UIManager:close(menu)
                    UIManager:show(InfoMessage:new{
                        text = book_file and _("Images for this document deleted.")
                            or _("All generated images deleted.") })
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
