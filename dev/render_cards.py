"""Render every card of a KR2Anki package with the official Anki library,
in light and dark mode at phone width (390 px) and tablet width (800 px).
usage: python render_cards.py package.apkg out.html"""
import sys, tempfile, os, html
from anki.collection import Collection
from anki.import_export_pb2 import ImportAnkiPackageRequest, ImportAnkiPackageOptions

col = Collection(os.path.join(tempfile.mkdtemp(), "c.anki2"))
col.import_anki_package(ImportAnkiPackageRequest(package_path=sys.argv[1],
    options=ImportAnkiPackageOptions(merge_notetypes=True, with_scheduling=False)))
frames = []
for nid in col.find_notes(""):
    note = col.get_note(nid)
    for card in note.cards():
        css = card.note_type()["css"]
        for side, body in (("front", card.question()), ("back", card.answer())):
            for night in (False, True):
                cls = "card card%d" % (card.ord + 1) + (" night_mode nightMode" if night else "")
                page = f"<!doctype html><meta charset=utf-8><style>{css} body{{margin:0}}</style><body class='{cls}'><div id=qa>{body}</div></body>"
                label = f"{note.fields[0]} · {card.template()['name']} · {side} · {'dark' if night else 'light'}"
                frames.append((label, page))
out = ["<!doctype html><meta charset=utf-8><title>Card previews</title><style>body{background:#ccc;font:12px sans-serif}figure{display:inline-block;margin:6px;vertical-align:top}iframe{width:390px;height:700px;border:1px solid #888;background:#fff}</style>"]
for label, page in frames:
    out.append(f"<figure><figcaption>{html.escape(label)}</figcaption><iframe srcdoc=\"{html.escape(page)}\"></iframe></figure>")
open(sys.argv[2], "w").write("\n".join(out))
print(len(frames), "renders ->", sys.argv[2])
