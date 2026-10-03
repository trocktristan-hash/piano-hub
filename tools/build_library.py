"""
Build / refresh the bundled song library from the Mutopia Project
(https://www.mutopiaproject.org) - free public-domain and Creative Commons
sheet music. Only solo piano pieces are imported; license + source are kept
in every song file.

  python tools/build_library.py               (default: up to 600 songs)
  python tools/build_library.py --limit 200
"""
import argparse
import html
import io
import os
import re
import sys
import time
import urllib.request
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pianolib import Library, MidiError, make_song, parse_midi, slugify  # noqa: E402

BASE = "https://www.mutopiaproject.org/cgibin/make-table.cgi?startat={}&Instrument={}"
UA = {"User-Agent": "PianoHub-library-builder/1.0 (+personal use)"}
HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, ".cache")
LIB = os.path.join(os.path.dirname(HERE), "library")

# Composers people actually search for get imported first.
PRIORITY = ["Beethoven", "Mozart", "Chopin", "Bach", "Debussy", "Satie", "Joplin", "Schubert",
            "Schumann", "Liszt", "Tchaikovsky", "Grieg", "Mendelssohn", "Brahms", "Haydn",
            "Clementi", "Handel", "Scarlatti", "Burgm", "Czerny", "Rachmaninoff", "Dvo", "Mussorgsky",
            "Pachelbel", "Vivaldi", "Albeniz", "Granados", "Fauré", "Faure", "Field", "Gottschalk"]

STYLE_TAGS = {"baroque", "classical", "romantic", "modern", "renaissance", "popular", "jazz", "ragtime",
              "folk", "march", "dance", "song", "hymn", "christmas", "technique"}


def fetch(url, binary=False, retries=3):
    os.makedirs(CACHE, exist_ok=True)
    fname = os.path.join(CACHE, re.sub(r"[^a-zA-Z0-9.]+", "_", url)[-150:])
    if os.path.exists(fname):
        with open(fname, "rb") as f:
            data = f.read()
    else:
        for attempt in range(retries):
            try:
                with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30) as r:
                    data = r.read()
                break
            except Exception as e:  # noqa: BLE001
                if attempt == retries - 1:
                    raise
                print("  retry", url, e)
                time.sleep(2)
        with open(fname, "wb") as f:
            f.write(data)
        time.sleep(0.25)  # be polite
    return data if binary else data.decode("utf-8", "replace")


def clean(cell):
    return html.unescape(re.sub(r"<[^>]+>", "", cell)).replace("\xa0", " ").strip()


def scrape_listing(listing="Piano"):
    pieces, start = [], 0
    while True:
        page = fetch(BASE.format(start, listing))
        for table in re.findall(r'<table class="table-bordered result-table">(.*?)</table>', page, re.S):
            cells = re.findall(r"<td>(.*?)</td>", table, re.S)
            if len(cells) < 12:
                continue
            title, composer, instrument = clean(cells[0]), clean(cells[1]), clean(cells[4])
            style, license_ = clean(cells[6]), clean(cells[9])
            mid = re.search(r'href="([^"]+?(?:-mids\.zip|\.mid))"', table)
            if not mid:
                continue
            pieces.append({
                "title": title,
                "composer": re.sub(r"^by\s+", "", composer),
                "instrument": instrument,
                "style": style,
                "license": license_,
                "url": mid.group(1),
            })
        print(f"listing @{start}: {len(pieces)} pieces so far")
        if "Next 10" not in page:
            break
        start += 10
    return pieces


def is_solo_guitar(p):
    return re.fullmatch(r"for (classical )?guitar( solo)?( \(.*\))?", p["instrument"].lower()) is not None


def is_solo_piano(p):
    inst = p["instrument"].lower()
    return re.fullmatch(r"for (piano|harpsichord|piano or harpsichord|harpsichord or piano|clavichord|keyboard)"
                        r"( solo)?( \(.*\))?", inst) is not None


def priority(p):
    for i, name in enumerate(PRIORITY):
        if name.lower() in p["composer"].lower():
            return i
    return len(PRIORITY)


def short_composer(c):
    c = re.sub(r"\s*\(.*?\)\s*", "", c).strip()
    return c or "Traditional"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=600, help="stop when the library has this many songs")
    ap.add_argument("--instrument", choices=["piano", "guitar"], default="piano")
    ap.add_argument("--min-sec", type=float, default=20)
    ap.add_argument("--max-sec", type=float, default=480)
    ap.add_argument("--max-nps", type=float, default=16)
    a = ap.parse_args()

    guitar = a.instrument == "guitar"
    pieces = [p for p in scrape_listing("Guitar" if guitar else "Piano") if (is_solo_guitar(p) if guitar else is_solo_piano(p))]
    pieces.sort(key=lambda p: (priority(p), p["composer"], p["title"]))
    print(f"{len(pieces)} solo keyboard pieces")

    lib = Library(LIB)
    have = {s["id"] for s in lib.index["songs"]}
    added = 0
    for p in pieces:
        if len(lib.index["songs"]) >= a.limit:
            break
        artist = short_composer(p["composer"])
        try:
            blob = fetch(p["url"], binary=True)
        except Exception as e:  # noqa: BLE001
            print("  download failed", p["url"], e)
            continue
        files = []
        if p["url"].endswith(".zip"):
            try:
                z = zipfile.ZipFile(io.BytesIO(blob))
            except zipfile.BadZipFile:
                continue
            mids = sorted(n for n in z.namelist() if n.lower().endswith(".mid"))[:8]
            for i, n in enumerate(mids):
                files.append((f"{p['title']} ({i + 1})" if len(mids) > 1 else p["title"], z.read(n)))
        else:
            files.append((p["title"], blob))

        for title, data in files:
            sid = slugify(f"{'guitar-' if guitar else ''}{artist}-{title}")
            if sid in have:
                continue
            try:
                parsed = parse_midi(data)
            except (MidiError, IndexError, Exception) as e:  # noqa: BLE001
                print("  parse failed", title, e)
                continue
            if not parsed.notes:
                continue
            tags = [p["style"].lower()] if p["style"].lower() in STYLE_TAGS else []
            tags.append("mutopia")
            if guitar:
                tags.append("guitar")
            song = make_song(parsed.notes, title, artist, tags, song_id=sid, tracks=parsed.track_names, programs=parsed.track_programs,
                             bpm=parsed.bpm, source="https://www.mutopiaproject.org", license_=p["license"])
            if not (a.min_sec <= song["duration"] <= a.max_sec) or song["nps"] > a.max_nps:
                continue
            lib.add(song, replace=True)
            have.add(sid)
            added += 1
            print(f"+ [{len(lib.index['songs'])}] {artist} - {title} ({song['duration']:.0f}s, {song['count']} notes)")
    lib.save()
    print(f"done: added {added}, library has {len(lib.index['songs'])} songs")


if __name__ == "__main__":
    main()
