-- Rebuilds kr2anki.koplugin/assets/kr2anki_notetypes.apkg (both note types
-- plus one sample note each). Run: luajit dev/build_assets.lua
package.path = "kr2anki.koplugin/?.lua;tests/support/?.lua;" .. package.path
local Apkg = require("kr2anki/apkg")
local N = require("kr2anki/notetypes")
local items = { N.sampleItem("word"), N.sampleItem("expression") }
for _, it in ipairs(items) do it.books = {} end
local notes = Apkg.notesFor(items, { cards = N.defaultCards() })
for _, n in ipairs(notes) do
    n.deck = "KR2Anki::Setup"
    n.tags[#n.tags + 1] = "kr2anki::sample"
end
local ok, err = Apkg.write{
    path = "kr2anki.koplugin/assets/kr2anki_notetypes.apkg", notes = notes,
    sqlite = require("lua-ljsqlite3/init"), json = require("json"), sha1 = require("kr2anki/sha1"),
    zip = require("kr2anki/zip").writeStored, tmpdir = os.getenv("TMPDIR") or "/tmp", now = 1760000000,
}
print(ok and "wrote kr2anki.koplugin/assets/kr2anki_notetypes.apkg" or ("failed: " .. tostring(err)))
