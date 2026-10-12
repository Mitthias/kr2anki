# KR2Anki

A KOReader plugin that turns dictionary lookups into reviewed Anki notes:
**Read → Check → Understand → Save → Remember.**

Save a word with one tap while reading, review it later (choose the sense, base
form and sentence), and export it to AnkiDroid through AnkiConnect Android, or as
an `.apkg` file when the connection isn't available.

Target: iReader Tango 2 · SmartOS 4.0.0 · KOReader 2026.07.1 · StarDict
dictionaries · AnkiConnect Android (IzzyOnDroid) · AnkiDroid.

<img width="739" height="736" alt="Screenshot 2026-10-12 at 12 08 37" src="https://github.com/user-attachments/assets/4a591aa3-74f8-4bb7-a52d-b22109a3d3be" />
<img width="1481" height="729" alt="Screenshot 2026-10-12 at 12 09 09" src="https://github.com/user-attachments/assets/48832649-69cf-4029-8812-c4036822afef" />
<img width="1484" height="718" alt="Screenshot 2026-10-12 at 12 09 29" src="https://github.com/user-attachments/assets/328ab773-8389-47b5-b0ed-d527757359ea" />


## Install on the Tango 2

1. Connect the Tango 2 to a computer over USB (or use any file manager on it).
2. Copy the whole `kr2anki.koplugin` folder into KOReader's plugin folder:
   `koreader/plugins/kr2anki.koplugin` (on the device this is usually
   `/sdcard/koreader/plugins/`). The folder name must stay `kr2anki.koplugin`.
3. Restart KOReader (☰ ▸ Exit ▸ Restart KOReader).
4. Check that **Tools ▸ KR2Anki** exists. If the plugin manager lists it as
   disabled: Tools ▸ More tools ▸ Plugin management ▸ tick KR2Anki.

## Set up AnkiConnect Android

KOReader, AnkiDroid and AnkiConnect Android all run on the Tango 2; KR2Anki talks
to AnkiConnect at `http://127.0.0.1:8765`.

1. **AnkiDroid**: install it and open it once so it creates its collection.
2. **AnkiConnect Android**: add the IzzyOnDroid repository to F-Droid (or
   download the APK from apt.izzysoft.de/fdroid), install *AnkiConnect Android*,
   open it, allow it to access AnkiDroid's database, and start its service (a
   notification shows it is running).
3. **Battery**: Settings ▸ Apps ▸ AnkiConnect Android ▸ Battery ▸ *Unrestricted*,
   and the same for AnkiDroid. Otherwise SmartOS closes AnkiConnect in the
   background and exports fail. (On SmartOS the page may be called "App launch"
   or "Power saving".)
4. In KOReader: **Tools ▸ KR2Anki ▸ Anki connection ▸ Setup wizard**. It walks
   through the three checks above, runs a live connection test, and creates the
   decks and the two note types. The wizard also opens the first time you use
   Export, and can be skipped; saving works without Anki.

If AnkiConnect Android can't create note types on your phone, the wizard (and
Export) write `koreader/kr2anki-export/kr2anki_notetypes.apkg`. Import it once
in AnkiDroid (⋮ ▸ Import ▸ that file); it adds the note types and two sample cards
in the deck `KR2Anki::Setup`, which you can delete. A copy is also bundled in
`kr2anki.koplugin/assets/`.

## First run

1. Open a book, long-press a word. The dictionary popup shows a full-width
   **★ Save** row above KOReader's buttons. Tap it. A notification confirms
   *"Saved 打ち明ける → Japanese · Inbox (1)"*; tap the row again to undo.
   If you have customized the popup's buttons before, the row isn't added
   automatically: popup menu ▸ Dictionary settings ▸ Customize buttons ▸
   tick **KR2Anki: Save**.
2. Select several words (long-press and drag). The selection menu has
   **★ Save word** and **◆ Save as expression**.
3. **Tools ▸ KR2Anki ▸ Open KR2Anki** (or a gesture, see below) opens the manager.
   **Start review** goes through the Inbox one item per screen: pick the sense,
   check the base form (✎), then **✓ Ready**. Page-forward skips, page-back
   goes to the previous item so you can change your decision.
4. **Export** sends Ready items to AnkiDroid in batches of 20. Then sync from
   AnkiDroid to your other devices.
5. Send back the output of **Tools ▸ KR2Anki ▸ Anki connection ▸ Diagnostics**
   (see TESTING.md).

### Gestures

Gesture manager ▸ choose a gesture ▸ General: **KR2Anki: Open manager**,
**KR2Anki: Start review**, **KR2Anki: Export**.

### The built-in Vocabulary Builder

Its words can be imported with **Tools ▸ KR2Anki ▸ Data ▸ Import from Vocabulary
Builder** (its database is only read, never changed). To avoid two buttons in
the popup, hide its button: popup menu ▸ Dictionary settings ▸ Customize buttons
▸ untick "Vocabulary builder".

## Dictionaries

KR2Anki parses dictionary entries with **profiles**: small data files in
`kr2anki.koplugin/profiles/` (JMdict-style Japanese–English, CC-CEDICT-style
Chinese–English, Korean–English, English–English, English–Chinese, and a generic
fallback). Each installed dictionary is matched automatically by name or by the
`lang=` line of its `.ifo` file; **Settings ▸ Dictionary profiles** shows the
match, lets you choose another, and has **Test on a word** to see what each
profile extracts. New profiles can be dropped into
`koreader/settings/kr2anki_profiles/` without touching code
(`profiles/generic.lua` documents every field).

## Files

| Path | Contents |
| --- | --- |
| `kr2anki.koplugin/` | The plugin: `_meta.lua`, `main.lua`, `kr2anki/` modules, `profiles/`, `assets/` |
| `tests/` | busted unit tests for the pure-logic modules |
| `dev/` | Desktop harness: KOReader-side flows on stand-in widgets, previews, Anki import checks |
| `TESTING.md` | Device checklist for every screen and the full read-to-Anki loop |
| `DECISIONS.md` | Choices made where the brief was silent, and every KOReader interface checked |

Data lives in KOReader's settings folder: `kr2anki.sqlite3` (items, sentences,
lookups, books) and `kr2anki.lua` (settings). Exports go to
`koreader/kr2anki-export/`.

## Development

```bash
dev/setup.sh
```

```bash
./run_tests.sh
```

`run_tests.sh` compiles every Lua file with LuaJIT, runs luacheck, the busted
suite (115 tests), the KOReader-side flows at five screen sizes (159 checks each,
on stand-in widgets that follow KOReader's layout and event rules), and imports
the generated packages with the official Anki library.
`dev/run_ui.sh --previews` renders `dev/previews/index.html`;
`dev/render_cards.py` renders every card template in light and dark mode.
