-- The gettext module sits under pcall: an older updater's process reads this
-- file to check the version and cannot resolve the modules of a newer layout.
local ok, gettext = pcall(require, "koassistant.core.gettext")
if not ok then gettext = function(s) return s end end
local _ = gettext
return {
    name = "koassistant",
    fullname = _("KOAssistant"),
    description = _([[A powerful AI assistant integrated into KOReader]]),
    version = "0.25.0",
}
