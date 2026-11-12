-- B537 on the real widgets: a tap of Generate Image opens the picture popup
-- (the scope popup's shape). The passage is not repeated; a note and the
-- X-Ray entries the prompt writer reads (at first the ones the passage names,
-- carried entries among them); then each setting as the X-Ray creation
-- form's dials show theirs ("Shape: Portrait ▾", a tap opens its list):
-- Prompt (Write the prompt with AI) beside Style, Shape beside Detail, the
-- provider beside the model that draws; Generate at the foot. A pick is the
-- setting; the note and the entries go with this picture only. The entry
-- list: the picked, the suggested, then each category, a carried entry
-- naming its book, and closing it keeps what is ticked. The long-press
-- offers no run buttons. Illustrate… and a gallery picture's Image
-- settings… open the same popup. Nothing is drawn: the generator is
-- replaced by a recorder (the network is blocked anyway).
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
-- An image provider with a key (a fake key in the run's own settings)
S.features({ image_gen_provider = "openai", api_keys = { openai = "sk-scenario-not-a-key" } })

local ui = S.open("Mock Series 3")
local file = ui.document.file
local Dialogs = require("koassistant.ui.dialogs")
local Actions = require("koassistant.prompts.actions")
local ActionCache = require("koassistant.artifacts.action_cache")
local XrayParser = require("koassistant.xray.xray_parser")
local XrayBrowser = require("koassistant.xray.xray_browser")
local ImageGenerator = require("koassistant.images.image_generator")
local NetworkMgr = require("ui/network/manager")

local drawn
ImageGenerator.generate = function(text, _config, _settings, book_info, gen_opts)
    drawn = { text = text, book_info = book_info, gen_opts = gen_opts }
end
NetworkMgr.runWhenConnected = function(_self, fn) fn() end

local function features() return S.plugin.settings:readSetting("features") or {} end
local function title()
    local w = S.top()
    return w and w._frame and w._frame[1] and w._frame[1][1] and w._frame[1][1].title or ""
end
-- Every text drawn in a window (labels and the passage too, not only buttons)
local function textsIn(node, out, seen)
    out, seen = out or {}, seen or {}
    if type(node) ~= "table" or seen[node] then return out end
    seen[node] = true
    if type(node.text) == "string" and node.face then out[#out + 1] = node.text end
    for i = 1, #node do textsIn(node[i], out, seen) end
    return out
end
local function drawnTexts() return "|" .. table.concat(textsIn(S.top()._frame), "|") .. "|" end
local function picksButton()
    for _idx, b in ipairs(S.buttons()) do
        if b.text:find("^X%-Ray entries:") then return b end
    end
end

local passage = "Gil Rook handed Tamsin the knife by way of hello."
S.chapter("The Grafter")

-- ── A tap: the popup ──
Dialogs.executeDirectAction(ui, Actions.highlight.image_gen, passage, S.plugin.configuration, S.plugin)
S.settle()
local all = table.concat(S.texts(), " | ")
S.note("popup:", all)
S.check(title() == "Generate Image", "a tap opens the picture popup")
local drawn_texts = drawnTexts()
S.check(not drawn_texts:find("Gil Rook handed Tamsin", 1, true), "the passage just selected is not repeated")
S.check(not drawn_texts:find("For this picture", 1, true), "no heading over the picture's own buttons")
S.check(all:find("Add a note… | X-Ray entries: Gil Rook ▾", 1, true) ~= nil,
    "a note, and the entry the passage names already on the list")
S.check(all:find("Prompt: Written by AI ▾ | Style: Book illustration ▾ | Shape: Fit my screen ▾ | Detail: Draft ▾", 1, true) ~= nil,
    "each setting by its name and value, two to a row, as the creation form's dials")
-- The model is the image list's first entry, whatever a model round made it
-- (it was typed here, and the round of 2026-11-06 moved the default without
-- this scenario being run: audit 2026-11-12)
local DEFAULT_IMAGE_MODEL = require("koassistant.request.model_lists")._image_models.openai[1]
S.check(all:find("Provider: OpenAI ▾ | Model: " .. DEFAULT_IMAGE_MODEL .. " ▾", 1, true) ~= nil,
    "the provider and the model that draw (" .. DEFAULT_IMAGE_MODEL .. ")")
S.check(not all:find("Write the prompt with AI", 1, true), "no check box: the Prompt dial says it")
S.check(all:find("Generate", 1, true) ~= nil, "Generate at the foot")
S.check(drawn == nil, "nothing drawn yet")
local frame = S.top()._frame
S.note("popup height:", frame.dimen.h, "of", S.Screen:getHeight())
S.check(frame.dimen.h <= S.Screen:getHeight() and S.top()._scroll == nil,
    "the popup fits the screen without scrolling")
S.shot("popup")

-- ── A long passage: the popup keeps its size (the passage is not shown) ──
S.closeAll()
local long_passage = string.rep("He handed Tamsin the knife by way of hello, and the cart came up the lane. ", 6)
Dialogs.executeDirectAction(ui, Actions.highlight.image_gen, long_passage, S.plugin.configuration, S.plugin)
S.settle()
S.check(S.top()._scroll == nil and S.top()._frame.dimen.h == frame.dimen.h,
    "a 450-character passage: the same popup, no scrolling")
S.closeAll()
Dialogs.executeDirectAction(ui, Actions.highlight.image_gen, passage, S.plugin.configuration, S.plugin)
S.settle()

-- ── A pick is the setting: a value opens its list ──
S.tap("Style: Book illustration ▾")
S.check(S.find("Watercolor") ~= nil, "Style opens the list of styles")
S.shot("style_list")
S.tap("Watercolor")
S.check(features().image_gen_style == "watercolor", "Watercolor is saved as the style")
S.check(title() == "Generate Image" and S.find("Style: Watercolor ▾") ~= nil, "back in the popup, on the new value")
S.tap("Shape: Fit my screen ▾")
S.tap("Portrait")
S.check(features().image_gen_shape == "portrait", "Portrait is saved as the shape")
S.check(S.find("Shape: Portrait ▾") ~= nil, "the shape's button shows it")

-- ── The note, for this picture ──
S.tap("Add a note…")
-- (on a device without a keyboard, KOReader's on-screen one sits above it)
local box
for i = #S.UIManager._window_stack, 1, -1 do
    local w = S.UIManager._window_stack[i].widget
    if not box and w.title == "Note for the picture" then box = w end
end
S.check(box ~= nil, "the note box opens over the popup")
S.check(box and box.description == nil and type(box.input_hint) == "string"
    and box.input_hint:find("what to include", 1, true) ~= nil,
    "no explanation over the box: the examples are its gray hint")
S.shot("note_box")
box:setInputText("at dusk, Jory at the gate")
S.tap("OK")
S.check(S.find("Note: at dusk, Jory at the gate") ~= nil, "the popup shows the note")
S.check(S.find("X-Ray entries: Jory, Gil Rook ▾") ~= nil, "the entry the note names joins the list, first")

-- ── The X-Ray entries: the picked, the suggested, then each category ──
S.tap({ "^X%-Ray entries:" })
local rows = S.texts()
S.note("picker:", table.concat(rows, " | "))
S.check(rows[1]:find("^\u{2611} Jory") and rows[2]:find("^\u{2611} Gil Rook"), "the picked first, ticked")
local suggested = table.concat(rows, "|"):match("|Suggested|(.-)|Cast|") or ""
S.check(rows[3] == "Suggested" and suggested:find("\u{2610} Tamsin Vael", 1, true) ~= nil,
    "then the suggested: Tamsin, named by one word of her name")
S.check(table.concat(rows, "|"):find("|Cast|", 1, true) ~= nil, "then the rest under their categories")
S.check(not table.concat(rows, "|"):find("Done", 1, true), "no Done to find")
S.tap({ "Jory" })
S.tap({ "Hollowmere" })
rows = S.texts()
S.check(rows[1]:find("^\u{2610} Jory"), "a cleared row keeps its place")
S.shot("picker")
S.top():onClose()
S.settle()
S.check(S.find("X-Ray entries: Gil Rook, Hollowmere ▾") ~= nil, "closing the list keeps what is ticked, in the order picked")
S.shot("popup_filled")

-- ── The writer off, picked in the Prompt list: nothing reads the entries ──
S.tap("Prompt: Written by AI ▾")
S.check(S.find("The passage as is, with your note and the style") ~= nil, "Prompt opens its two choices")
S.shot("prompt_list")
S.tap("The passage as is, with your note and the style")
S.check(features().image_gen_writer == false, "Write the prompt with AI is saved off")
S.check(S.find("Prompt: Passage as is ▾") ~= nil, "the dial shows it")
local pb = picksButton()
S.check(pb and pb.button.enabled == false, "the entries button is grayed while the writer is off")
S.tap("Prompt: Passage as is ▾")
S.tap("Written by AI, from the passage, the entries and your note")
S.check(features().image_gen_writer ~= false and S.find("Prompt: Written by AI ▾") ~= nil, "and back on")

-- ── Generate: the note and the entries go with this picture ──
local drawn_from = S.top()
S.tap("Generate")
S.check(drawn ~= nil and drawn.text == passage, "Generate draws the passage")
S.check(drawn and drawn.gen_opts.note == "at dusk, Jory at the gate", "with the note")
S.check(drawn and table.concat(drawn.gen_opts.picked or {}, "|") == "Gil Rook|Hollowmere", "with the list")
S.check(S.top() == ui, "the popup is gone")

-- ── The next tap starts afresh ──
drawn = nil
Dialogs.executeDirectAction(ui, Actions.highlight.image_gen, passage, S.plugin.configuration, S.plugin)
S.settle()
S.check(S.find("Add a note…") ~= nil and S.find("X-Ray entries: Gil Rook ▾") ~= nil,
    "the next picture starts with no note, the entries as its passage names them")
S.check(S.find("Style: Watercolor ▾") ~= nil, "but the style stays as picked")

-- ── Every exit closes it and draws nothing: the X, a tap outside, Back ──
local Event = require("ui/event")
local Geom = require("ui/geometry")
local popup = S.top()
popup._frame[1][1].right_button.callback()
S.settle()
S.check(not S.UIManager:isWidgetShown(popup), "the X closes it")
Dialogs.executeDirectAction(ui, Actions.highlight.image_gen, passage, S.plugin.configuration, S.plugin)
S.settle()
popup = S.top()
popup:onTapClose(nil, { pos = Geom:new{ x = 2, y = 2, w = 0, h = 0 } })
S.settle()
S.check(not S.UIManager:isWidgetShown(popup), "a tap outside closes it")
Dialogs.executeDirectAction(ui, Actions.highlight.image_gen, passage, S.plugin.configuration, S.plugin)
S.settle()
popup = S.top()
if require("device"):hasKeys() then
    S.UIManager:sendEvent(Event:new("KeyPress", require("device/key"):new("Back", {})))
    S.settle()
    S.check(not S.UIManager:isWidgetShown(popup), "Back closes it")
else
    -- a device without keys (the wiki runs' e-reader) has no Back to bind
    popup._frame[1][1].right_button.callback()
    S.settle()
end
S.check(drawn == nil, "no exit draws anything")

-- ── A list's late answer never reopens a popup that drew ──
-- (OpenRouter's catalog can arrive after Generate: its pick calls the
-- popup's rebuild, here from a list the drawn popup opened)
for _idx, row in ipairs(drawn_from._rows) do
    if row.id == "look" then row.items[1].callback() end
end
S.settle()
S.tap("Square")
S.check(S.top() == ui, "the drawn popup stays closed")
S.check(features().image_gen_shape == "square", "the pick itself is saved")

-- ── The long-press: no run buttons, the placement rows only ──
local ActionHold = require("koassistant.ui.action_hold")
ActionHold.show(S.plugin, Actions.highlight.image_gen, { surface = "highlight", run = function() end })
S.settle()
local hold = table.concat(S.texts(), " | ")
S.note("hold menu:", hold)
S.check(not hold:find("Generate now", 1, true) and hold:find("Remove", 1, true) ~= nil,
    "the long-press has the placement rows and nothing that draws")
S.closeAll()

-- ── Illustrate…: the same popup, a note, no entries to pick ──
drawn = nil
local data = XrayParser.parse(ActionCache.getXrayCache(file).result)
XrayParser.mergeUserAliases(data, ActionCache.getUserAliases(file))
local gil
for _idx, item in ipairs(data.characters or {}) do
    if item.name == "Gil Rook" then gil = item end
end
XrayBrowser:show(data, { title = "Mock Series 3 - The Orchard", book_file = file, plugin = S.plugin,
    configuration = S.plugin.configuration, enable_emoji = false }, ui)
S.settle()
XrayBrowser:_illustrate(gil, "characters")
S.settle()
all = table.concat(S.texts(), " | ")
S.note("Illustrate:", all)
S.check(title() == "Illustrate \"Gil Rook\"", "Illustrate… opens the picture popup")
S.check(all:find("Add a note…", 1, true) and not all:find("X-Ray", 1, true),
    "a note, no entries (the entry is the subject)")
S.shot("illustrate")
S.tap("Illustrate")
S.check(drawn and drawn.gen_opts.entry and drawn.gen_opts.entry.name == "Gil Rook", "Illustrate draws the entry")
S.closeAll()

-- ── Carried entries: named, listed with their book, picked like the book's own ──
-- (the carried list refreshed from the series first, as any X-Ray change does)
require("koassistant.xray.xray_merge").refreshCarried(file, features(), "anthropic", ui)
S.settle()
S.chapter("The Inn Sign")
drawn = nil
Dialogs.executeDirectAction(ui, Actions.highlight.image_gen,
    "Dorrit Hale, the letters said, was selling. The Warden was named in the small print.",
    S.plugin.configuration, S.plugin)
S.settle()
S.check(S.find("X-Ray entries: Dorrit Hale, the Warden ▾") ~= nil,
    "the carried Dorrit Hale and the Warden: \"The Warden\" is the carried character, not this book's term")
S.tap({ "^X%-Ray entries:" })
rows = S.texts()
S.note("picker:", table.concat(rows, " | "))
S.check(rows[1]:find("^\u{2611} Dorrit Hale") and rows[1]:find("Book 2", 1, true),
    "a carried entry names its book, as the X-Ray's category pages do")
S.check(table.concat(rows, "|"):find("Elias Penrose", 1, true) ~= nil, "every carried entry can be picked")
S.check(not (table.concat(rows, "|"):match("|Suggested|(.-)|Cast|") or ""):find("The Drowned", 1, true),
    "the sentence's opening \"The\" suggests nothing")
S.shot("picker_carried")
S.top():onClose()
S.settle()
S.tap("Generate")
S.check(drawn and table.concat(drawn.gen_opts.picked or {}, "|") == "Dorrit Hale|the Warden", "they go to the writer")
S.closeAll()
S.chapter("The Grafter")

-- ── The chat provider cannot draw: the provider question first ──
local f = S.plugin.settings:readSetting("features")
f.image_gen_provider, f.provider = "auto", "anthropic"
drawn = nil
Dialogs.executeDirectAction(ui, Actions.highlight.image_gen, passage, S.plugin.configuration, S.plugin)
S.settle()
local question = S.top()
S.check(question and question.title and question.title:find("can't make images", 1, true) ~= nil,
    "the provider question comes before the popup")
S.tap("Cancel")
S.check(S.top() == ui and drawn == nil, "Cancel: no popup, nothing drawn")
Dialogs.executeDirectAction(ui, Actions.highlight.image_gen, passage, S.plugin.configuration, S.plugin)
S.settle()
S.tap("OpenAI")
S.check(title() == "Generate Image"
    and table.concat(S.texts(), " | "):find("Provider: OpenAI ▾ | Model: " .. DEFAULT_IMAGE_MODEL .. " ▾", 1, true) ~= nil,
    "after the answer: the popup, on the provider that draws and its model")
S.check(S.plugin.settings:readSetting("features").image_gen_provider == "openai", "the answer saved as Provider")
S.closeAll()

-- ── The model button names the model that draws (a retired id's replacement) ──
local ImageOptions = require("koassistant.images.image_options")
f = S.plugin.settings:readSetting("features")
f.image_gen_provider, f.image_gen_model_xai = "xai", "grok-imagine-image-pro"
f.api_keys = f.api_keys or {}
f.api_keys.xai = "xai-scenario-not-a-key"
ImageOptions.show(S.plugin, { actions = { { text = "Regenerate", callback = function() end } } })
S.settle()
S.check(table.concat(S.texts(), " | "):find("grok-imagine-image-2.0", 1, true) ~= nil,
    "a retired id shows as its replacement")
S.closeAll()
f.image_gen_provider = "openai"

-- ── A long typed style is cut on its button, so the popup keeps its size ──
-- (and were a row to grow, the clamp keeps the bottom on the screen)
popup = ImageOptions.show(S.plugin, { actions = {
    { text = "Regenerate", callback = function() end },
    { text = "Regenerate and replace", callback = function() end },
} })
S.settle()
f.image_gen_style, f.image_gen_style_custom = "custom", string.rep("a 1920s travel poster ", 9)
S.tap("Shape: Square ▾")
S.tap("Portrait")
popup = S.top()
local fd = popup._frame.dimen
S.note("frame with the long style:", fd.y, fd.h, "screen", S.Screen:getHeight())
S.check(fd.y >= 0 and fd.y + fd.h <= S.Screen:getHeight(), "with a 200-character style it stays on the screen")
S.check(S.find("Regenerate and replace") ~= nil, "the buttons stay reachable")
local custom_text
for _idx, b in ipairs(S.buttons()) do
    if b.text:find("^Style: Custom") then custom_text = b.text end
end
S.check(custom_text and custom_text:find("… ▾$") ~= nil, "a long typed style is cut on its button")
S.closeAll()
f.image_gen_style, f.image_gen_style_custom = "watercolor", nil

-- ── A gallery picture's Image settings…: the settings and the two Regenerates ──
ImageOptions.show(S.plugin, { actions = {
    { text = "Regenerate", callback = function() end },
    { text = "Regenerate and replace", callback = function() end },
} })
S.settle()
all = table.concat(S.texts(), " | ")
S.note("Image settings:", all)
S.check(title() == "Image settings" and not all:find("Add a note", 1, true)
    and not all:find("Prompt:", 1, true), "the gallery's: settings only, no prompt to write")
S.check(all:find("Regenerate and replace", 1, true) ~= nil, "with the two Regenerates")
S.shot("image_settings")
S.closeAll()

S.finish()
