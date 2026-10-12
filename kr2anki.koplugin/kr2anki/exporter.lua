--[[--
Export to Anki through AnkiConnect, one batch per step so the screen can be
redrawn between batches ("Exporting… 20 / 41").

    local job = Exporter.new{ client = client, store = store, caps = caps, settings = s }
    local summary = job:prepare()          -- pre-check: decks, note types, duplicates
    job:start{ kr_dupes = "merge", other_dupes = "skip" }
    while not job:step().finished do end   -- UI: one step per UIManager tick
    -- job.result = { added, merged, skipped, failed = { {item, reason} }, unreachable, stopped }

Nothing leaves Ready until Anki returns a note id for it; every failure keeps
the item Ready with its reason in last_error.
Pure Lua (store and client are passed in).
--]]

local Anki = require("kr2anki/anki")
local Lang = require("kr2anki/lang")
local N = require("kr2anki/notetypes")

local E = {}
E.__index = E
E.BATCH = 20

local UNREACHABLE_REASON = "AnkiConnect stopped answering"

--[[--
@param opts table
  client: kr2anki/anki client
  store: kr2anki/db store
  caps: capability result from client:probe()
  settings: { deck_pattern, cards, ja_furigana, ko_romanize, send_as_is }
  media_for: function(item) -> { name, data } or nil (dictionary audio)
  items: optional list of items (default: store:exportItems)
--]]
function E.new(opts)
    local o = setmetatable({}, E)
    o.client = opts.client
    o.store = opts.store
    o.caps = opts.caps or { actions = {} }
    o.plan = Anki.plan(o.caps)
    o.settings = opts.settings or {}
    o.media_for = opts.media_for
    o.items = opts.items
    o.result = { added = 0, merged = 0, updated = 0, skipped = 0, failed = {} }
    return o
end

function E:deckFor(item)
    return Lang.deckName(self.settings.deck_pattern, item.language)
end

function E:fieldsFor(item, sound)
    local f, model = N.buildFields(item, {
        cards = self.settings.cards, ja_furigana = self.settings.ja_furigana,
        ko_romanize = self.settings.ko_romanize, sound = sound,
    })
    return f, model
end

function E:noteFor(item, sound)
    local fields, model = self:fieldsFor(item, sound)
    return Anki.note(self:deckFor(item), model, fields, N.tags(item, item.books))
end

-- Returns nil, kind when AnkiConnect is unreachable.
function E:call(action, params)
    local result, err, kind = self.client:call(action, params)
    if kind == "unreachable" then self.unreachable = true end
    return result, err, kind
end

local function contains(list, v)
    for _, x in ipairs(list or {}) do
        if x == v then return true end
    end
    return false
end

-- Pre-check -------------------------------------------------------------------------

--[[--
@treturn table summary
  total, by_deck = { {deck, n} }, new = {items}, kr_dupes = {items}, other_dupes = {items},
  updates = {items}, need_notetypes (bool), unreachable (bool), notes (strings for the screen)
--]]
function E:prepare()
    local s = { total = 0, by_deck = {}, new = {}, kr_dupes = {}, other_dupes = {}, updates = {}, notes = {} }
    self.summary = s
    local items = self.items or self.store:exportItems({ send_as_is = self.settings.send_as_is })
    local to_add = {}
    for _, item in ipairs(items) do
        if item.status == "anki" then
            if item.needs_update == 1 and item.anki_note_id and self.plan.merge then
                s.updates[#s.updates + 1] = item
            end
        else
            to_add[#to_add + 1] = item
        end
    end
    s.total = #to_add
    local deck_counts, deck_order = {}, {}
    for _, item in ipairs(to_add) do
        local d = self:deckFor(item)
        if not deck_counts[d] then
            deck_counts[d] = 0
            deck_order[#deck_order + 1] = d
        end
        deck_counts[d] = deck_counts[d] + 1
    end
    for _, d in ipairs(deck_order) do s.by_deck[#s.by_deck + 1] = { deck = d, n = deck_counts[d] } end
    if #to_add == 0 and #s.updates == 0 then return s end

    -- Note types
    local need_models = {}
    for _, item in ipairs(to_add) do
        need_models[item.type == "expression" and N.EXPR_MODEL or N.WORD_MODEL] = true
    end
    for _, item in ipairs(s.updates) do
        need_models[item.type == "expression" and N.EXPR_MODEL or N.WORD_MODEL] = true
    end
    local models, _, kind = self:call("modelNames")
    if kind == "unreachable" then s.unreachable = true return s end
    if kind == "ok" then
        for name in pairs(need_models) do
            if not contains(models, name) then
                if self.plan.create_models then
                    local params = N.createModelParams(name == N.EXPR_MODEL and "expression" or "word")
                    local _, err, k = self:call("createModel", params)
                    if k == "unreachable" then s.unreachable = true return s end
                    if k ~= "ok" then
                        s.need_notetypes = true
                        s.notes[#s.notes + 1] = "createModel: " .. tostring(err)
                    end
                else
                    s.need_notetypes = true
                end
            end
        end
    end

    -- Decks: create the missing ones, or list them for the user when this
    -- AnkiConnect can't (AnkiConnect Android has no createDeck)
    if self.plan.list_decks then
        local decks, _, k = self:call("deckNames")
        if k == "unreachable" then s.unreachable = true return s end
        if k == "ok" and type(decks) == "table" then
            local have = {}
            for _, d in ipairs(decks) do have[tostring(d):lower()] = true end
            s.missing_decks = {}
            for _, d in ipairs(deck_order) do
                if not have[d:lower()] then
                    local created = false
                    if self.plan.create_decks then
                        local _, _, k2 = self:call("createDeck", { deck = d })
                        if k2 == "unreachable" then s.unreachable = true return s end
                        created = k2 == "ok"
                    end
                    if not created then s.missing_decks[#s.missing_decks + 1] = d end
                end
            end
            if #s.missing_decks == 0 then s.missing_decks = nil end
        end
    end

    -- Duplicates among KR2Anki notes (same note type, same first field)
    local can = {}
    if self.plan.check_duplicates and #to_add > 0 then
        local notes = {}
        for i, item in ipairs(to_add) do notes[i] = self:noteFor(item) end
        local res, _, k = self:call("canAddNotes", { notes = self.client:array(notes) })
        if k == "unreachable" then s.unreachable = true return s end
        if k == "ok" and type(res) == "table" then
            for i = 1, #to_add do can[i] = res[i] end
        end
    end
    for i, item in ipairs(to_add) do
        if can[i] == false then
            local model = item.type == "expression" and N.EXPR_MODEL or N.WORD_MODEL
            local first = item.type == "expression" and "Pattern" or "Word"
            local fields = self:fieldsFor(item)
            local existing
            if self.plan.find then
                local ids, _, k = self:call("findNotes", {
                    query = Anki.quote("note", model) .. " " .. Anki.quote(first, fields[first]) })
                if k == "unreachable" then s.unreachable = true return s end
                if k == "ok" and type(ids) == "table" and ids[1] then existing = tonumber(ids[1]) end
            end
            if self.plan.find and not existing then
                -- refused for another reason (deck, empty field…): send it, so
                -- Anki's own reason is reported instead of a false duplicate
                s.new[#s.new + 1] = item
            else
                item._existing_note_id = existing
                s.kr_dupes[#s.kr_dupes + 1] = item
            end
        else
            s.new[#s.new + 1] = item
        end
    end

    -- Same word in another note type in the same deck
    if self.plan.find and self.settings.check_other_notetypes ~= false then
        local keep = {}
        for _, item in ipairs(s.new) do
            local word = item.type == "expression" and (item.pattern or item.lemma) or item.lemma
            local alts = {}
            for _, field in ipairs({ "Front", "Word", "Expression", "Vocab", "Vocabulary", "Kanji", "Hanzi" }) do
                alts[#alts + 1] = Anki.quote(field, word)
            end
            local query = Anki.quote("deck", self:deckFor(item)) .. ' -"note:KR2Anki*" (' .. table.concat(alts, " OR ") .. ")"
            local ids, _, k = self:call("findNotes", { query = query })
            if k == "unreachable" then s.unreachable = true return s end
            if k == "ok" and type(ids) == "table" and ids[1] then
                s.other_dupes[#s.other_dupes + 1] = item
            else
                keep[#keep + 1] = item
            end
        end
        s.new = keep
    end
    return s
end

-- Sending ------------------------------------------------------------------------------

--[[--
@param choices { kr_dupes = "merge"|"skip", other_dupes = "skip"|"add" }
--]]
function E:start(choices)
    choices = choices or {}
    local s = self.summary or self:prepare()
    self.queue = {}
    for _, item in ipairs(s.new) do self.queue[#self.queue + 1] = { op = "add", item = item } end
    for _, item in ipairs(s.other_dupes) do
        if choices.other_dupes == "add" then
            self.queue[#self.queue + 1] = { op = "add", item = item, allow_duplicate = true }
        else
            self.result.skipped = self.result.skipped + 1
        end
    end
    for _, item in ipairs(s.kr_dupes) do
        if choices.kr_dupes ~= "skip" and self.plan.merge and item._existing_note_id then
            self.queue[#self.queue + 1] = { op = "merge", item = item, note_id = item._existing_note_id }
        else
            self.result.skipped = self.result.skipped + 1
        end
    end
    for _, item in ipairs(s.updates) do
        self.queue[#self.queue + 1] = { op = "update", item = item, note_id = item.anki_note_id }
    end
    self.pos = 0
    self.total = #self.queue
    self.started = true
end

function E:requestStop()
    self.stop_requested = true
end

function E:fail(item, reason)
    self.result.failed[#self.result.failed + 1] = { item = item, reason = reason }
    pcall(self.store.setError, self.store, item.id, reason)
end

function E:soundFor(item)
    if not (self.media_for and self.plan.media and item.audio) then return nil end
    local ok, m = pcall(self.media_for, item)
    if not ok or not m then return nil end
    local b64 = require("kr2anki/b64")
    local _, _, k = self:call("storeMediaFile", { filename = m.name, data = b64(m.data) })
    if k == "ok" then return "[sound:" .. m.name .. "]" end
end

function E:addBatch(ops)
    local notes = {}
    for i, op in ipairs(ops) do
        local note = self:noteFor(op.item, self:soundFor(op.item))
        if op.allow_duplicate then note.options.allowDuplicate = true end
        notes[i] = note
        if self.unreachable then return end
    end
    local ids
    if self.plan.batch_add then
        local res, err, k = self:call("addNotes", { notes = self.client:array(notes) })
        if k == "unreachable" then return end
        if k == "ok" and type(res) == "table" then
            ids = res
        elseif not self.plan.single_add then
            for _, op in ipairs(ops) do self:fail(op.item, tostring(err)) end
            return
        end
    end
    for i, op in ipairs(ops) do
        local id = ids and ids[i]
        if id ~= nil and not self.client:isNull(id) and tonumber(id) then
            self.store:markExported(op.item.id, tonumber(id))
            self.result.added = self.result.added + 1
        elseif self.plan.single_add then
            -- one by one, to get Anki's reason for this note
            local res, err, k = self:call("addNote", { note = notes[i] })
            if k == "unreachable" then return end
            if k == "ok" and tonumber(res) then
                self.store:markExported(op.item.id, tonumber(res))
                self.result.added = self.result.added + 1
            else
                self:fail(op.item, err or "Anki did not add the note")
            end
        else
            self:fail(op.item, "Anki did not add the note")
        end
    end
end

-- Add this item's sentence to an existing note ("update": every sentence
-- the item has, since the ones already on the card are skipped).
function E:mergeOne(op)
    local item = op.item
    local fields = self:fieldsFor(item)
    local new_sentences = { fields.Sentence or "" }
    if op.op == "update" then
        new_sentences = {}
        for _, s in ipairs(item.sentences or {}) do new_sentences[#new_sentences + 1] = (N.sentenceFields(s)) end
    end
    local current
    if self.plan.read_notes then
        local res, _, k = self:call("notesInfo", { notes = self.client:array({ op.note_id }) })
        if k == "unreachable" then return end
        local info = k == "ok" and type(res) == "table" and res[1]
        if info and type(info) == "table" and info.fields and info.fields.Sentence then
            current = info.fields.Sentence.value or info.fields.Sentence
            if type(current) ~= "string" then current = nil end
        elseif k == "ok" then
            self:fail(item, "The card in Anki was not found")
            return
        end
    end
    local merged
    if current then
        merged = current
        for _, s in ipairs(new_sentences) do merged = N.mergeSentence(merged, s) end
    else
        -- cannot read the note: write all of this item's sentences
        merged = ""
        for _, s in ipairs(item.sentences or {}) do
            merged = N.mergeSentence(merged, (N.sentenceFields(s)))
        end
    end
    local update = { Sentence = merged }
    if item.type ~= "expression" then update.LookupCount = tostring(item.lookup_count or 1) end
    local _, err, k = self:call("updateNoteFields", { note = { id = op.note_id, fields = update } })
    if k == "unreachable" then return end
    if k == "ok" then
        self.store:markExported(item.id, op.note_id)
        if op.op == "update" then self.result.updated = self.result.updated + 1 end
        self.result.merged = self.result.merged + 1
    else
        self:fail(item, err or "Anki did not update the card")
    end
end

--[[--
Process one batch.
@treturn table progress { done, total, deck, word, finished }
--]]
function E:step()
    if not self.started then self:start() end
    local progress = { done = self.pos, total = self.total }
    if self.pos >= self.total or self.stop_requested or self.unreachable then
        return self:finish()
    end
    local batch = {}
    local op_kind = self.queue[self.pos + 1].op
    while #batch < E.BATCH and self.pos + #batch < self.total do
        local op = self.queue[self.pos + #batch + 1]
        if (op.op == "add") ~= (op_kind == "add") then break end
        batch[#batch + 1] = op
    end
    if op_kind == "add" then
        self:addBatch(batch)
    else
        for _, op in ipairs(batch) do
            self:mergeOne(op)
            if self.unreachable then break end
        end
    end
    if self.unreachable then
        return self:finish()
    end
    self.pos = self.pos + #batch
    local last = batch[#batch].item
    progress.done = self.pos
    progress.deck = self:deckFor(last)
    progress.word = last.type == "expression" and (last.pattern or last.lemma) or last.lemma
    progress.finished = false
    if self.pos >= self.total then return self:finish() end
    return progress
end

function E:finish()
    if not self.finished then
        self.finished = true
        if self.unreachable then
            self.result.unreachable = true
            -- whatever was not confirmed stays Ready
            local confirmed = {}
            for i = self.pos + 1, self.total do
                local op = self.queue[i]
                local item = op.item
                local fresh = self.store:getItem(item.id)
                if fresh and fresh.status ~= "anki" or (fresh and op.op == "update" and fresh.needs_update == 1) then
                    if not confirmed[item.id] then
                        confirmed[item.id] = true
                        self:fail(item, UNREACHABLE_REASON)
                    end
                end
            end
        elseif self.stop_requested and self.pos < self.total then
            self.result.stopped = true
            self.result.not_sent = self.total - self.pos
        end
    end
    return { done = self.pos, total = self.total, finished = true }
end

-- Items to retry after a partial failure.
function E:failedItems()
    local out = {}
    for _, f in ipairs(self.result.failed) do out[#out + 1] = f.item end
    return out
end

return E
