--[[--
Capture: the "★ Save" row in the dictionary popup and the two buttons in the
text-selection menu. Saving is one local database write; nothing here touches
the network.

Interfaces (checked against KOReader 2026.07.1, see DECISIONS.md):
* ReaderDictionary:addToDictButtons(spec)       readerdictionary.lua
* DictQuickLookup fields word, lookupword, results, dict_index, button_table
* ReaderHighlight:addToHighlightDialog(idx, fn) readerhighlight.lua
* ReaderHighlight:getSelectedWordContext(n), .selected_text
* ReaderDictionary:startSdcv(word, dict_names, fuzzy)
--]]

local Lang = require("kr2anki/lang")
local S = require("kr2anki/sentence")
local Safe = require("kr2anki/safe")
local U = require("kr2anki/u8")
local _ = require("gettext")
local T = require("ffi/util").template

local C = {}

C.BUTTON_ID = "zz_kr2anki_save" -- sorts after "vocabulary", so our row is on top

-- Book and context ---------------------------------------------------------------

function C.bookInfo(ui)
    if not (ui and ui.document) then return nil end
    local props = ui.doc_props or {}
    local hash
    if ui.doc_settings then hash = ui.doc_settings:readSetting("partial_md5_checksum") end
    if not hash and ui.document.file then
        local ok, util = pcall(require, "util")
        if ok and util.partialMD5 then hash = util.partialMD5(ui.document.file) end
    end
    local authors = props.authors
    if type(authors) == "string" then authors = authors:gsub("\n", ", ") end
    return {
        title = props.display_title or props.title,
        authors = authors,
        language = props.language,
        file_hash = hash,
        file = ui.document.file,
    }
end

-- Raw context around the current selection: { prev, selection, next, position, page }
function C.selectionContext(ui, selection, lang)
    local ctx = { selection = selection }
    local hl = ui and ui.highlight
    if not (hl and hl.selected_text and ui.document) then return ctx end
    local nb = Lang.isCharBased(lang) and 80 or 50
    local ok, prev, nxt = pcall(hl.getSelectedWordContext, hl, nb)
    if ok then ctx.prev, ctx.next = prev, nxt end
    local pos0 = hl.selected_text.pos0
    if type(pos0) == "string" then ctx.position = pos0 end
    local pok, page = pcall(function() return ui:getCurrentPage() end)
    if pok then ctx.page = page end
    return ctx
end

function C.sentenceRecord(ctx, lang)
    local r = S.extract{ prev = ctx.prev, selection = ctx.selection, next = ctx.next, lang = lang }
    r.selection = ctx.selection
    r.context_before = ctx.prev
    r.context_after = ctx.next
    r.position = ctx.position
    r.page = ctx.page
    return r
end

function C.detectLanguage(host, word, dict_lang)
    local book = C.bookInfo(host.ui)
    return Lang.detect{
        word = word,
        book_override = host:bookOverride(book),
        book_lang = book and book.language,
        dict_lang = dict_lang,
    }
end

-- Notifications ---------------------------------------------------------------------

local function notify(text)
    local Notification = require("ui/widget/notification")
    Notification:notify(text, Notification.SOURCE_ALWAYS_SHOW)
end

local function savedText(item_label, lang, status, inbox)
    local where = status == "ready" and _("Ready") or T(_("Inbox (%1)"), inbox)
    return T(_("Saved %1 → %2 · %3"), item_label, Lang.name(lang), where)
end

-- Popup button --------------------------------------------------------------------

local LABELS = {
    new = _("★ Save"),
    nodef = _("Save without definition"),
    saved_inbox = _("✓ Saved · Inbox"),
    saved_ready = _("✓ Saved · Ready"),
    in_anki = _("✓ In Anki · Add this sentence"),
    added_sentence = _("✓ Sentence added · Undo"),
    known = _("— Known · Move to Inbox"),
}

local function popupResultIndex(popup)
    return popup.dict_index or 1
end

local function popupLemma(popup)
    local r = popup.results and popup.results[popupResultIndex(popup)]
    if r and not r.no_result and r.word and r.word ~= "" then return r.word end
    return popup.lookupword or popup.word
end

local function popupDictLang(host, popup)
    local r = popup.results and popup.results[popupResultIndex(popup)]
    if not r or r.no_result then return nil end
    return host:getDictInfo():language(r.dict, r.ifo_lang)
end

local function hasDefinition(popup)
    local r = popup.results and popup.results[1]
    return r ~= nil and not r.no_result
end

-- Work out the button state for a popup (cached on the popup).
function C.popupState(host, popup)
    local st = popup._kr2anki
    if st then return st end
    st = {}
    popup._kr2anki = st
    local store = host:getStore()
    local lemma = popupLemma(popup)
    st.lemma = lemma
    st.lang = C.detectLanguage(host, lemma, popupDictLang(host, popup))
    local item = store and store:findItem(st.lang, "word", lemma)
    st.item_id = item and item.id
    if item and (item.status == "inbox" or item.status == "ready") then
        st.state = item.status == "ready" and "saved_ready" or "saved_inbox"
        st.existing = true
    elseif item and item.status == "anki" then
        st.state = "in_anki"
    elseif item and item.status == "known" then
        st.state = "known"
    else
        st.state = hasDefinition(popup) and "new" or "nodef"
        st.discarded = item ~= nil and item.status == "discarded"
    end
    st.initial = st.state
    return st
end

function C.popupLabel(host, popup)
    local ok, st = pcall(C.popupState, host, popup)
    if not ok then
        Safe.log("popup state:", st)
        return LABELS.new
    end
    return LABELS[st.state] or LABELS.new
end

local function refreshButton(popup, text)
    local UIManager = require("ui/uimanager")
    local bt = popup.button_table
    local button = bt and (bt.getButtonById and bt:getButtonById(C.BUTTON_ID) or (bt.button_by_id or {})[C.BUTTON_ID])
    if not button then return end
    button:setText(text, button.width)
    UIManager:setDirty(popup, function() return "ui", button.dimen end)
end

-- Build the capture for the word in a popup.
function C.popupCapture(host, popup, st)
    local ui = host.ui
    local hl = ui and ui.highlight
    local selection = popup.word
    if hl and hl.selected_text and hl.selected_text.text and hl.selected_text.text ~= "" then
        selection = U.squash(hl.selected_text.text)
    end
    local ctx = C.selectionContext(ui, selection, st.lang)
    local lookups = host:getDictInfo():lookupsFromResults(popup.results or {}, popupResultIndex(popup))
    return {
        type = "word",
        language = st.lang,
        surface = selection,
        lemma = st.lemma,
        lookups = lookups,
        sentence = C.sentenceRecord(ctx, st.lang),
        book = C.bookInfo(ui),
    }
end

function C.afterSave(host, label, lang, result)
    host:noteSessionSave("word", result)
    notify(savedText(label, lang, result.status, result.inbox))
end

function C.onPopupTap(host, popup)
    local store = host:getStore()
    if not store then return end
    local st = C.popupState(host, popup)
    local state = st.state
    if state == "new" or state == "nodef" then
        -- the reader may have switched to another dictionary result since the
        -- popup was built: save the headword that is on screen now
        st.lemma = popupLemma(popup)
        st.lang = C.detectLanguage(host, st.lemma, popupDictLang(host, popup))
    end
    if state == "new" or state == "nodef" or state == "known" then
        local cap = C.popupCapture(host, popup, st)
        cap.reactivate = state == "known" or st.discarded == true
        st.result = store:saveCapture(cap)
        st.state = st.result.status == "ready" and "saved_ready" or "saved_inbox"
        st.saved_here = true
        refreshButton(popup, LABELS[st.state])
        C.afterSave(host, st.lemma, st.lang, st.result)
        if host.settings:get("close_popup_after_save") then popup:onClose() end
    elseif (state == "saved_inbox" or state == "saved_ready") and st.saved_here then
        -- undo
        store:undoSave(st.result)
        host:noteSessionUndo("word", st.result)
        st.result, st.saved_here = nil, nil
        st.state = st.initial == "known" and "known" or (hasDefinition(popup) and "new" or "nodef")
        if st.initial == "saved_inbox" or st.initial == "saved_ready" then st.state = st.initial end
        refreshButton(popup, LABELS[st.state])
        notify(T(_("Removed %1"), st.lemma))
    elseif state == "saved_inbox" or state == "saved_ready" then
        C.existingDialog(host, popup, st)
    elseif state == "in_anki" then
        local cap = C.popupCapture(host, popup, st)
        st.result = store:saveCapture(cap)
        st.state = "added_sentence"
        refreshButton(popup, LABELS.added_sentence)
        notify(T(_("Sentence added to %1 · sent with the next export"), st.lemma))
    elseif state == "added_sentence" then
        store:undoSave(st.result)
        st.result = nil
        st.state = "in_anki"
        refreshButton(popup, LABELS.in_anki)
    end
end

-- The word was saved earlier: add this sentence, or remove the item.
function C.existingDialog(host, popup, st)
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local ConfirmBox = require("ui/widget/confirmbox")
    local store = host:getStore()
    local dialog
    dialog = ButtonDialog:new{
        title = T(_("%1 is already saved."), st.lemma),
        buttons = {
            { {
                text = _("Add this sentence"),
                callback = Safe.wrap("add sentence", function()
                    UIManager:close(dialog)
                    local cap = C.popupCapture(host, popup, st)
                    st.result = store:saveCapture(cap)
                    st.saved_here = true
                    notify(T(_("Sentence added to %1"), st.lemma))
                end),
            } },
            { {
                text = _("Remove from KR2Anki"),
                callback = function()
                    UIManager:close(dialog)
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Remove %1 and its saved sentences?"), st.lemma),
                        ok_text = _("Remove"),
                        ok_callback = Safe.wrap("remove", function()
                            store:delete({ st.item_id })
                            st.state = "new"
                            st.existing = nil
                            refreshButton(popup, LABELS.new)
                            notify(T(_("Removed %1"), st.lemma))
                        end),
                    })
                end,
            } },
            { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } },
        },
    }
    UIManager:show(dialog)
end

function C.registerDictButton(host)
    local dict = host.ui and host.ui.dictionary
    if not (dict and dict.addToDictButtons) then
        Safe.log("ReaderDictionary:addToDictButtons is missing; the popup Save button is disabled")
        return false
    end
    dict:addToDictButtons({
        id = C.BUTTON_ID,
        menu_text = _("KR2Anki: Save"),
        text_func = function(popup) return C.popupLabel(host, popup) end,
        insert_first = true,
        font_bold = true,
        show_func = function(popup)
            return not popup.is_wiki and not popup.is_wiki_fullpage
        end,
        callback = Safe.wrap("save", function(popup) C.onPopupTap(host, popup) end),
    })
    return true
end

-- Text-selection menu ---------------------------------------------------------------

-- Silent dictionary lookup (no popup). Returns results or {}.
function C.silentLookup(host, word)
    local dict = host.ui and host.ui.dictionary
    if not (dict and dict.startSdcv) then return {} end
    local ok, results = pcall(dict.startSdcv, dict, word, dict.enabled_dict_names, false)
    if not ok or type(results) ~= "table" then
        Safe.log("silent lookup failed:", results)
        return {}
    end
    local out = {}
    for __, r in ipairs(results) do
        if not r.no_result and r.dict and r.dict ~= "" then out[#out + 1] = r end
    end
    return out
end

function C.saveSelectionWord(host, hl)
    local store = host:getStore()
    if not store or not hl.selected_text then return end
    local selection = U.squash(hl.selected_text.text or "")
    if selection == "" then return end
    local results = C.silentLookup(host, selection)
    local lookups = host:getDictInfo():lookupsFromResults(results, 1)
    local lemma = lookups[1] and lookups[1].headword or selection
    local lang = C.detectLanguage(host, lemma, lookups[1] and lookups[1].dict_lang)
    local ctx = C.selectionContext(host.ui, selection, lang)
    local existing = store:findItem(lang, "word", lemma)
    local result = store:saveCapture{
        type = "word", language = lang, surface = selection, lemma = lemma, lookups = lookups,
        sentence = C.sentenceRecord(ctx, lang), book = C.bookInfo(host.ui),
        reactivate = existing ~= nil and (existing.status == "known" or existing.status == "discarded"),
    }
    hl:onClose()
    if existing and existing.status == "anki" then
        notify(T(_("Sentence added to %1 · sent with the next export"), lemma))
    else
        C.afterSave(host, lemma, lang, result)
    end
end

function C.saveSelectionExpression(host, hl)
    local store = host:getStore()
    if not store or not hl.selected_text then return end
    local selection = U.squash(hl.selected_text.text or "")
    if selection == "" then return end
    local lang = C.detectLanguage(host, selection, nil)
    local ctx = C.selectionContext(host.ui, selection, lang)
    local result = store:saveCapture{
        type = "expression", language = lang, surface = selection, pattern = selection, lookups = {},
        sentence = C.sentenceRecord(ctx, lang), book = C.bookInfo(host.ui),
    }
    hl:onClose()
    host:noteSessionSave("expression", result)
    notify(savedText("◆ " .. U.ellipsize(selection, 16), lang, result.status, result.inbox))
end

function C.registerHighlightButtons(host)
    local hl = host.ui and host.ui.highlight
    if not (hl and hl.addToHighlightDialog) then
        Safe.log("ReaderHighlight:addToHighlightDialog is missing; selection-menu buttons are disabled")
        return false
    end
    -- keys sort after KOReader's "01_select" … "11_follow_link", so ours come last
    hl:addToHighlightDialog("kr2anki_1_save_word", function(this)
        return {
            text = _("★ Save word"),
            enabled = this.selected_text ~= nil,
            callback = Safe.wrap("save word", function() C.saveSelectionWord(host, this) end),
        }
    end)
    hl:addToHighlightDialog("kr2anki_2_save_expression", function(this)
        return {
            text = _("◆ Save as expression"),
            enabled = this.selected_text ~= nil,
            callback = Safe.wrap("save expression", function() C.saveSelectionExpression(host, this) end),
        }
    end)
    return true
end

return C
