--[[--
KR2Anki's own SQLite database (kr2anki.sqlite3 in KOReader's settings folder).
KOReader's vocabulary_builder.sqlite3 is never written; see vbimport.lua.

    local Store = require("kr2anki/db")
    local store = Store.new(path, { json = rapidjson })
    local r = store:saveCapture(capture)

Every write is one transaction on a short-lived connection, so a save is a
single local write (well under 100 ms) and the file is never left open.
--]]

local SQ3 = require("lua-ljsqlite3/init")
local U = require("kr2anki/u8")
local Ruby = require("kr2anki/ruby")

local SCHEMA_VERSION = 1

local SCHEMA = {
    [[CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)]],
    [[CREATE TABLE IF NOT EXISTS books (
        id                INTEGER PRIMARY KEY AUTOINCREMENT,
        title             TEXT,
        authors           TEXT,
        language          TEXT,
        file_hash         TEXT,
        file              TEXT,
        language_override TEXT
    )]],
    [[CREATE INDEX IF NOT EXISTS books_hash ON books(file_hash)]],
    [[CREATE TABLE IF NOT EXISTS items (
        id               INTEGER PRIMARY KEY AUTOINCREMENT,
        uid              TEXT NOT NULL UNIQUE,
        type             TEXT NOT NULL DEFAULT 'word',
        language         TEXT NOT NULL,
        lemma            TEXT,
        lemma_key        TEXT,
        surface          TEXT,
        reading          TEXT,
        pos              TEXT,
        chosen_lookup_id INTEGER,
        chosen_sense     INTEGER,
        definition       TEXT,
        full_definition  TEXT,
        usage_notes      TEXT,
        dict_examples    TEXT,
        pattern          TEXT,
        meaning          TEXT,
        formation        TEXT,
        nuance           TEXT,
        personal_note    TEXT,
        dictionary       TEXT,
        audio            TEXT,
        pitch_accent     TEXT,
        status           TEXT NOT NULL DEFAULT 'inbox',
        anki_note_id     INTEGER,
        needs_update     INTEGER NOT NULL DEFAULT 0,
        lookup_count     INTEGER NOT NULL DEFAULT 1,
        last_error       TEXT,
        sort_key         TEXT,
        created_at       INTEGER NOT NULL,
        updated_at       INTEGER NOT NULL
    )]],
    [[CREATE INDEX IF NOT EXISTS items_status ON items(status, language)]],
    [[CREATE INDEX IF NOT EXISTS items_key ON items(language, type, lemma_key)]],
    [[CREATE TABLE IF NOT EXISTS sentences (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        item_id         INTEGER NOT NULL,
        book_id         INTEGER,
        text            TEXT,
        highlight_start INTEGER,
        highlight_end   INTEGER,
        position        TEXT,
        page            TEXT,
        is_primary      INTEGER NOT NULL DEFAULT 0,
        missing         INTEGER NOT NULL DEFAULT 0,
        selection       TEXT,
        context_before  TEXT,
        context_after   TEXT,
        created_at      INTEGER NOT NULL
    )]],
    [[CREATE INDEX IF NOT EXISTS sentences_item ON sentences(item_id)]],
    [[CREATE INDEX IF NOT EXISTS sentences_book ON sentences(book_id)]],
    [[CREATE TABLE IF NOT EXISTS lookups (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        item_id        INTEGER NOT NULL,
        dictionary     TEXT,
        headword       TEXT,
        raw_definition TEXT,
        parsed         TEXT,
        is_html        INTEGER NOT NULL DEFAULT 0,
        dict_lang      TEXT,
        sort_order     INTEGER NOT NULL DEFAULT 0
    )]],
    [[CREATE INDEX IF NOT EXISTS lookups_item ON lookups(item_id)]],
}

-- Future migrations: [version] = { sql, ... }
local MIGRATIONS = {}

local STATUSES = { "inbox", "ready", "anki", "known", "discarded" }

local TRANSITIONS = {
    inbox = { ready = true, known = true, discarded = true },
    ready = { inbox = true, anki = true, known = true, discarded = true },
    anki = { known = true },
    known = { inbox = true },
    discarded = { inbox = true },
}

local ITEM_COLUMNS = {
    "type", "language", "lemma", "surface", "reading", "pos", "chosen_lookup_id", "chosen_sense", "definition",
    "full_definition", "usage_notes", "dict_examples", "pattern", "meaning", "formation", "nuance",
    "personal_note", "dictionary", "audio", "pitch_accent", "status", "anki_note_id", "needs_update",
    "lookup_count", "last_error",
}
local EDITABLE = {}
for _, c in ipairs(ITEM_COLUMNS) do EDITABLE[c] = true end

local function num(v)
    if v == nil then return nil end
    return tonumber(v)
end

local function str(v)
    if v == nil then return nil end
    return tostring(v)
end

local function lemmaKey(s)
    return U.trim(tostring(s or "")):lower()
end

-- A–Z key: reading for Japanese and Chinese (kana / toneless pinyin),
-- the word itself for Korean (Hangul order) and other languages.
local function sortKey(item)
    local lang = item.language
    local base = item.type == "expression" and (item.pattern or item.lemma) or item.lemma
    local reading = item.reading
    if lang == "ja" then
        return U.toHiragana((reading and reading ~= "") and reading or base or "")
    elseif lang == "zh" then
        if reading and reading ~= "" then return Ruby.stripTones(Ruby.numberedToMarks(reading)):lower() end
        return base or ""
    end
    return lemmaKey(base)
end

local random_seeded = false
local function newUid()
    if not random_seeded then
        math.randomseed(os.time() + math.floor((os.clock() * 1e6) % 1e6))
        random_seeded = true
    end
    local alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local out = { "k" }
    for _ = 1, 11 do
        local i = math.random(1, #alphabet)
        out[#out + 1] = alphabet:sub(i, i)
    end
    return table.concat(out)
end

local Store = {}
Store.__index = Store
Store.STATUSES = STATUSES
Store.TRANSITIONS = TRANSITIONS
Store.sortKey = sortKey

--[[--
@param path database file
@param opts { json = codec with encode/decode }
--]]
function Store.new(path, opts)
    local self = setmetatable({ path = path, json = (opts or {}).json, now = (opts or {}).now or os.time }, Store)
    self:_init()
    return self
end

function Store:_open()
    local conn = SQ3.open(self.path)
    conn:set_busy_timeout(2000)
    return conn
end

function Store:_tx(fn)
    local conn = self:_open()
    conn:exec("BEGIN IMMEDIATE")
    local ok, res = pcall(fn, conn)
    if ok then
        conn:exec("COMMIT")
    else
        pcall(conn.exec, conn, "ROLLBACK")
    end
    conn:close()
    if not ok then error(res, 0) end
    return res
end

function Store:_read(fn)
    local conn = self:_open()
    local ok, res = pcall(fn, conn)
    conn:close()
    if not ok then error(res, 0) end
    return res
end

function Store:_init()
    local conn = self:_open()
    conn:exec("PRAGMA journal_mode=TRUNCATE")
    for _, stmt in ipairs(SCHEMA) do conn:exec(stmt) end
    local version = num(conn:rowexec("SELECT max(version) FROM schema_version"))
    if not version then
        conn:exec("INSERT INTO schema_version(version) VALUES (" .. SCHEMA_VERSION .. ")")
        version = SCHEMA_VERSION
    end
    for v = version + 1, SCHEMA_VERSION do
        for _, sql in ipairs(MIGRATIONS[v] or {}) do conn:exec(sql) end
        conn:exec("UPDATE schema_version SET version = " .. v)
    end
    conn:close()
end

function Store:schemaVersion()
    return self:_read(function(conn) return num(conn:rowexec("SELECT max(version) FROM schema_version")) end)
end

-- Rows as tables keyed by column name.
local function rows(conn, sql, ...)
    local stmt = conn:prepare(sql)
    if select("#", ...) > 0 then stmt:bind(...) end
    local out = {}
    local res, n = stmt:resultset("hik")
    stmt:close()
    if not res or not res[0] then return out end
    local header = res[0]
    for i = 1, n do
        local row = {}
        for c, name in ipairs(header) do
            local v = res[c][i]
            if type(v) == "cdata" then v = tonumber(v) end
            row[name] = v
        end
        out[i] = row
    end
    return out
end

local function one(conn, sql, ...)
    return rows(conn, sql, ...)[1]
end

local function exec(conn, sql, ...)
    local stmt = conn:prepare(sql)
    if select("#", ...) > 0 then stmt:bind(...) end
    stmt:step()
    stmt:close()
end

local function lastId(conn)
    return num(conn:rowexec("SELECT last_insert_rowid()"))
end

-- JSON helpers ------------------------------------------------------------------

function Store:_encode(t)
    if t == nil then return nil end
    if not self.json then return nil end
    local ok, s = pcall(self.json.encode, t)
    return ok and s or nil
end

local function stripNulls(v, null)
    if type(v) ~= "table" then
        if null ~= nil and v == null then return nil end
        return v
    end
    local out = {}
    for k, x in pairs(v) do
        if not (null ~= nil and x == null) then out[k] = stripNulls(x, null) end
    end
    return out
end

function Store:_decode(s)
    if not s or s == "" or not self.json then return nil end
    local ok, t = pcall(self.json.decode, s)
    if not ok then return nil end
    return stripNulls(t, self.json.null)
end

-- Books -----------------------------------------------------------------------------

local function upsertBook(conn, book)
    if not book then return nil end
    local row
    if book.file_hash and book.file_hash ~= "" then
        row = one(conn, "SELECT id FROM books WHERE file_hash = ?", book.file_hash)
    end
    if not row and book.title and book.title ~= "" then
        row = one(conn, "SELECT id FROM books WHERE title = ? AND coalesce(authors, '') = ? AND file_hash IS NULL",
            book.title, book.authors or "")
    end
    if row then
        exec(conn, "UPDATE books SET title = coalesce(?, title), authors = coalesce(?, authors), "
            .. "language = coalesce(?, language), file = coalesce(?, file), file_hash = coalesce(file_hash, ?) WHERE id = ?",
            book.title, book.authors, book.language, book.file, book.file_hash, row.id)
        return row.id
    end
    exec(conn, "INSERT INTO books(title, authors, language, file_hash, file) VALUES (?, ?, ?, ?, ?)",
        book.title, book.authors, book.language, book.file_hash, book.file)
    return lastId(conn)
end

function Store:upsertBook(book)
    return self:_tx(function(conn) return upsertBook(conn, book) end)
end

function Store:bookByHash(hash)
    if not hash then return nil end
    return self:_read(function(conn) return one(conn, "SELECT * FROM books WHERE file_hash = ?", hash) end)
end

function Store:book(id)
    return self:_read(function(conn) return one(conn, "SELECT * FROM books WHERE id = ?", id) end)
end

function Store:setBookLanguageOverride(book_id, code)
    self:_tx(function(conn) exec(conn, "UPDATE books SET language_override = ? WHERE id = ?", code, book_id) end)
end

function Store:allBooks()
    return self:_read(function(conn) return rows(conn, "SELECT * FROM books ORDER BY title") end)
end

-- Saving ------------------------------------------------------------------------------

local function joinList(t)
    if type(t) ~= "table" or #t == 0 then return nil end
    return table.concat(t, "\n")
end

local function fieldsFromLookup(lookup, sense_index)
    local parsed = lookup and lookup.parsed or {}
    local senses = parsed.senses or {}
    local sense = senses[sense_index or 1] or senses[1]
    return {
        definition = sense and sense.text or nil,
        pos = (sense and sense.pos) or parsed.pos,
        reading = parsed.reading,
        full_definition = parsed.full,
        usage_notes = joinList(parsed.notes),
        dict_examples = joinList(parsed.examples),
        dictionary = lookup and lookup.dictionary,
        audio = parsed.audio,
        pitch_accent = parsed.pitch,
    }
end
Store.fieldsFromLookup = fieldsFromLookup

function Store:_insertLookups(conn, item_id, lookups, start_order)
    local ids = {}
    for i, l in ipairs(lookups or {}) do
        exec(conn, "INSERT INTO lookups(item_id, dictionary, headword, raw_definition, parsed, is_html, dict_lang, sort_order) "
            .. "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            item_id, l.dictionary, l.headword, l.raw_definition, self:_encode(l.parsed), l.is_html and 1 or 0,
            l.dict_lang, (start_order or 0) + i)
        ids[i] = lastId(conn)
    end
    return ids
end

local function insertSentence(conn, item_id, book_id, s, primary, now)
    exec(conn, "INSERT INTO sentences(item_id, book_id, text, highlight_start, highlight_end, position, page, "
        .. "is_primary, missing, selection, context_before, context_after, created_at) "
        .. "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        item_id, book_id, s.text, s.hl_start, s.hl_end, str(s.position), str(s.page), primary and 1 or 0,
        s.missing and 1 or 0, s.selection, s.context_before, s.context_after, now)
    return lastId(conn)
end

function Store:_findItem(conn, language, kind, lemma)
    return one(conn, "SELECT * FROM items WHERE language = ? AND type = ? AND lemma_key = ? ORDER BY id LIMIT 1",
        language, kind or "word", lemmaKey(lemma))
end

function Store:findItem(language, kind, lemma)
    return self:_read(function(conn) return self:_findItem(conn, language, kind, lemma) end)
end

function Store:inboxCount()
    return self:_read(function(conn)
        return num(conn:rowexec("SELECT count(*) FROM items WHERE status = 'inbox'")) or 0
    end)
end

--[[--
Save a capture. An existing item with the same lemma, language and type gains
the sentence instead of being duplicated.
@param cap table
  type ("word"|"expression"), language, surface, lemma, pattern,
  lookups = { {dictionary, headword, raw_definition, parsed, is_html, dict_lang}, ... } (displayed one first),
  sentence = { text, hl_start, hl_end, missing, selection, context_before, context_after, position, page },
  book = { title, authors, language, file_hash, file },
  reactivate: move a Known/Discarded item back to the Inbox
@treturn table { item_id, sentence_id, created, status, prev_status, prev_needs_update, inbox }
--]]
function Store:saveCapture(cap)
    local now = self.now()
    return self:_tx(function(conn)
        local kind = cap.type or "word"
        local lemma = kind == "expression" and (cap.pattern or cap.surface) or (cap.lemma or cap.surface)
        local book_id = upsertBook(conn, cap.book)
        local existing = self:_findItem(conn, cap.language, kind, lemma)
        local result = { created = false }
        if existing then
            result.item_id = existing.id
            result.prev_status = existing.status
            result.prev_needs_update = existing.needs_update
            local status = existing.status
            local needs_update = existing.needs_update
            -- the same sentence saved again (or imported twice) is not stored twice
            local same = cap.sentence and cap.sentence.text and one(conn,
                "SELECT id FROM sentences WHERE item_id = ? AND text = ?", existing.id, cap.sentence.text)
            result.duplicate_sentence = same ~= nil
            if status == "anki" and not same then needs_update = 1 end
            if (status == "known" or status == "discarded") and cap.reactivate then status = "inbox" end
            result.counted = not same
            exec(conn, "UPDATE items SET lookup_count = lookup_count + ?, status = ?, needs_update = ?, updated_at = ? WHERE id = ?",
                same and 0 or 1, status, needs_update, now, existing.id)
            if cap.sentence and not same then
                local has_primary = num(conn:rowexec("SELECT count(*) FROM sentences WHERE is_primary = 1 AND item_id = "
                    .. existing.id)) or 0
                result.sentence_id = insertSentence(conn, existing.id, book_id, cap.sentence, has_primary == 0, now)
            end
            -- keep lookups from dictionaries this item has not seen yet
            local known = {}
            for _, l in ipairs(rows(conn, "SELECT dictionary, headword FROM lookups WHERE item_id = ?", existing.id)) do
                known[(l.dictionary or "") .. "\0" .. (l.headword or "")] = true
            end
            local fresh = {}
            for _, l in ipairs(cap.lookups or {}) do
                if not known[(l.dictionary or "") .. "\0" .. (l.headword or "")] then fresh[#fresh + 1] = l end
            end
            local max_order = num(conn:rowexec("SELECT coalesce(max(sort_order), 0) FROM lookups WHERE item_id = "
                .. existing.id)) or 0
            result.added_lookup_ids = self:_insertLookups(conn, existing.id, fresh, max_order)
            result.status = status
        else
            local first = cap.lookups and cap.lookups[1]
            local f = fieldsFromLookup(first, 1)
            if kind == "expression" then f = {} end
            local item = {
                type = kind, language = cap.language, lemma = lemma, reading = f.reading, pattern = cap.pattern,
            }
            exec(conn, "INSERT INTO items(uid, type, language, lemma, lemma_key, surface, reading, pos, chosen_sense, "
                .. "definition, full_definition, usage_notes, dict_examples, pattern, dictionary, audio, pitch_accent, "
                .. "status, lookup_count, sort_key, created_at, updated_at) "
                .. "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'inbox', 1, ?, ?, ?)",
                cap.uid or newUid(), kind, cap.language, lemma, lemmaKey(lemma), cap.surface, f.reading, f.pos,
                first and 1 or nil, f.definition, f.full_definition, f.usage_notes, f.dict_examples,
                cap.pattern, f.dictionary, f.audio, f.pitch_accent, sortKey(item), now, now)
            local item_id = lastId(conn)
            local lookup_ids = self:_insertLookups(conn, item_id, cap.lookups, 0)
            if lookup_ids[1] then
                exec(conn, "UPDATE items SET chosen_lookup_id = ? WHERE id = ?", lookup_ids[1], item_id)
            end
            if cap.sentence then
                result.sentence_id = insertSentence(conn, item_id, book_id, cap.sentence, true, now)
            end
            result.item_id = item_id
            result.created = true
            result.status = "inbox"
        end
        result.inbox = num(conn:rowexec("SELECT count(*) FROM items WHERE status = 'inbox'")) or 0
        return result
    end)
end

-- Undo a save made with saveCapture (the popup's "Saved" button).
function Store:undoSave(result)
    if not result or not result.item_id then return end
    self:_tx(function(conn)
        if result.created then
            exec(conn, "DELETE FROM sentences WHERE item_id = ?", result.item_id)
            exec(conn, "DELETE FROM lookups WHERE item_id = ?", result.item_id)
            exec(conn, "DELETE FROM items WHERE id = ?", result.item_id)
        else
            if result.sentence_id then
                local s = one(conn, "SELECT is_primary FROM sentences WHERE id = ?", result.sentence_id)
                exec(conn, "DELETE FROM sentences WHERE id = ?", result.sentence_id)
                if s and s.is_primary == 1 then
                    exec(conn, "UPDATE sentences SET is_primary = 1 WHERE id = (SELECT min(id) FROM sentences WHERE item_id = ?)",
                        result.item_id)
                end
            end
            for _, id in ipairs(result.added_lookup_ids or {}) do
                exec(conn, "DELETE FROM lookups WHERE id = ?", id)
            end
            exec(conn, "UPDATE items SET lookup_count = max(1, lookup_count - ?), status = ?, needs_update = ?, updated_at = ? WHERE id = ?",
                result.counted == false and 0 or 1, result.prev_status or "inbox", result.prev_needs_update or 0,
                self.now(), result.item_id)
        end
    end)
end

-- Reading ------------------------------------------------------------------------------

function Store:_loadItem(conn, id)
    local item = one(conn, "SELECT * FROM items WHERE id = ?", id)
    if not item then return nil end
    item.sentences = rows(conn, "SELECT s.*, b.title AS book_title, b.authors AS book_authors, b.language AS book_language "
        .. "FROM sentences s LEFT JOIN books b ON b.id = s.book_id WHERE s.item_id = ? ORDER BY s.is_primary DESC, s.id", id)
    for _, s in ipairs(item.sentences) do
        s.hl_start, s.hl_end = s.highlight_start, s.highlight_end
        s.missing = s.missing == 1
        if s.book_id then s.book = { id = s.book_id, title = s.book_title, authors = s.book_authors, language = s.book_language } end
    end
    item.sentence = item.sentences[1]
    item.lookups = rows(conn, "SELECT * FROM lookups WHERE item_id = ? ORDER BY sort_order, id", id)
    for _, l in ipairs(item.lookups) do
        l.parsed = self:_decode(l.parsed) or { senses = {} }
        l.parsed.senses = l.parsed.senses or {}
    end
    item.books = {}
    local seen = {}
    for _, s in ipairs(item.sentences) do
        if s.book and not seen[s.book.id] then
            seen[s.book.id] = true
            item.books[#item.books + 1] = s.book
        end
    end
    return item
end

function Store:getItem(id)
    return self:_read(function(conn) return self:_loadItem(conn, id) end)
end

function Store:getItems(ids)
    return self:_read(function(conn)
        local out = {}
        for _, id in ipairs(ids) do
            local it = self:_loadItem(conn, id)
            if it then out[#out + 1] = it end
        end
        return out
    end)
end

function Store:counts()
    return self:_read(function(conn)
        local c = { inbox = 0, ready = 0, anki = 0, known = 0, discarded = 0, total = 0, updates = 0 }
        for _, r in ipairs(rows(conn, "SELECT status, count(*) AS n FROM items GROUP BY status")) do
            c[r.status] = r.n
            c.total = c.total + r.n
        end
        c.updates = num(conn:rowexec("SELECT count(*) FROM items WHERE status = 'anki' AND needs_update = 1")) or 0
        return c
    end)
end

-- { {language, words, expressions}, ... } for Inbox items, biggest first.
function Store:inboxByLanguage()
    return self:_read(function(conn)
        return rows(conn, "SELECT language, sum(type = 'word') AS words, sum(type = 'expression') AS expressions, "
            .. "count(*) AS n FROM items WHERE status = 'inbox' GROUP BY language ORDER BY n DESC, language")
    end)
end

function Store:lastSaved()
    return self:_read(function(conn)
        local it = one(conn, "SELECT i.*, s.created_at AS saved_at, b.title AS book_title FROM sentences s "
            .. "JOIN items i ON i.id = s.item_id LEFT JOIN books b ON b.id = s.book_id ORDER BY s.created_at DESC, s.id DESC LIMIT 1")
        if not it then
            it = one(conn, "SELECT *, created_at AS saved_at FROM items ORDER BY created_at DESC, id DESC LIMIT 1")
        end
        return it
    end)
end

-- Filters -------------------------------------------------------------------------------

--[[
filter = {
  language = "ja", book_id = 3 (or "none"), statuses = { inbox = true, … },
  type = "word"|"expression", since = ts, until = ts, search = "text", ids = {…}
}
]]
local function whereClause(filter)
    local where, args = { "1 = 1" }, {}
    filter = filter or {}
    if filter.language then
        where[#where + 1] = "i.language = ?"
        args[#args + 1] = filter.language
    end
    if filter.book_id == "none" then
        where[#where + 1] = "NOT EXISTS (SELECT 1 FROM sentences s WHERE s.item_id = i.id AND s.book_id IS NOT NULL)"
    elseif filter.book_id then
        where[#where + 1] = "EXISTS (SELECT 1 FROM sentences s WHERE s.item_id = i.id AND s.book_id = ?)"
        args[#args + 1] = filter.book_id
    end
    if filter.statuses and next(filter.statuses) then
        local list = {}
        for _, s in ipairs(STATUSES) do
            if filter.statuses[s] then list[#list + 1] = "'" .. s .. "'" end
        end
        if #list > 0 then where[#where + 1] = "i.status IN (" .. table.concat(list, ",") .. ")" end
    end
    if filter.type then
        where[#where + 1] = "i.type = ?"
        args[#args + 1] = filter.type
    end
    if filter.since then
        where[#where + 1] = "i.created_at >= ?"
        args[#args + 1] = filter.since
    end
    if filter["until"] then
        where[#where + 1] = "i.created_at < ?"
        args[#args + 1] = filter["until"]
    end
    if filter.search and U.trim(filter.search) ~= "" then
        local q = "%" .. U.trim(filter.search):lower():gsub("[%%_\\]", "\\%0") .. "%"
        where[#where + 1] = "(lower(i.lemma) LIKE ? ESCAPE '\\' OR lower(i.surface) LIKE ? ESCAPE '\\' "
            .. "OR lower(coalesce(i.reading, '')) LIKE ? ESCAPE '\\' OR lower(coalesce(i.definition, '')) LIKE ? ESCAPE '\\' "
            .. "OR lower(coalesce(i.meaning, '')) LIKE ? ESCAPE '\\' OR lower(coalesce(i.pattern, '')) LIKE ? ESCAPE '\\' "
            .. "OR lower(coalesce(i.sort_key, '')) LIKE ? ESCAPE '\\')"
        for _ = 1, 7 do args[#args + 1] = q end
    end
    return table.concat(where, " AND "), args
end

local ORDER = {
    newest = "i.created_at DESC, i.id DESC",
    oldest = "i.created_at ASC, i.id ASC",
    az = "i.sort_key COLLATE NOCASE ASC, i.lemma ASC",
}

function Store:count(filter)
    local where, args = whereClause(filter)
    return self:_read(function(conn)
        local r = one(conn, "SELECT count(*) AS n FROM items i WHERE " .. where, unpack(args))
        return r and r.n or 0
    end)
end

-- Light rows for lists.
function Store:query(filter, sort, offset, limit)
    local where, args = whereClause(filter)
    local sql = "SELECT i.id, i.uid, i.type, i.language, i.lemma, i.surface, i.reading, i.definition, i.meaning, "
        .. "i.pattern, i.status, i.created_at, i.needs_update, i.last_error FROM items i WHERE " .. where
        .. " ORDER BY " .. (ORDER[sort or "newest"] or ORDER.newest)
    if limit then sql = sql .. " LIMIT " .. math.floor(limit) .. " OFFSET " .. math.floor(offset or 0) end
    return self:_read(function(conn) return rows(conn, sql, unpack(args)) end)
end

function Store:queryIds(filter, sort)
    local out = {}
    for i, r in ipairs(self:query(filter, sort)) do out[i] = r.id end
    return out
end

-- { {language, n}, ... }
function Store:languages(filter)
    local where, args = whereClause(filter)
    return self:_read(function(conn)
        return rows(conn, "SELECT i.language, count(*) AS n FROM items i WHERE " .. where
            .. " GROUP BY i.language ORDER BY n DESC, i.language", unpack(args))
    end)
end

-- { {book_id, title, authors, n}, ... } — items saved from two books count in both.
function Store:booksFor(filter)
    local where, args = whereClause(filter)
    return self:_read(function(conn)
        local list = rows(conn, "SELECT b.id AS book_id, b.title, b.authors, count(DISTINCT i.id) AS n "
            .. "FROM items i JOIN sentences s ON s.item_id = i.id JOIN books b ON b.id = s.book_id WHERE " .. where
            .. " GROUP BY b.id ORDER BY max(s.created_at) DESC", unpack(args))
        local none = one(conn, "SELECT count(*) AS n FROM items i WHERE " .. where
            .. " AND NOT EXISTS (SELECT 1 FROM sentences s WHERE s.item_id = i.id AND s.book_id IS NOT NULL)", unpack(args))
        if none and none.n > 0 then list[#list + 1] = { book_id = "none", title = nil, n = none.n } end
        return list
    end)
end

-- Inbox items for a review session, newest first (like the Inbox list).
function Store:reviewQueue(filter)
    local f = {}
    for k, v in pairs(filter or {}) do f[k] = v end
    f.statuses = { inbox = true }
    return self:queryIds(f, "newest")
end

-- Editing ------------------------------------------------------------------------------

function Store:update(id, fields)
    local sets, args = {}, {}
    for k, v in pairs(fields) do
        if EDITABLE[k] then
            sets[#sets + 1] = k .. " = ?"
            if v == false then v = nil end
            args[#args + 1] = v
        end
    end
    if #sets == 0 then return end
    self:_tx(function(conn)
        sets[#sets + 1] = "updated_at = ?"
        args[#args + 1] = self.now()
        args[#args + 1] = id
        exec(conn, "UPDATE items SET " .. table.concat(sets, ", ") .. " WHERE id = ?", unpack(args))
        local it = one(conn, "SELECT * FROM items WHERE id = ?", id)
        if it then
            local key = it.type == "expression" and (it.pattern or it.lemma) or it.lemma
            exec(conn, "UPDATE items SET sort_key = ?, lemma_key = ? WHERE id = ?", sortKey(it), lemmaKey(key), id)
            if it.type == "expression" and it.pattern and it.pattern ~= it.lemma then
                exec(conn, "UPDATE items SET lemma = ?, lemma_key = ? WHERE id = ?", it.pattern, lemmaKey(it.pattern), id)
            end
        end
    end)
end

-- Choose a sense of one of the item's lookups (sets lemma to its headword).
function Store:chooseSense(item_id, lookup_id, sense_index)
    self:_tx(function(conn)
        local l = one(conn, "SELECT * FROM lookups WHERE id = ? AND item_id = ?", lookup_id, item_id)
        if not l then return end
        l.parsed = self:_decode(l.parsed) or {}
        local f = fieldsFromLookup(l, sense_index)
        local it = one(conn, "SELECT * FROM items WHERE id = ?", item_id)
        local lemma = (l.headword and l.headword ~= "") and l.headword or it.lemma
        local new = { type = it.type, language = it.language, lemma = lemma, reading = f.reading }
        exec(conn, "UPDATE items SET chosen_lookup_id = ?, chosen_sense = ?, definition = ?, pos = ?, reading = ?, "
            .. "full_definition = ?, usage_notes = ?, dict_examples = ?, dictionary = ?, audio = ?, pitch_accent = ?, "
            .. "lemma = ?, lemma_key = ?, sort_key = ?, updated_at = ? WHERE id = ?",
            lookup_id, sense_index, f.definition, f.pos, f.reading, f.full_definition, f.usage_notes, f.dict_examples,
            f.dictionary, f.audio, f.pitch_accent, lemma, lemmaKey(lemma), sortKey(new), self.now(), item_id)
    end)
end

function Store:addLookups(item_id, lookups)
    return self:_tx(function(conn)
        local max_order = num(conn:rowexec("SELECT coalesce(max(sort_order), 0) FROM lookups WHERE item_id = "
            .. math.floor(item_id))) or 0
        return self:_insertLookups(conn, item_id, lookups, max_order)
    end)
end

function Store:setPrimarySentence(item_id, sentence_id)
    self:_tx(function(conn)
        exec(conn, "UPDATE sentences SET is_primary = (id = ?) WHERE item_id = ?", sentence_id, item_id)
        exec(conn, "UPDATE items SET updated_at = ? WHERE id = ?", self.now(), item_id)
    end)
end

function Store:updateSentence(sentence_id, s)
    self:_tx(function(conn)
        exec(conn, "UPDATE sentences SET text = ?, highlight_start = ?, highlight_end = ? WHERE id = ?",
            s.text, s.hl_start, s.hl_end, sentence_id)
    end)
end

--[[--
Change status of several items, following the allowed transitions.
@param opts { allow_empty_meaning = bool (for Ready), force = bool (undo in review) }
@treturn table { changed = n, skipped_invalid = n, skipped_meaning = n }
--]]
function Store:setStatus(ids, status, opts)
    opts = opts or {}
    local res = { changed = 0, skipped_invalid = 0, skipped_meaning = 0 }
    self:_tx(function(conn)
        for _, id in ipairs(ids) do
            local it = one(conn, "SELECT id, status, type, meaning FROM items WHERE id = ?", id)
            if it then
                local ok = opts.force or (TRANSITIONS[it.status] and TRANSITIONS[it.status][status]) or it.status == status
                if ok and status == "ready" and it.type == "expression" and not opts.force
                        and not opts.allow_empty_meaning and U.trim(it.meaning or "") == "" then
                    res.skipped_meaning = res.skipped_meaning + 1
                elseif ok then
                    if it.status ~= status then
                        exec(conn, "UPDATE items SET status = ?, updated_at = ? WHERE id = ?", status, self.now(), id)
                    end
                    res.changed = res.changed + 1
                else
                    res.skipped_invalid = res.skipped_invalid + 1
                end
            end
        end
    end)
    return res
end

-- Change the language of items (keeps everything else).
function Store:setLanguage(ids, code)
    self:_tx(function(conn)
        for _, id in ipairs(ids) do
            exec(conn, "UPDATE items SET language = ?, updated_at = ? WHERE id = ?", code, self.now(), id)
            local it = one(conn, "SELECT * FROM items WHERE id = ?", id)
            if it then exec(conn, "UPDATE items SET sort_key = ? WHERE id = ?", sortKey(it), id) end
        end
    end)
end

-- Convert between word and expression.
function Store:setType(id, kind)
    self:_tx(function(conn)
        local it = one(conn, "SELECT * FROM items WHERE id = ?", id)
        if not it or it.type == kind then return end
        if kind == "expression" then
            local pattern = it.pattern or it.surface or it.lemma
            exec(conn, "UPDATE items SET type = 'expression', pattern = ?, lemma = ?, lemma_key = ?, updated_at = ? WHERE id = ?",
                pattern, pattern, lemmaKey(pattern), self.now(), id)
        else
            local lemma = it.surface or it.pattern or it.lemma
            local l = one(conn, "SELECT headword FROM lookups WHERE item_id = ? ORDER BY sort_order LIMIT 1", id)
            if l and l.headword and l.headword ~= "" then lemma = l.headword end
            exec(conn, "UPDATE items SET type = 'word', lemma = ?, lemma_key = ?, updated_at = ? WHERE id = ?",
                lemma, lemmaKey(lemma), self.now(), id)
        end
    end)
end

function Store:delete(ids)
    self:_tx(function(conn)
        for _, id in ipairs(ids) do
            exec(conn, "DELETE FROM sentences WHERE item_id = ?", id)
            exec(conn, "DELETE FROM lookups WHERE item_id = ?", id)
            exec(conn, "DELETE FROM items WHERE id = ?", id)
        end
    end)
end

function Store:anyInAnki(ids)
    return self:_read(function(conn)
        for _, id in ipairs(ids) do
            local r = one(conn, "SELECT status FROM items WHERE id = ?", id)
            if r and r.status == "anki" then return true end
        end
        return false
    end)
end

-- Export bookkeeping ------------------------------------------------------------------

-- Items to export: Ready (or Inbox too when send_as_is), plus In Anki items
-- with a new sentence to add.
function Store:exportItems(opts)
    opts = opts or {}
    local statuses = "'ready'"
    if opts.send_as_is then statuses = "'ready','inbox'" end
    return self:_read(function(conn)
        local out = {}
        for _, r in ipairs(rows(conn, "SELECT id FROM items WHERE status IN (" .. statuses .. ") ORDER BY language, created_at, id")) do
            out[#out + 1] = self:_loadItem(conn, r.id)
        end
        if opts.include_updates ~= false then
            for _, r in ipairs(rows(conn, "SELECT id FROM items WHERE status = 'anki' AND needs_update = 1 ORDER BY id")) do
                out[#out + 1] = self:_loadItem(conn, r.id)
            end
        end
        return out
    end)
end

function Store:markExported(id, note_id)
    self:_tx(function(conn)
        exec(conn, "UPDATE items SET status = 'anki', anki_note_id = ?, needs_update = 0, last_error = NULL, updated_at = ? WHERE id = ?",
            note_id, self.now(), id)
    end)
end

function Store:setError(id, msg)
    self:_tx(function(conn)
        exec(conn, "UPDATE items SET last_error = ?, updated_at = ? WHERE id = ?", msg, self.now(), id)
    end)
end

function Store:clearNeedsUpdate(id)
    self:_tx(function(conn)
        exec(conn, "UPDATE items SET needs_update = 0, last_error = NULL WHERE id = ?", id)
    end)
end

return Store
