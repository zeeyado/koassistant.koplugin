--- Interactive quiz viewer
--- Shows one question at a time with answer selection, scoring, and review.

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("ffi/util").template
local _ = require("koassistant_gettext")
local Screen = Device.screen
local MD = require("apps/filemanager/lib/md")
local logger = require("logger")

local QUIZ_CSS = [[
@page { margin: 0; font-family: 'Noto Sans'; }
body { margin: 0; line-height: 1.3; text-align: left; padding: 0; }
h3 { font-size: 1.1em; margin: 0.5em 0 0.3em 0; font-weight: bold; }
p { margin: 0.4em 0; }
ul, ol { margin: 0.3em 0; padding-left: 1.5em; }
.option-not-picked { color: #999; }
.answer-key { margin-top: 0.8em; padding-top: 0.5em; border-top: 1px solid #999; }
]]

local QuizViewer = InputContainer:extend{
    quiz_data = nil,      -- parsed quiz data from QuizParser
    opts = nil,           -- { title, chapter, book_author, on_save_notebook, on_save_state }
    width = nil,
    height = nil,

    -- State (can be restored from saved quiz_state)
    current_index = 1,
    answers = nil,        -- {[idx] = "B" or "user typed text"}
    revealed = nil,       -- {[idx] = true} when answer has been shown
    correct = nil,        -- {[idx] = true/false/nil}
    phase = "taking",     -- "taking" | "complete"

    -- Layout
    text_padding = Size.padding.large,
    text_margin = Size.margin.small,
    button_padding = Size.padding.default,
}

function QuizViewer:init()
    self.answers = self.answers or {}
    self.revealed = self.revealed or {}
    self.correct = self.correct or {}
    self.opts = self.opts or {}

    self.align = "center"
    self.region = Geom:new{
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    self.width = self.width or Screen:getWidth() - Screen:scaleBySize(12)
    self.height = self.height or Screen:getHeight() - Screen:scaleBySize(12)

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    if Device:isTouchDevice() then
        local range = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
        self.ges_events = {
            TapClose = { GestureRange:new{ ges = "tap", range = range } },
            Swipe = { GestureRange:new{ ges = "swipe", range = range } },
        }
    end

    self:_buildUI()
end

--- Build or rebuild the full UI for the current question
function QuizViewer:_buildUI()
    local questions = self.quiz_data and self.quiz_data.questions or {}
    local total = #questions

    if self.phase == "complete" then
        self:_buildCompletionUI()
        return
    end

    local q = questions[self.current_index]
    if not q then return end

    -- Title bar
    local title_text
    if self.opts.chapter then
        title_text = T(_("Quiz: %1 — %2/%3"), self.opts.chapter, self.current_index, total)
    else
        title_text = T(_("Quiz — Question %1/%2"), self.current_index, total)
    end

    local titlebar = TitleBar:new{
        width = self.width,
        align = "left",
        with_bottom_line = true,
        title = title_text,
        title_face = Font:getFace("smallinfofont"),
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    -- Build buttons for this question type
    local buttons = self:_buildQuestionButtons(q, self.current_index)

    local button_table = ButtonTable:new{
        width = self.width - 2 * self.button_padding,
        buttons = buttons,
        zero_sep = true,
        show_parent = self,
    }
    -- Store for later getButtonById calls
    self._button_table = button_table

    -- Content area
    local content_height = self.height - titlebar:getHeight() - button_table:getSize().h
    local content_html = self:_buildQuestionHTML(q, self.current_index)

    local html_widget = ScrollHtmlWidget:new{
        html_body = content_html,
        css = QUIZ_CSS,
        default_font_size = Screen:scaleBySize(20),
        width = self.width - 2 * self.text_padding - 2 * self.text_margin,
        height = content_height - 2 * self.text_padding - 2 * self.text_margin,
        dialog = self,
    }
    self._html_widget = html_widget

    local text_frame = FrameContainer:new{
        padding = self.text_padding,
        margin = self.text_margin,
        bordersize = 0,
        html_widget,
    }

    self.frame = FrameContainer:new{
        radius = Size.radius.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            titlebar,
            CenterContainer:new{
                dimen = Geom:new{ w = self.width, h = text_frame:getSize().h },
                text_frame,
            },
            CenterContainer:new{
                dimen = Geom:new{ w = self.width, h = button_table:getSize().h },
                button_table,
            },
        },
    }

    self.movable = MovableContainer:new{
        ignore_events = { "swipe", "hold", "hold_release", "hold_pan", "touch", "pan", "pan_release" },
        self.frame,
    }

    self[1] = WidgetContainer:new{
        align = self.align,
        dimen = self.region,
        self.movable,
    }
end

--- Build HTML content for a question
function QuizViewer:_buildQuestionHTML(q, idx)
    local parts = {}

    -- Question type label
    local type_labels = {
        multiple_choice = _("Multiple Choice"),
        short_answer = _("Short Answer"),
        essay = _("Discussion"),
    }
    table.insert(parts, "<h3>" .. (type_labels[q.type] or q.type) .. "</h3>")

    -- Question text
    local q_html = MD(q.question, {}) or q.question
    table.insert(parts, q_html)

    -- MC: show options
    if q.type == "multiple_choice" and q.options then
        table.insert(parts, "<ul>")
        for _li, letter in ipairs({"A", "B", "C", "D"}) do
            if q.options[letter] then
                local prefix = letter .. ") "
                local opt_text = q.options[letter]

                -- Highlight selected answer after reveal (monochrome e-ink friendly)
                if self.revealed[idx] then
                    if letter == q.correct then
                        -- Correct answer: bold with checkmark
                        table.insert(parts, "<li><b>" .. prefix .. opt_text .. "</b> \xE2\x9C\x93</li>")
                    elseif letter == self.answers[idx] and letter ~= q.correct then
                        -- User's wrong pick: regular with X
                        table.insert(parts, "<li>" .. prefix .. opt_text .. " \xE2\x9C\x97</li>")
                    else
                        -- Not picked: grayed out
                        table.insert(parts, '<li><span class="option-not-picked">' .. prefix .. opt_text .. "</span></li>")
                    end
                else
                    -- Before answering: plain options
                    table.insert(parts, "<li>" .. prefix .. opt_text .. "</li>")
                end
            end
        end
        table.insert(parts, "</ul>")
    end

    -- Show answer/explanation after reveal
    if self.revealed[idx] then
        table.insert(parts, '<div class="answer-key">')
        if q.type == "multiple_choice" then
            table.insert(parts, "<p><b>" .. _("Correct answer: ") .. (q.correct or "?") .. "</b></p>")
            if q.explanation and q.explanation ~= "" then
                table.insert(parts, "<p>" .. q.explanation .. "</p>")
            end
        elseif q.type == "short_answer" then
            if q.model_answer and q.model_answer ~= "" then
                table.insert(parts, "<p><b>" .. _("Model answer:") .. "</b> " .. q.model_answer .. "</p>")
            end
            if q.key_points and #q.key_points > 0 then
                table.insert(parts, "<p><b>" .. _("Key points:") .. "</b></p><ul>")
                for _ki, kp in ipairs(q.key_points) do
                    table.insert(parts, "<li>" .. kp .. "</li>")
                end
                table.insert(parts, "</ul>")
            end
        elseif q.type == "essay" then
            if q.key_points and #q.key_points > 0 then
                table.insert(parts, "<p><b>" .. _("Key points a good answer should cover:") .. "</b></p><ul>")
                for _ki, kp in ipairs(q.key_points) do
                    table.insert(parts, "<li>" .. kp .. "</li>")
                end
                table.insert(parts, "</ul>")
            end
        end
        table.insert(parts, "</div>")
    end

    return table.concat(parts, "\n")
end

--- Build button rows for a question
function QuizViewer:_buildQuestionButtons(q, idx)
    local buttons = {}
    local self_ref = self

    if q.type == "multiple_choice" then
        if not self.revealed[idx] then
            -- Row 1: answer options A B C D
            local option_row = {}
            for _li, letter in ipairs({"A", "B", "C", "D"}) do
                if q.options and q.options[letter] then
                    table.insert(option_row, {
                        text = letter,
                        id = "opt_" .. letter,
                        callback = function()
                            self_ref:_selectMCAnswer(idx, letter)
                        end,
                    })
                end
            end
            table.insert(buttons, option_row)
        else
            -- After answering: show result status
            local result_text
            if self.correct[idx] then
                result_text = _("Correct!")
            else
                result_text = T(_("Incorrect — answer: %1"), q.correct or "?")
            end
            table.insert(buttons, {{ text = result_text, enabled = false }})
        end
    elseif q.type == "short_answer" or q.type == "essay" then
        local reveal_label = q.type == "essay" and _("Show Key Points") or _("Show Answer")
        if not self.revealed[idx] then
            table.insert(buttons, {
                {
                    text = reveal_label,
                    callback = function() self_ref:_revealAnswer(idx) end,
                },
            })
        else
            -- Self-grading: always show both buttons, highlight current selection
            table.insert(buttons, {
                {
                    text = self.correct[idx] == true and ("[" .. _("Got it right") .. "]") or _("Got it right"),
                    callback = function() self_ref:_selfGrade(idx, true) end,
                },
                {
                    text = self.correct[idx] == false and ("[" .. _("Missed it") .. "]") or _("Missed it"),
                    callback = function() self_ref:_selfGrade(idx, false) end,
                },
            })
        end
    end

    -- Navigation row (always present)
    local total = #(self.quiz_data.questions or {})
    local nav_row = {
        {
            text = "‹ " .. _("Prev"),
            enabled = self.current_index > 1,
            callback = function() self_ref:_navigate(-1) end,
        },
        {
            text = T("%1/%2", self.current_index, total),
            callback = function() self_ref:_showQuestionPicker() end,
        },
        {
            text = _("Next") .. " ›",
            enabled = self.current_index < total,
            callback = function() self_ref:_navigate(1) end,
        },
        {
            text = _("Close"),
            callback = function() self_ref:_confirmClose() end,
        },
    }

    -- Replace "Next" with "Finish" on last question
    if self.current_index == total then
        nav_row[3] = {
            text = _("Finish"),
            callback = function() self_ref:_showCompletion() end,
        }
    end

    table.insert(buttons, nav_row)

    -- Make buttons non-bold
    for _ri, btn_row in ipairs(buttons) do
        for _bi, btn in ipairs(btn_row) do
            btn.font_bold = false
        end
    end

    return buttons
end

--- Select a multiple choice answer
function QuizViewer:_selectMCAnswer(idx, letter)
    local q = self.quiz_data.questions[idx]
    if not q then return end

    self.answers[idx] = letter
    self.revealed[idx] = true
    self.correct[idx] = (letter == q.correct)

    self:_refresh()
end

--- Reveal answer (for short answer / essay)
function QuizViewer:_revealAnswer(idx)
    self.revealed[idx] = true
    self:_refresh()
end

--- Self-grade a short answer or essay
function QuizViewer:_selfGrade(idx, is_correct)
    self.correct[idx] = is_correct
    self:_refresh()
end

--- Navigate to previous/next question
function QuizViewer:_navigate(delta)
    local total = #(self.quiz_data.questions or {})
    local new_idx = self.current_index + delta
    if new_idx >= 1 and new_idx <= total then
        self.current_index = new_idx
        self:_refresh()
    end
end

--- Show question picker (jump to any question)
function QuizViewer:_showQuestionPicker()
    local questions = self.quiz_data.questions or {}
    local buttons = {}
    local self_ref = self

    for idx, q in ipairs(questions) do
        -- Build label: number + type indicator + status
        local type_short = { multiple_choice = "MC", short_answer = "SA", essay = "D" }
        local status = ""
        if self_ref.correct[idx] == true then
            status = " [+]"
        elseif self_ref.correct[idx] == false then
            status = " [-]"
        elseif self_ref.revealed[idx] then
            status = " [?]"
        end

        local label = T("%1. %2%3", idx, type_short[q.type] or "?", status)
        -- 3 per row
        if (idx - 1) % 3 == 0 then
            table.insert(buttons, {})
        end
        table.insert(buttons[#buttons], {
            text = label,
            callback = function()
                UIManager:close(self_ref._picker_dialog)
                self_ref.current_index = idx
                self_ref:_refresh()
            end,
        })
    end

    self._picker_dialog = ButtonDialog:new{
        title = _("Jump to Question"),
        buttons = buttons,
    }
    UIManager:show(self._picker_dialog)
end

--- Show completion summary
function QuizViewer:_showCompletion()
    self.phase = "complete"
    self:_refresh()
end

--- Build the completion screen UI
function QuizViewer:_buildCompletionUI()
    local questions = self.quiz_data.questions or {}
    local total = #questions

    -- Calculate scores per type
    local scores = { multiple_choice = {0, 0}, short_answer = {0, 0}, essay = {0, 0} }
    local total_correct = 0
    local total_answered = 0

    for idx, q in ipairs(questions) do
        if scores[q.type] then
            scores[q.type][2] = scores[q.type][2] + 1
        end
        if self.correct[idx] ~= nil then
            total_answered = total_answered + 1
            if self.correct[idx] then
                total_correct = total_correct + 1
                if scores[q.type] then
                    scores[q.type][1] = scores[q.type][1] + 1
                end
            end
        end
    end

    local pct = total_answered > 0 and math.floor(total_correct / total_answered * 100 + 0.5) or 0

    -- Build summary HTML
    local parts = {}
    table.insert(parts, "<h3>" .. _("Quiz Complete") .. "</h3>")
    table.insert(parts, "<p><b>" .. T(_("Score: %1/%2 (%3)"), total_correct, total_answered, pct .. "%") .. "</b></p>")

    local type_labels = { multiple_choice = _("Multiple Choice"), short_answer = _("Short Answer"), essay = _("Discussion") }
    table.insert(parts, "<ul>")
    for _ti, qtype in ipairs({"multiple_choice", "short_answer", "essay"}) do
        if scores[qtype][2] > 0 then
            table.insert(parts, "<li>" .. type_labels[qtype] .. ": " .. scores[qtype][1] .. "/" .. scores[qtype][2] .. "</li>")
        end
    end
    table.insert(parts, "</ul>")

    -- Unanswered count
    local unanswered = total - total_answered
    if unanswered > 0 then
        table.insert(parts, "<p>" .. T(_("%1 question(s) not answered."), unanswered) .. "</p>")
    end

    local html_body = table.concat(parts, "\n")

    -- Title bar
    local titlebar = TitleBar:new{
        width = self.width,
        align = "left",
        with_bottom_line = true,
        title = _("Quiz Results"),
        title_face = Font:getFace("smallinfofont"),
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    -- Buttons
    local self_ref = self
    local button_rows = {
        {
            {
                text = _("Copy"),
                callback = function()
                    self_ref:_copyResults()
                end,
            },
            {
                text = _("Export"),
                callback = function()
                    self_ref:_exportResults()
                end,
            },
            {
                text = _("Notebook"),
                callback = function()
                    self_ref:_saveToNotebook()
                end,
            },
        },
        {
            {
                text = _("Review All"),
                callback = function()
                    self_ref.phase = "taking"
                    self_ref.current_index = 1
                    self_ref:_refresh()
                end,
            },
            {
                text = _("Close"),
                callback = function()
                    self_ref:onClose()
                end,
            },
        },
    }
    for _ri, row in ipairs(button_rows) do
        for _bi, btn in ipairs(row) do
            btn.font_bold = false
        end
    end

    local button_table = ButtonTable:new{
        width = self.width - 2 * self.button_padding,
        buttons = button_rows,
        zero_sep = true,
        show_parent = self,
    }

    local content_height = self.height - titlebar:getHeight() - button_table:getSize().h

    local html_widget = ScrollHtmlWidget:new{
        html_body = html_body,
        css = QUIZ_CSS,
        default_font_size = Screen:scaleBySize(20),
        width = self.width - 2 * self.text_padding - 2 * self.text_margin,
        height = content_height - 2 * self.text_padding - 2 * self.text_margin,
        dialog = self,
    }

    local text_frame = FrameContainer:new{
        padding = self.text_padding,
        margin = self.text_margin,
        bordersize = 0,
        html_widget,
    }

    self.frame = FrameContainer:new{
        radius = Size.radius.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            titlebar,
            CenterContainer:new{
                dimen = Geom:new{ w = self.width, h = text_frame:getSize().h },
                text_frame,
            },
            CenterContainer:new{
                dimen = Geom:new{ w = self.width, h = button_table:getSize().h },
                button_table,
            },
        },
    }

    self.movable = MovableContainer:new{
        ignore_events = { "swipe", "hold", "hold_release", "hold_pan", "touch", "pan", "pan_release" },
        self.frame,
    }

    self[1] = WidgetContainer:new{
        align = self.align,
        dimen = self.region,
        self.movable,
    }
end

--- Refresh the viewer (rebuild UI and redraw)
function QuizViewer:_refresh()
    -- Trigger full rebuild
    self:_buildUI()
    UIManager:setDirty(self, "partial")
end

--- Build formatted text summary of quiz results (for notebook, copy, export)
function QuizViewer:_buildResultText()
    local questions = self.quiz_data.questions or {}
    local lines = {}
    local book_title = self.opts and self.opts.title or _("Unknown")
    local chapter = self.opts and self.opts.chapter

    table.insert(lines, "# " .. _("Quiz Results"))
    if chapter then
        table.insert(lines, T(_("**Book:** %1 — %2"), book_title, chapter))
    else
        table.insert(lines, T(_("**Book:** %1"), book_title))
    end
    table.insert(lines, T(_("**Date:** %1"), os.date("%Y-%m-%d %H:%M")))
    table.insert(lines, "")

    local total_correct = 0
    local total_answered = 0
    for idx in ipairs(questions) do
        if self.correct[idx] ~= nil then
            total_answered = total_answered + 1
            if self.correct[idx] then total_correct = total_correct + 1 end
        end
    end
    local pct = total_answered > 0 and math.floor(total_correct / total_answered * 100 + 0.5) or 0
    table.insert(lines, T(_("**Score: %1/%2 (%3)**"), total_correct, total_answered, pct .. "%"))
    table.insert(lines, "")

    for idx, q in ipairs(questions) do
        table.insert(lines, T("**%1.** %2", idx, q.question))
        if q.type == "multiple_choice" and self.answers[idx] then
            table.insert(lines, T(_("Your answer: %1 — Correct: %2"), self.answers[idx], q.correct or "?"))
        end
        if self.correct[idx] == true then
            table.insert(lines, _("Result: Correct"))
        elseif self.correct[idx] == false then
            table.insert(lines, _("Result: Incorrect"))
        else
            table.insert(lines, _("Result: Not answered"))
        end
        table.insert(lines, "")
    end

    return table.concat(lines, "\n")
end

--- Copy quiz results to clipboard
function QuizViewer:_copyResults()
    local Device = require("device")
    local text = self:_buildResultText()
    Device.input.setClipboardText(text)
    UIManager:show(InfoMessage:new{
        text = _("Quiz results copied to clipboard."),
        timeout = 2,
    })
end

--- Export quiz results to file
function QuizViewer:_exportResults()
    local text = self:_buildResultText()
    local book_title = self.opts and self.opts.title or "Quiz"
    local chapter = self.opts and self.opts.chapter

    -- Build filename
    local filename = book_title:gsub("[/\\:*?\"<>|]", "_")
    if chapter then
        filename = filename .. " - " .. chapter:gsub("[/\\:*?\"<>|]", "_")
    end
    filename = filename .. " Quiz " .. os.date("%Y-%m-%d") .. ".md"

    local DataStorage = require("datastorage")
    local export_dir = DataStorage:getDataDir() .. "/koassistant_exports"
    local lfs = require("libs/libkoreader-lfs")
    lfs.mkdir(export_dir)
    local filepath = export_dir .. "/" .. filename

    local file = io.open(filepath, "w")
    if file then
        file:write(text)
        file:close()
        UIManager:show(InfoMessage:new{
            text = T(_("Saved to:\n%1"), filepath),
        })
    else
        UIManager:show(InfoMessage:new{
            text = _("Failed to save file."),
        })
    end
end

--- Save quiz results to notebook
function QuizViewer:_saveToNotebook()
    local text = self:_buildResultText()
    if self.opts and self.opts.on_save_notebook then
        self.opts.on_save_notebook(text)
        UIManager:show(InfoMessage:new{
            text = _("Quiz results saved to notebook."),
            timeout = 2,
        })
    else
        UIManager:show(InfoMessage:new{
            text = _("Notebook not available for this book."),
        })
    end
end

--- Confirm close when quiz is in progress
function QuizViewer:_confirmClose()
    -- If quiz is complete or all answered, just close
    local all_revealed = true
    for idx in ipairs(self.quiz_data.questions or {}) do
        if not self.revealed[idx] then
            all_revealed = false
            break
        end
    end

    if self.phase == "complete" or all_revealed then
        self:onClose()
        return
    end

    -- Confirm with unanswered questions
    local ConfirmBox = require("ui/widget/confirmbox")
    local self_ref = self
    UIManager:show(ConfirmBox:new{
        text = _("You have unanswered questions. Close the quiz?"),
        ok_text = _("Close"),
        cancel_text = _("Continue"),
        ok_callback = function()
            self_ref:onClose()
        end,
    })
end

-- Event handlers

function QuizViewer:onClose()
    -- Save quiz state for review on next open
    if self.opts and self.opts.on_save_state then
        -- Only save if user has answered at least one question
        local has_answers = false
        for _idx in ipairs(self.quiz_data.questions or {}) do
            if self.revealed[_idx] then has_answers = true; break end
        end
        if has_answers then
            self.opts.on_save_state({
                answers = self.answers,
                revealed = self.revealed,
                correct = self.correct,
                current_index = self.current_index,
                phase = self.phase,
            })
        end
    end
    UIManager:close(self)
    return true
end

function QuizViewer:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "partial", self.frame and self.frame.dimen
    end)
end

function QuizViewer:onShow()
    UIManager:setDirty(self, function()
        return "partial", self.frame and self.frame.dimen
    end)
    return true
end

function QuizViewer:onTapClose(arg, ges_ev)
    if self.frame and ges_ev.pos:notIntersectWith(self.frame.dimen) then
        self:_confirmClose()
    end
    return true
end

function QuizViewer:onSwipe(arg, ges)
    if self.frame and ges.pos:intersectWith(self.frame.dimen) then
        local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
        if direction == "west" then
            -- Swipe left: next question
            self:_navigate(1)
            return true
        elseif direction == "east" then
            -- Swipe right: previous question
            self:_navigate(-1)
            return true
        end
    end
    return true
end

return QuizViewer
