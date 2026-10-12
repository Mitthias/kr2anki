--[[--
Settings ▸ Anki connection ▸ Diagnostics: KOReader interfaces, AnkiConnect
capabilities and the export path chosen, the database and dictionaries.
Shown in a text viewer so it can be copied and sent back.
--]]

local Anki = require("kr2anki/anki")
local Safe = require("kr2anki/safe")
local _ = require("gettext")
local T = require("ffi/util").template

local D = {}

local function yesno(v) return v and "✓" or "×" end

function D.report(host, force)
    local out = {}
    local function add(s) out[#out + 1] = s end
    local ok_v, Version = pcall(require, "version")
    add("KR2Anki diagnostics · " .. os.date("%Y-%m-%d %H:%M"))
    if ok_v then add("KOReader " .. tostring(Version:getCurrentRevision())) end
    add("")
    add(_("KOReader interfaces"))
    for __, c in ipairs(host.hook_status or {}) do add(T("  %1 %2", yesno(c[2]), c[1])) end
    add("")
    add(_("AnkiConnect (http://127.0.0.1:8765)"))
    local caps = host:getCaps(force)
    if not caps.reachable then
        add("  ○ " .. _("Not reachable") .. (caps.error and (": " .. tostring(caps.error)) or ""))
    else
        add(T("  ● %1 · API version %2", _("Connected"), tostring(caps.version)))
        for __, d in ipairs(caps.details or {}) do
            add(T("  %1 %2%3", d.status == "works" and "✓" or "×", d.action,
                d.status == "works" and "" or (" — " .. d.status .. (d.error and (": " .. tostring(d.error):sub(1, 60)) or ""))))
        end
        local plan = Anki.plan(caps)
        add("")
        add(_("Export path"))
        add("  " .. (plan.batch_add and "addNotes in batches of 20" or (plan.single_add and "addNote, one by one" or "cannot add notes: use .apkg")))
        add("  " .. (plan.create_models and "note types: created by AnkiConnect" or "note types: import kr2anki_notetypes.apkg once"))
        add("  " .. (plan.check_duplicates and "duplicates: canAddNotes" or "duplicates: not checked before sending"))
        add("  " .. (plan.merge and "merge: findNotes + updateNoteFields" or "merge: not available (Skip only)"))
        add("  " .. (plan.media and "audio: storeMediaFile" or "audio: not sent"))
    end
    add("")
    add(_("Database"))
    local store = host:getStore()
    if store then
        local c = store:counts()
        add(T("  %1", store.path))
        add(T("  ○ %1 · ● %2 · ✓ %3 · — %4 · × %5", c.inbox, c.ready, c.anki, c.known, c.discarded))
    end
    add("")
    add(_("Dictionaries and profiles"))
    local di = host:getDictInfo()
    if #di.dicts == 0 then add("  " .. _("No StarDict dictionaries found in ") .. tostring(di.data_dir)) end
    for __, d in ipairs(di.dicts) do
        local p = di:profileFor(d.name)
        add(T("  %1 · %2 · %3", d.name, tostring(di:language(d.name) or "?"), p.name))
    end
    for __, e in ipairs(di.profile_errors or {}) do add("  × " .. e) end
    return table.concat(out, "\n")
end

function D.show(host, force)
    local text = Safe.run("diagnostics", D.report, host, force)
    if not text then return end
    local UIManager = require("ui/uimanager")
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{ title = _("KR2Anki diagnostics"), text = text })
end

return D
