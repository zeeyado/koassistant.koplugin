-- KOAssistant luacheck configuration
std = "luajit"
unused_args = false
self = false

-- KOReader globals
globals = {
    "G_reader_settings",
    "G_defaults",
    "table.pack",
    "table.unpack",
}

-- Warnings reference: https://luacheck.readthedocs.io/en/stable/warnings.html
-- W211: unused variable
-- W411: variable was previously defined
-- W421: shadowing definition of argument
-- W431: shadowing upvalue
-- W432: shadowing upvalue argument
-- W631: line too long

ignore = {
    "211",      -- Unused variables (common in Lua - keeping imports for later)
    "212",      -- Unused argument
    "231",      -- Variable is never accessed (often intentional placeholders)
    "241",      -- Variable is mutated but never accessed
    "311",      -- Value assigned to variable is unused
    "312",      -- Value of argument is unused
    "411",      -- Variable was previously defined (redefinition in blocks)
    "542",      -- Empty if branch
    "561",      -- Cyclomatic complexity too high
    "571",      -- not (x ~= y) style suggestions
    "611",      -- Line contains only whitespace
    "612",      -- Line contains trailing whitespace
    "631",      -- Line too long

    -- Safe to shadow: common local variable names reused in nested blocks
    "411/success", "411/result", "411/err", "411/ok", "411/logger",
    "431/success", "431/result", "431/err", "431/ok", "431/logger",

    -- Safe to shadow: loop index variables in nested loops
    "431/_idx", "431/_i",
    "421/_idx", "421/_i",  -- Also loop variable redefinition

    -- Safe to shadow: commonly reused module references inside functions
    -- (creating local ref to module for clarity/performance)
    "431/UIManager", "431/InfoMessage", "431/ButtonDialog", "431/Menu",
    "431/Notification", "431/Device", "431/ModelLists", "431/TestConfig",
}

-- CRITICAL: We do NOT ignore "431/_" - this catches the gettext bug:
--   local _ = require("koassistant_gettext")
--   for _, x in ipairs(...) -- CAUGHT! shadowing _ breaks translations

-- Per-file overrides
files["ui/prompts_manager.lua"] = {
    ignore = { "423" },  -- Shadowing loop variable (nested loops with _idx)
}
files["main.lua"] = {
    ignore = { "432/self" },  -- Shadowing self in nested callbacks
}
files["dialogs.lua"] = {
    ignore = { "421/prompt_type" },  -- Argument shadowing in callback
}
files["tests/**/*.lua"] = {
    ignore = { "113", "421", "431" },  -- Tests can be more relaxed
}
