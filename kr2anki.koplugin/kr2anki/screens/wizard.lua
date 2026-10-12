--[[--
Setup wizard: five checks, once. Rows 1–3 are a manual checklist with written
steps; row 4 is a live connection test (passing it also ticks rows 1–2);
row 5 creates the decks and note types, or guides the one-time .apkg import.
Skippable: saving works without Anki.
--]]

local HorizontalGroup = require("ui/widget/horizontalgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local BaseScreen = require("kr2anki/ui/screen")
local Kit = require("kr2anki/ui/kit")
local Lang = require("kr2anki/lang")
local N = require("kr2anki/notetypes")
local Safe = require("kr2anki/safe")
local _ = require("gettext")
local T = require("ffi/util").template

local Wizard = BaseScreen:extend{ name = "kr2anki_wizard", then_export = false }

local PACKAGES = { ankidroid = "com.ichi2.anki", ankiconnect = "com.kamwithk.ankiconnectandroid" }

local STEPS = {
    {
        key = "ankidroid", title = _("AnkiDroid installed"),
        steps = _([[Install AnkiDroid (from Google Play, F-Droid or ankidroid.org) and open it once, so it creates its collection.

Tap "Mark done" when it is installed.]]),
    },
    {
        key = "ankiconnect", title = _("AnkiConnect Android installed"),
        steps = _([[1. Install IzzyOnDroid's F-Droid repository, or the F-Droid client, or download the APK from apt.izzysoft.de/fdroid (search "AnkiConnect Android").
2. Install AnkiConnect Android.
3. Open it once and allow access to AnkiDroid's database when asked.
4. Start its service; a notification shows it is running.

Tap "Mark done" when its service is running.]]),
    },
    {
        key = "battery", title = _("Battery optimization off"),
        steps = _([[Otherwise Android closes AnkiConnect in the background and exports fail.

Settings ▸ Apps ▸ AnkiConnect Android ▸ Battery ▸ Unrestricted.
Do the same for AnkiDroid.

On SmartOS the battery page may be called "App launch" or "Power saving": allow it to run in the background.

Tap "Mark done" when both are set.]]),
    },
}

function Wizard:setup()
    self.done = self.host.settings:get("wizard") or {}
    self.test = nil -- nil | "ok" | "fail"
    self.create = nil
    -- Android can tell whether a package is installed (hint only)
    local ok, android = pcall(require, "android")
    if ok and android and android.isPackageEnabled then
        for key, pkg in pairs(PACKAGES) do
            local pok, enabled = pcall(android.isPackageEnabled, pkg)
            if pok and enabled then self.done[key] = true end
        end
    end
end

function Wizard:save()
    self.host.settings:set("wizard", self.done)
end

function Wizard:showSteps(step)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title = step.title .. "\n\n" .. step.steps,
        title_align = "left",
        buttons = { {
            { text = _("Close"), callback = function() UIManager:close(dialog) end },
            { text = self.done[step.key] and _("Mark not done") or _("Mark done"), callback = function()
                UIManager:close(dialog)
                self.done[step.key] = not self.done[step.key] or nil
                self:save()
                self:refresh()
            end },
        } },
    }
    UIManager:show(dialog)
end

function Wizard:runTest()
    local caps = Safe.run("connection test", function() return self.host:getCaps(true) end)
    if caps and caps.reachable then
        self.test = "ok"
        self.caps = caps
        self.done.ankidroid = true
        self.done.ankiconnect = true
        self.done.connection = true
    else
        self.test = "fail"
        self.done.connection = nil
    end
    self:save()
    self:refresh()
end

function Wizard:runCreate()
    local caps = self.caps or self.host:getCaps()
    if not caps.reachable then
        self.create = _("Run the connection test first.")
        self:refresh()
        return
    end
    local client = self.host:client()
    local plan = require("kr2anki/anki").plan(caps)
    local models = client:call("modelNames") or {}
    local have = {}
    for __, m in ipairs(models) do have[m] = true end
    local missing = {}
    for __, name in ipairs({ N.WORD_MODEL, N.EXPR_MODEL }) do
        if not have[name] then
            if plan.create_models then
                local __, err, kind = client:call("createModel", N.createModelParams(name == N.EXPR_MODEL and "expression" or "word"))
                if kind ~= "ok" then missing[#missing + 1] = name .. ": " .. tostring(err) end
            else
                missing[#missing + 1] = name
            end
        end
    end
    local decks = 0
    if plan.create_decks then
        local pattern = self.host.settings:get("deck_pattern")
        for __, code in ipairs({ "en", "zh", "ja", "ko" }) do
            local result = { client:call("createDeck", { deck = Lang.deckName(pattern, code) }) }
            if result[3] == "ok" then decks = decks + 1 end
        end
    end
    if #missing == 0 then
        self.done.create = true
        if plan.create_decks then
            self.create = T(_("Note types ready. %1 decks checked."), decks)
        else
            self.create = _("Note types ready. This AnkiConnect can't create decks: Export lists the decks to create in AnkiDroid.")
        end
    else
        self.done.create = nil
        local path = require("kr2anki/screens/export").writeNotetypePackage(self.host, false)
        self.create = T(_("AnkiConnect can't create note types here. Import them once:\nIn AnkiDroid: ⋮ ▸ Import ▸ %1\nThen tap Create again to check."),
            path or "kr2anki_notetypes.apkg")
    end
    self:save()
    self:refresh()
end

local function mark(state)
    if state == "done" then
        return Kit.text("✓", Kit.uiBold(Kit.SIZE.title), {})
    elseif state == "action" then
        local s = Kit.dp(26)
        return require("ui/widget/container/framecontainer"):new{ bordersize = 0, padding = 0, margin = 0,
            background = Kit.BLACK, radius = Kit.dp(4),
            Kit.box(s, s, Kit.text("×", Kit.uiBold(Kit.SIZE.small), { fgcolor = Kit.WHITE })) }
    end
    return Kit.text("○", Kit.ui(Kit.SIZE.body), {})
end

function Wizard:checkRow(cw, state, title, sub, button)
    local mark_w = Kit.dp(40)
    local btn_w = button and button:getSize().w + Kit.dp(8) or 0
    local text_w = cw - mark_w - btn_w
    local text = VerticalGroup:new{ align = "left",
        Kit.textbox(title, state == "action" and Kit.uiBold() or Kit.ui(), text_w, { max_lines = 2 }) }
    if sub then table.insert(text, Kit.textbox(sub, Kit.ui(Kit.SIZE.tiny), text_w, { fgcolor = Kit.GREY_DARK, max_lines = 4 })) end
    local h = math.max(Kit.TAP, text:getSize().h + Kit.dp(14))
    local row = HorizontalGroup:new{ align = "center",
        Kit.box(mark_w, h, mark(state), "left"),
        Kit.box(text_w, h, text, "left") }
    if button then table.insert(row, Kit.box(btn_w, h, button, "right")) end
    return row
end

function Wizard:stepIndex()
    for i, s in ipairs(STEPS) do
        if not self.done[s.key] then return i end
    end
    if not self.done.connection then return 4 end
    if not self.done.create then return 5 end
    return 6
end

function Wizard:rowsFor(cw)
    local rows = {}
    for __, s in ipairs(STEPS) do
        local state = self.done[s.key] and "done" or "action"
        local step = s
        rows[#rows + 1] = Kit.tap(self:checkRow(cw, state, s.title,
            state == "done" and _("Done") or _("Needs action · tap for steps")), function() self:showSteps(step) end)
    end
    local test_state = self.done.connection and "done" or (self.test == "fail" and "action" or "todo")
    rows[#rows + 1] = self:checkRow(cw, test_state, _("Connection test"),
        self.test == "fail" and _("Not reachable. Open AnkiConnect Android, then test again.")
            or (self.done.connection and _("Done") or _("Not checked")),
        Kit.button{ text = _("Test"), size = Kit.SIZE.small, callback = function() self:runTest() end })
    local create_state = self.done.create and "done" or "todo"
    rows[#rows + 1] = self:checkRow(cw, create_state, _("Create decks and note types"),
        self.create or T(_("Not checked · %1"), Lang.deckName(self.host.settings:get("deck_pattern"), "ja")),
        Kit.button{ text = _("Create"), size = Kit.SIZE.small, callback = function() Safe.run("create", self.runCreate, self) end })
    return rows
end

function Wizard:build(w, h)
    local header = Kit.header{ width = w, title = _("Set up Anki export"), on_back = function() self:onClose() end,
        right = Kit.link(_("Skip"), function() self:finish() end, { size = Kit.SIZE.small }) }
    local cw = w - 2 * Kit.PAD
    local step = math.min(5, self:stepIndex())
    local all_done = self:stepIndex() == 6
    local bottom_row = HorizontalGroup:new{ align = "center",
        Kit.box(math.floor(cw * 0.45), Kit.TAP, Kit.text(all_done and _("All done") or T(_("Step %1 of 5"), step),
            Kit.ui(Kit.SIZE.body), {}), "left"),
        Kit.button{ text = all_done and (self.then_export and _("Export") or _("Done")) or _("Continue"), primary = true,
            width = cw - math.floor(cw * 0.45), callback = function()
                if all_done then self:finish() return end
                local i = self:stepIndex()
                if i <= 3 then self:showSteps(STEPS[i])
                elseif i == 4 then self:runTest()
                else Safe.run("create", self.runCreate, self) end
            end } }
    local bottom = VerticalGroup:new{ align = "left", Kit.hline(w, Kit.dp(2)), Kit.vspan(Kit.dp(12)),
        Kit.pad(bottom_row, Kit.PAD, 0), Kit.vspan(Kit.dp(12)) }
    local avail = h - header:getSize().h - bottom:getSize().h
    local body = Kit.flowColumns(cw, avail, function(col)
        local blocks = { Kit.vspan(Kit.dp(10)),
            Kit.textbox(_("Five checks, once. You can still save words without Anki; they wait in the Inbox."),
                Kit.ui(Kit.SIZE.small), col, { fgcolor = Kit.GREY_DARK }),
            Kit.vspan(Kit.dp(8)), Kit.hline(col, Kit.dp(1)) }
        for i, r in ipairs(self:rowsFor(col)) do
            blocks[#blocks + 1] = r
            if i < 5 then blocks[#blocks + 1] = Kit.hline(col, Kit.dp(1), Kit.GREY_LIGHT) end
        end
        return blocks
    end)
    return VerticalGroup:new{ align = "left", header, Kit.box(w, avail, Kit.pad(body, Kit.PAD, 0), "top"), bottom }
end

function Wizard:finish()
    local then_export = self.then_export
    local app = self.app
    self:onClose()
    if then_export and app then
        app:open("kr2anki/screens/export", {})
    end
end

return Wizard
