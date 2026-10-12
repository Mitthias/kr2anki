"""Import KR2Anki packages with the official Anki library.
usage: python check_apkg.py first.apkg second.apkg
Checks notes, cards, rendering, and that importing the second package
(same GUIDs, changed content) updates notes instead of duplicating them."""
import sys, tempfile, os
from anki.collection import Collection
from anki.import_export_pb2 import ImportAnkiPackageRequest, ImportAnkiPackageOptions

d = tempfile.mkdtemp()
col = Collection(os.path.join(d, "test.anki2"))

def imp(path):
    # default options, as AnkiDroid uses: update notes when the package is newer
    req = ImportAnkiPackageRequest(package_path=path, options=ImportAnkiPackageOptions(
        merge_notetypes=True, with_scheduling=False, with_deck_configs=False))
    return col.import_anki_package(req)

imp(sys.argv[1])
nids = col.find_notes("")
print("notes:", len(nids), "cards:", len(col.find_cards("")))
print("decks:", sorted(d.name for d in col.decks.all_names_and_ids()))
for nid in nids:
    n = col.get_note(nid)
    cards = n.cards()
    print(" ", n.note_type()["name"], "|", n.fields[0], "| guid", n.guid, "| tags", n.tags,
          "| cards", [c.template()["name"] for c in cards])
    for c in cards:
        q = c.question(); a = c.answer()
        assert q.strip(), "empty front"
        if "Reading" == c.template()["name"]:
            assert "<ruby>" in a, "furigana not rendered"
first = col.get_note(nids[0])
print("render check: recognition back contains ruby:", "<ruby>" in first.cards()[0].answer())
if len(sys.argv) > 2:
    imp(sys.argv[2])
    nids2 = col.find_notes("")
    print("after re-import notes:", len(nids2), "(same count means updated, not duplicated)")
    w = [col.get_note(n) for n in nids2 if col.get_note(n).guid == "kr2anki-sample-word"][0]
    print("updated definition:", w["Definition"])
col.close()
