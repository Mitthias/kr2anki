-- Writes a test package: luajit dev/make_apkg.lua out.apkg [definition-override]
package.path = "kr2anki.koplugin/?.lua;tests/support/?.lua;" .. package.path
local Apkg = require("kr2anki/apkg")
local N = require("kr2anki/notetypes")
local word, expr = N.sampleItem("word"), N.sampleItem("expression")
word.books = { { title = "こころ", authors = "夏目漱石" } }
if arg[2] then word.definition = arg[2] end
local en = { type = "word", language = "en", uid = "kr2anki-sample-en", lemma = "inexhaustible", surface = "inexhaustible",
    reading = "/ɪnɪɡˈzɔːstəbl/", pos = "adjective", definition = "impossible to use up; never-ending", lookup_count = 1,
    created_at = os.time(), dictionary = "WordNet",
    sentence = { text = "I was within and without, simultaneously enchanted and repelled by the inexhaustible variety of life.",
                 hl_start = 72, hl_end = 84, book = { title = "The Great Gatsby", authors = "F. Scott Fitzgerald" } } }
local notes, media = Apkg.notesFor({ word, expr, en }, { cards = N.defaultCards() })
local ok, err = Apkg.write{ path = arg[1], notes = notes, media = media, sqlite = require("lua-ljsqlite3/init"),
    json = require("json"), sha1 = require("kr2anki/sha1"), zip = require("kr2anki/zip").writeStored,
    tmpdir = os.getenv("TMPDIR") or "/tmp", now = os.time() + tonumber(os.getenv("LATER") or 0) }
print(ok, err)
