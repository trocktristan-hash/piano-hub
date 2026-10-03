"""
Convert MIDI files / Virtual Piano sheets into PianoHub songs.

  python tools/midi2song.py add song.mid --name "Title" --artist "Artist" --tags anime,pop
  python tools/midi2song.py add folder/            (every .mid in a folder)
  python tools/midi2song.py sheet sheet.txt --name "Title" --bpm 140
  python tools/midi2song.py lua song.mid -o song.lua   (standalone Lua table)
  python tools/midi2song.py remove some-song-id
  python tools/midi2song.py list
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pianolib import Library, make_song, parse_midi, parse_sheet, slugify, song_to_lua  # noqa: E402

DEFAULT_LIB = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "library")


def midi_files(path):
    if os.path.isdir(path):
        for name in sorted(os.listdir(path)):
            if name.lower().endswith((".mid", ".midi")):
                yield os.path.join(path, name)
    else:
        yield path


def cmd_add(a):
    lib = Library(a.library)
    tags = a.tags.split(",") if a.tags else []
    for path in midi_files(a.path):
        with open(path, "rb") as f:
            parsed = parse_midi(f.read())
        if not parsed.notes:
            print(f"skip {path}: no notes")
            continue
        base = os.path.splitext(os.path.basename(path))[0].replace("_", " ")
        name = a.name or base
        song = make_song(parsed.notes, name, a.artist, tags, tracks=parsed.track_names, programs=parsed.track_programs,
                         bpm=parsed.bpm, added_by=a.by,
                         song_id=a.id or slugify(f"{a.artist}-{name}" if a.artist != "Unknown" else name))
        e = lib.add(song, replace=a.replace)
        print(f"added {e['id']}: {e['count']} notes, {e['duration']:.0f}s")
    lib.save()


def cmd_sheet(a):
    lib = Library(a.library)
    with open(a.path, encoding="utf-8") as f:
        notes = parse_sheet(f.read(), a.bpm)
    song = make_song(notes, a.name, a.artist, a.tags.split(",") if a.tags else [], bpm=a.bpm)
    e = lib.add(song)
    lib.save()
    print(f"added {e['id']}: {e['count']} notes")


def cmd_lua(a):
    with open(a.path, "rb") as f:
        parsed = parse_midi(f.read())
    name = a.name or os.path.splitext(os.path.basename(a.path))[0]
    out = a.output or os.path.splitext(a.path)[0] + ".lua"
    with open(out, "w", encoding="utf-8") as f:
        f.write(song_to_lua(make_song(parsed.notes, name, a.artist)))
    print(f"wrote {out}")


def cmd_remove(a):
    lib = Library(a.library)
    print("removed" if lib.remove(a.id) else "not found")
    lib.save()


def cmd_list(a):
    for s in Library(a.library).index["songs"]:
        print(f"{s['id']:50s} {s['artist'][:24]:24s} {s['duration']:6.0f}s {s['nps']:5.1f}nps")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--library", default=DEFAULT_LIB)
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("add")
    s.add_argument("path")
    s.add_argument("--name")
    s.add_argument("--artist", default="Unknown")
    s.add_argument("--tags", default="")
    s.add_argument("--id")
    s.add_argument("--by")
    s.add_argument("--replace", action="store_true")
    s.set_defaults(fn=cmd_add)

    s = sub.add_parser("sheet")
    s.add_argument("path")
    s.add_argument("--name", required=True)
    s.add_argument("--artist", default="Unknown")
    s.add_argument("--tags", default="sheet")
    s.add_argument("--bpm", type=float, default=120)
    s.set_defaults(fn=cmd_sheet)

    s = sub.add_parser("lua")
    s.add_argument("path")
    s.add_argument("-o", "--output")
    s.add_argument("--name")
    s.add_argument("--artist", default="Unknown")
    s.set_defaults(fn=cmd_lua)

    s = sub.add_parser("remove")
    s.add_argument("id")
    s.set_defaults(fn=cmd_remove)

    s = sub.add_parser("list")
    s.set_defaults(fn=cmd_list)

    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
