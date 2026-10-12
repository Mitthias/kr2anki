--[[--
Anki package (.apkg) writer: a legacy collection (schema 11, collection.anki2)
plus the media map, zipped. Every note's GUID is the item's uid and the note
types have fixed ids, so importing the same item again updates the note
instead of duplicating it.

    Apkg.write{
        path = ".../kr2anki-2026-10-09-2152.apkg",
        notes = { { kind = "word"|"expression", deck = "Reading::Japanese", fields = {…}, tags = {…}, guid = uid } },
        media = { { name = "run.mp3", data = bytes } },
        sqlite = SQ3, json = codec, sha1 = function, zip = function(path, entries),
        tmpdir = "...",
    }
--]]

local N = require("kr2anki/notetypes")

local A = {}

local SCHEMA = {
    [[CREATE TABLE col (id integer primary key, crt integer not null, mod integer not null, scm integer not null,
        ver integer not null, dty integer not null, usn integer not null, ls integer not null, conf text not null,
        models text not null, decks text not null, dconf text not null, tags text not null)]],
    [[CREATE TABLE notes (id integer primary key, guid text not null, mid integer not null, mod integer not null,
        usn integer not null, tags text not null, flds text not null, sfld integer not null, csum integer not null,
        flags integer not null, data text not null)]],
    [[CREATE TABLE cards (id integer primary key, nid integer not null, did integer not null, ord integer not null,
        mod integer not null, usn integer not null, type integer not null, queue integer not null, due integer not null,
        ivl integer not null, factor integer not null, reps integer not null, lapses integer not null,
        left integer not null, odue integer not null, odid integer not null, flags integer not null, data text not null)]],
    [[CREATE TABLE revlog (id integer primary key, cid integer not null, usn integer not null, ivl integer not null,
        lastIvl integer not null, factor integer not null, time integer not null, type integer not null)]],
    [[CREATE TABLE graves (usn integer not null, oid integer not null, type integer not null)]],
    "CREATE INDEX ix_notes_usn on notes (usn)",
    "CREATE INDEX ix_cards_usn on cards (usn)",
    "CREATE INDEX ix_revlog_usn on revlog (usn)",
    "CREATE INDEX ix_cards_nid on cards (nid)",
    "CREATE INDEX ix_cards_sched on cards (did, queue, due)",
    "CREATE INDEX ix_revlog_cid on revlog (cid)",
    "CREATE INDEX ix_notes_csum on notes (csum)",
}

-- Stable positive deck id from the deck name.
function A.deckId(name)
    local h = 5381
    for i = 1, #name do
        h = (h * 33 + name:byte(i)) % 2147483647
    end
    return 1500000000000 + h
end

function A.stripHtml(s)
    s = tostring(s or ""):gsub("%[sound:[^%]]*%]", ""):gsub("<[^>]*>", "")
    s = s:gsub("&nbsp;", " "):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&amp;", "&")
    return s
end

function A.checksum(sha1, first_field)
    return tonumber(sha1(A.stripHtml(first_field)):sub(1, 8), 16)
end

local function modelJson(json, kind, deck_id, now)
    local m = N.model(kind)
    local flds, tmpls = {}, {}
    for i, name in ipairs(m.fields) do
        flds[i] = { name = name, ord = i - 1, sticky = false, rtl = false, font = "Arial", size = 20,
                    media = json.array({}) }
    end
    for i, t in ipairs(m.templates) do
        tmpls[i] = { name = t.name, ord = i - 1, qfmt = t.front, afmt = t.back, bqfmt = "", bafmt = "",
                     did = json.null, bfont = "", bsize = 0 }
    end
    -- req: each template needs its flag field (and SentenceCloze for cloze)
    local req = {}
    local index = {}
    for i, name in ipairs(m.fields) do index[name] = i - 1 end
    for i, t in ipairs(m.templates) do
        local need = { index[m.flags[i]] }
        local extra = N.TEMPLATE_REQUIRES[t.name]
        if extra and index[extra] then need[#need + 1] = index[extra] end
        req[i] = json.array({ i - 1, "all", json.array(need) })
    end
    return {
        id = m.id, name = m.name, type = 0, mod = now, usn = -1, sortf = 0, did = deck_id,
        tmpls = tmpls, flds = flds, css = N.CSS,
        latexPre = "\\documentclass[12pt]{article}\n\\special{papersize=3in,5in}\n\\usepackage[utf8]{inputenc}\n"
            .. "\\usepackage{amssymb,amsmath}\n\\pagestyle{empty}\n\\setlength{\\parindent}{0in}\n\\begin{document}\n",
        latexPost = "\\end{document}", latexsvg = false,
        req = json.array(req), tags = json.array({}), vers = json.array({}),
    }
end

local function deckJson(json, id, name, now)
    return {
        id = id, name = name, mod = now, usn = -1, desc = "", dyn = 0, conf = 1, collapsed = false,
        browserCollapsed = false, extendNew = 0, extendRev = 0,
        lrnToday = json.array({ 0, 0 }), revToday = json.array({ 0, 0 }),
        newToday = json.array({ 0, 0 }), timeToday = json.array({ 0, 0 }),
    }
end

local function dconfJson(json)
    return {
        ["1"] = {
            id = 1, name = "Default", mod = 0, usn = 0, maxTaken = 60, autoplay = true, timer = 0,
            replayq = true, dyn = false,
            new = { delays = json.array({ 1, 10 }), ints = json.array({ 1, 4, 0 }), initialFactor = 2500,
                    order = 1, perDay = 20, bury = false },
            lapse = { delays = json.array({ 10 }), mult = 0, minInt = 1, leechFails = 8, leechAction = 1 },
            rev = { perDay = 200, ease4 = 1.3, ivlFct = 1, maxIvl = 36500, bury = false, hardFactor = 1.2 },
        },
    }
end

-- Which templates make a card for these fields (mirrors the {{#flag}} wrappers).
function A.cardOrds(kind, fields)
    local m = N.model(kind)
    local ords = {}
    for i, t in ipairs(m.templates) do
        local flag = fields[m.flags[i]]
        local extra = N.TEMPLATE_REQUIRES[t.name]
        if flag and flag ~= "" and (not extra or (fields[extra] and fields[extra] ~= "")) then
            ords[#ords + 1] = i - 1
        end
    end
    return ords
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

--[[--
Write the package. Returns true, or nil and an error.
--]]
function A.write(opts)
    local SQ3, json, sha1 = assert(opts.sqlite), assert(opts.json), assert(opts.sha1)
    local now = opts.now or os.time()
    local tmp = (opts.tmpdir or "/tmp") .. "/kr2anki-" .. tostring(now) .. "-" .. math.random(1000, 9999) .. ".anki2"
    os.remove(tmp)

    local decks = {}
    local deck_order = {}
    for _, n in ipairs(opts.notes) do
        if not decks[n.deck] then
            decks[n.deck] = A.deckId(n.deck)
            deck_order[#deck_order + 1] = n.deck
        end
    end
    local first_deck = deck_order[1] and decks[deck_order[1]] or 1

    local ok, err = pcall(function()
        local conn = SQ3.open(tmp)
        for _, s in ipairs(SCHEMA) do conn:exec(s) end
        local models = {
            [tostring(N.WORD_MODEL_ID)] = modelJson(json, "word", first_deck, now),
            [tostring(N.EXPR_MODEL_ID)] = modelJson(json, "expression", first_deck, now),
        }
        local deck_t = { ["1"] = deckJson(json, 1, "Default", now) }
        for _, name in ipairs(deck_order) do
            deck_t[tostring(decks[name])] = deckJson(json, decks[name], name, now)
        end
        local conf = {
            nextPos = #opts.notes + 1, estTimes = true, activeDecks = json.array({ 1 }), sortType = "noteFld",
            timeLim = 0, sortBackwards = false, addToCur = true, curDeck = 1, newSpread = 0, dueCounts = true,
            curModel = N.WORD_MODEL_ID, collapseTime = 1200,
        }
        local stmt = conn:prepare("INSERT INTO col VALUES (1, ?, ?, ?, 11, 0, 0, 0, ?, ?, ?, ?, '{}')")
        stmt:bind(math.floor(now / 86400) * 86400, now * 1000, now * 1000, json.encode(conf), json.encode(models),
            json.encode(deck_t), json.encode(dconfJson(json)))
        stmt:step()
        stmt:close()

        local note_stmt = conn:prepare("INSERT INTO notes VALUES (?, ?, ?, ?, -1, ?, ?, ?, ?, 0, '')")
        local card_stmt = conn:prepare("INSERT INTO cards VALUES (?, ?, ?, ?, ?, -1, 0, 0, ?, 0, 0, 0, 0, 0, 0, 0, 0, '')")
        local base_id = now * 1000
        local card_id = base_id
        for i, n in ipairs(opts.notes) do
            local m = N.model(n.kind)
            local values = {}
            for k, name in ipairs(m.fields) do values[k] = n.fields[name] or "" end
            local nid = base_id + i
            local sfld = A.stripHtml(values[1])
            note_stmt:reset():clearbind()
            note_stmt:bind(nid, n.guid, m.id, now, " " .. table.concat(n.tags or {}, " ") .. " ",
                table.concat(values, "\31"), sfld, A.checksum(sha1, values[1]))
            note_stmt:step()
            for _, ord in ipairs(A.cardOrds(n.kind, n.fields)) do
                card_id = card_id + 1
                card_stmt:reset():clearbind()
                card_stmt:bind(card_id + #opts.notes, nid, decks[n.deck], ord, now, i)
                card_stmt:step()
            end
        end
        note_stmt:close()
        card_stmt:close()
        conn:close()
    end)
    if not ok then
        os.remove(tmp)
        return nil, "cannot build collection: " .. tostring(err)
    end

    local collection = readFile(tmp)
    os.remove(tmp)
    if not collection then return nil, "cannot read collection" end
    local media_map = {}
    local entries = { { name = "collection.anki2", data = collection } }
    for i, m in ipairs(opts.media or {}) do
        media_map[tostring(i - 1)] = m.name
        entries[#entries + 1] = { name = tostring(i - 1), data = m.data }
    end
    local media_json = next(media_map) and json.encode(media_map) or "{}"
    table.insert(entries, 2, { name = "media", data = media_json })
    local zok, zerr = (opts.zip or require("kr2anki/zip").write)(opts.path, entries, now)
    if not zok then return nil, "cannot write zip: " .. tostring(zerr) end
    return true
end

-- Notes for a list of items, as Apkg.write expects them.
function A.notesFor(items, opts)
    local Lang = require("kr2anki/lang")
    local notes, media = {}, {}
    for _, item in ipairs(items) do
        local sound
        if opts.sound_for then
            local m = opts.sound_for(item)
            if m then
                media[#media + 1] = m
                sound = "[sound:" .. m.name .. "]"
            end
        end
        local fields = N.buildFields(item, { cards = opts.cards, ja_furigana = opts.ja_furigana,
                                             ko_romanize = opts.ko_romanize, sound = sound })
        notes[#notes + 1] = {
            kind = item.type == "expression" and "expression" or "word",
            deck = Lang.deckName(opts.deck_pattern, item.language),
            fields = fields, tags = N.tags(item, item.books), guid = item.uid,
        }
    end
    return notes, media
end

return A
