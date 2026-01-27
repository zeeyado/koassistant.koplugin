local Device = require("device")
local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
local Screen = Device.screen
local _ = require("koassistant_gettext")
local InputDialog = require("ui/widget/inputdialog")
local ChatGPTViewer = require("koassistant_chatgptviewer")
local MessageHistory = require("koassistant_message_history")
local GptQuery = require("koassistant_gpt_query")
local queryChatGPT = GptQuery.query
local isStreamingInProgress = GptQuery.isStreamingInProgress
local ConfigHelper = require("koassistant_config_helper")
local logger = require("logger")

-- Helper function for string formatting with translations
local T = require("ffi/util").template

local ChatHistoryDialog = {
    -- Track currently open dialogs to ensure proper cleanup
    current_menu = nil,
    current_chat_viewer = nil,
    current_options_dialog = nil,
}

-- Helper to safely close a widget
local function safeClose(widget)
    if widget then
        UIManager:close(widget)
    end
end

-- Helper to close all tracked dialogs
function ChatHistoryDialog:closeAllDialogs()
    safeClose(self.current_options_dialog)
    self.current_options_dialog = nil
    safeClose(self.current_menu)
    self.current_menu = nil
    safeClose(self.current_chat_viewer)
    self.current_chat_viewer = nil
end

function ChatHistoryDialog:showChatListMenuOptions(ui, document, chat_history_manager, config, nav_context)
    -- Close any existing options dialog first
    safeClose(self.current_options_dialog)

    local self_ref = self
    local dialog
    local buttons = {
        {
            {
                text = _("Delete all chats for this book"),
                callback = function()
                    safeClose(dialog)
                    self_ref.current_options_dialog = nil
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Delete all chats for \"%1\"?\n\nThis action cannot be undone."), document.title),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            local deleted_count = chat_history_manager:deleteAllChatsForDocument(document.path)
                            UIManager:show(InfoMessage:new{
                                text = T(_("Deleted %1 chat(s)"), deleted_count),
                                timeout = 2,
                            })
                            -- Close the chat list menu and go back to document list
                            safeClose(self_ref.current_menu)
                            self_ref.current_menu = nil
                            -- Refresh the document list
                            UIManager:scheduleIn(0.5, function()
                                self_ref:showChatHistoryBrowser(ui, nil, chat_history_manager, config, nav_context)
                            end)
                        end,
                    })
                end,
            },
        },
        {
            {
                text = _("Close"),
                callback = function()
                    safeClose(dialog)
                    self_ref.current_options_dialog = nil
                end,
            },
        },
    }

    dialog = ButtonDialog:new{
        title = document.title,
        buttons = buttons,
    }
    self.current_options_dialog = dialog
    UIManager:show(dialog)
end

function ChatHistoryDialog:showDocumentMenuOptions(ui, chat_history_manager, config)
    -- Close any existing options dialog first
    safeClose(self.current_options_dialog)

    local self_ref = self
    local dialog
    local buttons = {
        {
            {
                text = _("View by Domain"),
                callback = function()
                    safeClose(dialog)
                    self_ref.current_options_dialog = nil
                    -- Close current menu first, then open new one with delay
                    safeClose(self_ref.current_menu)
                    self_ref.current_menu = nil
                    -- Delay to let UIManager process the close before opening new menu
                    UIManager:scheduleIn(0.1, function()
                        self_ref:showChatsByDomainBrowser(ui, chat_history_manager, config)
                    end)
                end,
            },
            {
                text = _("View by Tag"),
                callback = function()
                    safeClose(dialog)
                    self_ref.current_options_dialog = nil
                    -- Close current menu first, then open new one with delay
                    safeClose(self_ref.current_menu)
                    self_ref.current_menu = nil
                    -- Delay to let UIManager process the close before opening new menu
                    UIManager:scheduleIn(0.1, function()
                        self_ref:showChatsByTagBrowser(ui, chat_history_manager, config)
                    end)
                end,
            },
        },
        {
            {
                text = _("Delete all chats"),
                callback = function()
                    safeClose(dialog)
                    self_ref.current_options_dialog = nil
                    UIManager:show(ConfirmBox:new{
                        text = _("Delete all saved chats?\n\nThis action cannot be undone."),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            local total_deleted, docs_deleted = chat_history_manager:deleteAllChats()
                            UIManager:show(InfoMessage:new{
                                text = T(_("Deleted %1 chat(s) from %2 book(s)"), total_deleted, docs_deleted),
                                timeout = 2,
                            })
                            -- Close the menu since there's nothing left to show
                            safeClose(self_ref.current_menu)
                            self_ref.current_menu = nil
                        end,
                    })
                end,
            },
        },
        {
            {
                text = _("Close"),
                callback = function()
                    safeClose(dialog)
                    self_ref.current_options_dialog = nil
                end,
            },
        },
    }

    dialog = ButtonDialog:new{
        title = _("Chat History Options"),
        buttons = buttons,
    }
    self.current_options_dialog = dialog
    UIManager:show(dialog)
end

-- Show navigation options when in Domain browser
function ChatHistoryDialog:showDomainBrowserMenuOptions(ui, chat_history_manager, config)
    safeClose(self.current_options_dialog)

    local self_ref = self
    local dialog
    local buttons = {
        {
            {
                text = _("View by Tag"),
                callback = function()
                    safeClose(dialog)
                    self_ref.current_options_dialog = nil
                    safeClose(self_ref.current_menu)
                    self_ref.current_menu = nil
                    UIManager:scheduleIn(0.1, function()
                        self_ref:showChatsByTagBrowser(ui, chat_history_manager, config)
                    end)
                end,
            },
        },
        {
            {
                text = _("Chat History"),
                callback = function()
                    safeClose(dialog)
                    self_ref.current_options_dialog = nil
                    safeClose(self_ref.current_menu)
                    self_ref.current_menu = nil
                    UIManager:scheduleIn(0.1, function()
                        self_ref:showChatHistoryBrowser(ui, nil, chat_history_manager, config)
                    end)
                end,
            },
        },
        {
            {
                text = _("Close"),
                callback = function()
                    safeClose(dialog)
                    self_ref.current_options_dialog = nil
                end,
            },
        },
    }

    dialog = ButtonDialog:new{
        title = _("Navigate"),
        buttons = buttons,
    }
    self.current_options_dialog = dialog
    UIManager:show(dialog)
end

-- Show navigation options when in Tag browser
function ChatHistoryDialog:showTagBrowserMenuOptions(ui, chat_history_manager, config)
    safeClose(self.current_options_dialog)

    local self_ref = self
    local dialog
    local buttons = {
        {
            {
                text = _("View by Domain"),
                callback = function()
                    safeClose(dialog)
                    self_ref.current_options_dialog = nil
                    safeClose(self_ref.current_menu)
                    self_ref.current_menu = nil
                    UIManager:scheduleIn(0.1, function()
                        self_ref:showChatsByDomainBrowser(ui, chat_history_manager, config)
                    end)
                end,
            },
        },
        {
            {
                text = _("Chat History"),
                callback = function()
                    safeClose(dialog)
                    self_ref.current_options_dialog = nil
                    safeClose(self_ref.current_menu)
                    self_ref.current_menu = nil
                    UIManager:scheduleIn(0.1, function()
                        self_ref:showChatHistoryBrowser(ui, nil, chat_history_manager, config)
                    end)
                end,
            },
        },
        {
            {
                text = _("Close"),
                callback = function()
                    safeClose(dialog)
                    self_ref.current_options_dialog = nil
                end,
            },
        },
    }

    dialog = ButtonDialog:new{
        title = _("Navigate"),
        buttons = buttons,
    }
    self.current_options_dialog = dialog
    UIManager:show(dialog)
end

-- Show chats grouped by domain
function ChatHistoryDialog:showChatsByDomainBrowser(ui, chat_history_manager, config)
    -- Close any existing menu first
    safeClose(self.current_menu)
    self.current_menu = nil

    -- Get chats grouped by domain
    local chats_by_domain = chat_history_manager:getChatsByDomain()

    -- Load domain definitions for display names
    local DomainLoader = require("domain_loader")
    local all_domains = DomainLoader.load()

    -- Build menu items for each domain that has chats
    local menu_items = {}
    local self_ref = self

    -- Get sorted list of domain keys (with chats)
    local domain_keys = {}
    for domain_key, chats in pairs(chats_by_domain) do
        if #chats > 0 then
            table.insert(domain_keys, domain_key)
        end
    end

    -- Sort: domains first (alphabetically by name), then "untagged" at the end
    table.sort(domain_keys, function(a, b)
        if a == "untagged" then return false end
        if b == "untagged" then return true end
        local name_a = all_domains[a] and all_domains[a].name or a
        local name_b = all_domains[b] and all_domains[b].name or b
        return name_a < name_b
    end)

    if #domain_keys == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No saved chats found"),
            timeout = 2,
        })
        return
    end

    for i, domain_key in ipairs(domain_keys) do
        local chats = chats_by_domain[domain_key]
        local chat_count = #chats

        -- Get display name
        local display_name
        if domain_key == "untagged" then
            display_name = _("Untagged")
        elseif all_domains[domain_key] then
            display_name = all_domains[domain_key].name
        else
            display_name = domain_key
        end

        -- Get most recent chat date for this domain
        local most_recent = chats[1] and chats[1].chat and chats[1].chat.timestamp or 0
        local date_str = most_recent > 0 and os.date("%Y-%m-%d", most_recent) or ""

        local right_text = tostring(chat_count) .. " " .. (chat_count == 1 and _("chat") or _("chats")) .. " • " .. date_str

        table.insert(menu_items, {
            text = display_name,
            mandatory = right_text,
            mandatory_dim = true,
            bold = true,
            callback = function()
                -- Target function handles closing current_menu
                self_ref:showChatsForDomain(ui, domain_key, chats, all_domains, chat_history_manager, config)
            end
        })
    end

    local Menu = require("ui/widget/menu")
    local domain_menu = Menu:new{
        title = _("Chat History by Domain"),
        title_bar_left_icon = "appbar.menu",
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        onLeftButtonTap = function()
            self_ref:showDomainBrowserMenuOptions(ui, chat_history_manager, config)
        end,
        item_table = menu_items,
        single_line = false,
        multilines_forced = true,
        items_font_size = 18,
        items_mandatory_font_size = 14,
        close_callback = function()
            if self_ref.current_menu == domain_menu then
                self_ref.current_menu = nil
            end
        end,
    }

    self.current_menu = domain_menu
    UIManager:show(domain_menu)
end

-- Show chats for a specific domain
function ChatHistoryDialog:showChatsForDomain(ui, domain_key, chats, all_domains, chat_history_manager, config)
    -- Close any existing menu first
    safeClose(self.current_menu)
    self.current_menu = nil

    -- Get display name
    local domain_name
    if domain_key == "untagged" then
        domain_name = _("Untagged")
    elseif all_domains[domain_key] then
        domain_name = all_domains[domain_key].name
    else
        domain_name = domain_key
    end

    local menu_items = {}
    local self_ref = self

    for idx, chat_entry in ipairs(chats) do
        local chat = chat_entry.chat
        local document_path = chat_entry.document_path

        local title = chat.title or _("Untitled Chat")
        local date_str = chat.timestamp and os.date("%Y-%m-%d", chat.timestamp) or ""
        local msg_count = chat.messages and #chat.messages or 0

        -- Show book info if available
        local book_info = ""
        if chat.book_title then
            book_info = chat.book_title
            if chat.book_author and chat.book_author ~= "" then
                book_info = book_info .. " • " .. chat.book_author
            end
        elseif document_path == "__GENERAL_CHATS__" then
            book_info = _("General Chat")
        end

        local right_text = date_str .. " • " .. msg_count .. " " .. (msg_count == 1 and _("msg") or _("msgs"))

        table.insert(menu_items, {
            text = title,
            info = book_info ~= "" and book_info or nil,
            mandatory = right_text,
            mandatory_dim = true,
            callback = function()
                -- Build a document object for compatibility with existing functions
                local doc = {
                    path = document_path,
                    title = chat.book_title or (document_path == "__GENERAL_CHATS__" and _("General AI Chats") or domain_name),
                    author = chat.book_author,
                }
                self_ref:showChatOptions(ui, document_path, chat, chat_history_manager, config, doc, nil)
            end
        })
    end

    local Menu = require("ui/widget/menu")
    local chat_menu
    chat_menu = Menu:new{
        title = domain_name .. " (" .. #chats .. ")",
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        single_line = false,
        multilines_forced = true,
        items_font_size = 18,
        items_mandatory_font_size = 14,
        onReturn = function()
            -- Close this menu using self_ref.current_menu (chat_menu is nil during Menu:new evaluation)
            if self_ref.current_menu then
                UIManager:close(self_ref.current_menu)
                self_ref.current_menu = nil
            end
            -- Delay to let UIManager process the close before showing new menu
            UIManager:scheduleIn(0.15, function()
                self_ref:showChatsByDomainBrowser(ui, chat_history_manager, config)
            end)
        end,
        close_callback = function()
            if self_ref.current_menu == chat_menu then
                self_ref.current_menu = nil
            end
        end,
    }

    -- Enable return button
    chat_menu.paths = chat_menu.paths or {}
    table.insert(chat_menu.paths, true)
    if chat_menu.page_return_arrow then
        chat_menu.page_return_arrow:show()
        chat_menu.page_return_arrow:enableDisable(true)
    end

    self.current_menu = chat_menu
    UIManager:show(chat_menu)
end

function ChatHistoryDialog:showChatHistoryBrowser(ui, current_document_path, chat_history_manager, config, nav_context)
    -- Close any existing menu first
    safeClose(self.current_menu)
    self.current_menu = nil

    -- Initialize navigation context if not provided
    nav_context = nav_context or {
        level = "documents",
        came_from_document = current_document_path ~= nil,
        initial_document = current_document_path
    }

    -- Get all documents that have chats
    local documents = chat_history_manager:getAllDocuments()

    if #documents == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No saved chats found"),
            timeout = 2,
        })
        return
    end

    -- Check if we should directly show chats for the current document
    if current_document_path then
        for idx, doc in ipairs(documents) do
            if doc.path == current_document_path then
                self:showChatsForDocument(ui, doc, chat_history_manager, config, nav_context)
                return
            end
        end
    end

    -- Create menu items for each document
    local menu_items = {}
    local self_ref = self  -- Capture self for callbacks

    logger.info("Chat history: Creating menu items for " .. #documents .. " documents")

    for doc_idx, doc in ipairs(documents) do
        logger.info("Chat history: Document - title: " .. (doc.title or "nil") .. ", author: " .. (doc.author or "nil"))

        local chats = chat_history_manager:getChatsForDocument(doc.path)
        local chat_count = #chats

        local latest_timestamp = 0
        for chat_idx, chat in ipairs(chats) do
            if chat.timestamp and chat.timestamp > latest_timestamp then
                latest_timestamp = chat.timestamp
            end
        end

        local date_str = latest_timestamp > 0 and os.date("%Y-%m-%d", latest_timestamp) or _("Unknown")

        local display_text = doc.title
        if doc.author and doc.author ~= "" then
            display_text = display_text .. " • " .. doc.author
        end

        local right_text = tostring(chat_count) .. " " .. (chat_count == 1 and _("chat") or _("chats")) .. " • " .. date_str

        -- Capture doc in closure
        local captured_doc = doc

        -- Determine help text based on document type
        local help_text
        if doc.path == "__GENERAL_CHATS__" then
            help_text = _("AI conversations without book context")
        else
            help_text = doc.path
        end

        table.insert(menu_items, {
            text = display_text,
            mandatory = right_text,
            mandatory_dim = true,
            bold = true,
            help_text = help_text,
            callback = function()
                logger.info("Document selected: " .. captured_doc.title)
                -- Target function handles closing current_menu
                self_ref:showChatsForDocument(ui, captured_doc, chat_history_manager, config, nav_context)
            end
        })
    end

    local document_menu = Menu:new{
        title = _("Chat History"),
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        title_bar_left_icon = "appbar.menu",
        multilines_show_more_text = true,
        items_max_lines = 2,
        single_line = false,
        multilines_forced = true,
        items_font_size = 18,
        items_mandatory_font_size = 14,
        onLeftButtonTap = function()
            self_ref:showDocumentMenuOptions(ui, chat_history_manager, config)
        end,
        close_callback = function()
            -- Only clear if this menu is still the current one
            if self_ref.current_menu == document_menu then
                logger.info("KOAssistant: document_menu close_callback - clearing current_menu")
                self_ref.current_menu = nil
            else
                logger.info("KOAssistant: document_menu close_callback - skipping, current_menu already changed")
            end
        end,
    }

    self.current_menu = document_menu
    logger.info("KOAssistant: Set current_menu to document_menu " .. tostring(document_menu))
    UIManager:show(document_menu)
end

function ChatHistoryDialog:showChatsForDocument(ui, document, chat_history_manager, config, nav_context)
    -- Close any existing menu first
    safeClose(self.current_menu)
    self.current_menu = nil

    nav_context = nav_context or {}
    nav_context.level = "chats"
    nav_context.current_document = document

    local chats = chat_history_manager:getChatsForDocument(document.path)

    if #chats == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No saved chats found for this document"),
            timeout = 2,
        })
        return
    end

    local menu_items = {}
    local self_ref = self

    for i, chat in ipairs(chats) do
        logger.info("Chat " .. i .. " ID: " .. (chat.id or "unknown") .. " - " .. (chat.title or "Untitled"))

        local date_str = os.date("%Y-%m-%d %H:%M", chat.timestamp or 0)
        local title = chat.title or "Untitled"
        local model = chat.model or "Unknown"
        -- Shorten model name for display (strip date suffix)
        local short_model = model:gsub("%-20%d%d%d%d%d%d$", "")
        local msg_count = #(chat.messages or {})

        local preview = ""
        for msg_idx, msg in ipairs(chat.messages or {}) do
            if msg.role == "user" and not msg.is_context then
                local content = msg.content or ""
                preview = content:sub(1, 30)
                if #content > 30 then
                    preview = preview .. "..."
                end
                break
            end
        end

        -- Capture chat in closure
        local captured_chat = chat
        table.insert(menu_items, {
            text = title .. " • " .. date_str,
            -- Compact format: "model • count" (no "messages" text)
            mandatory = short_model .. " • " .. msg_count,
            mandatory_dim = true,
            bold = true,
            help_text = preview,
            callback = function()
                logger.info("Chat selected: " .. (captured_chat.id or "unknown") .. " - " .. (captured_chat.title or "Untitled"))
                self_ref:showChatOptions(ui, document.path, captured_chat, chat_history_manager, config, document, nav_context)
            end
        })
    end

    local chat_menu
    chat_menu = Menu:new{
        title = T(_("Chats: %1"), document.title),
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        title_bar_left_icon = "appbar.menu",
        items_per_page = 8,
        multilines_show_more_text = true,
        items_max_lines = 2,
        single_line = false,
        items_font_size = 20,
        items_mandatory_font_size = 16,
        align_baselines = false,
        with_dots = false,
        onLeftButtonTap = function()
            self_ref:showChatListMenuOptions(ui, document, chat_history_manager, config, nav_context)
        end,
        onReturn = function()
            logger.info("Chat history: Return button pressed")
            safeClose(chat_menu)
            self_ref.current_menu = nil
            self_ref:showChatHistoryBrowser(ui, nil, chat_history_manager, config, nav_context)
        end,
        close_callback = function()
            -- Only clear if this menu is still the current one
            if self_ref.current_menu == chat_menu then
                logger.info("KOAssistant: chat_menu close_callback - clearing current_menu")
                self_ref.current_menu = nil
            else
                logger.info("KOAssistant: chat_menu close_callback - skipping, current_menu already changed")
            end
        end,
    }

    -- Enable the return button by populating paths table
    -- This must be done after creation but before showing
    chat_menu.paths = chat_menu.paths or {}
    table.insert(chat_menu.paths, true)

    -- Force the return button to be visible and enabled
    -- The button starts hidden and disabled by default in Menu:init()
    -- We need to both show() it and enableDisable(true) after setting paths
    if chat_menu.page_return_arrow then
        chat_menu.page_return_arrow:show()
        chat_menu.page_return_arrow:enableDisable(true)
        logger.info("Chat history: Return arrow button shown and enabled")
    else
        logger.warn("Chat history: page_return_arrow not found")
    end

    self.current_menu = chat_menu
    logger.info("KOAssistant: Set current_menu to " .. tostring(chat_menu))
    UIManager:show(chat_menu)
end

function ChatHistoryDialog:showChatOptions(ui, document_path, chat, chat_history_manager, config, document, nav_context)
    logger.info("KOAssistant: showChatOptions - self.current_menu = " .. tostring(self.current_menu))
    -- Close any existing options dialog first
    safeClose(self.current_options_dialog)
    self.current_options_dialog = nil

    if not chat or not chat.id then
        UIManager:show(InfoMessage:new{
            text = _("Error: Cannot load chat data."),
            timeout = 2,
        })
        return
    end

    -- IMPORTANT: Always reload chat from disk to get the latest version
    -- This prevents using stale cached data if the chat was modified elsewhere
    local fresh_chat = chat_history_manager:getChatById(document_path, chat.id)
    if fresh_chat then
        logger.info("ChatHistoryDialog: Reloaded fresh chat data for id: " .. chat.id)
        chat = fresh_chat
    else
        logger.warn("ChatHistoryDialog: Could not reload chat, using cached version")
    end

    local date_str = os.date("%Y-%m-%d %H:%M", chat.timestamp or 0)
    local model = chat.model or "Unknown"
    local msg_count = #(chat.messages or {})

    local detailed_title = (chat.title or _("Untitled Chat")) .. "\n" ..
        _("Date:") .. " " .. date_str .. "\n" ..
        _("Model:") .. " " .. model .. "\n" ..
        _("Messages:") .. " " .. tostring(msg_count)

    local self_ref = self
    local dialog
    -- Capture the current menu reference NOW, before any callbacks run
    -- This ensures we can close it later even if self.current_menu changes
    local menu_to_close = self.current_menu

    -- Format tags for display
    local tags_display = ""
    if chat.tags and #chat.tags > 0 then
        local tag_strs = {}
        for _, t in ipairs(chat.tags) do
            table.insert(tag_strs, "#" .. t)
        end
        tags_display = table.concat(tag_strs, " ")
    end

    local buttons = {
        {
            {
                text = _("Continue Chat"),
                callback = function()
                    safeClose(dialog)
                    self_ref.current_options_dialog = nil
                    -- Close the menu before opening the chat viewer
                    if menu_to_close then
                        UIManager:close(menu_to_close)
                    end
                    self_ref.current_menu = nil
                    self_ref:continueChat(ui, document_path, chat, chat_history_manager, config)
                end,
            },
            {
                text = _("Rename"),
                callback = function()
                    safeClose(dialog)
                    self_ref.current_options_dialog = nil
                    self_ref:showRenameDialog(ui, document_path, chat, chat_history_manager, config, document, nav_context)
                end,
            },
        },
        {
            {
                text = _("Tags") .. (tags_display ~= "" and ": " .. tags_display or ""),
                callback = function()
                    safeClose(dialog)
                    self_ref.current_options_dialog = nil
                    self_ref:showTagsManager(ui, document_path, chat, chat_history_manager, config, document, nav_context)
                end,
            },
        },
        {
            {
                text = _("Export"),
                callback = function()
                    safeClose(dialog)
                    self_ref.current_options_dialog = nil
                    self_ref:showExportOptions(document_path, chat.id, chat_history_manager)
                end,
            },
            {
                text = _("Delete"),
                callback = function()
                    safeClose(dialog)
                    self_ref.current_options_dialog = nil
                    -- Pass the menu reference to the confirm dialog - it will close only on confirm
                    self_ref:confirmDeleteWithClose(ui, document_path, chat.id, chat_history_manager, config, document, nav_context, menu_to_close)
                end,
            },
        },
        {
            {
                text = _("Close"),
                callback = function()
                    safeClose(dialog)
                    self_ref.current_options_dialog = nil
                end,
            },
        },
    }

    dialog = ButtonDialog:new{
        title = detailed_title,
        buttons = buttons,
    }

    self.current_options_dialog = dialog
    UIManager:show(dialog)
end

function ChatHistoryDialog:showRenameDialog(ui, document_path, chat, chat_history_manager, config, document, nav_context)
    local self_ref = self
    local rename_dialog

    rename_dialog = InputDialog:new{
        title = _("Rename Chat"),
        input = chat.title or _("Untitled Chat"),
        buttons = {
            {
                {
                    text = _("Close"),
                    id = "close",
                    callback = function()
                        UIManager:close(rename_dialog)
                    end,
                },
                {
                    text = _("Rename"),
                    callback = function()
                        local new_title = rename_dialog:getInputText()
                        UIManager:close(rename_dialog)

                        local success = chat_history_manager:renameChat(document_path, chat.id, new_title)

                        if success then
                            UIManager:show(InfoMessage:new{
                                text = _("Chat renamed successfully"),
                                timeout = 2,
                            })
                            -- Refresh the chat list
                            if document then
                                self_ref:showChatsForDocument(ui, document, chat_history_manager, config, nav_context)
                            end
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Failed to rename chat"),
                                timeout = 2,
                            })
                        end
                    end,
                },
            },
        },
    }

    UIManager:show(rename_dialog)
end

function ChatHistoryDialog:showTagsManager(ui, document_path, chat, chat_history_manager, config, document, nav_context)
    local self_ref = self
    local tags_dialog = nil  -- Track current dialog for proper closing

    -- Function to show the tags menu
    local function showTagsMenu()
        -- Close previous dialog if exists
        if tags_dialog then
            UIManager:close(tags_dialog)
            tags_dialog = nil
        end

        -- Reload chat to get latest tags
        local fresh_chat = chat_history_manager:getChatById(document_path, chat.id)
        if fresh_chat then
            chat = fresh_chat
        end

        local current_tags = chat.tags or {}
        local all_tags = chat_history_manager:getAllTags()

        local buttons = {}

        -- Show current tags with remove option
        if #current_tags > 0 then
            table.insert(buttons, {
                {
                    text = _("Current tags:"),
                    enabled = false,
                },
            })

            for ti, tag in ipairs(current_tags) do
                table.insert(buttons, {
                    {
                        text = "#" .. tag .. " ✕",
                        callback = function()
                            chat_history_manager:removeTagFromChat(document_path, chat.id, tag)
                            UIManager:show(InfoMessage:new{
                                text = T(_("Removed tag: %1"), tag),
                                timeout = 1,
                            })
                            UIManager:scheduleIn(0.3, showTagsMenu)
                        end,
                    },
                })
            end

            table.insert(buttons, {
                {
                    text = "────────────────────",
                    enabled = false,
                },
            })
        end

        -- Show existing tags that aren't on this chat (for quick add)
        local available_tags = {}
        for ti, tag in ipairs(all_tags) do
            local already_has = false
            for ci, current in ipairs(current_tags) do
                if current == tag then
                    already_has = true
                    break
                end
            end
            if not already_has then
                table.insert(available_tags, tag)
            end
        end

        if #available_tags > 0 then
            table.insert(buttons, {
                {
                    text = _("Add existing tag:"),
                    enabled = false,
                },
            })

            -- Show up to 5 existing tags for quick add
            local shown_tags = 0
            for ai, tag in ipairs(available_tags) do
                if shown_tags >= 5 then break end
                table.insert(buttons, {
                    {
                        text = "#" .. tag,
                        callback = function()
                            chat_history_manager:addTagToChat(document_path, chat.id, tag)
                            UIManager:show(InfoMessage:new{
                                text = T(_("Added tag: %1"), tag),
                                timeout = 1,
                            })
                            UIManager:scheduleIn(0.3, showTagsMenu)
                        end,
                    },
                })
                shown_tags = shown_tags + 1
            end

            table.insert(buttons, {
                {
                    text = "────────────────────",
                    enabled = false,
                },
            })
        end

        -- Add new tag button
        table.insert(buttons, {
            {
                text = _("+ Add new tag"),
                callback = function()
                    local tag_dialog
                    tag_dialog = InputDialog:new{
                        title = _("New Tag"),
                        input_hint = _("Enter tag name"),
                        buttons = {
                            {
                                {
                                    text = _("Close"),
                                    id = "close",
                                    callback = function()
                                        UIManager:close(tag_dialog)
                                        showTagsMenu()
                                    end,
                                },
                                {
                                    text = _("Add"),
                                    is_enter_default = true,
                                    callback = function()
                                        local new_tag = tag_dialog:getInputText()
                                        UIManager:close(tag_dialog)
                                        if new_tag and new_tag ~= "" then
                                            -- Remove # if user typed it
                                            new_tag = new_tag:gsub("^#", "")
                                            new_tag = new_tag:match("^%s*(.-)%s*$")  -- trim
                                            if new_tag ~= "" then
                                                chat_history_manager:addTagToChat(document_path, chat.id, new_tag)
                                                UIManager:show(InfoMessage:new{
                                                    text = T(_("Added tag: %1"), new_tag),
                                                    timeout = 1,
                                                })
                                            end
                                        end
                                        UIManager:scheduleIn(0.3, showTagsMenu)
                                    end,
                                },
                            },
                        },
                    }
                    UIManager:show(tag_dialog)
                    tag_dialog:onShowKeyboard()
                end,
            },
        })

        -- Done button
        table.insert(buttons, {
            {
                text = _("Done"),
                callback = function()
                    -- Close the tags dialog
                    if tags_dialog then
                        UIManager:close(tags_dialog)
                        tags_dialog = nil
                    end
                    -- Go back to chat options with refreshed chat data
                    self_ref:showChatOptions(ui, document_path, chat, chat_history_manager, config, document, nav_context)
                end,
            },
        })

        tags_dialog = ButtonDialog:new{
            title = _("Manage Tags"),
            buttons = buttons,
        }
        self_ref.current_options_dialog = tags_dialog
        UIManager:show(tags_dialog)
    end

    showTagsMenu()
end

-- Show tags menu for use from chat viewer (simpler version without nav context)
function ChatHistoryDialog:showTagsMenuForChat(document_path, chat_id, chat_history_manager)
    local self_ref = self
    local tags_dialog = nil  -- Track current dialog for proper closing

    local function showTagsMenu()
        -- Close previous dialog if exists
        if tags_dialog then
            UIManager:close(tags_dialog)
            tags_dialog = nil
        end

        -- Get fresh chat data
        local chat = chat_history_manager:getChatById(document_path, chat_id)
        if not chat then
            UIManager:show(InfoMessage:new{
                text = _("Chat not found"),
                timeout = 2,
            })
            return
        end

        local current_tags = chat.tags or {}
        local all_tags = chat_history_manager:getAllTags()

        local buttons = {}

        -- Show current tags with remove option
        if #current_tags > 0 then
            table.insert(buttons, {
                {
                    text = _("Current tags:"),
                    enabled = false,
                },
            })

            for _idx, tag in ipairs(current_tags) do
                table.insert(buttons, {
                    {
                        text = "#" .. tag .. " ✕",
                        callback = function()
                            chat_history_manager:removeTagFromChat(document_path, chat_id, tag)
                            UIManager:show(InfoMessage:new{
                                text = T(_("Removed tag: %1"), tag),
                                timeout = 1,
                            })
                            UIManager:scheduleIn(0.3, showTagsMenu)
                        end,
                    },
                })
            end

            table.insert(buttons, {
                {
                    text = "────────────────────",
                    enabled = false,
                },
            })
        end

        -- Show existing tags that aren't on this chat (for quick add)
        local available_tags = {}
        for _, tag in ipairs(all_tags) do
            local already_has = false
            for _, current in ipairs(current_tags) do
                if current == tag then
                    already_has = true
                    break
                end
            end
            if not already_has then
                table.insert(available_tags, tag)
            end
        end

        if #available_tags > 0 then
            table.insert(buttons, {
                {
                    text = _("Add existing tag:"),
                    enabled = false,
                },
            })

            -- Show up to 5 existing tags for quick add
            local shown_tags = 0
            for _idx, tag in ipairs(available_tags) do
                if shown_tags >= 5 then break end
                table.insert(buttons, {
                    {
                        text = "#" .. tag,
                        callback = function()
                            chat_history_manager:addTagToChat(document_path, chat_id, tag)
                            UIManager:show(InfoMessage:new{
                                text = T(_("Added tag: %1"), tag),
                                timeout = 1,
                            })
                            UIManager:scheduleIn(0.3, showTagsMenu)
                        end,
                    },
                })
                shown_tags = shown_tags + 1
            end

            table.insert(buttons, {
                {
                    text = "────────────────────",
                    enabled = false,
                },
            })
        end

        -- Add new tag button
        table.insert(buttons, {
            {
                text = _("+ Add new tag"),
                callback = function()
                    local tag_input
                    tag_input = InputDialog:new{
                        title = _("New Tag"),
                        input_hint = _("Enter tag name"),
                        buttons = {
                            {
                                {
                                    text = _("Cancel"),
                                    id = "close",
                                    callback = function()
                                        UIManager:close(tag_input)
                                        showTagsMenu()
                                    end,
                                },
                                {
                                    text = _("Add"),
                                    is_enter_default = true,
                                    callback = function()
                                        local new_tag = tag_input:getInputText()
                                        UIManager:close(tag_input)
                                        if new_tag and new_tag ~= "" then
                                            -- Remove # if user typed it
                                            new_tag = new_tag:gsub("^#", "")
                                            new_tag = new_tag:match("^%s*(.-)%s*$")  -- trim
                                            if new_tag ~= "" then
                                                chat_history_manager:addTagToChat(document_path, chat_id, new_tag)
                                                UIManager:show(InfoMessage:new{
                                                    text = T(_("Added tag: %1"), new_tag),
                                                    timeout = 1,
                                                })
                                            end
                                        end
                                        UIManager:scheduleIn(0.3, showTagsMenu)
                                    end,
                                },
                            },
                        },
                    }
                    UIManager:show(tag_input)
                    tag_input:onShowKeyboard()
                end,
            },
        })

        -- Done button
        table.insert(buttons, {
            {
                text = _("Done"),
                callback = function()
                    if tags_dialog then
                        UIManager:close(tags_dialog)
                        tags_dialog = nil
                    end
                end,
            },
        })

        tags_dialog = ButtonDialog:new{
            title = _("Manage Tags"),
            buttons = buttons,
        }
        UIManager:show(tags_dialog)
    end

    showTagsMenu()
end

function ChatHistoryDialog:continueChat(ui, document_path, chat, chat_history_manager, config)
    if not chat or not chat.id then
        UIManager:show(InfoMessage:new{
            text = _("Error: Cannot load chat data."),
            timeout = 2,
        })
        return
    end

    -- IMPORTANT: Always reload chat from disk to ensure we have the latest version
    -- This is critical to prevent data loss from stale cached data
    local fresh_chat = chat_history_manager:getChatById(document_path, chat.id)
    if fresh_chat then
        logger.info("continueChat: Using fresh chat data with " .. #(fresh_chat.messages or {}) .. " messages")
        chat = fresh_chat
    else
        logger.warn("continueChat: Could not reload chat from disk, using provided data")
    end

    -- Track this as the last opened chat
    chat_history_manager:setLastOpenedChat(document_path, chat.id)

    -- Close any existing chat viewer
    safeClose(self.current_chat_viewer)
    self.current_chat_viewer = nil

    config = config or {}
    config.features = config.features or {}

    local history
    local ok, err = pcall(function()
        history = MessageHistory:fromSavedMessages(chat.messages, chat.model, chat.id, chat.prompt_action, chat.launch_context)
    end)

    if not ok or not history then
        logger.warn("Failed to load message history: " .. (err or "unknown error"))
        UIManager:show(InfoMessage:new{
            text = _("Error: Failed to load chat messages."),
            timeout = 2,
        })
        return
    end

    local self_ref = self

    -- Get stored highlighted text for display toggle (available for chats saved after this feature)
    local chat_highlighted_text = chat.original_highlighted_text or ""

    -- addMessage now accepts an optional callback for async streaming
    -- @param message string: The user's message
    -- @param is_context boolean: Whether this is a context message (hidden from display)
    -- @param on_complete function: Optional callback(success, answer, error) for streaming
    -- @return answer string (non-streaming) or nil (streaming - result via callback)
    local function addMessage(message, is_context, on_complete)
        if not message or message == "" then
            logger.warn("KOAssistant: addMessage called with empty message")
            if on_complete then on_complete(false, nil, "Empty message") end
            return nil
        end

        logger.info("KOAssistant: Adding user message to history, length: " .. #message)
        history:addUserMessage(message, is_context)

        -- Use callback pattern for streaming support
        logger.info("KOAssistant: Calling queryChatGPT with " .. #history:getMessages() .. " messages")
        local answer_result = queryChatGPT(history:getMessages(), config, function(success, answer, err, reasoning)
            logger.info("KOAssistant: queryChatGPT callback - success: " .. tostring(success) .. ", answer length: " .. tostring(answer and #answer or 0) .. ", err: " .. tostring(err))
            -- Only save if we got a non-empty answer
            if success and answer and answer ~= "" then
                -- Reasoning only passed for non-streaming responses when model actually used it
                history:addAssistantMessage(answer, history:getModel() or (config and config.model), reasoning, ConfigHelper:buildDebugInfo(config))

                -- Auto-save continued chats
                if config.features.auto_save_all_chats or (config.features.auto_save_chats ~= false) then
                    local save_ok = chat_history_manager:saveChat(document_path, chat.title, history, {id = chat.id})
                    if not save_ok then
                        logger.warn("KOAssistant: Failed to save updated chat")
                    end
                end
            elseif success and (not answer or answer == "") then
                -- Streaming returned success but empty content - treat as error
                logger.warn("KOAssistant: Got success but empty answer, treating as error")
                success = false
                err = err or _("No response received from AI")
            end
            -- Call the completion callback
            if on_complete then on_complete(success, answer, err) end
        end)

        -- For non-streaming, return the result directly
        if not isStreamingInProgress(answer_result) then
            return answer_result
        end
        return nil -- Streaming will update via callback
    end

    local date_str = os.date("%Y-%m-%d %H:%M", chat.timestamp or 0)
    local msg_count = #(chat.messages or {})
    local model = chat.model or "AI"
    -- Shorten model name for display
    local short_model = model:gsub("%-20%d%d%d%d%d%d$", "")

    -- Compact title: "Title • date • model • count"
    local detailed_title = (chat.title or _("Untitled")) .. " • " ..
                          date_str .. " • " ..
                          short_model .. " • " ..
                          tostring(msg_count)

    local function showLoadingDialog()
        local loading = InfoMessage:new{
            text = _("Loading..."),
            timeout = 0.1
        }
        UIManager:show(loading)
    end

    -- Function to create and show the chat viewer
    -- state param for rotation: {text, scroll_ratio, scroll_to_bottom}
    local function showChatViewer(content_text, state)
        -- Always close existing viewer first
        safeClose(self_ref.current_chat_viewer)
        self_ref.current_chat_viewer = nil

        -- Note: launch context is now included in createResultText() via history.launch_context
        local display_text = content_text or (state and state.text) or history:createResultText(chat_highlighted_text, config)

        local viewer = ChatGPTViewer:new{
            title = detailed_title,
            text = display_text,
            scroll_to_bottom = state and false or true, -- Scroll to bottom on initial open, preserve position on rotation
            configuration = config,
            original_history = history,
            original_highlighted_text = chat_highlighted_text,
            settings_callback = function(path, value)
                local plugin = ui and ui.koassistant
                if not plugin then
                    local top_widget = UIManager:getTopmostVisibleWidget()
                    if top_widget and top_widget.ui and top_widget.ui.koassistant then
                        plugin = top_widget.ui.koassistant
                    end
                end

                if plugin and plugin.settings then
                    local parts = {}
                    for part in path:gmatch("[^.]+") do
                        table.insert(parts, part)
                    end

                    if #parts == 1 then
                        plugin.settings:saveSetting(parts[1], value)
                    elseif #parts == 2 then
                        local group = plugin.settings:readSetting(parts[1]) or {}
                        group[parts[2]] = value
                        plugin.settings:saveSetting(parts[1], group)
                    end
                    plugin.settings:flush()

                    if config and config.features and parts[1] == "features" and parts[2] == "show_debug_in_chat" then
                        config.features.show_debug_in_chat = value
                    end
                end
            end,
            update_debug_callback = function(show_debug)
                if history and history.show_debug_in_chat ~= nil then
                    history.show_debug_in_chat = show_debug
                end
            end,
            onAskQuestion = function(self_viewer, question)
                showLoadingDialog()

                UIManager:scheduleIn(0.1, function()
                    -- Use callback pattern for streaming support
                    local function onResponseComplete(success, answer, err)
                        if success and answer then
                            local new_content = history:createResultText(chat_highlighted_text, config)
                            showChatViewer(new_content)
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Failed to get response: ") .. (err or "Unknown error"),
                                timeout = 2,
                            })
                        end
                    end

                    local answer = addMessage(question, false, onResponseComplete)

                    -- For non-streaming, the answer is returned directly and callback was already called
                    -- For streaming, answer is nil and callback will be called when stream completes
                end)
            end,
            save_callback = function()
                if config.features.auto_save_all_chats then
                    UIManager:show(InfoMessage:new{
                        text = _("Auto-save is enabled in settings"),
                        timeout = 2,
                    })
                elseif config.features.auto_save_chats ~= false then
                    UIManager:show(InfoMessage:new{
                        text = _("Continued chats are automatically saved"),
                        timeout = 2,
                    })
                else
                    local save_ok = chat_history_manager:saveChat(document_path, chat.title, history, {id = chat.id})
                    UIManager:show(InfoMessage:new{
                        text = save_ok and _("Chat saved") or _("Failed to save chat"),
                        timeout = 2,
                    })
                end
            end,
            export_callback = function()
                -- Copy chat as markdown directly to clipboard (consistent with new chats)
                local markdown = chat_history_manager:exportChatAsMarkdown(document_path, chat.id)
                if markdown then
                    Device.input.setClipboardText(markdown)
                    local Notification = require("ui/widget/notification")
                    UIManager:show(Notification:new{
                        text = _("Chat copied to clipboard"),
                        timeout = 2,
                    })
                end
            end,
            tag_callback = function()
                -- Show tag management dialog for this chat
                self_ref:showTagsMenuForChat(document_path, chat.id, chat_history_manager)
            end,
            close_callback = function()
                self_ref.current_chat_viewer = nil
            end,
            -- Add rotation support by providing a recreation function
            _recreate_func = function(captured_state)
                -- Simply recreate by calling showChatViewer with state
                -- This preserves all the same callbacks and settings through closure
                showChatViewer(nil, captured_state)
            end,
            -- Restore scroll position if provided (from rotation)
            _initial_scroll_ratio = state and state.scroll_ratio or nil,
        }

        self_ref.current_chat_viewer = viewer
        UIManager:show(viewer)
    end

    showChatViewer()
end

function ChatHistoryDialog:showExportOptions(document_path, chat_id, chat_history_manager)
    safeClose(self.current_options_dialog)
    self.current_options_dialog = nil

    local self_ref = self
    local dialog

    local buttons = {
        {
            {
                text = _("Copy as Text"),
                callback = function()
                    local text = chat_history_manager:exportChatAsText(document_path, chat_id)
                    if text then
                        Device.input.setClipboardText(text)
                        UIManager:show(InfoMessage:new{
                            text = _("Chat copied to clipboard as text"),
                            timeout = 2,
                        })
                    end
                    safeClose(dialog)
                    self_ref.current_options_dialog = nil
                end,
            },
            {
                text = _("Copy as Markdown"),
                callback = function()
                    local markdown = chat_history_manager:exportChatAsMarkdown(document_path, chat_id)
                    if markdown then
                        Device.input.setClipboardText(markdown)
                        UIManager:show(InfoMessage:new{
                            text = _("Chat copied to clipboard as markdown"),
                            timeout = 2,
                        })
                    end
                    safeClose(dialog)
                    self_ref.current_options_dialog = nil
                end,
            },
        },
        {
            {
                text = _("Close"),
                callback = function()
                    safeClose(dialog)
                    self_ref.current_options_dialog = nil
                end,
            },
        },
    }

    dialog = ButtonDialog:new{
        title = _("Export Chat"),
        buttons = buttons,
    }

    self.current_options_dialog = dialog
    UIManager:show(dialog)
end

-- Simple delete confirmation - menu is already closed before this is called
function ChatHistoryDialog:confirmDeleteSimple(ui, document_path, chat_id, chat_history_manager, config, document, nav_context)
    local self_ref = self

    UIManager:show(ConfirmBox:new{
        text = _("Are you sure you want to delete this chat?"),
        ok_text = _("Delete"),
        ok_callback = function()
            local success = chat_history_manager:deleteChat(document_path, chat_id)

            if success then
                UIManager:show(InfoMessage:new{
                    text = _("Chat deleted"),
                    timeout = 2,
                })

                -- Schedule the reload with a small delay to let UI settle
                UIManager:scheduleIn(0.1, function()
                    -- Check if there are any chats left for this document
                    local remaining_chats = chat_history_manager:getChatsForDocument(document.path)
                    if #remaining_chats == 0 then
                        -- No chats left, go back to document list
                        self_ref:showChatHistoryBrowser(ui, nil, chat_history_manager, config, nav_context)
                    else
                        -- Still have chats, reload the chat list
                        self_ref:showChatsForDocument(ui, document, chat_history_manager, config, nav_context)
                    end
                end)
            else
                UIManager:show(InfoMessage:new{
                    text = _("Failed to delete chat"),
                    timeout = 2,
                })
            end
        end,
    })
end

-- Delete confirmation that closes menu only on confirm (not on cancel)
function ChatHistoryDialog:confirmDeleteWithClose(ui, document_path, chat_id, chat_history_manager, config, document, nav_context, menu_to_close)
    local self_ref = self

    UIManager:show(ConfirmBox:new{
        text = _("Are you sure you want to delete this chat?"),
        ok_text = _("Delete"),
        ok_callback = function()
            -- Delete the chat first
            local success = chat_history_manager:deleteChat(document_path, chat_id)

            if success then
                -- Close the menu AFTER delete succeeds
                if menu_to_close then
                    UIManager:close(menu_to_close)
                end
                self_ref.current_menu = nil

                -- Show info message
                UIManager:show(InfoMessage:new{
                    text = _("Chat deleted"),
                    timeout = 2,
                })

                -- Schedule the reload AFTER a delay to let the close complete
                UIManager:scheduleIn(0.2, function()
                    -- Check if there are any chats left for this document
                    local remaining_chats = chat_history_manager:getChatsForDocument(document.path)
                    if #remaining_chats == 0 then
                        -- No chats left, go back to document list
                        self_ref:showChatHistoryBrowser(ui, nil, chat_history_manager, config, nav_context)
                    else
                        -- Still have chats, reload the chat list
                        self_ref:showChatsForDocument(ui, document, chat_history_manager, config, nav_context)
                    end
                end)
            else
                UIManager:show(InfoMessage:new{
                    text = _("Failed to delete chat"),
                    timeout = 2,
                })
            end
        end,
        -- On cancel, menu stays open - nothing to do
    })
end

-- Legacy confirmDelete for backwards compatibility
function ChatHistoryDialog:confirmDelete(ui, document_path, chat_id, chat_history_manager, config, document, nav_context)
    -- Close current menu first if it exists
    if self.current_menu then
        UIManager:close(self.current_menu)
        self.current_menu = nil
    end
    self:confirmDeleteSimple(ui, document_path, chat_id, chat_history_manager, config, document, nav_context)
end

-- Show chats grouped by tag
function ChatHistoryDialog:showChatsByTagBrowser(ui, chat_history_manager, config)
    -- Close any existing menu first
    safeClose(self.current_menu)
    self.current_menu = nil

    -- Get all tags with chat counts
    local tag_counts = chat_history_manager:getTagChatCounts()

    -- Build menu items for each tag that has chats
    local menu_items = {}
    local self_ref = self

    -- Get sorted list of tags
    local tags = {}
    for tag, count in pairs(tag_counts) do
        if count > 0 then
            table.insert(tags, { name = tag, count = count })
        end
    end

    -- Sort alphabetically by tag name
    table.sort(tags, function(a, b)
        return a.name < b.name
    end)

    if #tags == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No tagged chats found.\n\nYou can add tags to chats from the chat options menu."),
            timeout = 3,
        })
        -- Go back to document view
        self:showChatHistoryBrowser(ui, nil, chat_history_manager, config)
        return
    end

    for i, tag_info in ipairs(tags) do
        local tag = tag_info.name
        local chat_count = tag_info.count

        -- Get most recent chat date for this tag
        local chats = chat_history_manager:getChatsByTag(tag)
        local most_recent = chats[1] and chats[1].chat and chats[1].chat.timestamp or 0
        local date_str = most_recent > 0 and os.date("%Y-%m-%d", most_recent) or ""

        local right_text = tostring(chat_count) .. " " .. (chat_count == 1 and _("chat") or _("chats")) .. " • " .. date_str

        table.insert(menu_items, {
            text = "#" .. tag,
            mandatory = right_text,
            mandatory_dim = true,
            bold = true,
            callback = function()
                -- Target function handles closing current_menu
                self_ref:showChatsForTag(ui, tag, chat_history_manager, config)
            end
        })
    end

    local tag_menu = Menu:new{
        title = _("Chat History by Tag"),
        title_bar_left_icon = "appbar.menu",
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        onLeftButtonTap = function()
            self_ref:showTagBrowserMenuOptions(ui, chat_history_manager, config)
        end,
        item_table = menu_items,
        single_line = false,
        multilines_forced = true,
        items_font_size = 18,
        items_mandatory_font_size = 14,
        close_callback = function()
            if self_ref.current_menu == tag_menu then
                self_ref.current_menu = nil
            end
        end,
    }

    self.current_menu = tag_menu
    UIManager:show(tag_menu)
end

-- Show chats for a specific tag
function ChatHistoryDialog:showChatsForTag(ui, tag, chat_history_manager, config)
    -- Close any existing menu first
    safeClose(self.current_menu)
    self.current_menu = nil

    local chats = chat_history_manager:getChatsByTag(tag)

    if #chats == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No chats found with this tag"),
            timeout = 2,
        })
        self:showChatsByTagBrowser(ui, chat_history_manager, config)
        return
    end

    local menu_items = {}
    local self_ref = self

    for idx, chat_entry in ipairs(chats) do
        local chat = chat_entry.chat
        local document_path = chat_entry.document_path

        local title = chat.title or _("Untitled Chat")
        local date_str = chat.timestamp and os.date("%Y-%m-%d", chat.timestamp) or ""
        local msg_count = chat.messages and #chat.messages or 0

        -- Show book info if available
        local book_info = ""
        if chat.book_title then
            book_info = chat.book_title
            if chat.book_author and chat.book_author ~= "" then
                book_info = book_info .. " • " .. chat.book_author
            end
        elseif document_path == "__GENERAL_CHATS__" then
            book_info = _("General Chat")
        end

        local right_text = date_str .. " • " .. msg_count .. " " .. (msg_count == 1 and _("msg") or _("msgs"))

        table.insert(menu_items, {
            text = title,
            info = book_info ~= "" and book_info or nil,
            mandatory = right_text,
            mandatory_dim = true,
            callback = function()
                -- Build a document object for compatibility with existing functions
                local doc = {
                    path = document_path,
                    title = chat.book_title or (document_path == "__GENERAL_CHATS__" and _("General AI Chats") or "#" .. tag),
                    author = chat.book_author,
                }
                self_ref:showChatOptions(ui, document_path, chat, chat_history_manager, config, doc, nil)
            end
        })
    end

    local chat_menu
    chat_menu = Menu:new{
        title = "#" .. tag .. " (" .. #chats .. ")",
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        single_line = false,
        multilines_forced = true,
        items_font_size = 18,
        items_mandatory_font_size = 14,
        onReturn = function()
            -- Close this menu using self_ref.current_menu (chat_menu is nil during Menu:new evaluation)
            if self_ref.current_menu then
                UIManager:close(self_ref.current_menu)
                self_ref.current_menu = nil
            end
            -- Delay to let UIManager process the close before showing new menu
            UIManager:scheduleIn(0.15, function()
                self_ref:showChatsByTagBrowser(ui, chat_history_manager, config)
            end)
        end,
        close_callback = function()
            if self_ref.current_menu == chat_menu then
                self_ref.current_menu = nil
            end
        end,
    }

    -- Enable return button
    chat_menu.paths = chat_menu.paths or {}
    table.insert(chat_menu.paths, true)
    if chat_menu.page_return_arrow then
        chat_menu.page_return_arrow:show()
        chat_menu.page_return_arrow:enableDisable(true)
    end

    self.current_menu = chat_menu
    UIManager:show(chat_menu)
end

return ChatHistoryDialog
