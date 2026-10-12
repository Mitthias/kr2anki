-- KOReader-side flows against stand-in widgets (dev/uistubs.lua):
-- capture hooks, every screen, review, export, wizard, menu, import.
-- Run through dev/run_ui.sh (sets SCREEN_W/H, DPI_SCALE, HARNESS_OUT).
local ROOT = os.getenv("KR2_ROOT")
local OUT = os.getenv("HARNESS_OUT")
local PLUGIN = ROOT .. "/kr2anki.koplugin"
package.path = ROOT .. "/dev/stubs/?.lua;" .. PLUGIN .. "/?.lua;" .. ROOT .. "/tests/support/?.lua;"
    .. ROOT .. "/.rocks/share/lua/5.1/?.lua;" .. package.path
package.cpath = ROOT .. "/.rocks/lib/lua/5.1/?.so;" .. package.cpath
local env = dofile(ROOT .. "/dev/uistubs.lua")
local SNAP = os.getenv("SNAP_DIR")
local svg
if SNAP and SNAP ~= "" then
    _G.HARNESS_PLUGIN = PLUGIN
    svg = dofile(ROOT .. "/dev/svgrender.lua")
    svg.install()
end

local json = require("json")
local FakeAnki = require("fakeanki")
local Anki = require("kr2anki/anki")

local fails, oks = 0, 0
local function check(cond, msg)
    if not cond then
        fails = fails + 1
        print("FAIL: " .. msg)
    else
        oks = oks + 1
        if os.getenv("VERBOSE") then print("ok   " .. msg) end
    end
end
local function has(pattern)
    for _, t in ipairs(texts()) do if tostring(t):find(pattern, 1, true) then return true end end
    return false
end
local function snap(name)
    if svg then
        local f = io.open(SNAP .. "/" .. name .. ".svg", "w")
        f:write(svg.render(paintTop(), env.W, env.H))
        f:close()
    end
end
-- page forward through a list until `text` shows (returns true if found)
local function findOnPages(text)
    local guard = 0
    while not has(text) and guard < 20 do
        local scr = UIM:top()
        if not scr.page or not scr.pages or scr.page >= scr.pages then break end
        swipe("west")
        guard = guard + 1
    end
    return has(text)
end

local function holdText(text)
    local target
    walk(paintTop(), function(w) if w.text == text and w.dimen then target = w return true end end)
    if not target then error("no row " .. text) end
    tapAt(target.dimen.x + 2, target.dimen.y + 2, "hold")
end

local function dismiss()
    while UIM:top() and UIM:top().__kind do UIM:close(UIM:top()) end
end

local function layoutOk(name)
    _G.OVERFLOWS = nil
    local bad = offscreen()
    check(#bad == 0, name .. ": everything on screen " .. table.concat(bad, "; "))
    check(_G.OVERFLOWS == nil, name .. ": no overflow " .. table.concat(_G.OVERFLOWS or {}, "; "))
    snap(name)
end

-- Dictionaries ------------------------------------------------------------------------
os.execute("mkdir -p '" .. OUT .. "/settings' '" .. OUT .. "/data/dict/jmdict' '" .. OUT .. "/data/dict/wordnet' '"
    .. OUT .. "/data/dict/cedict' '" .. OUT .. "/data/dict/korean' '" .. OUT .. "/data/dict/jmdict/res'")
local function ifo(dir, name, lang)
    local f = io.open(OUT .. "/data/dict/" .. dir .. "/" .. dir .. ".ifo", "w")
    f:write("StarDict's dict ifo file\nversion=3.0.0\nbookname=" .. name .. "\nwordcount=1\nlang=" .. lang .. "\n")
    f:close()
end
ifo("jmdict", "JMdict (English)", "ja-en")
ifo("wordnet", "WordNet 3.0", "en-en")
ifo("cedict", "CC-CEDICT", "zh-en")
ifo("korean", "Korean-English Dictionary", "ko-en")
local snd = io.open(OUT .. "/data/dict/jmdict/res/uchiakeru.mp3", "wb"); snd:write("ID3fake"); snd:close()

local DICT = {
    ["打ち明けない"] = { { dict = "JMdict (English)", word = "打ち明ける",
        definition = 'うちあける【打ち明ける】\n(v1,vt) 1. to confide (a secret); to reveal; to disclose\n2. to be frank; to speak one\'s mind; to open one\'s heart\n3. (arch) to empty out (a container)\n<a href="sound://uchiakeru.mp3">▶</a>' } },
    ["なった"] = { { dict = "JMdict (English)", word = "成る",
        definition = "なる【成る】\n(v5r,vi) 1. to become; to get; to grow; to turn into\n2. to reach; to attain (an age, a time)\n"
            .. "3. to result in; to prove to be\n4. to consist of; to be composed of\n5. to be completed; to be finished\n"
            .. "6. to be promoted (shogi piece)\n7. to change into\n8. (hon) to do" },
        { dict = "JMdict (English)", word = "なる", definition = "なる\n(v5r,vi) to sound; to ring" } },
    ["打算"] = { { dict = "CC-CEDICT", word = "打算", definition = "打算 [da3 suan4]\n/to plan/to intend/to calculate/CL:個|个[ge4]/" } },
    ["ran"] = { { dict = "WordNet 3.0", word = "run",
        definition = 'v 1: move fast by using one\'s feet; "Don\'t run--you\'ll be out of breath"\n2: flee; take to one\'s heels\n3: stretch out over a distance' } },
    ["먹었다"] = { { dict = "Korean-English Dictionary", word = "먹다", definition = "먹다 [meokda]\n1. eat, have, take\n2. drink" } },
    ["inexhaustible"] = { { dict = "WordNet 3.0", word = "inexhaustible",
        definition = "/ɪnɪɡˈzɔːstəbl/\nadj 1: incapable of being entirely consumed or used up\n2: that cannot be entirely used up" } },
}
for _, list in pairs(DICT) do
    for _, r in ipairs(list) do
        local lang = r.dict:find("JMdict") and { lang_in = "ja", lang_out = "en" } or nil
        r.ifo_lang = lang
    end
end

-- Fake ReaderUI ---------------------------------------------------------------------------
local BOOKS = {
    kokoro = { title = "こころ", authors = "夏目漱石", language = "ja", hash = "hash-kokoro" },
    gatsby = { title = "The Great Gatsby", authors = "F. Scott Fitzgerald", language = "en", hash = "hash-gatsby" },
    huozhe = { title = "活着", authors = "余华", language = "zh", hash = "hash-huozhe" },
    korean = { title = "채식주의자", authors = "한강", language = "ko", hash = "hash-ko" },
}

local function makeUI(book)
    local ui = {}
    ui.menu = { registerToMainMenu = function(_, w) ui._menu_widget = w end }
    ui.dictionary = {
        _buttons = {}, data_dir = OUT .. "/data/dict",
        enabled_dict_names = { "JMdict (English)", "WordNet 3.0", "CC-CEDICT", "Korean-English Dictionary" },
        addToDictButtons = function(self, spec) self._buttons[spec.id] = spec end,
        startSdcv = function(_, word)
            local r = DICT[word]
            if not r then return { { dict = "Not available", word = word, definition = "No results.", no_result = true } } end
            local copy = {}
            for i, x in ipairs(r) do copy[i] = { dict = x.dict, word = x.word, definition = x.definition, ifo_lang = x.ifo_lang } end
            return copy
        end,
    }
    if book then
        ui.highlight = {
            _buttons = {},
            addToHighlightDialog = function(self, k, fn) self._buttons[k] = fn end,
            getSelectedWordContext = function(self) return self._prev, self._next end,
            onClose = function(self) self.closed = true; self.selected_text = nil end,
        }
        ui.document = { file = OUT .. "/books/" .. book.title .. ".epub" }
        ui.doc_props = { display_title = book.title, authors = book.authors, language = book.language }
        ui.doc_settings = { readSetting = function(_, k) if k == "partial_md5_checksum" then return book.hash end end }
        ui.getCurrentPage = function() return 3 end
    end
    return ui
end

local KR2Anki = dofile(PLUGIN .. "/main.lua")
local fake = FakeAnki.new()
local function newHost(book)
    local ui = makeUI(book)
    local host = KR2Anki:new{ ui = ui, path = PLUGIN }
    host.client = function(_, timeout) return Anki.new{ json = json, transport = fake:transport(), timeout = timeout } end
    return host, ui
end

local Capture = require("kr2anki/capture")

local function select(ui, prev, text, nxt)
    ui.highlight.selected_text = { text = text, pos0 = "/body/p[3]/text().12" }
    ui.highlight._prev, ui.highlight._next = prev, nxt
    ui.highlight.closed = nil
end

local function popup(ui, word, results, idx)
    local p = { word = word, results = results, dict_index = idx or 1, ui = ui }
    p.lookupword = results[idx or 1].word
    p._btn = { width = 100, setText = function(self, t) self.text = t end, dimen = {} }
    p.button_table = { getButtonById = function() return p._btn end }
    p.onClose = function() p.closed = true end
    return p
end

-- 1. Plugin init and hooks ------------------------------------------------------------------
local host, ui = newHost(BOOKS.kokoro)
check(ui._menu_widget == host, "registers in the main menu")
local spec = ui.dictionary._buttons[Capture.BUTTON_ID]
check(spec ~= nil and spec.insert_first and spec.menu_text, "adds a first-row popup button with a menu entry")
check(ui.highlight._buttons.kr2anki_1_save_word and ui.highlight._buttons.kr2anki_2_save_expression, "adds two selection-menu buttons")
check(DISPATCHER_ACTIONS.kr2anki_open and DISPATCHER_ACTIONS.kr2anki_review and DISPATCHER_ACTIONS.kr2anki_export,
    "registers three gesture actions")
local missing = {}
for _, c in ipairs(host.hook_status) do if not c[2] then missing[#missing + 1] = c[1] end end
check(#missing == 2 and missing[1] == "socket.http", "hook check flags only what the harness lacks: " .. table.concat(missing, ", "))
local ok_fm = pcall(function() return KR2Anki:new{ ui = makeUI(nil), path = PLUGIN } end)
check(ok_fm, "loads in the file manager too (no highlight module)")

-- 2. Popup: Save, undo, existing, no definition --------------------------------------------
select(ui, "私はその人を常に先生と呼んでいた。だからここでもただ先生と書くだけで本名は", "打ち明けない",
    "。これは世間を憚かる遠慮というよりも、")
local p = popup(ui, "打ち明けない", DICT["打ち明けない"])
check(spec.text_func(p) == "★ Save", "new word shows ★ Save")
local t0 = os.clock()
spec.callback(p)
local save_ms = (os.clock() - t0) * 1000
check(save_ms < 100, string.format("save takes under 100 ms (%.1f ms CPU)", save_ms))
check(p._btn.text == "✓ Saved · Inbox", "button becomes ✓ Saved · Inbox")
check(LAST_NOTIFY == "Saved 打ち明ける → Japanese · Inbox (1)", "notification: " .. tostring(LAST_NOTIFY))
local store = host:getStore()
local item = store:findItem("ja", "word", "打ち明ける")
check(item ~= nil, "item stored")
local full = store:getItem(item.id)
check(full.surface == "打ち明けない" and full.reading == "うちあける", "surface and reading stored")
check(full.definition == "to confide (a secret); to reveal; to disclose", "first sense chosen")
check(full.sentence.text == "だからここでもただ先生と書くだけで本名は打ち明けない。", "sentence cut: " .. full.sentence.text)
check(full.sentence.text:sub(full.sentence.hl_start, full.sentence.hl_end) == "打ち明けない", "highlight offsets")
check(full.sentence.book.title == "こころ" and full.sentence.page == "3", "book and page stored")
check(full.audio == "uchiakeru.mp3", "dictionary audio reference kept")
spec.callback(p)
check(p._btn.text == "★ Save" and store:counts().total == 0, "tapping again undoes the save")
spec.callback(p)
check(not p.closed, "popup stays open by default")
item = store:findItem("ja", "word", "打ち明ける")
-- switching to another dictionary result before saving saves that headword
select(ui, "私が先生と知り合いに", "なった", "のは鎌倉である。")
local pn = popup(ui, "なった", DICT["なった"])
spec.text_func(pn)
pn.dict_index = 2
spec.callback(pn)
check(store:findItem("ja", "word", "なる") ~= nil and store:findItem("ja", "word", "成る") == nil,
    "saves the result on screen at tap time")
spec.callback(pn) -- undo
check(store:findItem("ja", "word", "なる") == nil, "undo after switching results")
-- the same word in a new popup: already saved
local p2 = popup(ui, "打ち明けない", DICT["打ち明けない"])
check(spec.text_func(p2) == "✓ Saved · Inbox", "existing Inbox word shows ✓ Saved · Inbox")
spec.callback(p2)
check(LAST_buttondialog and LAST_buttondialog.title:find("already saved", 1, true), "tapping an existing item asks what to do")
select(ui, "", "打ち明けない", "と彼は言った。")
pressDialogButton(LAST_buttondialog, "Add this sentence")
check(#store:getItem(item.id).sentences == 1 + 1, "adds this sentence to the existing item")
-- no definition
local nodef = ui.dictionary:startSdcv("珍語")
local p3 = popup(ui, "珍語", nodef)
check(spec.text_func(p3) == "Save without definition", "no result shows Save without definition")
select(ui, "これは", "珍語", "です。")
spec.callback(p3)
local nd = store:findItem("ja", "word", "珍語")
check(nd and store:getItem(nd.id).definition == nil, "saved with empty definition fields")
-- Close popup after saving
host.settings:set("close_popup_after_save", true)
select(ui, "", "打算", "")
local p4 = popup(ui, "打算", DICT["打算"])
spec.callback(p4)
check(p4.closed, "closes the popup when the setting is on")
host.settings:set("close_popup_after_save", false)
local da = store:findItem("ja", "word", "打算")
check(da ~= nil, "Han-only word in a Japanese book is Japanese")

-- 3. Selection menu -----------------------------------------------------------------------------
select(ui, "私が先生と知り合いに", "なった", "のは鎌倉である。")
local btn = ui.highlight._buttons.kr2anki_1_save_word(ui.highlight)
check(btn.text == "★ Save word", "selection menu: ★ Save word")
btn.callback()
local naru = store:findItem("ja", "word", "成る")
check(naru ~= nil, "Save word looks the selection up and saves its headword")
check(ui.highlight.closed, "selection menu closes after saving")
check(#store:getItem(naru.id).lookups == 2, "keeps every dictionary result")
select(ui, "その犠牲としてみんなこの淋しみを味わ", "わなくてはならない", "でしょう」")
ui.highlight._buttons.kr2anki_2_save_expression(ui.highlight).callback()
local expr = store:findItem("ja", "expression", "わなくてはならない")
check(expr and expr.pattern == "わなくてはならない", "Save as expression prefills Pattern with the raw selection")
check(LAST_NOTIFY:find("◆", 1, true), "expression notification")

-- other languages
local _, uiEn = newHost(BOOKS.gatsby)
select(uiEn, "He ", "ran", " home. Then he slept.")
uiEn.highlight._buttons.kr2anki_1_save_word(uiEn.highlight).callback()
local run = store:findItem("en", "word", "run")
check(run and store:getItem(run.id).sentence.text == "He ran home.", "English word saved under its base form")
local _, uiZh = newHost(BOOKS.huozhe)
select(uiZh, "我们", "打算", "明天去。你呢？")
uiZh.highlight._buttons.kr2anki_1_save_word(uiZh.highlight).callback()
local zh = store:findItem("zh", "word", "打算")
check(zh and store:getItem(zh.id).sentence.text == "我们打算明天去。", "Chinese word: book language decides Han-only")
check(zh and store:getItem(zh.id).reading == "dǎ suàn", "pinyin converted to tone marks")
local _, uiKo = newHost(BOOKS.korean)
select(uiKo, "우리는 밥을 ", "먹었다", ". 그리고 잤다.")
uiKo.highlight._buttons.kr2anki_1_save_word(uiKo.highlight).callback()
check(store:findItem("ko", "word", "먹다") ~= nil, "Korean word saved under the dictionary headword")
-- in Anki / Known states
store:setStatus({ run.id }, "ready")
store:markExported(run.id, 1700000009999)
local pr = popup(uiEn, "ran", DICT.ran)
check(spec.text_func(pr) == "✓ In Anki · Add this sentence" or uiEn.dictionary._buttons[Capture.BUTTON_ID].text_func(pr) == "✓ In Anki · Add this sentence",
    "In Anki item shows Add this sentence")
local specEn = uiEn.dictionary._buttons[Capture.BUTTON_ID]
select(uiEn, "She ", "ran", " away fast.")
specEn.callback(pr)
check(store:getItem(run.id).needs_update == 1, "adding a sentence to an In Anki item queues an update")
store:setStatus({ naru.id }, "known")
local pk = popup(ui, "なった", DICT["なった"])
check(spec.text_func(pk) == "— Known · Move to Inbox", "Known item shows that instead")
store:setStatus({ naru.id }, "inbox", { force = true })
store:setStatus({ naru.id }, "discarded")
local pd = popup(ui, "なった", DICT["なった"])
check(spec.text_func(pd) == "★ Save", "a Discarded word can be saved again")
spec.callback(pd)
check(store:getItem(naru.id).status == "inbox", "saving a Discarded word moves it back to the Inbox")
spec.callback(pd)
check(store:getItem(naru.id).status == "discarded", "undo restores Discarded")
store:setStatus({ naru.id }, "inbox")
store:setStatus({ naru.id }, "known")

-- 4. Home ----------------------------------------------------------------------------------------
host.settings:set("nudge_threshold", 3)
host:openManager()
UIM:runTicks()
check(has("KR2Anki"), "home opens")
check(has("● Anki: Connected"), "home shows Anki status after the check")
check(has("Inbox") and has("Ready") and has("In Anki") and has("Known / × Discarded"), "status rows")
check(has("items waiting for review"), "nudge banner at the threshold")
check((has("Japanese") and has("words")) or has("languages"), "Inbox per language (rows, or a summary row when space is short)")
check(has("Start review (") and has("Export ("), "bottom row")
layoutOk("home")

-- 5. Browse → list -> selection --------------------------------------------------------------
tapText("^Browse$")
check(has("All languages") and has("Japanese") and has("English"), "browse languages")
layoutOk("browse_languages")
tapText("^Japanese$")
check(has("All books") and has("『こころ』"), "browse books for a language")
tapText("『こころ』")
check(has("items ·"), "item list opens")
check(has("○ Inbox · ● Ready"), "legend line")
layoutOk("items_list")
tapText("Newest ⇅") -- sort toggle
check(has("A–Z ⇅"), "sort toggle switches to A–Z")
-- long-press a row → selection mode
findOnPages("成る")
holdText("成る")
check(has("1 selected"), "long-press enters selection mode")
tapText("^Select page$")
check(has("selected") and has("● Mark Ready"), "select page + bulk bar")
layoutOk("items_selecting")
tapText("● Mark Ready")
check(LAST_infomessage and LAST_infomessage.text:find("marked Ready", 1, true), "bulk Mark Ready reports: " .. tostring(LAST_infomessage and LAST_infomessage.text))
check(LAST_infomessage.text:find("expression needs a meaning", 1, true) == nil, "expressions allowed with empty meaning by default")
UIM:close(LAST_infomessage)
-- delete with confirmation
UIM:top():goPage(1)
check(findOnPages("珍語"), "finds the row to delete")
holdText("珍語")
tapText("× Delete")
check(LAST_confirmbox and LAST_confirmbox.text:find("Delete 1 items", 1, true), "delete asks for confirmation")
confirm()
check(store:findItem("ja", "word", "珍語") == nil, "deleted")
-- filter
tapText("^Filter$")
check(has("STATUS") and has("TYPE") and has("SAVED"), "filter screen")
layoutOk("filter")
tapText("In Anki")
tapText("^Apply$")
check(has("Filter · 1") and has("Clear filter"), "active filter marked")
check(has("No words match this filter."), "empty filtered list")
layoutOk("items_filtered_empty")
tapText("Show all")
check(not has("No words match this filter."), "Show all clears the filter")
UIM:top():onClose(); UIM:runTicks()
UIM:top():onClose(); UIM:runTicks()
UIM:top():onClose(); UIM:runTicks()

-- 6. Review session ----------------------------------------------------------------------------
store:setStatus(store:queryIds({ statuses = { ready = true } }), "inbox")
store:setStatus({ naru.id }, "inbox")
host:openReview()
check(has("Review 1 /"), "review opens")
layoutOk("review_first")
-- find the 8-sense word
local guard = 0
while not has("成る") and guard < 10 do swipe("west"); guard = guard + 1 end
check(has("成る"), "reaches the 8-sense word")
check(has("More senses ("), "more than 5 senses: More senses button")
check(has("1. to become; to get; to grow; to turn into"), "first sense shown")
check(has("‹") and has("JMdict (Engl"), "switch between dictionary results")
layoutOk("review_8_senses")
tapText("More senses")
check(has("Choose a sense"), "full-screen sense picker")
layoutOk("senses_picker")
findOnPages("8. to do")
tapText("8. to do")
local nr = store:getItem(naru.id)
check(nr.chosen_sense == 8 and nr.definition:find("to do", 1, true), "sense 8 chosen from the picker")
-- base form picker
tapText("✎")
check(LAST_buttondialog and LAST_buttondialog.title == "Base form", "✎ opens the base-form picker")
check(#dialogButtons(LAST_buttondialog) == 4, "every headword + Type another + Cancel: " .. table.concat(dialogButtons(LAST_buttondialog), " | "))
pressDialogButton(LAST_buttondialog, "なる  ·")
check(store:getItem(naru.id).lemma == "なる", "choosing a headword reloads its senses")
tapText("✎")
pressDialogButton(LAST_buttondialog, "成る  ·")
-- ready, then page back and change the decision
local index_before = UIM:top().index
tapText("✓ Ready")
check(UIM:top().index == index_before + 1, "Ready advances")
check(store:getItem(naru.id).status == "ready", "item is Ready")
swipe("east")
check(UIM:top().index == index_before and has("●"), "page back shows the previous item with its decision")
tapText("× Discard")
check(store:getItem(naru.id).status == "discarded", "decision can be changed after page-back")
-- expression screen
UIM:top():onClose(); UIM:runTicks()
host:openReview()
guard = 0
while not has("PATTERN") and guard < 10 do swipe("west"); guard = guard + 1 end
check(has("PATTERN") and has("MEANING") and has("FORMATION") and has("NUANCE"), "expression screen fields")
layoutOk("review_expression")
tapText("わなくてはならない", 1)
LAST_inputdialog._input = "〜なくてはならない"
pressDialogButton(LAST_inputdialog, "Save")
check(store:getItem(expr.id).pattern == "〜なくてはならない", "Pattern edited through the input dialog")
check(has("〜なくてはならない"), "edited pattern shown")
-- run to the end
guard = 0
while not has("Review done") and guard < 12 do tapText("Skip"); guard = guard + 1 end
check(has("Ready ·") and has("skipped"), "end-of-session summary")
check(has("Done") and has("Export ("), "summary buttons")
layoutOk("review_summary")
UIM:top():onClose(); UIM:runTicks()

-- 7. Single-item editor and sentence actions --------------------------------------------------
UIM:top():onClose(); UIM:runTicks()
host:getApp():open("kr2anki/screens/review", { ids = { item.id }, single = true })
check(has("Edit") and has("Close"), "single-item editor")
tapText("だからここでも", 1)
check(LAST_buttondialog and table.concat(dialogButtons(LAST_buttondialog), "|"):find("Shorten", 1, true), "sentence box offers Shorten")
check(table.concat(dialogButtons(LAST_buttondialog), "|"):find("Choose another sentence (2)", 1, true), "and Choose another sentence")
pressDialogButton(LAST_buttondialog, "Show more context")
check(store:getItem(item.id).sentence.text:find("私はその人を常に先生と呼んでいた。", 1, true), "more context adds the previous sentence")
tapText("NOTE")
tapText("Tap to add")
LAST_inputdialog._input = "Opening page: the narrator never reveals 先生's real name."
pressDialogButton(LAST_inputdialog, "Save")
check(store:getItem(item.id).personal_note:find("Opening page", 1, true), "note saved")
tapText("✓ Ready")
check(store:getItem(item.id).status == "ready", "editor sets status and closes")

-- 8. Export ----------------------------------------------------------------------------------------
store:setStatus(store:queryIds({ statuses = { inbox = true } }), "ready", { allow_empty_meaning = true })
host.settings:set("wizard_seen", true)
fake:addExisting("Basic", { Front = "打算", Back = "plan" }, "Reading::Japanese")
fake.decks["Reading::Japanese"] = 1
host:openExport()
UIM:runTicks()
check(has("ready to export"), "export pre-check")
check(has("BY DECK") and has("Reading::Japanese"), "counts per deck")
check(has("Cards: Recognition"), "active card types with Change")
check(has("IN ANOTHER NOTE TYPE: 1") and has("Add anyway"), "other note type duplicate: Skip / Add anyway")
layoutOk("export_precheck")
tapText("^Export$")
UIM:runTicks()
check(has("✓ Done") or has("Done, with failures"), "export result")
check(has("added ·") and has("merged ·") and has("failed"), "result counts")
layoutOk("export_result")
local c = store:counts()
check(c.ready == 1 and c.anki >= 5, "exported items are In Anki; the skipped duplicate stays Ready (" .. c.ready .. "/" .. c.anki .. ")")
local ex = store:getItem(item.id)
local note = fake.notes[ex.anki_note_id]
check(note and note.fields.Sound == "[sound:uchiakeru.mp3]" and fake.media["uchiakeru.mp3"], "dictionary audio stored and linked")
check(note and note.fields.Reading == "打[う]ち 明[あ]ける", "furigana reading")
check(note and note.fields.PersonalNote:find("Opening page", 1, true), "note exported")
UIM:top():onClose(); UIM:runTicks()

-- unreachable
store:setStatus({ store:findItem("ja", "word", "打算").id }, "ready")
fake.down = true
host.settings:set("caps", nil)
host:openExport()
UIM:runTicks()
check(has("Can't reach AnkiConnect Android.") and has("Nothing was lost."), "unreachable message")
check(has("How to fix") and has("Retry") and has("Save as Anki package"), "unreachable actions")
layoutOk("export_unreachable")
tapText("Save as Anki package")
check(has("ready to save"), "package fallback offered")
tapText("Save package")
check(has("Package saved") and has("kr2anki-export"), "package written: " .. table.concat(texts(), " | "):sub(1, 200))
layoutOk("export_package")
tapText("^Mark as exported$")
check(store:counts().ready == 0, "Mark as exported moves items on (ready=" .. store:counts().ready .. ", inbox=" .. store:counts().inbox .. ")")
UIM:top():onClose(); UIM:runTicks()
fake.down = false

-- Android-like: no createModel
local fake2 = FakeAnki.new{ unsupported = { createModel = "html" } }
host.client = function(_, timeout) return Anki.new{ json = json, transport = fake2:transport(), timeout = timeout } end
host.settings:set("caps", nil)
store:setStatus({ store:findItem("ja", "word", "打算").id }, "inbox", { force = true })
store:setStatus({ store:findItem("ja", "word", "打算").id }, "ready")
host:openExport()
UIM:runTicks()
check(has("Anki needs the KR2Anki note types."), "note types missing: import guidance")
layoutOk("export_need_notetypes")
tapText("^Write note%-type package$")
check(LAST_infomessage.text:find("kr2anki_notetypes.apkg", 1, true), "note-type package written")
dismiss()
UIM:top():onClose(); UIM:runTicks()
-- AnkiConnect Android as it really behaves: no createDeck/createModel/addNotes
local fake3 = FakeAnki.new{ android = true }
fake3.models["KR2Anki Word"] = { fields = require("kr2anki/notetypes").WORD_FIELDS }
fake3.models["KR2Anki Expression"] = { fields = require("kr2anki/notetypes").EXPR_FIELDS }
fake3.decks["Reading::Japanese"] = 2
host.client = function(_, timeout) return Anki.new{ json = json, transport = fake3:transport(), timeout = timeout } end
host.settings:set("caps", nil)
store:setStatus({ run.id }, "known")
local cocky = store:saveCapture{ type = "word", language = "en", surface = "cocky", lemma = "cocky", lookups = {} }.item_id
store:setStatus({ cocky }, "ready")
host:openExport()
UIM:runTicks()
check(has("Create these decks in AnkiDroid first.") and has("Reading::English"), "missing decks listed: " .. table.concat(texts(), " | "):sub(1, 300))
layoutOk("export_need_decks")
fake3.decks["Reading::English"] = 3
tapText("^Check again$")
UIM:runTicks()
check(has("ready to export"), "after creating the deck the pre-check appears")
tapText("^Export$")
UIM:runTicks()
check(has("✓ Done") and store:getItem(cocky).status == "anki", "exported through addNote one by one")
UIM:top():onClose(); UIM:runTicks()
host.client = function(_, timeout) return Anki.new{ json = json, transport = fake:transport(), timeout = timeout } end
host.settings:set("caps", nil)

-- 9. Wizard -------------------------------------------------------------------------------------
host:openWizard()
check(has("Set up Anki export") and has("Step 1 of 5"), "wizard opens at step 1")
layoutOk("wizard")
tapText("AnkiDroid installed")
pressDialogButton(LAST_buttondialog, "Mark done")
tapText("^Test$")
check(has("Step 3 of 5") or has("Step 5 of 5"), "connection test ticks rows 1–2")
tapText("^Create$")
check(has("Note types ready"), "creates decks and note types")
UIM:top():onClose(); UIM:runTicks()

-- 10. Menu, diagnostics, import ---------------------------------------------------------------------
local menu = {}
host:addToMainMenu(menu)
local count = 0
local function walkMenu(items)
    for _, it in ipairs(items or {}) do
        count = count + 1
        if it.text_func then it.text_func() end
        if it.checked_func then it.checked_func() end
        if it.sub_item_table_func then walkMenu(it.sub_item_table_func()) end
        if it.sub_item_table then walkMenu(it.sub_item_table) end
    end
end
local okm, errm = pcall(walkMenu, menu.kr2anki.sub_item_table)
check(okm, "every menu item builds: " .. tostring(errm))
check(count > 40, "menu tree has " .. count .. " items")
check(menu.kr2anki.sorting_hint == "tools", "menu sits under Tools")
local report = require("kr2anki/diagnostics").report(host, true)
check(report:find("✓ addNotes", 1, true) and report:find("JMdict (English) · ja · JMdict-style", 1, true), "diagnostics report")
-- Vocabulary Builder import
local SQ3 = require("lua-ljsqlite3/init")
local vb = SQ3.open(OUT .. "/settings/vocabulary_builder.sqlite3")
vb:exec("CREATE TABLE vocabulary (word TEXT, title_id INTEGER, create_time INTEGER, prev_context TEXT, next_context TEXT, highlight TEXT); CREATE TABLE title (id INTEGER, name TEXT);")
vb:exec("INSERT INTO title VALUES (1, 'The Great Gatsby');")
vb:exec("INSERT INTO vocabulary VALUES ('inexhaustible', 1, 1700000000, 'repelled by the ', ' variety of life.', NULL);")
vb:exec("INSERT INTO vocabulary VALUES ('ran', 1, 1700000001, 'He ', ' home.', NULL);")
vb:close()
local before = store:counts().total
require("kr2anki/vbimport").start(host)
confirm()
check(LAST_infomessage.text:find("Imported 1 words", 1, true), "import reports: " .. tostring(LAST_infomessage.text))
check(store:counts().total == before + 1, "import adds new words only")
require("kr2anki/vbimport").start(host)
confirm()
check(LAST_infomessage.text:find("Imported 0 words", 1, true), "importing twice adds no duplicates")

-- 11. Gestures --------------------------------------------------------------------------------------
host:onKR2AnkiOpen()
check(has("KR2Anki"), "gesture opens the manager")
host.app:closeAll()

local errs = 0
for _, l in ipairs(LOGGED) do if l:find("^err") then errs = errs + 1; print("  logged " .. l:sub(1, 300)) end end
check(errs == 0, "nothing logged as an error")
print(string.format("%d ok, %d failed", oks, fails))
os.exit(fails == 0 and 0 or 1)
