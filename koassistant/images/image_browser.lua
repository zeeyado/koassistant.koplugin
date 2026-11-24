--[[--
KOAssistant Generated Images gallery (PR #96; thumbnails, Regenerate and
the books list: image round S7).

Pictures made by koassistant/images/image_generator.lua live in
data_dir/koassistant_images with their thumbnails (thumbnails/) and the
images index (book, prompt, provenance, who drew it, the kinds of the
reader's data its prompt carries). show() opens on a list when the pictures
come from more than one place (All images, each book with the newest
picture first, Without a book), else on the pictures themselves: a grid of
thumbnails (koassistant/images/image_grid.lua; a device without a
touchscreen keeps the list of names). Tap = the picture with its prompt as
the caption; hold = the prompt with Regenerate (beside the old picture, or
in its place), Edit prompt…, Image settings… (koassistant/images/
image_options.lua: the settings rows, then Regenerate; S9) and Delete
image…; ☰ = delete all of the set shown. Thumbnails the grid lacks are made
when their page is first shown.

show(opts): opts.book_file (+ opts.book_title for the title) = that book's
pictures (the per-book entry points).
]]

local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Screen = Device.screen
local lfs = require("libs/libkoreader-lfs")
local ImageGenerator = require("koassistant.images.image_generator")
local _ = require("koassistant.core.gettext")
local T = require("ffi/util").template

local ImageBrowser = {}

-- The file types the generator saves
local IMAGE_EXTENSIONS = { png = true, jpg = true, jpeg = true, webp = true }

-- Pictures whose thumbnail could not be made this session (not retried)
local no_thumb = {}

--- Every picture in the images folder, newest first.
local function listImages()
    local dir = ImageGenerator.getImagesDir()
    local files = {}
    if not lfs.attributes(dir, "mode") then return files end
    for entry in lfs.dir(dir) do
        local ext = entry:match("%.(%w+)$")
        if ext and IMAGE_EXTENSIONS[ext:lower()] then
            local path = dir .. "/" .. entry
            local attr = lfs.attributes(path)
            if attr and attr.mode == "file" then
                files[#files + 1] = {
                    name = entry,
                    path = path,
                    mtime = attr.modification or 0,
                    size = attr.size or 0,
                }
            end
        end
    end
    table.sort(files, function(a, b) return a.mtime > b.mtime end)
    return files
end

local function bookOf(index, name)
    local ie = index[name]
    return type(ie) == "table" and type(ie.book_file) == "string" and ie.book_file or nil
end

--- The places the pictures come from: All images first, then each book (the
--- one with the newest picture first), then Without a book. files = newest
--- first, index = the images index. Pure.
--- @return table { { key = "all" | book_file | "none", title, files }, ... }
function ImageBrowser.groups(files, index)
    local by_book, order, none = {}, {}, {}
    for _idx, f in ipairs(files) do
        local book = bookOf(index, f.name)
        if book then
            local g = by_book[book]
            if not g then
                g = { key = book, files = {} }
                by_book[book] = g
                order[#order + 1] = book
            end
            local title = index[f.name].book_title
            if not g.title and type(title) == "string" and title ~= "" then g.title = title end
            g.files[#g.files + 1] = f
        else
            none[#none + 1] = f
        end
    end
    local out = { { key = "all", title = _("All images"), files = files } }
    for _idx, book in ipairs(order) do
        local g = by_book[book]
        g.title = g.title or book:match("([^/]+)$") or book
        out[#out + 1] = g
    end
    if #none > 0 then
        out[#out + 1] = { key = "none", title = _("Without a book"), files = none }
    end
    return out
end

--- How many pictures the gallery's All images shows (Browse by type's count).
function ImageBrowser.count()
    return #listImages()
end

--- The pictures of one place (a groups() key), or of one X-Ray entry (B486:
--- a table key { book, names, others, main }, ImageGenerator.picturesOf's).
local function filesOf(key, files, index)
    if key == "all" then return files end
    local out = {}
    if type(key) == "table" then
        local wanted = {}
        for _idx, name in ipairs(ImageGenerator.picturesOf(key.book, key.names, key.others, key.main, index)) do
            wanted[name] = true
        end
        for _idx, f in ipairs(files) do
            if wanted[f.name] then out[#out + 1] = f end
        end
        return out
    end
    for _idx, f in ipairs(files) do
        local book = bookOf(index, f.name)
        if (key == "none" and not book) or (key ~= "none" and book == key) then
            out[#out + 1] = f
        end
    end
    return out
end

--- What the hold view shows for an index entry: who drew the picture when
--- the index knows, the provenance line, then the prompt sent. Pure.
function ImageBrowser.holdText(entry)
    local shown = ImageGenerator.promptShown(entry.prompt,
        type(entry.provenance) == "string" and entry.provenance or nil)
    if type(entry.provider) ~= "string" then return shown end
    local who = ImageGenerator.providerName(entry.provider)
    if type(entry.model) == "string" and entry.model ~= "" then who = who .. " / " .. entry.model end
    return T(_("Drawn by %1."), who) .. "\n" .. shown
end

local function viewImage(path, prompt)
    local ok, ImageViewer = pcall(require, "ui/widget/imageviewer")
    if not ok then return end
    -- Sent prompt as the native toggleable caption (triangle icon; starts
    -- hidden). Truncated so the title bar can't squeeze the image out — the
    -- full prompt lives behind the picture's hold.
    local caption = prompt
    if caption and #caption > 400 then
        caption = require("util").fixUtf8(caption:sub(1, 400), "") .. "…"
    end
    UIManager:show(ImageViewer:new{
        file = path,
        with_title_bar = true,
        title_text = path:match("([^/]+)%.%w+$") or path:match("([^/]+)$"),
        caption = caption,
        caption_visible = false,
        is_doc_page = false,
    })
end

-- The plugin instance: the reader's when a book is open, else the file
-- browser's (its configuration and settings make a regenerate's request)
local function pluginInstance()
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI.instance and ReaderUI.instance.koassistant then return ReaderUI.instance.koassistant end
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance and FileManager.instance.koassistant then return FileManager.instance.koassistant end
    return nil
end

-- The reader's UI when it has this book open (the privacy screen a question
-- opens from More… edits the live book)
local function readerFor(book_file)
    if not book_file then return nil end
    local ReaderUI = require("apps/reader/readerui")
    local r = ReaderUI.instance
    if r and r.document and r.document.file == book_file then return r end
    return nil
end

--- The prompt in an editor; on_ok(text) draws it.
local function editPrompt(prompt, on_ok)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Edit prompt"),
        description = _("The picture is drawn from this text as it stands, by the image provider and model now in effect. Your edit is saved with the new picture; this one stays."),
        input = prompt or "",
        allow_newline = true,
        -- only text_height sizes an InputDialog
        text_height = Screen:scaleBySize(300),
        buttons = { {
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Regenerate"),
                callback = function()
                    local text = dialog:getInputText()
                    UIManager:close(dialog)
                    if type(text) == "string" and text:match("%S") then on_ok(text) end
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- One place's pictures on screen. set = { key, title }; on_close runs when
--- it closes (the books list recounts).
local function showSet(set, on_close)
    local view  -- the grid, or the list of names
    local touch = Device:isTouchDevice()

    local function titleFor(n)
        if type(set.key) == "table" then return T(_("Pictures of %1 (%2)"), set.title, n) end
        if set.key == "all" then return T(_("Generated Images (%1)"), n) end
        if set.key == "none" then return T(_("Generated Images: without a book (%1)"), n) end
        return T(_("Generated Images: %1 (%2)"), set.title, n)
    end

    local function itemsNow()
        local index = ImageGenerator.readIndex()
        local out = {}
        for _idx, f in ipairs(filesOf(set.key, listImages(), index)) do
            local thumb = ImageGenerator.thumbnailPath(f.name)
            local entry = index[f.name]
            local display = f.name:gsub("%.%w+$", "")
            local label = ImageGenerator.subjectFromName(f.name)
            out[#out + 1] = {
                name = f.name,
                path = f.path,
                size = f.size,
                entry = type(entry) == "table" and entry or nil,
                display = display,
                label = label ~= "" and label or display,
                thumb = lfs.attributes(thumb, "mode") == "file" and thumb or nil,
            }
        end
        return out
    end

    local reload  -- after a deletion or a new picture (defined below)

    local function confirmDelete(item, also_close)
        UIManager:show(ConfirmBox:new{
            text = T(_("Delete this image?\n\n%1"), item.display),
            ok_text = _("Delete"),
            ok_callback = function()
                ImageGenerator.deleteImages({ item.name })
                if also_close then UIManager:close(also_close) end
                reload()
            end,
        })
    end

    local function regenerate(item, prompt, edited, replace)
        local plugin = pluginInstance()
        if not plugin then
            UIManager:show(InfoMessage:new{ text = _("Image generation is not available here.") })
            return
        end
        local book_file = item.entry and item.entry.book_file
        require("ui/network/manager"):runWhenConnected(function()
            if plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
            ImageGenerator.regenerate({
                name = item.name, entry = item.entry, prompt = prompt, edited = edited, replace = replace,
                plugin = plugin, ui = readerFor(book_file),
                -- the new picture leads the set once its viewer closes
                on_viewer_close = function() reload(1) end,
            }, plugin.configuration, plugin.settings)
        end)
    end

    local function onTap(item)
        local entry = item.entry
        viewImage(item.path, entry and type(entry.prompt) == "string"
            and ImageGenerator.promptShown(entry.prompt, type(entry.provenance) == "string" and entry.provenance or nil)
            or nil)
    end

    -- Hold = the prompt, scrollable (InfoMessage truncated — device
    -- 2026-08-13), with Regenerate (beside the old picture, or in its place),
    -- Edit prompt…, Image settings… (S9: the panel, then the same two) and
    -- Delete; a picture with no recorded prompt (made before the index) gets
    -- the delete confirm
    local function onHold(item)
        local entry = item.entry
        if not (entry and type(entry.prompt) == "string" and entry.prompt ~= "") then
            confirmDelete(item)
            return
        end
        local TextViewer = require("ui/widget/textviewer")
        local tv
        local function again(replace)
            UIManager:close(tv)
            regenerate(item, entry.prompt, false, replace)
        end
        tv = TextViewer:new{
            title = item.display,
            title_multilines = true,
            text = ImageBrowser.holdText(entry),
            add_default_buttons = true,
            buttons_table = {
                {
                    { text = _("Regenerate"), callback = function() again(false) end },
                    { text = _("Regenerate and replace"), callback = function() again(true) end },
                },
                {
                    { text = _("Edit prompt…"), callback = function()
                        editPrompt(entry.prompt, function(text)
                            UIManager:close(tv)
                            regenerate(item, text, true)
                        end)
                    end },
                    { text = _("Image settings…"), callback = function()
                        local plugin = pluginInstance()
                        if not (plugin and plugin.settings) then
                            UIManager:show(InfoMessage:new{ text = _("Image generation is not available here.") })
                            return
                        end
                        -- over the hold view: closing it comes back here; the
                        -- provider question first when the chat provider
                        -- cannot draw
                        require("koassistant.images.image_generator").providerFirst(plugin, function()
                            require("koassistant.images.image_options").show(plugin, {
                                actions = {
                                    { text = _("Regenerate"), callback = function() again(false) end },
                                    { text = _("Regenerate and replace"), callback = function() again(true) end },
                                },
                            })
                        end)
                    end },
                },
                {
                    { text = _("Delete image…"), callback = function() confirmDelete(item, tv) end },
                },
            },
        }
        UIManager:show(tv)
    end

    -- Thumbnails a page lacks are made before it is built (once per picture;
    -- a failure shows the placeholder and is not tried again this session)
    local function ensureThumbnails(page_items)
        local missing = {}
        for _idx, item in ipairs(page_items) do
            if not item.thumb and not no_thumb[item.name] then missing[#missing + 1] = item end
        end
        if #missing == 0 then return end
        local note = InfoMessage:new{ text = _("Making previews…") }
        UIManager:show(note)
        UIManager:forceRePaint()
        for _idx, item in ipairs(missing) do
            if ImageGenerator.makeThumbnail(item.name) then
                item.thumb = ImageGenerator.thumbnailPath(item.name)
            else
                no_thumb[item.name] = true
            end
        end
        UIManager:close(note)
    end

    local function deleteAll(items)
        UIManager:show(ConfirmBox:new{
            text = set.key == "all" and T(_("Delete all %1 generated images?"), #items)
                or T(_("Delete these %1 images?"), #items),
            ok_text = _("Delete all"),
            ok_callback = function()
                local names = {}
                for _idx, item in ipairs(items) do names[#names + 1] = item.name end
                ImageGenerator.deleteImages(names)
                reload()
            end,
        })
    end

    -- The ☰ menu, the same in both views: its rows hang from the icon, the
    -- settings row last
    local function showMenu(items)
        require("koassistant.ui.icon_menu").show(view, {
            { text = set.key == "all" and _("Delete all images…") or _("Delete these images…"),
                callback = function() deleteAll(items) end },
        }, pluginInstance())
    end

    local function close()
        if view then UIManager:close(view) end
        view = nil
        if on_close then on_close() end
    end

    local items = itemsNow()
    if touch then
        local ImageGrid = require("koassistant.images.image_grid")
        view = ImageGrid:new{
            title = titleFor(#items),
            items = items,
            on_tap = onTap,
            on_hold = onHold,
            on_menu = function() showMenu(view.items) end,
            on_close = function()
                view = nil
                if on_close then on_close() end
            end,
            before_page = ensureThumbnails,
        }
        reload = function(page)
            if not view then return end
            local now = itemsNow()
            if #now == 0 then
                close()
                return
            end
            view.title_bar:setTitle(titleFor(#now), true)
            view:setItems(now, page)
        end
        UIManager:show(view)
        return
    end

    -- No touchscreen: the list of names (the gallery before S7)
    local function menuItems(list)
        local out = {}
        for _idx, item in ipairs(list) do
            out[#out + 1] = {
                text = item.display,
                mandatory = string.format("%d KB", math.floor(item.size / 1024 + 0.5)),
                mandatory_dim = true,
                callback = function() onTap(item) end,
                hold_callback = function() onHold(item) end,
            }
        end
        return out
    end
    local list_items = items
    view = Menu:new{
        title = titleFor(#items),
        item_table = menuItems(items),
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function() showMenu(list_items) end,
        onMenuSelect = function(_self_menu, item)
            if item and item.callback then item.callback() end
            return true
        end,
        onMenuHold = function(_self_menu, item)
            if item and item.hold_callback then item.hold_callback() end
            return true
        end,
        close_callback = function()
            view = nil
            if on_close then on_close() end
        end,
        multilines_show_more_text = true,
        items_max_lines = 2,
        single_line = false,
        multilines_forced = true,
        items_font_size = 18,
        items_mandatory_font_size = 14,
    }
    reload = function(page)
        if not view then return end
        list_items = itemsNow()
        if #list_items == 0 then
            close()
            return
        end
        -- the same page after a deletion; the first after a new picture
        local keep = page and 1 or ((view.page or 1) - 1) * (view.perpage or 1) + 1
        view:switchItemTable(titleFor(#list_items), menuItems(list_items), keep)
    end
    UIManager:show(view)
end

--- Show the gallery. opts (optional): { book_file, book_title } = that
--- book's pictures.
function ImageBrowser.show(opts)
    opts = opts or {}
    ImageGenerator.sweepThumbnails()
    local files = listImages()
    local index = ImageGenerator.readIndex()
    if opts.entry then
        -- One X-Ray entry's pictures (B486): { book_file, names, others, main, title }
        local e = opts.entry
        local key = { book = e.book_file, names = e.names, others = e.others, main = e.main }
        if #filesOf(key, files, index) == 0 then
            UIManager:show(InfoMessage:new{ text = _("No pictures of this entry yet.") })
            return
        end
        showSet({ key = key, title = e.title or "" }, opts.on_close)
        return
    end
    if opts.book_file then
        if #filesOf(opts.book_file, files, index) == 0 then
            UIManager:show(InfoMessage:new{ text = _("No generated images for this document.") })
            return
        end
        showSet({ key = opts.book_file,
            title = opts.book_title or opts.book_file:match("([^/]+)$") or opts.book_file })
        return
    end
    if #files == 0 then
        UIManager:show(InfoMessage:new{ text = _("No generated images yet.") })
        return
    end
    local groups = ImageBrowser.groups(files, index)
    if #groups <= 2 then
        -- one place: its pictures straight away
        showSet(groups[1])
        return
    end
    -- More than one place: a list of them, recounted when a set closes
    local menu
    local function rows(list)
        local out = {}
        for i, g in ipairs(list) do
            local group, row = g, i
            out[#out + 1] = {
                text = group.title,
                mandatory = tostring(#group.files),
                callback = function()
                    showSet({ key = group.key, title = group.title }, function()
                        if not menu then return end
                        local now = listImages()
                        if #now == 0 then
                            UIManager:close(menu)
                            return
                        end
                        -- recounted, on the page of the row that was opened
                        menu:switchItemTable(nil, rows(ImageBrowser.groups(now, ImageGenerator.readIndex())), row)
                    end)
                end,
            }
        end
        return out
    end
    menu = Menu:new{
        title = _("Generated Images"),
        item_table = rows(groups),
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        close_callback = function() menu = nil end,
        onMenuSelect = function(_self_menu, item)
            if item and item.callback then item.callback() end
            return true
        end,
        single_line = true,
        items_font_size = 18,
        items_mandatory_font_size = 14,
    }
    UIManager:show(menu)
end

return ImageBrowser
