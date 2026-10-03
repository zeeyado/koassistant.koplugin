-- B360 (2026-09-29): a screen that closes before its picker opens (and comes
-- back from the picker's Back or Cancel) must also come back when the reader
-- taps outside the picker or presses the Back key, or the whole flow is lost.
-- KOReader routes both through the widget's onClose: ButtonDialog calls
-- tap_close_callback there (a button's own UIManager:close never does);
-- SpinWidget calls close_callback on EVERY close, OK and Cancel included, so
-- a spinner's reopen lives in close_callback alone (with it beside the
-- button callbacks too, the screen would open twice). ConfirmBox's onClose
-- already calls cancel_callback.
--
-- One source guard per wired dialog: the constructor holding the anchor must
-- carry its hook. Also: the action wizard's refresh closes the step-3 dialog
-- it reopens (a stale name opened a second copy over the first).
--
-- Run: lua tests/unit/test_tap_outside_back.lua  (or lua tests/run_tests.lua --unit)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    return tests_dir:match("(.+)/[^/]+$") or "."
end
local plugin_dir = setupPaths()

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:suite(name) print(string.format("\n  [%s]", name)) end
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then self.passed = self.passed + 1; print("    ok   " .. name)
    else self.failed = self.failed + 1; print("    FAIL " .. name); print("      " .. tostring(err)) end
end
function TestRunner:assertTrue(v, msg) if not v then error(msg or "expected truthy", 2) end end

local sources = {}
local function read(rel)
    if not sources[rel] then
        local f = assert(io.open(plugin_dir .. "/" .. rel, "r"))
        sources[rel] = f:read("*a")
        f:close()
    end
    return sources[rel]
end

-- The widget constructor (brace-matched) holding the nth occurrence of anchor.
-- Returns the widget name and the constructor text.
local function constructorAt(src, anchor, nth)
    local pos = 0
    for _i = 1, nth or 1 do
        pos = src:find(anchor, pos + 1, true)
        if not pos then return nil end
    end
    local start, widget
    local limit = pos + #anchor  -- an anchor may hold the constructor call itself
    for _j, w in ipairs({ "ButtonDialog:new", "SpinWidget:new" }) do
        local i = 1
        while true do
            local s = src:find(w, i, true)
            if not s or s > limit then break end
            if not start or s > start then start, widget = s, w:match("^(%a+)") end
            i = s + 1
        end
    end
    if not start then return nil end
    local open = src:find("{", start, true)
    local depth, i = 0, open
    repeat
        local c = src:sub(i, i)
        if c == "{" then depth = depth + 1 elseif c == "}" then depth = depth - 1 end
        i = i + 1
    until depth == 0 or i > #src
    local body = src:sub(open, i - 1)
    -- The anchor must sit inside this constructor (or right before its brace)
    if pos > i then return nil end
    return widget, body
end

local function expectHook(rel, anchor, nth, reopen)
    local widget, body = constructorAt(read(rel), anchor, nth)
    TestRunner:assertTrue(widget, rel .. ": constructor for " .. anchor)
    if widget == "SpinWidget" then
        TestRunner:assertTrue(body:find("close_callback", 1, true), rel .. ": spinner close_callback")
        TestRunner:assertTrue(not body:find("cancel_callback", 1, true),
            rel .. ": no cancel_callback beside it (the screen would open twice)")
        if reopen then
            local _s, n = body:gsub(reopen:gsub("%p", "%%%0"), "")
            TestRunner:assertTrue(n == 1, rel .. ": the spinner reopens its screen once, got " .. n)
        end
    else
        TestRunner:assertTrue(body:find("tap_close_callback", 1, true), rel .. ": tap_close_callback")
        if reopen then
            local hook = body:match("tap_close_callback%s*=%s*(.-)\n%s*}%s*$")
                or body:match("tap_close_callback%s*=%s*(.*)")
            TestRunner:assertTrue(hook and hook:find(reopen, 1, true),
                rel .. ": the tap outside runs " .. reopen)
        end
    end
end

local SITES = {
    -- X-Ray popup and its checkpoint, section and version screens
    { "main.lua", "title = group_title", 1, "self_ref:_showXrayScopePopup(action, action_id, on_update, cached_entry, opts)" },
    { "main.lua", 'title = T(_("Section X-Ray: %1"), sec.label)', 1, "self_ref:_showSectionXrayList(opts)" },
    { "main.lua", 'title = T(_("Delete Section X-Ray: %1?"), sec.label)', 1, "self_ref:_showSectionXrayList(opts)" },
    { "main.lua", "They include your complete version (100%), which is not installed", 1, "self_ref:_showXrayCheckpointList(opts)" },
    { "main.lua", 'title = T(_("Delete all %1 checkpoints?"), #ladder)', 1, "self_ref:_showXrayCheckpointList(opts)" },
    { "main.lua", "title = spoiler_confirm", 1, "self_ref:_showXrayLadderRungOptions(rung, opts)" },
    { "main.lua", "buttons = confirm_rows,", 1, "self_ref:_showXrayLadderRungOptions(rung, opts)" },
    { "main.lua", 'title = T(_("Checkpoint: %1"), label)', 1, "self_ref:_showXrayCheckpointList(opts)" },
    { "main.lua", 'title = T(_("Install the version from %1 as your current X-Ray?', 1, "self_ref:_showXrayCheckpointList(opts)" },
    { "main.lua", 'title = T(_("Delete the X-Ray version from %1?"), label)', 1, "self_ref:_showXrayCheckpointList(opts)" },
    { "main.lua", 'title = T(_("X-Ray version: %1"), label)', 1, "self_ref:_showXrayCheckpointList(opts)" },
    { "main.lua", "-- A tap outside is Back (B360)\n    tap_close_callback = function()\n      if opts and opts.back", 1, "opts.back()" },
    { "main.lua", 'title = opts.title or _("Checkpoint spacing:")', 1, "opts.on_back()" },
    -- Cross-book merge
    { "koassistant_xray_merge.lua", "title = confirm_text,", 1, "XrayMerge.startCrossBookFlow(opts)" },
    -- The fold and chain confirms are shared by the merge picker's rows and
    -- the direct entries (B394 slice 1): the tap outside runs the `back` they
    -- were handed (the picker's reopen; nothing for a direct entry, which
    -- closed no screen that Back returns to). The hand-off is checked below.
    { "koassistant_xray_merge.lua", "title = confirm_title, buttons = btns,", 1, "back" },
    { "koassistant_xray_merge.lua", "buttons = chain_buttons,", 1, "back" },
    { "koassistant_xray_merge.lua", 'other books with an X-Ray"), opts.title or "?")', 1, "XrayMerge.startCrossBookFlow(opts)" },
    -- Duplicates
    { "koassistant_xray_dedup.lua", "title = T(_(\"%1: %2\"), pair.cat_label, reasonLabel(pair.reason))", 1, "showList(false)" },
    { "koassistant_xray_dedup.lua", 'title = _("Never-merge pairs: tap one to allow it again")', 1, "showList(false)" },
    -- Groups
    { "koassistant_book_groups_ui.lua", "tagged with the series \\\"%2\\\".\"),", 1, "done" },
    { "koassistant_book_groups_ui.lua", 'title_text = T(_("Move \\"%1\\" to position"), title)', 1, "GroupsUI.showMoveDialog(group_id, path, opts)" },
    { "koassistant_book_groups_ui.lua", 'title = T(_("Groups: %1"), BookGroups.displayTitle(path, opts.ui))', 1, "opts.on_close()" },
    -- Book Settings: the Quiz spinners
    { "koassistant_book_settings.lua", "extra_callback = function() setField(field, nil) end,", 1, "reopen()" },
    -- Requests: the checkpoint size warning, the library books editor, the alias pages
    { "koassistant_dialogs.lua", "characters (~%2K-%3K tokens) in this background request", 1, 'on_complete(nil, "size_warning_declined")' },
    { "koassistant_dialogs.lua", 'items selected: tap to remove"), #books)', 1, "refreshInputDialog()" },
    { "koassistant_dialogs.lua", '.. (total_pages > 1 and ("  (" .. page .. "/" .. total_pages .. ")") or ""),', 1, "show_category_pick()" },
    { "koassistant_dialogs.lua", '.. (total_pages > 1 and ("  (" .. page .. "/" .. total_pages .. ")") or ""),', 2, "show_category_pick()" },
    -- Action wizard and editors
    { "koassistant_ui/prompts_manager.lua", 'title = _("Select Context"),', 1, "self:showStep1_NameAndContext(state)" },
    { "koassistant_ui/prompts_manager.lua", "self.wizard_behavior_dialog = ButtonDialog:new{", 1, "self:showStep3_Settings(state)" },
    { "koassistant_ui/prompts_manager.lua", "self.binary_dialog = ButtonDialog:new{", 1, "self:showPerProviderReasoningMenu(state)" },
    { "koassistant_ui/prompts_manager.lua", "self.effort_dialog = ButtonDialog:new{", 1, "self:showPerProviderReasoningMenu(state)" },
    { "koassistant_ui/prompts_manager.lua", "self.effort_dialog = ButtonDialog:new{", 2, "self:showPerProviderReasoningMenu(state)" },
    { "koassistant_ui/prompts_manager.lua", "self.per_provider_dialog = ButtonDialog:new{", 1, "refreshParent()" },
    { "koassistant_ui/prompts_manager.lua", "self.anthropic_dialog = ButtonDialog:new{", 1, "self:showPerProviderReasoningMenu(state)" },
    { "koassistant_ui/prompts_manager.lua", "local new_config = { budget = spin.value }", 1, "self:showPerProviderReasoningMenu(state)" },
    { "koassistant_ui/prompts_manager.lua", "self.anthropic_effort_dialog = ButtonDialog:new{", 1, "self:showPerProviderReasoningMenu(state)" },
    { "koassistant_ui/prompts_manager.lua", "self.openai_dialog = ButtonDialog:new{", 1, "self:showPerProviderReasoningMenu(state)" },
    { "koassistant_ui/prompts_manager.lua", "self.gemini_dialog = ButtonDialog:new{", 1, "self:showPerProviderReasoningMenu(state)" },
    { "koassistant_ui/prompts_manager.lua", "self.builtin_behavior_dialog = ButtonDialog:new{", 1, "self:showBuiltinSettingsDialog(state)" },
    { "koassistant_ui/prompts_manager.lua", "self.domain_selector_dialog = ButtonDialog:new{", 1, "return_callback()" },
    { "koassistant_ui/prompts_manager.lua", "self.custom_behavior_dialog = ButtonDialog:new{", 1, "self:showCustomQuickSettingsDialog(state)" },
}

TestRunner:suite("a tap outside a step does what its Back or Cancel does (B360)")

for _idx, site in ipairs(SITES) do
    local rel, anchor, nth, reopen = site[1], site[2], site[3], site[4]
    TestRunner:test(string.format("%s: %s%s", rel, anchor:gsub("%s+", " "):sub(1, 60),
        nth > 1 and (" (#" .. nth .. ")") or ""), function()
        expectHook(rel, anchor, nth, reopen)
    end)
end

TestRunner:suite("the merge picker hands its reopen to the shared confirms (B394 slice 1)")

TestRunner:test("the picker's fold and chain rows come back to the picker", function()
    local src = read("koassistant_xray_merge.lua")
    TestRunner:assertTrue(src:find("confirmFanIn(opts, mates, main_entry, tgt_group,\n"
        .. "                            function() XrayMerge.startCrossBookFlow(opts) end)", 1, true),
        "the project fold's confirm reopens the picker on Back and on a tap outside")
    TestRunner:assertTrue(src:find("-- Back one step to the book list, not abandon\n"
        .. "                    function() XrayMerge.startCrossBookFlow(opts) end)", 1, true),
        "the series chain's confirm reopens the picker on Back and on a tap outside")
    -- Both confirms run `back` from their Back button as well
    local _s, n = src:gsub("if back then back%(%) end", "")
    TestRunner:assertTrue(n == 2, "Back and the tap outside do the same thing in both confirms, got " .. n)
end)

TestRunner:suite("the action wizard refreshes the step 3 it shows")

TestRunner:test("no refresh closes a dialog that no longer exists", function()
    local pm = read("koassistant_ui/prompts_manager.lua")
    TestRunner:assertTrue(not pm:find("self.advanced_dialog", 1, true),
        "self.advanced_dialog is never assigned: closing it left step 3 open under its new copy")
    local _s, n = pm:gsub("UIManager:close%(self%.step3_dialog%)\n%s*self:showStep3_Settings%(state%)", "")
    TestRunner:assertTrue(n >= 11, "every reopen of step 3 closes the old one first, got " .. n)
end)

print(string.format("\n  test_tap_outside_back: %d passed, %d failed",
    TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
