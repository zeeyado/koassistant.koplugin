--[[--
One-time feature-settings migrations (the upgrade chain).

Extracted VERBATIM from AskGPT:initSettings (main.lua, 2026-08-10) so the chain
is pure and unit-testable: tests/unit/test_migrations.lua runs synthetic upgrade
fixtures (v0.20.0 disk shapes, fresh-install seeds) through it and asserts
outcomes + idempotence.

Contract:
  * Migrations.run(features) mutates the given features table IN PLACE and
    returns needs_save; the caller persists (initSettings saveSetting + flush).
  * Every one-time stamp written here MUST also be listed in
    koassistant/storage/storage_registry.lua SETTINGS_SUBKEYS.internal — otherwise Reset
    Settings / Fresh Start delete the stamp and the migration re-fires against a
    post-migration table (the _xray_auto_legacy_optin near-miss, 2026-08-10).
    test_storage_registry.lua's stamp scan enforces this.
  * Fresh installs are seeded with the stamps that must NOT fire on a virgin
    table (see the features seed in initSettings); keep that seed in sync when
    adding a migration whose legacy state is indistinguishable from fresh.
  * The model-default refresh deliberately stays in initSettings: it re-runs
    every launch (not one-time) and needs the plugin instance + ModelLists.
]]

local logger = require("koassistant.core.logger")
local Constants = require("koassistant.core.constants")
local _ = require("koassistant.core.gettext")

local Migrations = {}

--- Run the one-time feature migrations against a persisted features table.
--- @param features table decoded features table (never nil)
--- @return boolean needs_save true when anything changed
function Migrations.run(features)
  local needs_save = false

  -- (show_debug_in_chat is deliberately NOT backfilled — nil reads as "off"
  -- everywhere it is consumed, and writing false here re-materialized the key for
  -- every user on every launch, defeating read-through. Defaults sweep D3.)

  -- Migrate translate_to to translation_language
  if features.translate_to ~= nil then
    if features.translation_language == nil then
      features.translation_language = features.translate_to
    end
    features.translate_to = nil
    needs_save = true
  end

  -- Clean up removed settings
  if features.use_new_request_format ~= nil then
    features.use_new_request_format = nil
    needs_save = true
  end
  -- The plain-text switches for right-to-left text left 2026-11-07 (B621):
  -- the Markdown view lays every block out in its own direction and draws
  -- every script in its own face, so a reader who had one on would otherwise
  -- never see that. Cleared, not kept.
  for _idx, k in ipairs({ "rtl_chat_text_mode", "rtl_translate_text_mode", "rtl_dictionary_text_mode" }) do
    if features[k] ~= nil then
      features[k] = nil
      needs_save = true
    end
  end

  -- Clean up transient flags that should never be persisted
  -- These are set at runtime for dictionary lookups but should not be saved
  if features.compact_view ~= nil then
    features.compact_view = nil
    needs_save = true
    logger.info("KOAssistant: Cleaned up stray compact_view flag")
  end
  if features.dictionary_view ~= nil then
    features.dictionary_view = nil
    needs_save = true
    logger.info("KOAssistant: Cleaned up stray dictionary_view flag")
  end
  if features.minimal_buttons ~= nil then
    features.minimal_buttons = nil
    needs_save = true
    logger.info("KOAssistant: Cleaned up stray minimal_buttons flag")
  end

  -- ONE-TIME migration to new behavior system (v0.6+)
  -- Only runs once, then sets behavior_migrated = true
  if not features.behavior_migrated then
    -- Migrate legacy custom_ai_behavior to custom_behaviors array
    if features.ai_behavior_variant == "custom"
       and features.custom_ai_behavior
       and features.custom_ai_behavior ~= "" then
      features.custom_behaviors = {
        {
          id = "migrated_1",
          name = _("Custom (migrated)"),
          text = features.custom_ai_behavior,
        }
      }
      features.selected_behavior = "migrated_1"
      logger.info("KOAssistant: Migrated custom_ai_behavior to custom_behaviors array")
    elseif features.ai_behavior_variant == "minimal" then
      features.selected_behavior = "mini"  -- builtin was renamed "minimal" -> "mini" (23c0726)
    else
      features.selected_behavior = "full"
    end
    -- Clean up legacy fields
    features.ai_behavior_variant = nil
    features.behavior_migrated = true
    needs_save = true
    logger.info("KOAssistant: Completed behavior system migration")
  end

  -- ONE-TIME migration: translate_copy_translation_only toggle → translate_copy_content dropdown
  if features.translate_copy_translation_only ~= nil then
    if features.translate_copy_translation_only then
      features.translate_copy_content = "response"
    else
      features.translate_copy_content = "full"
    end
    features.translate_copy_translation_only = nil
    needs_save = true
    logger.info("KOAssistant: Migrated translate_copy_translation_only to translate_copy_content")
  end

  -- (selected_behavior is deliberately NOT backfilled — every read site resolves
  -- `features.selected_behavior or "standard"`, so writing it here only
  -- re-materialized the key for every user on every launch. Defaults sweep D3.)

  -- ONE-TIME migration: old export directory options → new simplified options
  -- book_folder → exports_folder + checkbox
  -- book_folder_custom → custom + checkbox
  if features.export_save_directory == "book_folder" then
    features.export_save_directory = "exports_folder"
    features.export_book_to_book_folder = true
    needs_save = true
    logger.info("KOAssistant: Migrated export_save_directory: book_folder → exports_folder + checkbox")
  elseif features.export_save_directory == "book_folder_custom" then
    features.export_save_directory = "custom"
    features.export_book_to_book_folder = true
    needs_save = true
    logger.info("KOAssistant: Migrated export_save_directory: book_folder_custom → custom + checkbox")
  end

  -- ONE-TIME migration: ui_language_auto boolean → ui_language string
  -- Converts old toggle to new picker format
  if features.ui_language == nil then
    if features.ui_language_auto == false then
      features.ui_language = "en"
      logger.info("KOAssistant: Migrated ui_language_auto=false to ui_language='en'")
    else
      features.ui_language = "auto"
    end
    features.ui_language_auto = nil  -- Clean up old setting
    needs_save = true
  end

  -- ONE-TIME reset: quiz_chapter_depth changed from cumulative TOC levels ("Follow KOReader
  -- TOC" / "Level 1-2" / "Level 1-3") to a single chapter level (Auto / Level 1/2/3 / All
  -- headings, default Level 2). The old values' meanings don't carry over, and the old default
  -- ("Follow KOReader TOC" = every heading) over-triggered, so re-baseline everyone on the new
  -- default. Runs once; a deliberate later pick (incl. "All TOC headings") is preserved.
  if not features._quiz_chapter_level_reset then
    features.quiz_chapter_depth = nil  -- nil → schema default (Level 2)
    features._quiz_chapter_level_reset = true
    needs_save = true
    logger.info("KOAssistant: Reset quiz_chapter_depth to the new single-level default (Level 2)")
  end

  -- ONE-TIME migration: user_languages string → interaction_languages array
  -- Converts old comma-separated string to new array format
  if not features.languages_migrated then
    if features.user_languages and features.user_languages ~= "" then
      -- Parse comma-separated string into array
      local languages = {}
      for lang in features.user_languages:gmatch("([^,]+)") do
        local trimmed = lang:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
          table.insert(languages, trimmed)
        end
      end
      features.interaction_languages = languages
      features.additional_languages = {}  -- Start empty
      logger.info("KOAssistant: Migrated user_languages to interaction_languages array")
    else
      features.interaction_languages = {}
      features.additional_languages = {}
    end
    -- Keep user_languages for backward compatibility during transition
    features.languages_migrated = true
    needs_save = true
  end

  -- ONE-TIME migration (reasoning v2): the global on/off reasoning master toggle
  -- and its ~20 per-provider sub-settings were replaced by the per-model reasoning
  -- system (global stance + per-provider/per-model prefs in features.reasoning_prefs,
  -- resolved in koassistant/request/model_constraints.lua). Clean reset: drop the old keys so everyone
  -- starts at each model's natural default. show_reasoning_indicator is display, kept.
  if not features._reasoning_v2_migrated then
    local old_reasoning_keys = {
      "enable_reasoning", "anthropic_adaptive", "anthropic_effort", "anthropic_reasoning",
      "reasoning_budget", "gemini_reasoning", "reasoning_depth", "gemini_thinking_budget",
      "openai_reasoning", "reasoning_effort", "zai_reasoning", "deepseek_reasoning",
      "openrouter_reasoning", "openrouter_effort", "sambanova_reasoning",
      "openai_always_on_effort", "xai_effort", "perplexity_effort", "groq_effort",
      "together_effort", "fireworks_effort", "_reasoning_hint_shown",
    }
    for _idx, k in ipairs(old_reasoning_keys) do
      if features[k] ~= nil then
        features[k] = nil
      end
    end
    features._reasoning_v2_migrated = true
    needs_save = true
    logger.info("KOAssistant: Migrated reasoning settings to per-model system (v2)")
  end

  -- ONE-TIME migration (Automatic X-Ray v2, xray_ecosystem_plan.md §7 P1): the
  -- xray_auto_update master used to be half of a double opt-in (master AND a
  -- per-book boolean). It now means "automatic for ALL books"; per-book keys are
  -- tri-state strings. An old master=true user's effective posture was "opted-in
  -- books only" → record the legacy grant (their boolean opt-ins keep working via
  -- BookSettings.xrayAutoOverride) and switch the master OFF — the new all-books
  -- meaning must stay opt-in fresh, never surprise spend.
  if not features._xray_auto_v2_migrated then
    if features.xray_auto_update == true then
      features._xray_auto_legacy_optin = true
      features.xray_auto_update = false
    end
    features._xray_auto_v2_migrated = true
    needs_save = true
    logger.info("KOAssistant: Migrated Automatic X-Ray to per-book tri-state (v2)")
  end

  -- ONE-TIME migration (tools posture): the enable_tool_workflows bool became the
  -- 3-state tools_posture (off/manual/auto). Since the per-chat checkbox shipped, the
  -- bool only set the checkbox default — so false/nil maps to "manual" (checkbox shown,
  -- unchecked; their pre-upgrade behavior) and true to "auto" (checkbox pre-checked).
  -- DELIBERATE: existing users get behavior-preserving "manual" even though the schema
  -- default is now "auto" (fresh installs only) — silently pre-ticking the checkbox for
  -- users who never enabled the experimental bool would be a surprise on update. "off"
  -- (no tools anywhere) is new and never assigned by migration.
  if not features._tools_posture_migrated then
    if features.tools_posture == nil then
      features.tools_posture = (features.enable_tool_workflows == true) and "auto" or "manual"
    end
    features.enable_tool_workflows = nil
    features._tools_posture_migrated = true
    needs_save = true
    logger.info("KOAssistant: Migrated enable_tool_workflows to tools_posture")
  end

  -- ONE-TIME migration (tools binary collapse, 2026-08-12): the 3-state
  -- tools_posture becomes the web-search-shaped bool enable_book_tools —
  -- maintainer: "no reason to have separate OFF vs Auto/Manual". "auto" → true;
  -- "manual" → false (chip starts off, exactly as before); "off" → false — the
  -- ONE behavior change: the chip is visible again and can be flipped per chat
  -- (hard-off is retired; hiding the chip is the Toolbar Buttons manager's
  -- job). Runs right after the posture migration above, so pre-posture users
  -- chain through in a single launch. nil stays nil (schema default true =
  -- the pre-collapse "auto" fresh-install behavior; A9 owns any default flip).
  -- Per-book KEY_TOOLS strings are NOT migrated — sidecars are lazy-touched;
  -- BookSettings reads legacy strings through toolsValueOn forever.
  if not features._tools_binary_migrated then
    if features.tools_posture ~= nil then
      features.enable_book_tools = (features.tools_posture == "auto")
      features.tools_posture = nil
      logger.info("KOAssistant: Migrated tools_posture to enable_book_tools")
    end
    features._tools_binary_migrated = true
    needs_save = true
  end

  -- Session-chips membership (book_scoped_controls_plan.md §4/§8): the chips row
  -- replaces the input dialog's checkbox pile + top-row Web/Domain buttons. All four
  -- chips on by default (maintainer 2026-07-12); the old show_spoiler_toggle bool is
  -- retired (spoiler visibility now lives in chip membership).
  if not features._session_chips_migrated then
    if features.session_chips == nil then
      features.session_chips = { "domain", "web_search", "book_tools", "scope", "attach", "spoiler" }
    end
    features.show_spoiler_toggle = nil
    features._session_chips_migrated = true
    needs_save = true
    logger.info("KOAssistant: Migrated show_spoiler_toggle to session_chips")
  end

  -- Scope chip membership (flexible_scope_plan.md phase 3): the seed above only runs
  -- once, so already-migrated lists need scope added — and rendered in canonical
  -- order (scope BEFORE spoiler, maintainer 2026-07-17). Ensures membership, then
  -- rebuilds the list in canonical order (keep the literal in sync with
  -- SESSION_CHIP_IDS in koassistant/ui/dialogs.lua). Supersedes the short-lived
  -- _session_chips_scope_added append (same day, never released).
  if not features._session_chips_scope_v2 then
    if type(features.session_chips) == "table" then
      local member = {}
      for _i, chip_id in ipairs(features.session_chips) do member[chip_id] = true end
      member.scope = true
      local new_list = {}
      for _i, chip_id in ipairs({ "domain", "web_search", "book_tools", "scope", "spoiler" }) do
        if member[chip_id] then table.insert(new_list, chip_id) end
      end
      features.session_chips = new_list
    end
    features._session_chips_scope_added = nil
    features._session_chips_scope_v2 = true
    needs_save = true
    logger.info("KOAssistant: Added scope chip to session_chips membership (canonical order)")
  end

  -- Attach chip membership (attach_plan.md v1): same ensure-membership +
  -- canonical-order rebuild as the scope migration above. Runs AFTER scope_v2
  -- (which rebuilds against the pre-attach canonical list and would drop
  -- "attach" on a fresh install's first pass — this re-adds it). Keep the
  -- literal in sync with SESSION_CHIP_IDS in koassistant/ui/dialogs.lua.
  if not features._session_chips_attach_v1 then
    if type(features.session_chips) == "table" then
      local member = {}
      for _i, chip_id in ipairs(features.session_chips) do member[chip_id] = true end
      member.attach = true
      local new_list = {}
      for _i, chip_id in ipairs({ "domain", "web_search", "book_tools", "scope", "attach", "spoiler" }) do
        if member[chip_id] then table.insert(new_list, chip_id) end
      end
      features.session_chips = new_list
    end
    features._session_chips_attach_v1 = true
    needs_save = true
    logger.info("KOAssistant: Added attach chip to session_chips membership (canonical order)")
  end

  -- Quick chip membership (controls_parity_plan.md §2/§9): same ensure-membership +
  -- canonical-order rebuild as the migrations above. Keep the literal in sync with
  -- SESSION_CHIP_IDS in koassistant/ui/dialogs.lua.
  if not features._session_chips_quick_v1 then
    if type(features.session_chips) == "table" then
      local member = {}
      for _i, chip_id in ipairs(features.session_chips) do member[chip_id] = true end
      member.quick = true
      local new_list = {}
      for _i, chip_id in ipairs({ "domain", "web_search", "book_tools", "quick", "scope", "attach", "spoiler" }) do
        if member[chip_id] then table.insert(new_list, chip_id) end
      end
      features.session_chips = new_list
    end
    features._session_chips_quick_v1 = true
    needs_save = true
    logger.info("KOAssistant: Added quick chip to session_chips membership (canonical order)")
  end

  -- ONE-TIME migration (report 3(a)): the raw web_search_max_uses spinner
  -- (Anthropic-only, 1-10) became the 3-level web_search_effort dial. Map a tuned
  -- value to the nearest level and retire the old key from GUI settings (a
  -- configuration.lua web_search_max_uses still wins in anthropic_request.lua).
  if not features._web_search_effort_migrated then
    local old_uses = tonumber(features.web_search_max_uses)
    if features.web_search_effort == nil and old_uses ~= nil then
      if old_uses <= 3 then
        features.web_search_effort = "light"
      elseif old_uses >= 8 then
        features.web_search_effort = "thorough"
      end
      -- 4-7 → standard = nil default, nothing to write
    end
    features.web_search_max_uses = nil
    features._web_search_effort_migrated = true
    needs_save = true
    logger.info("KOAssistant: Migrated web_search_max_uses to web_search_effort")
  end

  -- ONE-TIME migration (2026-08-09): the dictionary-bypass default action moved
  -- from Dictionary to Quick Define. Clear a stored "dictionary" so those users
  -- follow the new default too; the flag guard means re-picking Dictionary
  -- afterwards sticks.
  if not features._dict_bypass_default_migrated then
    if features.dictionary_bypass_action == "dictionary" then
      features.dictionary_bypass_action = nil
      logger.info("KOAssistant: Dictionary bypass action moved to the Quick Define default")
    end
    features._dict_bypass_default_migrated = true
    needs_save = true
  end

  -- ONE-TIME seed (surrounding_context_plan.md): highlight actions' surrounding
  -- context used to fall back to the DICTIONARY context settings. Copy a tuned
  -- dictionary mode into the new highlight_context_mode so flag-true actions keep
  -- their behavior after the decouple. Everyone else stays at the "none" default —
  -- ambient context is opt-in and must not start flowing after an update.
  if not features._highlight_context_migrated then
    if features.highlight_context_mode == nil
        and features.dictionary_context_mode ~= nil
        and features.dictionary_context_mode ~= "none" then
      features.highlight_context_mode = features.dictionary_context_mode
      if features.highlight_context_chars == nil and features.dictionary_context_chars ~= nil then
        features.highlight_context_chars = features.dictionary_context_chars
      end
      logger.info("KOAssistant: Seeded highlight context mode from dictionary settings")
    end
    features._highlight_context_migrated = true
    needs_save = true
  end

  -- FINAL session-chips migration (defaults_propagation_plan.md G1). Chip membership moved
  -- to the auto-injecting registry in koassistant/core/constants.lua, so from here on a NEW chip
  -- reaches existing users with no migration at all. One transition step is still needed:
  -- users who deliberately turned a chip OFF have it absent from session_chips but no
  -- dismissal record, and auto-injection would resurrect it. Seed the dismissal list from
  -- the current gap (canonical ids minus saved membership) to preserve their choice.
  -- The canonical ids AS OF this migration (frozen): a chip added later (B395
  -- added one, since removed) was never in an old membership list, and must reach the
  -- reader through the registry's injection, not land here as "dismissed".
  if not features._session_chips_registry_v1 then
    if type(features.session_chips) == "table" then
      local member = {}
      for _idx, id in ipairs(features.session_chips) do member[id] = true end
      local dismissed = {}
      for _idx, id in ipairs({ "domain", "web_search", "book_tools", "quick", "scope", "attach", "spoiler" }) do
        if not member[id] then table.insert(dismissed, id) end
      end
      if #dismissed > 0 then
        features._dismissed_session_chips = dismissed
        logger.info("KOAssistant: Seeded session-chip dismissals from existing membership")
      end
    end
    features._session_chips_registry_v1 = true
    needs_save = true
  end

  -- ONE-TIME migration (image round S2, 2026-10-14): OpenAI's size and quality
  -- rows and xAI's aspect ratio row became Shape and Detail, one pair for every
  -- image provider. A picked shape keeps its meaning (the drawing provider's
  -- row first when both were picked); OpenAI's quality becomes the Detail only
  -- while OpenAI draws, so no other provider starts drawing dearer pictures.
  -- Default, which left it to the provider, takes the new defaults (Fit my
  -- screen, Draft). The old keys go, so this runs once and needs no stamp.
  if features.image_gen_size ~= nil or features.image_gen_quality ~= nil
      or features.image_gen_aspect ~= nil then
    local shapes = {
      ["1024x1024"] = "square", ["1536x1024"] = "landscape", ["1024x1536"] = "portrait",
      ["1:1"] = "square", ["16:9"] = "landscape", ["3:2"] = "landscape",
      ["9:16"] = "portrait", ["2:3"] = "portrait",
    }
    local details = { low = "draft", medium = "standard", high = "best" }
    local pick = features.image_gen_provider
    local draws = (pick ~= nil and pick ~= "auto") and pick or features.provider
    local first, second = features.image_gen_size, features.image_gen_aspect
    if draws == "xai" then first, second = second, first end
    if features.image_gen_shape == nil then
      features.image_gen_shape = shapes[first] or shapes[second]
    end
    if features.image_gen_detail == nil and draws == "openai" then
      features.image_gen_detail = details[features.image_gen_quality]
    end
    features.image_gen_size, features.image_gen_quality, features.image_gen_aspect = nil, nil, nil
    needs_save = true
    logger.info("KOAssistant: Moved the image size, quality and aspect settings to Shape and Detail")
  end

  -- ONE-TIME migration (B395 slice 2, rulings 2 and 21 of 2026-10-14): every
  -- global sharing switch becomes Ask, a switch that was on included ("there
  -- was no other option to make it work"); reading position keeps its own
  -- two values; per-book values and the trusted list are kept (they are
  -- exactly "Allow for this book" and "Not for this book"). An install that
  -- had decided any switch gets the one-time notice at its first interaction
  -- (koassistant/ui/data_access.lua maybeShowUpgradeNotice).
  if not features._privacy_ask_migrated then
    local decided = false
    for _idx, key in ipairs({
      "enable_book_text_extraction", "enable_highlights_sharing", "enable_annotations_sharing",
      "enable_notebook_sharing", "enable_advanced_stats", "enable_library_scanning",
    }) do
      if features[key] ~= nil then
        decided = true
        features[key] = nil
      end
    end
    if features.enable_basic_stats ~= nil then decided = true end
    if decided then
      features._privacy_notice_pending = true
      logger.info("KOAssistant: Privacy switches reset to Ask (the question model)")
    end
    features._privacy_ask_migrated = true
    needs_save = true
  end

  return needs_save
end

return Migrations
