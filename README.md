# 🎹 PianoHub

Autoplay piano for Roblox Virtual-Piano-style pianos (61 keys, `1!2@34$5%6^78*9(0qQwWeErtTyYuiIoOpPasSdDfgGhHjJklLzZxcCvVbBnm`),
driven through `VirtualInputManager`, with a shared song library you grow from Discord.

```
piano-hub/
├─ PianoHub.lua          the script you execute (GUI + player + MIDI parser)
├─ library/
│  ├─ index.json         song list the GUI downloads on every launch
│  └─ songs/<id>.json    one file per song (downloaded + cached on first play)
├─ tools/
│  ├─ pianolib.py        MIDI / sheet → song converter (shared by everything)
│  ├─ midi2song.py       CLI: add .mid files / sheets, export .lua tables
│  └─ build_library.py   rebuilds the bundled library from Mutopia (public domain / CC)
└─ bot/                  Discord bot: /addsong etc. commits straight to the repo
```

> `floor-assist/` is a separate, unrelated web app (an AI sales-floor assistant). See [floor-assist/README.md](floor-assist/README.md).

The bundled library has **388 solo piano pieces** and **336 classical guitar pieces** (Beethoven, Chopin, Bach, Debussy, Satie,
Joplin, Mozart, Schumann, Grieg …) taken from the [Mutopia Project](https://www.mutopiaproject.org).
Every song file keeps its license (public domain or Creative Commons).

---

## 1. Put it on GitHub (once)

1. Create a **public** GitHub repo, e.g. `piano-hub`.
2. Push this folder to it:
   ```bash
   git remote add origin https://github.com/trocktristan-hash/piano-hub.git
   git push -u origin main
   ```
3. In `PianoHub.lua`, set `CONFIG.LibraryURL` to
   `https://raw.githubusercontent.com/trocktristan-hash/piano-hub/main/library/`, then commit and push again.
   (You can also paste the URL into the GUI under **Settings → Library URL**.)

## 2. Run it (Potassium or any executor)

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/trocktristan-hash/piano-hub/main/PianoHub.lua"))()
```

Sit at the piano, choose a song, then click back into the game window during the countdown.

> **Turn off Shift Lock** in Roblox settings. Black keys are played with Shift held down,
> so Shift Lock would keep toggling while a song plays.

### Features

| Tab | What's there |
|---|---|
| **Library** | Search (name / composer / tag), sort (A-Z, artist, newest, length, difficulty), tag chips, ★ favorites, recent songs, difficulty dots, right-click or **+** to queue |
| **Player** | Live 61-key visualizer, speed 0.25–3×, transpose ±24 with **auto transpose**, out-of-range notes (Fold / Drop / **88-key Ctrl** mode), Tap or **Hold** notes (real note lengths), tap length, left/right hand only with a split point, chord cap, same-key repeat guard, per-track mute, loop off/one/all, autoplay next, shuffle |
| **Queue** | Reorder, remove, shuffle, play queue, history |
| **Humanize** | Presets: Natural / Expressive / Sloppy / Beginner. Timing jitter, chord rolling (strum), tempo drift (rubato), pauses between phrases, hold-length variance, missed notes, wrong notes with self-correction, 10-finger limit (5 notes per hand). Each play is randomized again. |
| **Perform** | **Warm up** (scales, arpeggios and finger exercises in the song's key; longer and flashier before crazy songs), **song transitions** (Cadence / Glissando / Playful "shave and a haircut" / Noodle bridge into the next key), **Improv** (grace notes, trills, mordents, fills in rests, broken chords, octave doubling, improvised intro, big finish), with automatic key detection |
| **LIVE panel** | Floating window while playing: tempo −/+ (eased), rubato, left/right hand on/off, octave shift, Improv/Human toggles, and actions: Hesitate, Slip-up, Redo phrase, Flourish, Warm up, Next song, Big ending, Stop |
| **Import** | Paste a Virtual Piano sheet, load a `.mid`/`.json` from a URL, save to your local library, rescan local files |
| **Settings** | Library URL, reload, clear cache, countdown, pause while typing in chat, notifications, rebindable hotkeys, accent colour, UI scale, release stuck keys, unload |

**Default hotkeys:** `RightControl` hides/shows the window, `F2` play/pause, `F3` stop, `F4` next, `F1` previous, `F5` hesitate, `F6` flourish, `F7` big ending, `F8` live panel.

**Local songs (no bot needed):** put `.mid` files in `workspace/PianoHub/midi/` inside your executor's
folder and press **Rescan**. They're parsed in-game by the built-in Lua MIDI reader.
Settings, favorites and downloaded songs are saved in `workspace/PianoHub/`.

## 🎸 Guitar mode

The **Guitar** tab switches PianoHub to Roblox guitars with the 6-string keyboard layout
(each key row is a string, low E = `z x c v …`, A = `a s d …`, D = `q w e …`, G = `` ` 1 2 … ``,
B = `Q W E …`, high e = `~ ! @ …`; every key to the right is one fret higher, frets 0–12).

- Every note gets a real string + fret: chords never put two notes on one string, the fretting hand
  stays within a reachable stretch (adjustable), and melodies stay near the current hand position.
- Strummed chords (alternating down/up strokes), optional vibrato (holds Ctrl on long notes) and
  palm muting (holds Space on short low notes). Tunings: Standard, Drop D, Half/Full step down,
  Drop C, Open G, Open D, DADGAD — match the game's TUNING button. Keep the game's CAPS (octave) off.
- **Guitar tracks only** mutes vocals/bass/piano parts when a MIDI has a guitar track (General MIDI
  programs 24–31 or a track named "guitar").
- Songs tagged `guitar` switch the instrument automatically. The library ships with **336 public-domain
  classical guitar pieces** (Tárrega, Sor, Giuliani, Carcassi, Aguado, …).

**Getting more guitar songs**
1. Drop `.mid` files into `workspace/PianoHub/guitar/` and press **Rescan** (converted once, then the `.mid` can be deleted).
2. **MuseScore:** open a score in the free MuseScore Studio app → *File → Export → MIDI*. Solo / fingerstyle arrangements work best.
3. **Guitar Pro tabs** (`.gp`, `.gp5`, `.gpx` from Ultimate Guitar, GProTab, …): open in the free **TuxGuitar** or MuseScore Studio and export MIDI.
4. Share with everyone: Discord `/addsong` with `instrument: Guitar`.
5. Refresh the bundled set: `python tools/build_library.py --instrument guitar --limit 800`.

## 3. Discord bot

1. Go to <https://discord.com/developers/applications> → New Application → **Bot** → Reset Token.
   Invite it with the `bot` and `applications.commands` scopes.
2. Create a GitHub **fine-grained token** for the repo with *Contents: Read and write*.
3. Set up and start the bot:
   ```bash
   cd bot
   pip install -r requirements.txt
   copy .env.example .env      # fill in DISCORD_TOKEN, GUILD_ID, GITHUB_TOKEN, GITHUB_REPO
   python bot.py
   ```

| Command | Who | |
|---|---|---|
| `/addsong file:<.mid> [name] [artist] [tags] [instrument]` | editors | Converts the MIDI and commits it to the library (`instrument: Guitar` puts it in the Guitar tab) |
| `/addurl url [name] [artist] [tags]` | editors | Same, from a direct `.mid` link |
| `/addsheet name sheet\|file [bpm]` | editors | Virtual Piano letter sheet |
| `/editsong song [name] [artist] [tags]` | editors | Rename or retag (autocomplete) |
| `/removesong song` | editors | Delete |
| `/songs [query]`, `/songinfo song`, `/library` | everyone | Browse, details, stats and the loader line |

Editors are members with *Manage Server*, plus any role in `EDITOR_ROLE_IDS`.
Each change is one commit (song file + index). Players get it the next time PianoHub loads or when
they press ⟳ (GitHub's raw cache can take up to ~5 minutes).
Set `STORAGE=local` to write into `library/` instead, and push it yourself.

## 4. Command-line tools

```bash
python tools/midi2song.py add song.mid --name "Title" --artist "Artist" --tags anime,pop
python tools/midi2song.py add some_folder/             # every .mid inside
python tools/midi2song.py sheet sheet.txt --name "Title" --bpm 140
python tools/midi2song.py lua song.mid -o song.lua      # standalone Lua table: { {ms, pitch, dur, track}, ... }
python tools/midi2song.py list
python tools/midi2song.py remove some-song-id
python tools/build_library.py --limit 600              # refresh the Mutopia import
```

### Song format

```json
{"v":1,"id":"...","name":"...","artist":"...","tags":[],"duration":130.4,"count":905,"nps":3.1,
 "tracks":["RH","LH"],"notes":[dt_ms, midi_pitch, dur_ms, track, dt_ms, ...]}
```

`notes` is flattened, and each `dt` counts from the previous note's start, which keeps files small.
MIDI pitch 60 = middle C = `t`.

### Virtual Piano sheet syntax

`[tu]` = chord, tokens separated by spaces = one beat each, letters written together (`tyu`) share a beat,
`|` or `-` = one beat rest, `.` = half-beat rest, lines starting with `#` are comments.
