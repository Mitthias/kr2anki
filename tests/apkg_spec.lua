local Apkg = require("kr2anki/apkg")
local N = require("kr2anki/notetypes")
local SQ3 = require("lua-ljsqlite3/init")
local json = require("json")
local sha1 = require("kr2anki/sha1")
local Zip = require("kr2anki/zip")

local function tmpdir()
    local d = os.tmpname()
    os.remove(d)
    os.execute("mkdir -p '" .. d .. "'")
    return d
end

local CHECK = [[
import json, sqlite3, sys, zipfile, tempfile, os
z = zipfile.ZipFile(sys.argv[1])
names = sorted(z.namelist())
d = tempfile.mkdtemp()
z.extract("collection.anki2", d)
c = sqlite3.connect(os.path.join(d, "collection.anki2"))
models = json.loads(c.execute("select models from col").fetchone()[0])
decks = json.loads(c.execute("select decks from col").fetchone()[0])
notes = c.execute("select guid, mid, flds, tags, csum, sfld from notes order by id").fetchall()
cards = c.execute("select nid, did, ord from cards order by nid, ord").fetchall()
out = {
  "names": names,
  "media": json.loads(z.read("media")),
  "models": sorted(m["name"] for m in models.values()),
  "fieldcount": {m["name"]: len(m["flds"]) for m in models.values()},
  "decks": sorted(d["name"] for d in decks.values()),
  "guids": [n[0] for n in notes],
  "nfields": [len(n[2].split("\x1f")) for n in notes],
  "tags": [n[3] for n in notes],
  "cards": [[r[2] for r in cards if r[0] == nid] for nid in sorted(set(r[0] for r in cards))],
  "csum_ok": all(n[4] == int(__import__("hashlib").sha1(n[5].encode()).hexdigest()[:8], 16) for n in notes),
}
print(json.dumps(out, ensure_ascii=False))
]]

local function inspect(path)
    local script = os.tmpname() .. ".py"
    local f = io.open(script, "w"); f:write(CHECK); f:close()
    local p = io.popen("python3 -I '" .. script .. "' '" .. path .. "'")
    local out = p:read("*a")
    p:close()
    os.remove(script)
    return json.decode(out)
end

describe(".apkg writer", function()
    it("writes a package Anki can read, with uid GUIDs and the right cards", function()
        local dir = tmpdir()
        local word, expr = N.sampleItem("word"), N.sampleItem("expression")
        word.books = { { title = "こころ", authors = "夏目漱石" } }
        local notes, media = Apkg.notesFor({ word, expr }, { cards = N.defaultCards() })
        local path = dir .. "/test.apkg"
        local ok, err = Apkg.write{ path = path, notes = notes, media = media, sqlite = SQ3, json = json, sha1 = sha1,
                                    zip = Zip.writeStored, tmpdir = dir }
        assert.is_true(ok, err)
        local r = inspect(path)
        assert.same({ "collection.anki2", "media" }, r.names)
        assert.same({ "KR2Anki Expression", "KR2Anki Word" }, r.models)
        assert.equal(22, r.fieldcount["KR2Anki Word"])
        assert.equal(12, r.fieldcount["KR2Anki Expression"])
        assert.same({ "Default", "Reading::Japanese" }, r.decks)
        assert.same({ "kr2anki-sample-word", "kr2anki-sample-expression" }, r.guids)
        assert.same({ 22, 12 }, r.nfields)
        assert.same({ 0, 1, 2 }, r.cards[1], "word: recognition, cloze, reading")
        assert.same({ 0 }, r.cards[2], "expression: recognition only (cloze off)")
        assert.truthy(r.tags[1]:find(" src::kr2anki ", 1, true))
        assert.is_true(r.csum_ok)
        os.execute("rm -rf '" .. dir .. "'")
    end)

    it("includes media files", function()
        local dir = tmpdir()
        local word = N.sampleItem("word")
        word.audio = "uchiakeru.mp3"
        local notes, media = Apkg.notesFor({ word }, {
            sound_for = function() return { name = "uchiakeru.mp3", data = "ID3fake" } end })
        assert.equal("[sound:uchiakeru.mp3]", notes[1].fields.Sound)
        local path = dir .. "/m.apkg"
        assert.is_true((Apkg.write{ path = path, notes = notes, media = media, sqlite = SQ3, json = json, sha1 = sha1,
                                    zip = Zip.writeStored, tmpdir = dir }))
        local r = inspect(path)
        assert.same({ ["0"] = "uchiakeru.mp3" }, r.media)
        assert.same({ "0", "collection.anki2", "media" }, r.names)
        os.execute("rm -rf '" .. dir .. "'")
    end)

    it("uses stable deck ids", function()
        assert.equal(Apkg.deckId("Reading::Japanese"), Apkg.deckId("Reading::Japanese"))
        assert.are_not.equal(Apkg.deckId("Reading::Japanese"), Apkg.deckId("Reading::English"))
        assert.is_true(Apkg.deckId("Reading::Japanese") < 2 ^ 53)
    end)
end)
