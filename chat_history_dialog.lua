local Device = require("device")
local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
local Screen = Device.screen
local _ = require("gettext")
local InputDialog = require("ui/widget/inputdialog")
local ChatGPTViewer = require("chatgptviewer")
local MessageHistory = require("message_history")
local queryChatGPT = require("gpt_query")
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

function ChatHistoryDialog:showChatListMenuOptions(ui, document, chat_history_manager, config)
    -- Close any existing options dialog first
    safeClose(self.current_options_dialog)

    local dialog
    local buttons = {
        {
            {
                text = _("Delete all chats for this book"),
                callback = function()
                    safeClose(dialog)
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Delete all chats for \"%1\"?\n\nThis action cannot be undone."), document.title),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            -- TODO: Implement delete all chats for document
                            UIManager:show(InfoMessage:new{
                                text = _("Delete all for book not yet implemented"),
                                timeout = 2,
                            })
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
                    self.current_options_dialog = nil
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

    local dialog
    local buttons = {
        {
            {
                text = _("Delete all chats"),
                callback = function()
                    safeClose(dialog)
                    UIManager:show(ConfirmBox:new{
                        text = _("Delete all saved chats?\n\nThis action cannot be undone."),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            -- TODO: Implement delete all functionality
                            UIManager:show(InfoMessage:new{
                                text = _("Delete all not yet implemented"),
                                timeout = 2,
                            })
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
                    self.current_options_dialog = nil
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
        table.insert(menu_items, {
            text = display_text,
            mandatory = right_text,
            mandatory_dim = true,
            bold = true,
            help_text = doc.path == "__GENERAL_CHATS__" and _("AI conversations without book context") or doc.path,
            callback = function()
                logger.info("Document selected: " .. captured_doc.title)
                -- Close the current menu before showing the next one
                safeClose(self_ref.current_menu)
                self_ref.current_menu = nil
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
            self_ref.current_menu = nil
        end,
    }

    self.current_menu = document_menu
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
            mandatory = model .. " • " .. msg_count .. " " .. (msg_count == 1 and _("message") or _("messages")),
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
            self_ref:showChatListMenuOptions(ui, document, chat_history_manager, config)
        end,
        onReturn = function()
            logger.info("Chat history: Return button pressed")
            safeClose(chat_menu)
            self_ref.current_menu = nil
            self_ref:showChatHistoryBrowser(ui, nil, chat_history_manager, config, nav_context)
        end,
        close_callback = function()
            self_ref.current_menu = nil
        end,
    }

    -- Enable the return button
    table.insert(chat_menu.paths, true)

    self.current_menu = chat_menu
    UIManager:show(chat_menu)
end

function ChatHistoryDialog:showChatOptions(ui, document_path, chat, chat_history_manager, config, document, nav_context)
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

    local buttons = {
        {
            {
                text = _("Continue Chat"),
                callback = function()
                    safeClose(dialog)
                    self_ref.current_options_dialog = nil
                    -- Also close the menu before opening the chat viewer
                    safeClose(self_ref.current_menu)
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
                    self_ref:confirmDelete(ui, document_path, chat.id, chat_history_manager, config, document, nav_context)
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
                    text = _("Cancel"),
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

    -- Close any existing chat viewer
    safeClose(self.current_chat_viewer)
    self.current_chat_viewer = nil

    config = config or {}
    config.features = config.features or {}

    local history
    local ok, err = pcall(function()
        history = MessageHistory:fromSavedMessages(chat.messages, chat.model, chat.id, chat.prompt_action)
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

    local function addMessage(message, is_context)
        if not message or message == "" then return nil end

        history:addUserMessage(message, is_context)
        local answer = queryChatGPT(history:getMessages(), config)
        history:addAssistantMessage(answer, history:getModel() or (config and config.model))

        -- Auto-save continued chats
        if config.features.auto_save_all_chats or (config.features.auto_save_chats ~= false) then
            local save_ok = chat_history_manager:saveChat(document_path, chat.title, history, {id = chat.id})
            if not save_ok then
                logger.warn("KOAssistant: Failed to save updated chat")
            end
        end

        return answer
    end

    local date_str = os.date("%Y-%m-%d %H:%M", chat.timestamp or 0)
    local msg_count = #(chat.messages or {})
    local model = chat.model or "AI"

    local detailed_title = (chat.title or _("Untitled")) .. " • " ..
                          date_str .. " • " ..
                          model .. " • " ..
                          tostring(msg_count) .. " " .. _("msgs")

    local function showLoadingDialog()
        local loading = InfoMessage:new{
            text = _("Loading..."),
            timeout = 0.1
        }
        UIManager:show(loading)
    end

    -- Function to create and show the chat viewer
    local function showChatViewer(content_text)
        -- Always close existing viewer first
        safeClose(self_ref.current_chat_viewer)
        self_ref.current_chat_viewer = nil

        local viewer = ChatGPTViewer:new{
            title = detailed_title,
            text = content_text or history:createResultText("", config),
            configuration = config,
            original_history = history,
            original_highlighted_text = "",
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

                    if config and config.features and parts[1] == "features" and parts[2] == "debug" then
                        config.features.debug = value
                    end
                end
            end,
            update_debug_callback = function(debug_mode)
                if history and history.debug_mode ~= nil then
                    history.debug_mode = debug_mode
                end
            end,
            onAskQuestion = function(_, question)
                showLoadingDialog()

                UIManager:scheduleIn(0.1, function()
                    local answer = addMessage(question)

                    if answer then
                        local new_content = history:createResultText("", config)
                        showChatViewer(new_content)
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Failed to get response. Please try again."),
                            timeout = 2,
                        })
                    end
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
                self_ref:showExportOptions(document_path, chat.id, chat_history_manager)
            end,
            close_callback = function()
                self_ref.current_chat_viewer = nil
            end
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

function ChatHistoryDialog:confirmDelete(ui, document_path, chat_id, chat_history_manager, config, document, nav_context)
    local self_ref = self

    UIManager:show(ConfirmBox:new{
        text = _("Are you sure you want to delete this chat?"),
        ok_text = _("Delete"),
        ok_callback = function()
            local success = chat_history_manager:deleteChat(document_path, chat_id)
            UIManager:show(InfoMessage:new{
                text = success and _("Chat deleted") or _("Failed to delete chat"),
                timeout = 2,
            })

            -- Refresh the chat list if we have the document info
            if success and document then
                -- Schedule refresh to happen after the info message
                UIManager:scheduleIn(0.5, function()
                    self_ref:showChatsForDocument(ui, document, chat_history_manager, config, nav_context)
                end)
            end
        end,
    })
end

return ChatHistoryDialog
