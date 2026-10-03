"""
PianoHub Discord bot - add songs to the shared library from Discord.

Slash commands
  /addsong   file:<.mid> [name] [artist] [tags]     convert a MIDI and publish it
  /addurl    url [name] [artist] [tags]              same, from a direct .mid link
  /addsheet  name sheet|file [bpm] [artist] [tags]   Virtual Piano letter sheet
  /editsong  song [name] [artist] [tags]
  /removesong song
  /songs     [query]                                 search the library
  /songinfo  song
  /library                                           stats + loader script

Storage: commits straight to your GitHub repo (library/index.json + library/songs/<id>.json),
which every PianoHub user downloads on launch. Set STORAGE=local to write into ../library instead.
"""
from __future__ import annotations

import asyncio
import base64
import json
import os
import sys
import time

import aiohttp
import discord
from discord import app_commands

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
from pianolib import (  # noqa: E402
    Library, MidiError, index_entry, make_song, parse_midi, parse_sheet, slugify, song_json,
)


def load_env(path):
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    os.environ.setdefault(k.strip(), v.strip().strip('"'))


load_env(os.path.join(HERE, ".env"))

TOKEN = os.environ.get("DISCORD_TOKEN", "")
GUILD_ID = int(os.environ.get("GUILD_ID") or 0)
EDITOR_ROLE_IDS = {int(x) for x in os.environ.get("EDITOR_ROLE_IDS", "").replace(" ", "").split(",") if x}
STORAGE = os.environ.get("STORAGE", "github").lower()
GH_TOKEN = os.environ.get("GITHUB_TOKEN", "")
GH_REPO = os.environ.get("GITHUB_REPO", "")  # owner/name
GH_BRANCH = os.environ.get("GITHUB_BRANCH", "main")
LIB_PATH = os.environ.get("LIBRARY_PATH", "library").strip("/")
MAX_MIDI_BYTES = int(os.environ.get("MAX_MIDI_KB", "1024")) * 1024
MAX_SECONDS = float(os.environ.get("MAX_SONG_SECONDS", "900"))
ACCENT = 0x7C5CFF


def stars(nps: float) -> str:
    n = 1 if nps < 2.5 else 2 if nps < 4.5 else 3 if nps < 6.5 else 4 if nps < 9 else 5
    return "●" * n + "○" * (5 - n)


def fmt_time(sec: float) -> str:
    sec = int(sec)
    return f"{sec // 60}:{sec % 60:02d}"


# --------------------------------------------------------------------------- storage backends

class LocalStore:
    """Writes into the repo's library/ folder (push it yourself)."""

    def __init__(self):
        self.lib = Library(os.path.join(HERE, "..", LIB_PATH))

    async def index(self):
        return self.lib.index

    async def put_song(self, song, message, replace=False):
        entry = self.lib.add(song, replace=replace)
        self.lib.save()
        return entry

    async def update_entry(self, song_id, mutate, message):
        path = os.path.join(self.lib.songs_dir, song_id + ".json")
        with open(path, encoding="utf-8") as f:
            song = json.load(f)
        mutate(song)
        return await self.put_song(song, message, replace=True)

    async def remove(self, song_id, message):
        ok = self.lib.remove(song_id)
        self.lib.save()
        return ok

    async def close(self):
        pass


class GitHubStore:
    """Commits song + index together in one commit via the Git Data API."""

    API = "https://api.github.com"

    def __init__(self):
        if not (GH_TOKEN and GH_REPO):
            raise SystemExit("Set GITHUB_TOKEN and GITHUB_REPO in bot/.env (or STORAGE=local)")
        self.session: aiohttp.ClientSession | None = None
        self.lock = asyncio.Lock()
        self._index = None
        self._index_at = 0.0

    async def _s(self):
        if self.session is None or self.session.closed:
            self.session = aiohttp.ClientSession(headers={
                "Authorization": f"Bearer {GH_TOKEN}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "PianoHub-bot",
            })
        return self.session

    async def _req(self, method, path, **kw):
        s = await self._s()
        async with s.request(method, self.API + path, **kw) as r:
            body = await r.text()
            if r.status >= 400:
                raise RuntimeError(f"GitHub {method} {path} -> {r.status}: {body[:300]}")
            return json.loads(body) if body and r.headers.get("Content-Type", "").startswith("application/json") else body

    async def _read_index(self, ref):
        s = await self._s()
        url = f"{self.API}/repos/{GH_REPO}/contents/{LIB_PATH}/index.json?ref={ref}"
        async with s.get(url, headers={"Accept": "application/vnd.github.raw+json"}) as r:
            if r.status == 404:
                return {"v": 1, "name": "PianoHub Library", "updated": 0, "songs": []}
            if r.status >= 400:
                raise RuntimeError(f"cannot read index.json: {r.status}")
            return json.loads(await r.text())

    async def index(self):
        if self._index is None or time.time() - self._index_at > 60:
            self._index = await self._read_index(GH_BRANCH)
            self._index_at = time.time()
        return self._index

    async def _commit(self, build, message):
        """build(index) -> (files{path: content|None}, result). Retries on races."""
        async with self.lock:
            for attempt in range(4):
                ref = await self._req("GET", f"/repos/{GH_REPO}/git/ref/heads/{GH_BRANCH}")
                head = ref["object"]["sha"]
                commit = await self._req("GET", f"/repos/{GH_REPO}/git/commits/{head}")
                index = await self._read_index(head)
                files, result = build(index)
                if not files:
                    return result  # nothing changed
                index["songs"].sort(key=lambda e: (e["artist"].lower(), e["name"].lower()))
                index["updated"] = int(time.time())
                files[f"{LIB_PATH}/index.json"] = json.dumps(index, separators=(",", ":"), ensure_ascii=False)
                tree = []
                for path, content in files.items():
                    item = {"path": path, "mode": "100644", "type": "blob"}
                    if content is None:
                        item["sha"] = None
                    else:
                        item["content"] = content
                    tree.append(item)
                new_tree = await self._req("POST", f"/repos/{GH_REPO}/git/trees",
                                           json={"base_tree": commit["tree"]["sha"], "tree": tree})
                new_commit = await self._req("POST", f"/repos/{GH_REPO}/git/commits",
                                             json={"message": message, "tree": new_tree["sha"], "parents": [head]})
                try:
                    await self._req("PATCH", f"/repos/{GH_REPO}/git/refs/heads/{GH_BRANCH}",
                                    json={"sha": new_commit["sha"]})
                except RuntimeError as e:
                    if "422" in str(e) and attempt < 3:
                        await asyncio.sleep(1 + attempt)
                        continue
                    raise
                self._index, self._index_at = index, time.time()
                return result
        raise RuntimeError("could not commit after retries")

    async def put_song(self, song, message, replace=False):
        def build(index):
            ids = {e["id"] for e in index["songs"]}
            if not replace and song["id"] in ids:
                base, i = song["id"], 2
                while f"{base}-{i}" in ids:
                    i += 1
                song["id"] = f"{base}-{i}"
            raw = song_json(song)
            entry = index_entry(song, raw)
            index["songs"] = [e for e in index["songs"] if e["id"] != song["id"]] + [entry]
            return {f"{LIB_PATH}/songs/{song['id']}.json": raw}, entry
        return await self._commit(build, message)

    async def update_entry(self, song_id, mutate, message):
        s = await self._s()
        url = f"{self.API}/repos/{GH_REPO}/contents/{LIB_PATH}/songs/{song_id}.json?ref={GH_BRANCH}"
        async with s.get(url, headers={"Accept": "application/vnd.github.raw+json"}) as r:
            if r.status >= 400:
                raise RuntimeError("song file not found")
            song = json.loads(await r.text())
        mutate(song)
        return await self.put_song(song, message, replace=True)

    async def remove(self, song_id, message):
        def build(index):
            before = len(index["songs"])
            index["songs"] = [e for e in index["songs"] if e["id"] != song_id]
            if len(index["songs"]) == before:
                return {}, False
            return {f"{LIB_PATH}/songs/{song_id}.json": None}, True
        return await self._commit(build, message)

    async def close(self):
        if self.session:
            await self.session.close()


store = LocalStore() if STORAGE == "local" else GitHubStore()

# --------------------------------------------------------------------------- bot

intents = discord.Intents.default()
client = discord.Client(intents=intents)
tree = app_commands.CommandTree(client)


def is_editor(inter: discord.Interaction) -> bool:
    m = inter.user
    if not isinstance(m, discord.Member):
        return False
    if m.guild_permissions.manage_guild:
        return True
    return bool(EDITOR_ROLE_IDS & {r.id for r in m.roles})


def editors_only():
    async def pred(inter: discord.Interaction):
        if is_editor(inter):
            return True
        raise app_commands.CheckFailure("You need a library editor role to do that.")
    return app_commands.check(pred)


def song_embed(entry, title="Added to the library", extra=None):
    e = discord.Embed(title=title, description=f"**{entry['name']}**\n{entry['artist']}", color=ACCENT)
    e.add_field(name="Length", value=fmt_time(entry["duration"]))
    e.add_field(name="Notes", value=str(entry["count"]))
    e.add_field(name="Difficulty", value=f"{stars(entry['nps'])}  ({entry['nps']} n/s)")
    if entry.get("tags"):
        e.add_field(name="Tags", value=", ".join(entry["tags"]), inline=False)
    e.set_footer(text=f"id: {entry['id']}" + (f"  ·  {extra}" if extra else ""))
    return e


def split_tags(tags: str | None):
    return [t for t in (tags or "").replace(";", ",").split(",") if t.strip()]


INSTRUMENTS = [app_commands.Choice(name="Piano", value="piano"), app_commands.Choice(name="Guitar", value="guitar")]


async def publish_midi(inter, data: bytes, filename: str, name, artist, tags, instrument="piano"):
    try:
        parsed = await asyncio.to_thread(parse_midi, data)
    except (MidiError, Exception) as e:  # noqa: BLE001
        return await inter.followup.send(f"❌ Couldn't read that MIDI: `{e}`")
    if not parsed.notes:
        return await inter.followup.send("❌ That MIDI has no playable notes.")
    name = (name or parsed.title or os.path.splitext(filename)[0].replace("_", " ")).strip()[:100]
    artist = (artist or "Unknown").strip()[:80]
    tag_list = split_tags(tags) + (["guitar"] if instrument == "guitar" else [])
    song = make_song(parsed.notes, name, artist, tag_list, tracks=parsed.track_names, bpm=parsed.bpm, programs=parsed.track_programs,
                     added_by=str(inter.user), source="discord")
    if song["duration"] > MAX_SECONDS:
        return await inter.followup.send(f"❌ Too long ({fmt_time(song['duration'])}). Limit is {fmt_time(MAX_SECONDS)}.")
    entry = await store.put_song(song, f"Add {artist} - {name} (via Discord, {inter.user})")
    note = f"{len(parsed.track_names)} track(s)"
    await inter.followup.send(embed=song_embed(entry, extra=note + "  ·  shows up next time PianoHub loads"))


@tree.command(description="Add a MIDI file to the PianoHub library")
@app_commands.describe(file=".mid file", name="Song name", artist="Artist / composer", tags="Comma separated, e.g. anime,pop",
                       instrument="Guitar songs show up in PianoHub's Guitar tab")
@app_commands.choices(instrument=INSTRUMENTS)
@editors_only()
async def addsong(inter: discord.Interaction, file: discord.Attachment, name: str | None = None,
                  artist: str | None = None, tags: str | None = None, instrument: str = "piano"):
    if not file.filename.lower().endswith((".mid", ".midi")):
        return await inter.response.send_message("❌ Attach a `.mid` file.", ephemeral=True)
    if file.size > MAX_MIDI_BYTES:
        return await inter.response.send_message("❌ File is too big.", ephemeral=True)
    await inter.response.defer(thinking=True)
    await publish_midi(inter, await file.read(), file.filename, name, artist, tags, instrument)


@tree.command(description="Add a MIDI from a direct download link")
@app_commands.choices(instrument=INSTRUMENTS)
@editors_only()
async def addurl(inter: discord.Interaction, url: str, name: str | None = None, artist: str | None = None,
                 tags: str | None = None, instrument: str = "piano"):
    if not url.startswith(("http://", "https://")):
        return await inter.response.send_message("❌ That's not a link.", ephemeral=True)
    await inter.response.defer(thinking=True)
    try:
        async with aiohttp.ClientSession() as s, s.get(url, timeout=aiohttp.ClientTimeout(total=20)) as r:
            if r.status != 200:
                return await inter.followup.send(f"❌ Download failed ({r.status}).")
            data = await r.content.read(MAX_MIDI_BYTES + 1)
    except Exception as e:  # noqa: BLE001
        return await inter.followup.send(f"❌ Download failed: `{e}`")
    if len(data) > MAX_MIDI_BYTES:
        return await inter.followup.send("❌ File is too big.")
    await publish_midi(inter, data, url.rsplit("/", 1)[-1].split("?")[0], name, artist, tags, instrument)


@tree.command(description="Add a Virtual Piano letter sheet, e.g. [tu] y t | ...")
@app_commands.describe(sheet="The letters (or attach a .txt)", bpm="Tempo: one space-separated token = one beat")
@editors_only()
async def addsheet(inter: discord.Interaction, name: str, sheet: str | None = None, file: discord.Attachment | None = None,
                   bpm: app_commands.Range[int, 30, 600] = 120, artist: str | None = None, tags: str | None = None):
    if file:
        text = (await file.read()).decode("utf-8", "replace")
    elif sheet:
        text = sheet.replace(" / ", "\n")
    else:
        return await inter.response.send_message("❌ Give a `sheet` or attach a .txt file.", ephemeral=True)
    await inter.response.defer(thinking=True)
    notes = parse_sheet(text, bpm)
    if not notes:
        return await inter.followup.send("❌ No notes found in that sheet.")
    song = make_song(notes, name[:100], (artist or "Unknown")[:80], split_tags(tags) + ["sheet"], bpm=bpm,
                     added_by=str(inter.user), source="discord")
    entry = await store.put_song(song, f"Add sheet {name} (via Discord, {inter.user})")
    await inter.followup.send(embed=song_embed(entry))


async def song_autocomplete(inter: discord.Interaction, current: str):
    idx = await store.index()
    q = current.lower()
    out = []
    for e in idx["songs"]:
        label = f"{e['name']} - {e['artist']}"
        if q in label.lower() or q in e["id"]:
            out.append(app_commands.Choice(name=label[:100], value=e["id"]))
            if len(out) >= 25:
                break
    return out


@tree.command(description="Remove a song from the library")
@app_commands.autocomplete(song=song_autocomplete)
@editors_only()
async def removesong(inter: discord.Interaction, song: str):
    await inter.response.defer(thinking=True)
    ok = await store.remove(song, f"Remove {song} (via Discord, {inter.user})")
    await inter.followup.send(f"🗑️ Removed `{song}`." if ok else f"❌ No song with id `{song}`.")


@tree.command(description="Rename / retag a song")
@app_commands.autocomplete(song=song_autocomplete)
@editors_only()
async def editsong(inter: discord.Interaction, song: str, name: str | None = None, artist: str | None = None,
                   tags: str | None = None):
    await inter.response.defer(thinking=True)

    def mutate(s):
        if name:
            s["name"] = name[:100]
        if artist:
            s["artist"] = artist[:80]
        if tags is not None:
            s["tags"] = sorted({t.strip().lower() for t in split_tags(tags)})
    try:
        entry = await store.update_entry(song, mutate, f"Edit {song} (via Discord, {inter.user})")
    except Exception as e:  # noqa: BLE001
        return await inter.followup.send(f"❌ {e}")
    await inter.followup.send(embed=song_embed(entry, title="Song updated"))


@tree.command(description="Search the PianoHub library")
async def songs(inter: discord.Interaction, query: str | None = None):
    idx = await store.index()
    words = (query or "").lower().split()
    hits = [e for e in idx["songs"]
            if all(w in f"{e['name']} {e['artist']} {' '.join(e.get('tags', []))}".lower() for w in words)]
    if not hits:
        return await inter.response.send_message("No songs found.", ephemeral=True)
    lines = [f"`{fmt_time(e['duration'])}` **{e['name']}** - {e['artist']}  {stars(e['nps'])}" for e in hits[:20]]
    emb = discord.Embed(title=f"{len(hits)} song(s)" + (f" for “{query}”" if query else ""), description="\n".join(lines), color=ACCENT)
    if len(hits) > 20:
        emb.set_footer(text=f"…and {len(hits) - 20} more. Narrow your search.")
    await inter.response.send_message(embed=emb)


@tree.command(description="Show details about a song")
@app_commands.autocomplete(song=song_autocomplete)
async def songinfo(inter: discord.Interaction, song: str):
    idx = await store.index()
    entry = next((e for e in idx["songs"] if e["id"] == song), None)
    if not entry:
        return await inter.response.send_message("Not found.", ephemeral=True)
    extra = f"added by {entry['addedBy']}" if entry.get("addedBy") else None
    await inter.response.send_message(embed=song_embed(entry, title="Song info", extra=extra))


@tree.command(description="Library stats and how to load PianoHub")
async def library(inter: discord.Interaction):
    idx = await store.index()
    total = len(idx["songs"])
    hours = sum(e["duration"] for e in idx["songs"]) / 3600
    artists = len({e["artist"] for e in idx["songs"]})
    emb = discord.Embed(title="🎹 PianoHub library", color=ACCENT,
                        description=f"**{total}** songs · **{artists}** artists · **{hours:.1f} h** of music")
    if STORAGE != "local":
        raw = f"https://raw.githubusercontent.com/{GH_REPO}/{GH_BRANCH}/PianoHub.lua"
        emb.add_field(name="Loader", value=f"```lua\nloadstring(game:HttpGet(\"{raw}\"))()\n```", inline=False)
    await inter.response.send_message(embed=emb)


@tree.error
async def on_app_error(inter: discord.Interaction, error: app_commands.AppCommandError):
    msg = str(error) if isinstance(error, app_commands.CheckFailure) else f"Something went wrong: `{error}`"
    if inter.response.is_done():
        await inter.followup.send(f"❌ {msg}", ephemeral=True)
    else:
        await inter.response.send_message(f"❌ {msg}", ephemeral=True)
    if not isinstance(error, app_commands.CheckFailure):
        print("command error:", repr(error), file=sys.stderr)


@client.event
async def on_ready():
    if GUILD_ID:
        g = discord.Object(id=GUILD_ID)
        tree.copy_global_to(guild=g)
        await tree.sync(guild=g)
    else:
        await tree.sync()
    print(f"PianoHub bot online as {client.user} · storage={STORAGE}")


if __name__ == "__main__":
    if not TOKEN:
        raise SystemExit("Set DISCORD_TOKEN in bot/.env")
    client.run(TOKEN)
