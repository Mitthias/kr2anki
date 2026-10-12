--[[--
Import from KOReader's built-in Vocabulary Builder. Its database is opened
read-only and never written. Each word is looked up again in the installed
dictionaries and added as an Inbox item; words already in KR2Anki gain the
sentence instead of a duplicate.
--]]

local DataStorage = require("datastorage")
local Lang = require("kr2anki/lang")
local Safe = require("kr2anki/safe")
local _ = require("gettext")
local T = require("ffi/util").template

local V = {}

V.PATH = DataStorage:getSettingsDir() .. "/vocabulary_builder.sqlite3"

-- Rows: { word, title, prev_context, next_context, highlight, create_time }
function V.readRows(path)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") ~= "file" then return nil, _("No Vocabulary Builder database found.") end
    local SQ3 = require("lua-ljsqlite3/init")
    local conn = SQ3.open(path, "ro")
    local stmt = conn:prepare("SELECT v.word, t.name, v.prev_context, v.next_context, v.highlight, v.create_time "
        .. "FROM vocabulary v LEFT JOIN title t ON t.id = v.title_id ORDER BY v.create_time")
    local rows = {}
    local row = stmt:step()
    while row do
        rows[#rows + 1] = { word = row[1], title = row[2], prev = row[3], next = row[4], highlight = row[5],
                            created = tonumber(row[6]) }
        row = stmt:step()
    end
    stmt:close()
    conn:close()
    return rows
end

-- Import one row; returns "added" | "merged" | "skipped".
function V.importRow(host, row, books_by_title)
    local Capture = require("kr2anki/capture")
    local store = host:getStore()
    local word = row.word
    if not word or word == "" then return "skipped" end
    local results = Capture.silentLookup(host, word)
    local lookups = host:getDictInfo():lookupsFromResults(results, 1)
    local lemma = lookups[1] and lookups[1].headword or word
    local book = row.title and books_by_title[row.title]
    local lang = Lang.detect{
        word = lemma,
        book_override = book and book.language_override,
        book_lang = book and book.language,
        dict_lang = lookups[1] and lookups[1].dict_lang,
    }
    local selection = (row.highlight and row.highlight ~= "") and row.highlight or word
    local S = require("kr2anki/sentence")
    local sent = S.extract{ prev = row.prev, selection = selection, next = row.next, lang = lang }
    sent.selection, sent.context_before, sent.context_after = selection, row.prev, row.next
    local existed = store:findItem(lang, "word", lemma)
    store:saveCapture{
        type = "word", language = lang, surface = selection, lemma = lemma, lookups = lookups,
        sentence = sent,
        book = row.title and { title = row.title, authors = book and book.authors, language = book and book.language,
                               file_hash = book and book.file_hash } or nil,
    }
    return existed and "merged" or "added"
end

function V.start(host)
    local store = host:getStore()
    if not store then return end
    local rows, err = V.readRows(V.PATH)
    if not rows then
        Safe.message(err)
        return
    end
    if #rows == 0 then
        Safe.message(_("The Vocabulary Builder has no words."))
        return
    end
    local books_by_title = {}
    for __, b in ipairs(store:allBooks()) do
        if b.title then books_by_title[b.title] = b end
    end
    local ConfirmBox = require("ui/widget/confirmbox")
    local UIManager = require("ui/uimanager")
    UIManager:show(ConfirmBox:new{
        text = T(_("Import %1 words from the Vocabulary Builder?\n\nEach word is looked up in your dictionaries and added to the Inbox. Words already in KR2Anki gain the sentence instead of a duplicate. The Vocabulary Builder is not changed."), #rows),
        ok_text = _("Import"),
        ok_callback = function()
            local Trapper = require("ui/trapper")
            Trapper:wrap(function()
                local added, merged, skipped = 0, 0, 0
                for i, row in ipairs(rows) do
                    if i % 10 == 1 then
                        local go_on = Trapper:info(T(_("Importing… %1 / %2"), i, #rows))
                        if not go_on then break end
                    end
                    local ok, res = pcall(V.importRow, host, row, books_by_title)
                    if not ok then
                        require("logger").warn("KR2Anki: import failed for", row.word, res)
                        skipped = skipped + 1
                    elseif res == "added" then added = added + 1
                    elseif res == "merged" then merged = merged + 1
                    else skipped = skipped + 1 end
                end
                Trapper:clear()
                Safe.message(T(_("Imported %1 words.\n%2 were already in KR2Anki and gained a sentence.\n%3 skipped."),
                    added, merged, skipped))
            end)
        end,
    })
end

return V
