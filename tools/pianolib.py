"""
pianolib - shared helpers for PianoHub.

* parse_midi(bytes)        -> list of notes (start_ms, pitch, dur_ms, track) + metadata
* parse_sheet(text, bpm)   -> notes from a Virtual Piano letter sheet ("[tu] y t | ...")
* make_song(...)           -> the compact song dict the Roblox script reads
* Library                  -> read/write library/index.json + library/songs/<id>.json
* song_to_lua(song)        -> a standalone `return { ... }` Lua table

No third-party dependencies.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import struct
import time
import unicodedata
from bisect import bisect_right
from dataclasses import dataclass, field

FORMAT_VERSION = 1

# Virtual Piano 61-key layout, C2 (MIDI 36) .. C7 (MIDI 96)
VP_KEYS = "1!2@34$5%6^78*9(0qQwWeErtTyYuiIoOpPasSdDfgGhHjJklLzZxcCvVbBnm"
VP_LOW = 36
VP_CHAR_TO_MIDI = {c: VP_LOW + i for i, c in enumerate(VP_KEYS)}

PEDAL_CAP_MS = 3000  # sustain pedal can lengthen a note by at most this much


# --------------------------------------------------------------------------- MIDI

class MidiError(ValueError):
    pass


@dataclass
class ParsedMidi:
    notes: list = field(default_factory=list)   # [start_ms, pitch, dur_ms, track]
    track_names: list = field(default_factory=list)
    track_programs: list = field(default_factory=list)  # General MIDI program per track (24-31 = guitars)
    title: str | None = None
    bpm: float = 120.0


def _vlq(data: bytes, pos: int):
    value = 0
    while True:
        if pos >= len(data):
            raise MidiError("truncated variable-length value")
        b = data[pos]
        pos += 1
        value = (value << 7) | (b & 0x7F)
        if b < 0x80:
            return value, pos


def parse_midi(data: bytes) -> ParsedMidi:
    start = data.find(b"MThd")
    if start < 0:
        raise MidiError("not a MIDI file (no MThd header)")
    hlen, fmt, ntracks, division = struct.unpack(">IHHH", data[start + 4:start + 14])
    pos = start + 8 + hlen

    smpte_ms_per_tick = None
    if division & 0x8000:
        fps = 256 - (division >> 8)
        tpf = division & 0xFF
        smpte_ms_per_tick = 1000.0 / (fps * tpf)
        tpq = 1
    else:
        tpq = division or 480

    tempos = [(0, 500000)]
    raw = []      # (tick, order, track, channel, pitch, on, velocity)
    programs = {}  # (track, channel) -> first program change
    pedals = []   # (tick, channel, down)
    track_names = []
    order = 0

    for tr in range(ntracks):
        cs = data.find(b"MTrk", pos)
        if cs < 0:
            break
        length = struct.unpack(">I", data[cs + 4:cs + 8])[0]
        pos = cs + 8
        end = min(pos + length, len(data))
        tick = 0
        status = 0
        name = None
        while pos < end:
            delta, pos = _vlq(data, pos)
            tick += delta
            if pos >= end:
                break
            b = data[pos]
            if b >= 0x80:
                status = b
                pos += 1
            elif status == 0:
                break  # running status with nothing to run: corrupt track
            if status == 0xFF:
                mtype = data[pos]
                ln, pos = _vlq(data, pos + 1)
                body = data[pos:pos + ln]
                if mtype == 0x51 and ln == 3:
                    tempos.append((tick, (body[0] << 16) | (body[1] << 8) | body[2]))
                elif mtype == 0x03 and name is None:
                    name = body.decode("latin-1", "replace").strip()
                pos += ln
                status = 0
                if mtype == 0x2F:
                    break
            elif status in (0xF0, 0xF7):
                ln, pos = _vlq(data, pos)
                pos += ln
                status = 0
            else:
                hi = status & 0xF0
                ch = status & 0x0F
                if hi in (0x80, 0x90):
                    pitch, vel = data[pos], data[pos + 1]
                    pos += 2
                    if ch != 9:  # skip drums
                        on = hi == 0x90 and vel > 0
                        raw.append((tick, order, tr, ch, pitch, on, vel))
                        order += 1
                elif hi == 0xB0:
                    ctrl, val = data[pos], data[pos + 1]
                    pos += 2
                    if ctrl == 64:
                        pedals.append((tick, ch, val >= 64))
                elif hi in (0xA0, 0xE0):
                    pos += 2
                elif hi == 0xC0:
                    programs.setdefault((tr, ch), data[pos])
                    programs.setdefault((-1, ch), data[pos])  # format 0 / channel-wide
                    pos += 1
                elif hi == 0xD0:
                    pos += 1
                else:
                    pos += 1
        track_names.append(name or "")
        pos = end

    # ---- tempo map -> tick to ms
    tempos.sort(key=lambda t: t[0])
    seg_ticks, seg_ms, seg_us = [], [], []
    ms = 0.0
    last_tick, last_us = 0, 500000
    for tk, us in tempos:
        ms += (tk - last_tick) * last_us / tpq / 1000.0
        seg_ticks.append(tk)
        seg_ms.append(ms)
        seg_us.append(us)
        last_tick, last_us = tk, us

    def to_ms(tick: int) -> float:
        if smpte_ms_per_tick is not None:
            return tick * smpte_ms_per_tick
        i = bisect_right(seg_ticks, tick) - 1
        return seg_ms[i] + (tick - seg_ticks[i]) * seg_us[i] / tpq / 1000.0

    # ---- sustain pedal intervals per channel (ms)
    pedal_iv: dict[int, list] = {}
    pedals.sort(key=lambda p: p[0])
    down_at: dict[int, float] = {}
    for tk, ch, down in pedals:
        t = to_ms(tk)
        if down and ch not in down_at:
            down_at[ch] = t
        elif not down and ch in down_at:
            pedal_iv.setdefault(ch, []).append((down_at.pop(ch), t))
    for ch, t in down_at.items():
        pedal_iv.setdefault(ch, []).append((t, t + PEDAL_CAP_MS))

    def pedal_extend(ch: int, end_ms: float) -> float:
        for a, b in pedal_iv.get(ch, ()):
            if a <= end_ms < b:
                return min(b, end_ms + PEDAL_CAP_MS)
        return end_ms

    # ---- pair note on/off
    raw.sort(key=lambda r: (r[0], r[1]))
    open_notes: dict[tuple, list] = {}
    notes = []
    for tick, _o, tr, ch, pitch, on, _vel in raw:
        key = (tr, ch, pitch)
        if on:
            open_notes.setdefault(key, []).append((tick, ch))
        else:
            stack = open_notes.get(key)
            if stack:
                st, c = stack.pop(0)
                s_ms = to_ms(st)
                e_ms = pedal_extend(c, to_ms(tick))
                notes.append([s_ms, pitch, max(e_ms - s_ms, 20.0), (tr, c)])
    last_ms = max((to_ms(r[0]) for r in raw), default=0.0)
    for (tr, ch, pitch), stack in open_notes.items():
        for st, c in stack:
            s_ms = to_ms(st)
            notes.append([s_ms, pitch, max(min(last_ms - s_ms, 2000.0), 100.0), (tr, c)])

    # remap used tracks to 0..n-1
    used = sorted({n[3] for n in notes})
    remap = {t: i for i, t in enumerate(used)}
    names = [track_names[t] if t < len(track_names) else "" for t, _c in used]
    progs = [programs.get((t, c), programs.get((-1, c), 0)) for t, c in used]
    for n in notes:
        n[3] = remap[n[3]]

    notes = normalize_notes(notes)
    title = next((n for n in track_names if n and not re.match(r"^(track|piano|untitled)", n, re.I)), None)
    return ParsedMidi(notes=notes, track_names=names, track_programs=progs, title=title,
                      bpm=round(60_000_000 / tempos[min(1, len(tempos) - 1)][1], 2))


def normalize_notes(notes):
    """Sort, round, shift to start at 0, and drop exact duplicates."""
    if not notes:
        return []
    notes.sort(key=lambda n: (n[0], n[1]))
    t0 = notes[0][0]
    out, seen = [], set()
    for s, p, d, tr in notes:
        s = int(round(s - t0))
        key = (s, p)
        if key in seen:
            continue
        seen.add(key)
        out.append([s, int(p), int(round(d)), int(tr)])
    return out


# --------------------------------------------------------------------------- sheets

def parse_sheet(text: str, bpm: float = 120) -> list:
    """Virtual Piano style letter sheet -> notes.

    Rules: a whitespace-separated token is one beat; letters glued together
    ("tyu") are a quick run sharing that beat; [abc] is a chord; '|' and '-'
    add a beat of rest; '.' adds half a beat.
    """
    beat = 60000.0 / max(bpm, 1)
    t = 0.0
    notes = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or line.startswith("//"):
            continue
        for token in re.findall(r"\[[^\]]*\]|[|\-.]|[^\s\[\]|\-.]+", line):
            if token in ("|", "-"):
                t += beat
                continue
            if token == ".":
                t += beat / 2
                continue
            if token.startswith("["):
                groups = [token[1:-1]]
            else:
                groups = list(re.findall(r"\[[^\]]*\]|.", token))
                groups = [g[1:-1] if g.startswith("[") else g for g in groups]
            groups = [g for g in groups if any(c in VP_CHAR_TO_MIDI for c in g)]
            if not groups:
                continue
            step = beat / len(groups) if len(groups) > 1 else beat
            for g in groups:
                for c in g:
                    if c in VP_CHAR_TO_MIDI:
                        notes.append([t, VP_CHAR_TO_MIDI[c], step * 0.9, 0])
                t += step
    return normalize_notes(notes)


# --------------------------------------------------------------------------- songs

def slugify(text: str, maxlen: int = 48) -> str:
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    text = re.sub(r"[^a-zA-Z0-9]+", "-", text).strip("-").lower()
    return (text[:maxlen].strip("-")) or "song"


def song_stats(notes):
    if not notes:
        return 0, 0.0, 0.0
    duration = max(s + d for s, _p, d, _t in notes) / 1000.0
    starts = len({s // 30 for s, *_ in notes})  # chord-aware density
    nps = starts / max(notes[-1][0] / 1000.0, 1.0)
    return len(notes), round(duration, 2), round(nps, 2)


def make_song(notes, name, artist="Unknown", tags=None, song_id=None, tracks=None,
              bpm=None, source=None, license_=None, added_by=None, programs=None):
    """Build the compact song dict. Notes are flattened as
    [delta_start_ms, pitch, dur_ms, track, ...] to keep files small."""
    flat, prev = [], 0
    for s, p, d, tr in notes:
        flat += [s - prev, p, d, tr]
        prev = s
    count, duration, nps = song_stats(notes)
    song = {
        "v": FORMAT_VERSION,
        "id": song_id or slugify(f"{artist}-{name}" if artist and artist != "Unknown" else name),
        "name": name,
        "artist": artist or "Unknown",
        "tags": sorted({t.strip().lower() for t in (tags or []) if t.strip()} | auto_tags(name, artist, nps)),
        "duration": duration,
        "count": count,
        "nps": nps,
        "tracks": tracks or [],
        "notes": flat,
    }
    if programs:
        song["programs"] = list(programs)
        if any(24 <= p <= 31 for p in programs) and all(24 <= p <= 39 for p in programs):
            song["tags"] = sorted(set(song["tags"]) | {"guitar"})  # guitar (+ bass) only
    if bpm:
        song["bpm"] = bpm
    if source:
        song["source"] = source
    if license_:
        song["license"] = license_
    if added_by:
        song["addedBy"] = added_by
    return song


def unflatten(flat):
    out, t = [], 0
    for i in range(0, len(flat), 4):
        t += flat[i]
        out.append([t, flat[i + 1], flat[i + 2], flat[i + 3]])
    return out


def song_json(song) -> str:
    return json.dumps(song, separators=(",", ":"), ensure_ascii=False)


def index_entry(song, raw_json: str):
    e = {k: song[k] for k in ("id", "name", "artist", "tags", "duration", "count", "nps")}
    e["hash"] = hashlib.sha1(raw_json.encode()).hexdigest()[:10]
    e["size"] = len(raw_json)
    e["added"] = int(time.time())
    for k in ("license", "addedBy"):
        if k in song:
            e[k] = song[k]
    return e


def song_to_lua(song) -> str:
    def lua_str(s):
        return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'
    notes = unflatten(song["notes"])
    rows = ",\n".join("\t\t{%d,%d,%d,%d}" % tuple(n) for n in notes)
    return (
        "-- PianoHub song. notes = { {start_ms, midi_pitch, duration_ms, track}, ... }\n"
        "return {\n"
        f"\tname = {lua_str(song['name'])},\n"
        f"\tartist = {lua_str(song['artist'])},\n"
        f"\tduration = {song['duration']},\n"
        "\tnotes = {\n" + rows + "\n\t},\n}\n"
    )


# --------------------------------------------------------------------------- library

class Library:
    """library/index.json + library/songs/<id>.json"""

    def __init__(self, root: str):
        self.root = root
        self.songs_dir = os.path.join(root, "songs")
        self.index_path = os.path.join(root, "index.json")
        os.makedirs(self.songs_dir, exist_ok=True)
        self.index = self._load()

    def _load(self):
        if os.path.exists(self.index_path):
            with open(self.index_path, encoding="utf-8") as f:
                return json.load(f)
        return {"v": FORMAT_VERSION, "name": "PianoHub Library", "updated": 0, "songs": []}

    def unique_id(self, base: str) -> str:
        ids = {s["id"] for s in self.index["songs"]}
        if base not in ids:
            return base
        i = 2
        while f"{base}-{i}" in ids:
            i += 1
        return f"{base}-{i}"

    def add(self, song, replace=False):
        if not replace:
            song["id"] = self.unique_id(song["id"])
        raw = song_json(song)
        with open(os.path.join(self.songs_dir, song["id"] + ".json"), "w", encoding="utf-8") as f:
            f.write(raw)
        entry = index_entry(song, raw)
        self.index["songs"] = [s for s in self.index["songs"] if s["id"] != song["id"]] + [entry]
        return entry

    def remove(self, song_id: str) -> bool:
        before = len(self.index["songs"])
        self.index["songs"] = [s for s in self.index["songs"] if s["id"] != song_id]
        p = os.path.join(self.songs_dir, song_id + ".json")
        if os.path.exists(p):
            os.remove(p)
        return len(self.index["songs"]) != before

    def index_json(self) -> str:
        self.index["songs"].sort(key=lambda s: (s["artist"].lower(), s["name"].lower()))
        self.index["updated"] = int(time.time())
        self.index["v"] = FORMAT_VERSION
        return json.dumps(self.index, separators=(",", ":"), ensure_ascii=False)

    def save(self):
        with open(self.index_path, "w", encoding="utf-8") as f:
            f.write(self.index_json())


# --------------------------------------------------------------------------- auto tags

FAMOUS = [
    "fur elise", "für elise", "moonlight", "pathetique", "pathétique", "appassionata", "ode to joy", "clair de lune",
    "gymnop", "gnossienne", "canon in d", "rondo alla turca", "turkish march", "alla turca", "the entertainer",
    "maple leaf rag", "mountain king", "minute waltz", "valse op. 64 no. 1", "nocturne op. 9 no. 2", "nocturne in e-flat major, op. 9",
    "fantaisie-impromptu", "fantasie impromptu", "revolutionary", "raindrop", "heroic", "héroïque", "polonaise in a-flat major, op. 53",
    "ballade no. 1", "liebestraum", "la campanella", "hungarian rhapsody no. 2", "consolation", "träumerei", "traumerei",
    "kinderszenen", "prelude in c major, bwv 846", "well-tempered", "goldberg", "toccata and fugue", "jesu, joy",
    "arabesque", "reverie", "rêverie", "golliwogg", "sonata no. 14", "sonata in c major, k. 545", "k. 545", "k. 331",
    "the swan", "swan lake", "nutcracker", "sugar plum", "waltz of the flowers", "flight of the bumblebee",
    "prelude in c-sharp minor", "pictures at an exhibition", "great gate", "lullaby", "wiegenlied", "air on the g",
    "greensleeves", "jingle bells", "silent night", "spring song", "wedding march", "habanera", "carmen",
    "blue danube", "radetzky", "william tell", "can-can", "hallelujah", "minuet in g", "musette",
]
CRAZY = [
    "campanella", "hungarian rhapsody", "mephisto", "islamey", "feux follets", "transcendental", "wilde jagd",
    "revolutionary", "winter wind", "op. 25 no. 11", "op. 10 no. 4", "op. 10 no. 1", "op. 10 no. 12",
    "flight of the bumblebee", "erlkönig", "erlkonig", "don juan", "rigoletto", "totentanz", "paganini",
    "tarantella", "toccata", "etude-tableau", "étude-tableau", "etudes-tableaux", "études-tableaux",
    "gnomenreigen", "spanish rhapsody", "rhapsodie espagnole", "scherzo no. 2", "polonaise in a-flat major, op. 53",
    "ballade no. 4", "sonata in b minor", "carmen", "blue danube", "réminiscences", "reminiscences", "fantasia on",
    "la valse", "petrushka", "rush", "black midi", "impossible",
]
CRAZY_NPS = 11.0  # anything denser than this sounds "crazy" on a Roblox piano


def auto_tags(name: str, artist: str = "", nps: float = 0.0):
    text = f"{name} {artist}".lower()
    tags = set()
    if any(k in text for k in FAMOUS):
        tags.add("famous")
    if nps >= CRAZY_NPS or any(k in text for k in CRAZY):
        tags.add("crazy")
    return tags
