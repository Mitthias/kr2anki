local Anki = require("kr2anki/anki")
local Exporter = require("kr2anki/exporter")
local N = require("kr2anki/notetypes")
local json = require("json")
local FakeAnki = require("fakeanki")
local T = require("testdb")

local function setup(fake_opts, n)
    local store = T.new()
    local ids = {}
    local words = { "打ち明ける", "淋しい", "罪悪", "書生", "犠牲", "向上心", "若々しい", "己れ", "端書", "成る" }
    for i = 1, n or 3 do
        local w = words[(i - 1) % #words + 1] .. (i > #words and tostring(i) or "")
        ids[i] = store:saveCapture(T.capture({ lemma = w, surface = w })).item_id
    end
    store:setStatus(ids, "ready")
    local fake = FakeAnki.new(fake_opts)
    local client = Anki.new{ json = json, transport = fake:transport() }
    local caps = client:probe()
    return store, fake, client, caps, ids
end

local function run(job)
    local steps = 0
    repeat
        local p = job:step()
        steps = steps + 1
    until p.finished
    return steps
end

describe("export", function()
    it("creates note types and decks, then adds notes in batches of 20", function()
        local store, fake, client, caps = setup(nil, 45)
        local job = Exporter.new{ client = client, store = store, caps = caps, settings = {} }
        local s = job:prepare()
        assert.equal(45, s.total)
        assert.same({ { deck = "Reading::Japanese", n = 45 } }, s.by_deck)
        assert.is_nil(s.need_notetypes)
        assert.truthy(fake.models["KR2Anki Word"])
        assert.truthy(fake.decks["Reading::Japanese"])
        job:start{}
        local p1 = job:step()
        assert.equal(20, p1.done)
        assert.equal(45, p1.total)
        assert.equal("Reading::Japanese", p1.deck)
        run(job)
        assert.equal(45, job.result.added)
        assert.equal(0, #job.result.failed)
        local c = store:counts()
        assert.equal(0, c.ready)
        assert.equal(45, c.anki)
        local it = store:getItem(1)
        assert.truthy(it.anki_note_id)
        local note = fake.notes[it.anki_note_id]
        assert.equal("KR2Anki Word", note.model)
        assert.equal("Reading::Japanese", note.deck)
        assert.equal(it.uid, note.fields.UID)
        local adds = 0
        for _, a in ipairs(fake:actionsCalled()) do if a == "addNotes" then adds = adds + 1 end end
        assert.equal(1 + 3, adds, "one empty call from the capability check, then 3 batches")
    end)

    it("merges a sentence into an existing KR2Anki card", function()
        local store, fake, client, caps, ids = setup(nil, 2)
        client:call("createModel", N.createModelParams("word"))
        fake.decks["Reading::Japanese"] = 5
        local existing = fake:addExisting("KR2Anki Word", { Word = "淋しい", Sentence = "old sentence" }, "Reading::Japanese")
        local job = Exporter.new{ client = client, store = store, caps = caps, settings = {} }
        local s = job:prepare()
        assert.equal(1, #s.kr_dupes)
        assert.equal("淋しい", s.kr_dupes[1].lemma)
        job:start{ kr_dupes = "merge" }
        run(job)
        assert.equal(1, job.result.added)
        assert.equal(1, job.result.merged)
        assert.equal("old sentence<br><br>本名は<b>打ち明けない</b>。", fake.notes[existing].fields.Sentence)
        local it = store:getItem(ids[2])
        assert.equal("anki", it.status)
        assert.equal(existing, it.anki_note_id)
    end)

    it("skips duplicates when asked and keeps them Ready", function()
        local store, fake, client, caps, ids = setup(nil, 2)
        client:call("createModel", N.createModelParams("word"))
        fake.decks["Reading::Japanese"] = 5
        fake:addExisting("KR2Anki Word", { Word = "淋しい" }, "Reading::Japanese")
        local job = Exporter.new{ client = client, store = store, caps = caps, settings = {} }
        job:prepare()
        job:start{ kr_dupes = "skip" }
        run(job)
        assert.equal(1, job.result.added)
        assert.equal(1, job.result.skipped)
        assert.equal("ready", store:getItem(ids[2]).status)
    end)

    it("detects the word in another note type and offers Skip or Add anyway", function()
        local store, fake, client, caps = setup(nil, 2)
        fake.decks["Reading::Japanese"] = 5
        fake:addExisting("Basic", { Front = "罪悪", Back = "sin" }, "Reading::Japanese")
        fake:addExisting("Basic", { Front = "淋しい", Back = "lonely" }, "Reading::Japanese")
        local job = Exporter.new{ client = client, store = store, caps = caps, settings = {} }
        local s = job:prepare()
        assert.equal(1, #s.other_dupes)
        assert.equal("淋しい", s.other_dupes[1].lemma)
        job:start{ other_dupes = "add" }
        run(job)
        assert.equal(2, job.result.added)
    end)

    it("reports partial failures with reasons and keeps those items Ready", function()
        local store, fake, client, caps, ids = setup({ reject = { ["罪悪"] = true } }, 3)
        local job = Exporter.new{ client = client, store = store, caps = caps, settings = {} }
        job:prepare()
        job:start{}
        run(job)
        assert.equal(2, job.result.added)
        assert.equal(1, #job.result.failed)
        assert.equal("cannot create note because it is empty", job.result.failed[1].reason)
        local it = store:getItem(ids[3])
        assert.equal("ready", it.status)
        assert.equal("cannot create note because it is empty", it.last_error)
        -- Retry: only the failed item is sent again
        fake.reject = {}
        local retry = Exporter.new{ client = client, store = store, caps = caps, settings = {}, items = job:failedItems() }
        retry:prepare()
        retry:start{}
        run(retry)
        assert.equal(1, retry.result.added)
        assert.equal("anki", store:getItem(ids[3]).status)
    end)

    it("survives AnkiConnect closing mid-export: nothing unconfirmed leaves Ready", function()
        local store, fake, client, caps = setup(nil, 30)
        local job = Exporter.new{ client = client, store = store, caps = caps, settings = {} }
        job:prepare()
        fake.fail_after = #fake.calls + 1 -- first addNotes works, then the app is killed
        job:start{}
        run(job)
        assert.is_true(job.result.unreachable)
        assert.equal(20, job.result.added)
        assert.equal(10, #job.result.failed)
        local c = store:counts()
        assert.equal(20, c.anki)
        assert.equal(10, c.ready)
    end)

    it("reports unreachable before sending anything", function()
        local store, fake, client, caps = setup(nil, 2)
        fake.down = true
        local job = Exporter.new{ client = client, store = store, caps = caps, settings = {} }
        local s = job:prepare()
        assert.is_true(s.unreachable)
        assert.equal(2, store:counts().ready)
    end)

    it("stops after the current batch when asked", function()
        local store, _, client, caps = setup(nil, 50)
        local job = Exporter.new{ client = client, store = store, caps = caps, settings = {} }
        job:prepare()
        job:start{}
        job:step()
        job:requestStop()
        run(job)
        assert.is_true(job.result.stopped)
        assert.equal(20, job.result.added)
        assert.equal(30, store:counts().ready)
    end)

    it("works without addNotes, canAddNotes or createModel (Android-like)", function()
        local store, fake, client, caps = setup({ unsupported = { addNotes = "html", canAddNotes = "html", createModel = "html" } }, 3)
        local job = Exporter.new{ client = client, store = store, caps = caps, settings = {} }
        local s = job:prepare()
        assert.is_true(s.need_notetypes)
        -- user imports the bundled package: the note types now exist
        fake.models["KR2Anki Word"] = { fields = N.WORD_FIELDS }
        fake.models["KR2Anki Expression"] = { fields = N.EXPR_FIELDS }
        job = Exporter.new{ client = client, store = store, caps = caps, settings = {} }
        s = job:prepare()
        assert.is_nil(s.need_notetypes)
        job:start{}
        run(job)
        assert.equal(3, job.result.added)
    end)

    it("lists missing decks when AnkiConnect can't create them (AnkiConnect Android)", function()
        local store = T.new()
        local a = store:saveCapture(T.capture({ language = "en", lemma = "cocky", surface = "cocky" })).item_id
        store:setStatus({ a }, "ready")
        local fake = FakeAnki.new{ android = true }
        local client = Anki.new{ json = json, transport = fake:transport() }
        local caps = client:probe()
        local job = Exporter.new{ client = client, store = store, caps = caps, settings = {} }
        local s = job:prepare()
        assert.is_true(s.need_notetypes, "createModel is not available either")
        assert.same({ "Reading::English" }, s.missing_decks)
        -- the user imports the note types and creates the deck in AnkiDroid
        fake.models["KR2Anki Word"] = { fields = N.WORD_FIELDS }
        fake.models["KR2Anki Expression"] = { fields = N.EXPR_FIELDS }
        fake.decks["Reading::English"] = 9
        job = Exporter.new{ client = client, store = store, caps = caps, settings = {} }
        s = job:prepare()
        assert.is_nil(s.need_notetypes)
        assert.is_nil(s.missing_decks)
        job:start{}
        run(job)
        assert.equal(1, job.result.added)
        assert.equal("anki", store:getItem(a).status)
    end)

    it("reports Anki's reason without the Java stack trace", function()
        local store = T.new()
        local a = store:saveCapture(T.capture({ language = "en", lemma = "cocky", surface = "cocky" })).item_id
        store:setStatus({ a }, "ready")
        local fake = FakeAnki.new{ android = true }
        fake.models["KR2Anki Word"] = { fields = N.WORD_FIELDS }
        local client = Anki.new{ json = json, transport = fake:transport() }
        local caps = client:probe()
        caps.actions.deckNames = false -- as if the deck check were skipped
        local job = Exporter.new{ client = client, store = store, caps = caps, settings = {} }
        job:prepare(); job:start{}; run(job)
        assert.equal(1, #job.result.failed)
        assert.equal("Couldn't get deck ID", job.result.failed[1].reason)
    end)

    it("sends a new sentence for an item already in Anki", function()
        local store, fake, client, caps, ids = setup(nil, 1)
        local job = Exporter.new{ client = client, store = store, caps = caps, settings = {} }
        job:prepare(); job:start{}; run(job)
        local note_id = store:getItem(ids[1]).anki_note_id
        store:saveCapture(T.capture({ sentence = { text = "全部打ち明けた。", hl_start = 7, hl_end = 21 } }))
        assert.equal(1, store:counts().updates)
        local job2 = Exporter.new{ client = client, store = store, caps = caps, settings = {} }
        local s = job2:prepare()
        assert.equal(0, s.total)
        assert.equal(1, #s.updates)
        job2:start{}; run(job2)
        assert.equal(1, job2.result.updated)
        assert.truthy(fake.notes[note_id].fields.Sentence:find("全部<b>打ち明けた</b>。", 1, true))
        assert.equal(0, store:counts().updates)
    end)

    it("uses per-language decks and tags", function()
        local store = T.new()
        local a = store:saveCapture(T.capture()).item_id
        local b = store:saveCapture(T.capture({ language = "en", lemma = "run", surface = "ran",
            book = { title = "The Great Gatsby", authors = "F. Scott Fitzgerald" } })).item_id
        store:setStatus({ a, b }, "ready")
        local fake = FakeAnki.new()
        local client = Anki.new{ json = json, transport = fake:transport() }
        local job = Exporter.new{ client = client, store = store, caps = client:probe(), settings = {} }
        local s = job:prepare()
        assert.equal(2, #s.by_deck)
        job:start{}; run(job)
        local en = fake.notes[store:getItem(b).anki_note_id]
        assert.equal("Reading::English", en.deck)
        assert.same({ "lang::English", "book::The_Great_Gatsby", "author::F._Scott_Fitzgerald", "dict::JMdict",
                      "type::word", "src::kr2anki" }, en.tags)
    end)
end)
