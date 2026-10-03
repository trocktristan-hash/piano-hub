--[[
	PianoHub  -  autoplay piano for Roblox (Virtual Piano 61-key layout)

	* Song library loaded from a GitHub repo every launch (songs added by the Discord bot show up automatically)
	* Local songs: drop .mid files in  workspace/PianoHub/midi/  or .json songs in  workspace/PianoHub/songs/
	* Built-in MIDI parser, Virtual Piano sheet import, URL import
	* Humanizer: timing jitter, chord rolling, tempo drift, phrase hesitation, missed / wrong notes
	  with corrections, 10-finger limit, hold-length variance + presets
	* Speed, transpose (auto), out-of-range handling (fold / drop / 88-key ctrl), tap or hold notes,
	  hand + track filters, chord cap, queue, shuffle, loop, favorites, recents, seek bar, live keyboard
	* Perform tab: warm-ups, natural song transitions, built-in improvisation; floating LIVE panel for real-time tweaks
	* Hotkeys (rebindable): RightControl = hide UI, F2 = play/pause, F3 = stop, F4 = next, F1 = previous,
	  F5 = hesitate, F6 = flourish, F7 = big ending, F8 = live panel

	Set CONFIG.LibraryURL below to your own repo's raw "library/" folder (see README.md).
]]

local CONFIG = {
	LibraryURL = "https://raw.githubusercontent.com/trocktristan-hash/piano-hub/main/library/",
	Folder = "PianoHub",
	Version = "1.0.0",
}

---------------------------------------------------------------------------------------------------
-- bootstrap
---------------------------------------------------------------------------------------------------
local genv = (getgenv and getgenv()) or _G
if genv.PianoHub and type(genv.PianoHub.Unload) == "function" then
	pcall(genv.PianoHub.Unload)
end

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local VIM = game:GetService("VirtualInputManager")
local LP = Players.LocalPlayer

local Hub = { conns = {} }
genv.PianoHub = Hub

local function bind(signal, fn)
	local c = signal:Connect(fn)
	table.insert(Hub.conns, c)
	return c
end

---------------------------------------------------------------------------------------------------
-- executor compatibility: files + http
---------------------------------------------------------------------------------------------------
local function isfn(f)
	return type(f) == "function"
end

local FS = { ok = isfn(writefile) and isfn(readfile) }

function FS.exists(p)
	if not FS.ok or not isfn(isfile) then
		return false
	end
	local ok, r = pcall(isfile, p)
	return ok and r == true
end

function FS.read(p)
	if not FS.exists(p) then
		return nil
	end
	local ok, r = pcall(readfile, p)
	return ok and r or nil
end

function FS.write(p, content)
	if FS.ok then
		pcall(writefile, p, content)
	end
end

function FS.mkdir(p)
	if not isfn(makefolder) then
		return
	end
	local ok, exists = pcall(function()
		return isfolder and isfolder(p)
	end)
	if not (ok and exists) then
		pcall(makefolder, p)
	end
end

function FS.list(p)
	if isfn(listfiles) then
		local ok, r = pcall(listfiles, p)
		if ok and type(r) == "table" then
			return r
		end
	end
	return {}
end

function FS.delete(p)
	if isfn(delfile) and FS.exists(p) then
		pcall(delfile, p)
	end
end

function FS.basename(p)
	return (p:match("([^/\\]+)$") or p)
end

local ROOT = CONFIG.Folder
for _, d in ipairs({ ROOT, ROOT .. "/cache", ROOT .. "/songs", ROOT .. "/midi", ROOT .. "/guitar" }) do
	FS.mkdir(d)
end

local function validBody(b)
	return type(b) == "string" and b ~= "" and not b:match("^%s*404: Not Found") and not b:match("^%s*400: Invalid request")
end

-- returns body or nil, reason. Tries every HTTP method executors commonly expose.
local function httpGet(url)
	local reasons = {}
	local ok, res = pcall(function()
		return game:HttpGet(url)
	end)
	if ok and validBody(res) then
		return res
	end
	reasons[#reasons + 1] = "HttpGet: " .. (ok and ("bad response " .. tostring(res):sub(1, 40)) or tostring(res):sub(1, 80))
	local req = (syn and syn.request) or (http and http.request) or (fluxus and fluxus.request) or http_request or request
	if req then
		local ok2, r = pcall(req, { Url = url, Method = "GET" })
		if ok2 and type(r) == "table" and (r.StatusCode == 200 or r.Success == true) and validBody(r.Body) then
			return r.Body
		end
		reasons[#reasons + 1] = "request: " .. (ok2 and type(r) == "table" and ("status " .. tostring(r.StatusCode)) or tostring(r):sub(1, 80))
	end
	return nil, table.concat(reasons, " | ")
end

local function jdecode(s)
	if type(s) ~= "string" then
		return nil, "no data"
	end
	if s:sub(1, 3) == string.char(239, 187, 191) then
		s = s:sub(4) -- strip UTF-8 BOM
	end
	local ok, r = pcall(HttpService.JSONDecode, HttpService, s)
	if ok then
		return r
	end
	return nil, tostring(r)
end

local function jencode(t)
	local ok, r = pcall(HttpService.JSONEncode, HttpService, t)
	return ok and r or nil
end

---------------------------------------------------------------------------------------------------
-- settings
---------------------------------------------------------------------------------------------------
local S = {
	LibraryURL = CONFIG.LibraryURL,
	Speed = 1,
	Transpose = 0,
	AutoTranspose = true,
	RangeMode = "Fold", -- Fold | Drop | 88-Key
	NoteMode = "Tap", -- Tap | Hold
	TapMs = 35,
	Hand = "Both", -- Both | Right | Left
	Split = 60,
	MaxChord = 0,
	MinRepeat = 25,
	Loop = "Off", -- Off | One | All
	Shuffle = false,
	Autoplay = true,
	Countdown = 2,
	PauseTyping = true,
	Notify = true,
	Accent = "Violet",
	Scale = 1,
	Sort = "A-Z",
	Keys = { Toggle = "RightControl", PlayPause = "F2", Stop = "F3", Next = "F4", Prev = "F1",
		Hesitate = "F5", Flourish = "F6", Ending = "F7", Live = "F8", Warmup = "" },
	Improv = { Enabled = false, Amount = 35, Ornaments = true, Fills = true, Octaves = true, Arpeggios = true, Intro = false, Ending = true },
	Transition = "Random",
	Instrument = "Piano", -- Piano | Guitar
	Guitar = { Tuning = "Standard", TracksOnly = true, Strum = true, StrumMs = 14, Stretch = 4, Vibrato = false, PalmMute = false, AutoSwitch = true },
	WarmupPlay = true,
	LiveAuto = true,
	Human = {
		Enabled = false,
		Preset = "Natural",
		Jitter = 10,
		Roll = 16,
		Drift = 3,
		Miss = 0.4,
		Wrong = 0.3,
		Correct = true,
		HoldVar = 15,
		Hesitate = 70,
		Fingers = true,
	},
	Favorites = {},
	Recent = {},
}

local SETTINGS_PATH = ROOT .. "/settings.json"

local function merge(dst, src)
	for k, v in pairs(src) do
		local d = dst[k]
		if type(d) == "table" and type(v) == "table" and next(d) ~= nil and #d == 0 then
			merge(d, v)
		elseif d ~= nil and type(d) == type(v) then
			dst[k] = v
		end
	end
end

do
	local saved = jdecode(FS.read(SETTINGS_PATH))
	if type(saved) == "table" then
		merge(S, saved)
	end
	if S.LibraryURL == "" or S.LibraryURL:find("YOUR_GITHUB_USER", 1, true) then
		S.LibraryURL = CONFIG.LibraryURL
	end
end

local saveQueued = false
local function saveSettings()
	if saveQueued then
		return
	end
	saveQueued = true
	task.delay(0.6, function()
		saveQueued = false
		local s = jencode(S)
		if s then
			FS.write(SETTINGS_PATH, s)
		end
	end)
end

---------------------------------------------------------------------------------------------------
-- keys: Virtual Piano layout  (C2 .. C7)
---------------------------------------------------------------------------------------------------
local VP_KEYS = "1!2@34$5%6^78*9(0qQwWeErtTyYuiIoOpPasSdDfgGhHjJklLzZxcCvVbBnm"
local VP_LOW, VP_HIGH = 36, 96
local LOW_EXT = "1234567890qwert" -- A0..B1  (Ctrl + key, 88-key pianos)
local HIGH_EXT = "yuiopasdfghj" -- C#7..C8 (Ctrl + key)
local BLACK = { [1] = true, [3] = true, [6] = true, [8] = true, [10] = true }
local NOTE_NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }

local DIGITS = { ["1"] = "One", ["2"] = "Two", ["3"] = "Three", ["4"] = "Four", ["5"] = "Five",
	["6"] = "Six", ["7"] = "Seven", ["8"] = "Eight", ["9"] = "Nine", ["0"] = "Zero" }
local SYMBOLS = { ["!"] = "One", ["@"] = "Two", ["#"] = "Three", ["$"] = "Four", ["%"] = "Five",
	["^"] = "Six", ["&"] = "Seven", ["*"] = "Eight", ["("] = "Nine", [")"] = "Zero" }

local PUNCT = { -- char -> KeyCode name, needs shift
	["`"] = { "Backquote", false }, ["~"] = { "Backquote", true }, ["-"] = { "Minus", false }, ["_"] = { "Minus", true },
	["="] = { "Equals", false }, ["+"] = { "Equals", true }, ["["] = { "LeftBracket", false }, ["{"] = { "LeftBracket", true },
	["]"] = { "RightBracket", false }, ["}"] = { "RightBracket", true }, ["\\"] = { "BackSlash", false }, ["|"] = { "BackSlash", true },
	[";"] = { "Semicolon", false }, [":"] = { "Semicolon", true }, ["'"] = { "Quote", false }, ['"'] = { "Quote", true },
	[","] = { "Comma", false }, ["<"] = { "Comma", true }, ["."] = { "Period", false }, [">"] = { "Period", true },
	["/"] = { "Slash", false }, ["?"] = { "Slash", true },
}

local function charKey(c)
	if PUNCT[c] then
		return { code = Enum.KeyCode[PUNCT[c][1]], shift = PUNCT[c][2], char = c }
	end
	if DIGITS[c] then
		return { code = Enum.KeyCode[DIGITS[c]], shift = false, char = c }
	elseif SYMBOLS[c] then
		return { code = Enum.KeyCode[SYMBOLS[c]], shift = true, char = c }
	end
	return { code = Enum.KeyCode[c:upper()], shift = c ~= c:lower(), char = c }
end

local KEYS, EXT_KEYS, CHAR_TO_MIDI = {}, {}, {}
local Guitar = {} -- filled in after the key output section
for i = 1, #VP_KEYS do
	local c = VP_KEYS:sub(i, i)
	KEYS[VP_LOW + i - 1] = charKey(c)
	CHAR_TO_MIDI[c] = VP_LOW + i - 1
end
for i = 1, #LOW_EXT do
	local k = charKey(LOW_EXT:sub(i, i))
	k.ctrl = true
	EXT_KEYS[20 + i] = k
end
for i = 1, #HIGH_EXT do
	local k = charKey(HIGH_EXT:sub(i, i))
	k.ctrl = true
	EXT_KEYS[96 + i] = k
end

local function noteName(p)
	return NOTE_NAMES[p % 12 + 1] .. tostring(math.floor(p / 12) - 1)
end

-- pitch (already transposed) -> playable pitch, key   (nil when dropped)
local function resolvePitch(p)
	if S.Instrument == "Guitar" then
		return Guitar.resolve(p)
	end
	if p >= VP_LOW and p <= VP_HIGH then
		return p, KEYS[p]
	end
	if S.RangeMode == "88-Key" and EXT_KEYS[p] then
		return p, EXT_KEYS[p]
	end
	if S.RangeMode == "Drop" then
		return nil
	end
	while p < VP_LOW do
		p += 12
	end
	while p > VP_HIGH do
		p -= 12
	end
	return p, KEYS[p]
end

---------------------------------------------------------------------------------------------------
-- key output (VirtualInputManager)
---------------------------------------------------------------------------------------------------
local Keys = { held = {}, releases = {}, token = 0, recent = {} }
local SHIFT, CTRL = Enum.KeyCode.LeftShift, Enum.KeyCode.LeftControl

local function send(down, code)
	pcall(VIM.SendKeyEvent, VIM, down, code, false, game)
end

function Keys.press(k, holdSeconds)
	local code = k.code
	if Keys.held[code] then
		send(false, code) -- re-trigger a key that is still held
	end
	if k.shift then
		send(true, SHIFT)
	end
	if k.ctrl then
		send(true, CTRL)
	end
	send(true, code)
	if k.ctrl then
		send(false, CTRL)
	end
	if k.shift then
		send(false, SHIFT)
	end
	Keys.token += 1
	Keys.held[code] = Keys.token
	table.insert(Keys.recent, os.clock())
	if #Keys.recent > 400 then
		table.remove(Keys.recent, 1)
	end
	table.insert(Keys.releases, { at = os.clock() + holdSeconds, code = code, tok = Keys.token })
end

function Keys.update(now)
	local r = Keys.releases
	for i = #r, 1, -1 do
		local item = r[i]
		if now >= item.at then
			table.remove(r, i)
			if Keys.held[item.code] == item.tok then
				Keys.held[item.code] = nil
				send(false, item.code)
			end
		end
	end
end

function Keys.releaseAll()
	for code in pairs(Keys.held) do
		send(false, code)
	end
	Keys.held = {}
	Keys.releases = {}
	send(false, SHIFT)
	send(false, CTRL)
	Guitar.release()
end

---------------------------------------------------------------------------------------------------
-- guitar: 6 strings x 13 frets (0-12). Each keyboard row is one string, each key to the right +1 fret.
---------------------------------------------------------------------------------------------------
Guitar.ROWS = { -- low E .. high e
	"zxcvbnm,./<>?",
	"asdfghjkl;':\"",
	"qwertyuiop[]\\",
	"`1234567890-=",
	"QWERTYUIOP{}|",
	"~!@#$%^&*()_+",
}
Guitar.FRETS = 12
Guitar.TUNINGS = {
	["Standard"] = { 40, 45, 50, 55, 59, 64 },
	["Drop D"] = { 38, 45, 50, 55, 59, 64 },
	["Half step down"] = { 39, 44, 49, 54, 58, 63 },
	["Full step down"] = { 38, 43, 48, 53, 57, 62 },
	["Drop C"] = { 36, 43, 48, 53, 57, 62 },
	["Open G"] = { 38, 43, 50, 55, 59, 62 },
	["Open D"] = { 38, 45, 50, 54, 57, 62 },
	["DADGAD"] = { 38, 45, 50, 55, 57, 62 },
}
Guitar.TUNING_ORDER = { "Standard", "Drop D", "Half step down", "Full step down", "Drop C", "Open G", "Open D", "DADGAD" }
Guitar.keys = {}
Guitar.hand = 3
Guitar.vibUntil, Guitar.muteUntil = 0, 0
Guitar.vibDown, Guitar.muteDown = false, false

function Guitar.active()
	return S.Instrument == "Guitar"
end

function Guitar.tuning()
	return Guitar.TUNINGS[S.Guitar.Tuning] or Guitar.TUNINGS.Standard
end

function Guitar.range()
	local t = Guitar.tuning()
	return t[1], t[6] + Guitar.FRETS
end

function Guitar.key(s, f)
	local row = Guitar.keys[s]
	if not row then
		row = {}
		Guitar.keys[s] = row
	end
	if not row[f] then
		local k = charKey(Guitar.ROWS[s]:sub(f + 1, f + 1))
		k.string, k.fret = s, f
		row[f] = k
	end
	return row[f]
end

-- best single position for a pitch near where the hand currently is
function Guitar.place(p)
	local t = Guitar.tuning()
	local bestS, bestF, bestCost = nil, nil, math.huge
	for s = 1, 6 do
		local f = p - t[s]
		if f >= 0 and f <= Guitar.FRETS then
			local cost = (f == 0) and 0.5 or math.abs(f - Guitar.hand)
			if cost < bestCost then
				bestS, bestF, bestCost = s, f, cost
			end
		end
	end
	return bestS, bestF
end

-- resolvePitch() for guitar mode
function Guitar.resolve(p)
	local lo, hi = Guitar.range()
	if p < lo or p > hi then
		if S.RangeMode == "Drop" then
			return nil
		end
		while p < lo do
			p += 12
		end
		while p > hi do
			p -= 12
		end
	end
	local s, f = Guitar.place(p)
	if not s then
		return nil
	end
	return p, Guitar.key(s, f)
end

-- strings for a chord (notes sorted low -> high): strictly rising strings, frets 0..12,
-- fretted notes within `stretch` frets of each other, as close to the hand as possible
function Guitar.voice(notes, tun, hand, stretch)
	local n = #notes
	if n > 6 then
		return nil
	end
	local best, bestCost = nil, math.huge
	local pick = {}
	local function rec(k, minS)
		if k > n then
			local lo, hi, cost = 99, -1, 0
			for i = 1, n do
				local f = pick[i][2]
				if f > 0 then
					lo = math.min(lo, f)
					hi = math.max(hi, f)
					cost += math.abs(f - hand)
				else
					cost += 0.5
				end
			end
			if hi >= 0 and hi - lo > stretch then
				return
			end
			if cost < bestCost then
				bestCost = cost
				best = {}
				for i = 1, n do
					best[i] = { pick[i][1], pick[i][2] }
				end
			end
			return
		end
		for s = minS, 6 - (n - k) do
			local f = notes[k].p - tun[s]
			if f >= 0 and f <= Guitar.FRETS then
				pick[k] = { s, f }
				rec(k + 1, s + 1)
			end
		end
	end
	rec(1, 1)
	return best
end

-- give every event a string + fret, keep chords playable, strum them
function Guitar.assign(out)
	local G = S.Guitar
	local tun = Guitar.tuning()
	table.sort(out, function(a, b)
		return a.t < b.t
	end)
	local groups = {}
	for _, e in ipairs(out) do
		local g = groups[#groups]
		if g and e.t - g.t <= 30 then
			table.insert(g.notes, e)
		else
			groups[#groups + 1] = { t = e.t, notes = { e } }
		end
	end
	local res = {}
	local hand = 3
	local down, lastChordT = true, -1e9
	for _, g in ipairs(groups) do
		table.sort(g.notes, function(a, b)
			return a.p < b.p
		end)
		local notes, seen = {}, {}
		for _, e in ipairs(g.notes) do
			if not seen[e.p] then
				seen[e.p] = true
				notes[#notes + 1] = e
			end
		end
		while #notes > 6 do
			table.remove(notes, #notes - 1)
		end
		local best
		while #notes > 0 do
			best = Guitar.voice(notes, tun, hand, G.Stretch)
			if best then
				break
			end
			if #notes > 2 then
				table.remove(notes, #notes - 1) -- drop an inner voice, keep melody + bass
			else
				table.remove(notes, 1)
			end
		end
		if best then
			local sum, cnt = 0, 0
			for k, e in ipairs(notes) do
				local s, f = best[k][1], best[k][2]
				e.key, e.p = Guitar.key(s, f), tun[s] + f
				if f > 0 then
					sum += f
					cnt += 1
				end
				res[#res + 1] = e
			end
			if cnt > 0 then
				hand = hand * 0.4 + (sum / cnt) * 0.6
			end
			if G.Strum and #notes >= 3 then
				if g.t - lastChordT > 700 then
					down = true -- a new phrase starts with a downstroke
				end
				for k, e in ipairs(notes) do
					local rank = down and (k - 1) or (#notes - k)
					e.t = g.t + rank * G.StrumMs
				end
				down = not down
				lastChordT = g.t
			end
		end
	end
	Guitar.hand = hand
	return res
end

-- mute everything that isn't a guitar track (when the MIDI has any)
function Guitar.autoMute(song)
	local progs, names = song.programs or {}, song.tracks or {}
	local isGuitar, any = {}, false
	for t = 0, (song.trackCount or 1) - 1 do
		local prog = progs[t + 1]
		local name = (names[t + 1] or ""):lower()
		local g = (prog and prog >= 24 and prog <= 31) or name:find("guit") ~= nil or name:find("gtr") ~= nil
		isGuitar[t] = g
		any = any or g
	end
	local muted = {}
	if any then
		for t, g in pairs(isGuitar) do
			if not g then
				muted[t] = true
			end
		end
	end
	return muted
end

-- techniques: hold Ctrl for vibrato on long notes, Space to palm-mute short low notes
function Guitar.technique(e, now)
	local G = S.Guitar
	local len = e.d / 1000 / math.max(S.Speed, 0.05)
	local k = e.key
	if G.Vibrato and e.d >= 650 then
		Guitar.vibUntil = math.max(Guitar.vibUntil, now + len)
	end
	if G.PalmMute and k.string and k.string <= 3 and e.d <= 200 then
		Guitar.muteUntil = math.max(Guitar.muteUntil, now + len + 0.04)
	end
end

function Guitar.update(now)
	local wantV = now < Guitar.vibUntil
	if wantV ~= Guitar.vibDown then
		Guitar.vibDown = wantV
		send(wantV, CTRL)
	end
	local wantM = now < Guitar.muteUntil
	if wantM ~= Guitar.muteDown then
		Guitar.muteDown = wantM
		send(wantM, Enum.KeyCode.Space)
	end
end

function Guitar.release()
	Guitar.vibUntil, Guitar.muteUntil = 0, 0
	if Guitar.muteDown then
		send(false, Enum.KeyCode.Space)
	end
	Guitar.vibDown, Guitar.muteDown = false, false
end


---------------------------------------------------------------------------------------------------
-- song formats: library json, MIDI (binary), Virtual Piano sheets
---------------------------------------------------------------------------------------------------
local Songs = {}

-- notes are { start_ms, pitch, dur_ms, track }
function Songs.normalize(notes)
	table.sort(notes, function(a, b)
		if a[1] == b[1] then
			return a[2] < b[2]
		end
		return a[1] < b[1]
	end)
	local out, seen = {}, {}
	local t0 = notes[1] and notes[1][1] or 0
	for _, n in ipairs(notes) do
		local t = math.floor(n[1] - t0 + 0.5)
		local key = t * 200 + n[2]
		if not seen[key] then
			seen[key] = true
			out[#out + 1] = { t, n[2], math.max(20, math.floor(n[3] + 0.5)), n[4] or 0 }
		end
	end
	return out
end

function Songs.finish(song)
	local notes = song.notes
	local maxTrack, lastEnd = 0, 0
	local starts, lastStart = 0, -1000
	for _, n in ipairs(notes) do
		if n[4] > maxTrack then
			maxTrack = n[4]
		end
		if n[1] + n[3] > lastEnd then
			lastEnd = n[1] + n[3]
		end
		if n[1] - lastStart > 30 then
			starts += 1
			lastStart = n[1]
		end
	end
	song.trackCount = maxTrack + 1
	song.duration = lastEnd / 1000
	song.count = #notes
	song.nps = (#notes > 0) and starts / math.max(notes[#notes][1] / 1000, 1) or 0
	song.tracks = song.tracks or {}
	return song
end

function Songs.fromData(data, entry)
	if type(data) ~= "table" or type(data.notes) ~= "table" then
		error("song file has no notes")
	end
	local notes, flat = {}, data.notes
	if type(flat[1]) == "table" then -- nested { {t,p,d,tr}, ... }
		for _, n in ipairs(flat) do
			notes[#notes + 1] = { n[1], n[2], n[3] or 200, n[4] or 0 }
		end
		notes = Songs.normalize(notes)
	else -- flattened delta encoding
		local t = 0
		for i = 1, #flat, 4 do
			t += flat[i]
			notes[#notes + 1] = { t, flat[i + 1], flat[i + 2], flat[i + 3] or 0 }
		end
	end
	return Songs.finish({
		id = entry and entry.id or data.id or HttpService:GenerateGUID(false),
		name = data.name or (entry and entry.name) or "Untitled",
		artist = data.artist or (entry and entry.artist) or "Unknown",
		tracks = data.tracks,
		programs = data.programs,
		tags = data.tags,
		notes = notes,
	})
end

function Songs.parseMidi(data, name)
	local pos = 1
	local byte = string.byte
	local function u8()
		local b = byte(data, pos)
		pos += 1
		return b or 0
	end
	local function u16()
		local a, b = byte(data, pos, pos + 1)
		pos += 2
		return (a or 0) * 256 + (b or 0)
	end
	local function u32()
		local a, b, c, d = byte(data, pos, pos + 3)
		pos += 4
		return (((a or 0) * 256 + (b or 0)) * 256 + (c or 0)) * 256 + (d or 0)
	end
	local function vlq()
		local v = 0
		for _ = 1, 4 do
			local b = u8()
			v = v * 128 + (b % 128)
			if b < 128 then
				break
			end
		end
		return v
	end

	local hs = data:find("MThd", 1, true)
	if not hs then
		error("not a MIDI file")
	end
	pos = hs + 4
	local hlen = u32()
	u16() -- format
	local ntracks = u16()
	local division = u16()
	pos = hs + 8 + hlen
	local tpq, smpte = division, nil
	if division >= 0x8000 then
		local fps = 256 - math.floor(division / 256)
		smpte = 1000 / (fps * (division % 256))
		tpq = 1
	end
	if tpq == 0 then
		tpq = 480
	end

	local tempos = { { 0, 500000 } }
	local raw, pedals, names, programs = {}, {}, {}, {}
	local order = 0
	for tr = 1, ntracks do
		local cs = data:find("MTrk", pos, true)
		if not cs then
			break
		end
		pos = cs + 4
		local len = u32()
		local stop = math.min(pos + len, #data + 1)
		local tick, status = 0, 0
		while pos < stop do
			tick += vlq()
			if pos >= stop then
				break
			end
			local b = byte(data, pos)
			if b >= 0x80 then
				status = b
				pos += 1
			elseif status == 0 then
				break
			end
			if status == 0xFF then
				local mtype = u8()
				local l = vlq()
				if mtype == 0x51 and l == 3 then
					local a, b2, c = byte(data, pos, pos + 2)
					table.insert(tempos, { tick, a * 65536 + b2 * 256 + c })
				elseif mtype == 0x03 and not names[tr] then
					names[tr] = data:sub(pos, pos + l - 1)
				end
				pos += l
				status = 0
				if mtype == 0x2F then
					break
				end
			elseif status == 0xF0 or status == 0xF7 then
				pos += vlq()
				status = 0
			else
				local hi = status - status % 16
				local ch = status % 16
				if hi == 0x80 or hi == 0x90 then
					local p, v = u8(), u8()
					if ch ~= 9 then
						order += 1
						raw[#raw + 1] = { tick, order, tr, ch, p, hi == 0x90 and v > 0 }
					end
				elseif hi == 0xB0 then
					local c, v = u8(), u8()
					if c == 64 then
						pedals[#pedals + 1] = { tick, ch, v >= 64 }
					end
				elseif hi == 0xA0 or hi == 0xE0 then
					pos += 2
				elseif hi == 0xC0 then
					local prog = u8()
					local id = tr * 32 + ch
					programs[id] = programs[id] or prog
					programs[-1 - ch] = programs[-1 - ch] or prog
				else
					pos += 1
				end
			end
		end
		pos = stop
	end

	table.sort(tempos, function(a, b)
		return a[1] < b[1]
	end)
	local segTick, segMs, segUs = {}, {}, {}
	local ms, lastTick, lastUs = 0, 0, 500000
	for _, tp in ipairs(tempos) do
		ms += (tp[1] - lastTick) / tpq * lastUs / 1000
		segTick[#segTick + 1], segMs[#segMs + 1], segUs[#segUs + 1] = tp[1], ms, tp[2]
		lastTick, lastUs = tp[1], tp[2]
	end
	local function toMs(tick)
		if smpte then
			return tick * smpte
		end
		local lo, hi = 1, #segTick
		while lo < hi do
			local mid = math.floor((lo + hi + 1) / 2)
			if segTick[mid] <= tick then
				lo = mid
			else
				hi = mid - 1
			end
		end
		return segMs[lo] + (tick - segTick[lo]) / tpq * segUs[lo] / 1000
	end

	-- sustain pedal: lengthen notes released while the pedal is down
	table.sort(pedals, function(a, b)
		return a[1] < b[1]
	end)
	local pedalIv, downAt = {}, {}
	for _, pd in ipairs(pedals) do
		local t, ch = toMs(pd[1]), pd[2]
		if pd[3] and not downAt[ch] then
			downAt[ch] = t
		elseif not pd[3] and downAt[ch] then
			pedalIv[ch] = pedalIv[ch] or {}
			table.insert(pedalIv[ch], { downAt[ch], t })
			downAt[ch] = nil
		end
	end
	local function pedalEnd(ch, e)
		for _, iv in ipairs(pedalIv[ch] or {}) do
			if iv[1] <= e and e < iv[2] then
				return math.min(iv[2], e + 3000)
			end
		end
		return e
	end

	table.sort(raw, function(a, b)
		if a[1] == b[1] then
			return a[2] < b[2]
		end
		return a[1] < b[1]
	end)
	local open, notes, usedTracks = {}, {}, {}
	for _, r in ipairs(raw) do
		local key = r[3] * 4096 + r[4] * 128 + r[5]
		if r[6] then
			open[key] = open[key] or {}
			table.insert(open[key], r[1])
		elseif open[key] and #open[key] > 0 then
			local st = table.remove(open[key], 1)
			local s = toMs(st)
			local id = r[3] * 32 + r[4]
			notes[#notes + 1] = { s, r[5], math.max(pedalEnd(r[4], toMs(r[1])) - s, 20), id }
			usedTracks[id] = true
		end
	end
	for key, starts in pairs(open) do
		for _, st in ipairs(starts) do
			local id = math.floor(key / 128) -- track * 32 + channel
			notes[#notes + 1] = { toMs(st), key % 128, 400, id }
			usedTracks[id] = true
		end
	end
	if #notes == 0 then
		error("MIDI has no playable notes")
	end
	local trackList = {}
	for t in pairs(usedTracks) do
		trackList[#trackList + 1] = t
	end
	table.sort(trackList)
	local remap, trackNames, trackProgs = {}, {}, {}
	for i, t in ipairs(trackList) do
		remap[t] = i - 1
		trackNames[i] = names[math.floor(t / 32)] or ""
		trackProgs[i] = programs[t] or programs[-1 - t % 32] or 0
	end
	for _, n in ipairs(notes) do
		n[4] = remap[n[4]]
	end
	return Songs.finish({
		id = "midi:" .. (name or "song"),
		name = name or "MIDI song",
		artist = "Local MIDI",
		tracks = trackNames,
		programs = trackProgs,
		notes = Songs.normalize(notes),
	})
end

-- Virtual Piano sheet: tokens separated by spaces are one beat; glued letters ("tyu") share a beat;
-- [abc] = chord; | or - = one beat rest; . = half beat rest. Lines starting with # are comments.
function Songs.parseSheet(text, bpm, name)
	local beat = 60000 / math.max(bpm or 120, 1)
	local t, notes = 0, {}
	local function isBreak(c)
		return c:match("%s") or c == "|" or c == "-" or c == "." or c == "[" or c == "]"
	end
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		line = line:gsub("^%s+", "")
		if line ~= "" and line:sub(1, 1) ~= "#" and line:sub(1, 2) ~= "//" then
			local i, n = 1, #line
			while i <= n do
				local c = line:sub(i, i)
				if c:match("%s") or c == "]" then
					i += 1
				elseif c == "|" or c == "-" then
					t += beat
					i += 1
				elseif c == "." then
					t += beat / 2
					i += 1
				elseif c == "[" then
					local j = line:find("]", i + 1, true) or (n + 1)
					local any = false
					for ch in line:sub(i + 1, j - 1):gmatch(".") do
						if CHAR_TO_MIDI[ch] then
							notes[#notes + 1] = { t, CHAR_TO_MIDI[ch], beat * 0.9, 0 }
							any = true
						end
					end
					if any then
						t += beat
					end
					i = j + 1
				else
					local run = {}
					while i <= n do
						c = line:sub(i, i)
						if isBreak(c) then
							break
						end
						if CHAR_TO_MIDI[c] then
							run[#run + 1] = CHAR_TO_MIDI[c]
						end
						i += 1
					end
					local step = #run > 1 and beat / #run or beat
					for _, p in ipairs(run) do
						notes[#notes + 1] = { t, p, step * 0.9, 0 }
						t += step
					end
				end
			end
		end
	end
	if #notes == 0 then
		error("no notes found in sheet")
	end
	return Songs.finish({
		id = "sheet:" .. HttpService:GenerateGUID(false),
		name = name or "Sheet",
		artist = "Sheet",
		notes = Songs.normalize(notes),
	})
end

function Songs.encode(song)
	local flat, prev = {}, 0
	for _, n in ipairs(song.notes) do
		flat[#flat + 1] = n[1] - prev
		flat[#flat + 1] = n[2]
		flat[#flat + 1] = n[3]
		flat[#flat + 1] = n[4]
		prev = n[1]
	end
	return jencode({ v = 1, name = song.name, artist = song.artist, tracks = song.tracks, programs = song.programs,
		tags = song.tags, duration = song.duration, count = song.count, nps = song.nps, notes = flat })
end

---------------------------------------------------------------------------------------------------
-- library
---------------------------------------------------------------------------------------------------
local BUILTIN = {
	{ id = "builtin:ode-to-joy", name = "Ode to Joy", artist = "Beethoven", bpm = 150, tags = { "built-in", "easy" },
		sheet = "[8u] u i o | [9o] i u y | [0t] t y u | [8u] - y y -\n[8u] u i o | [9o] i u y | [0t] t y u | [8y] - t t -\n[9y] y u t | [0y] ui u t | [9y] ui u y | [8t] y 5 -\n[8u] u i o | [9o] i u y | [0t] t y u | [8y] - t t" },
	{ id = "builtin:twinkle", name = "Twinkle Twinkle Little Star", artist = "Traditional", bpm = 110, tags = { "built-in", "easy" },
		sheet = "[8t] t [0o] o [qp] p [0o] - | [wi] i [8u] u [5y] y [8t] -\n[0o] o [qi] i [8u] u [5y] - | [0o] o [qi] i [8u] u [5y] -\n[8t] t [0o] o [qp] p [0o] - | [wi] i [8u] u [5y] y [8t] -" },
	{ id = "builtin:fur-elise", name = "Für Elise (opening)", artist = "Beethoven", bpm = 220, tags = { "built-in", "classical" },
		sheet = "f D f D f a d s | [6p] 0 e t u p | [3a] 0 W u O a | [6s] 0 e u f D\nf D f a d s | [6p] 0 e t u p | [3a] 0 W u s a | [6p] 0 e a s d\n[8f] w o g f d | [5d] w i f d s | [6s] 0 p d s a | [3a] - u f - f\nf D f D f a d s | [6p] 0 e t u p | [3a] 0 W u O a | [6s] 0 e u f D\nf D f a d s | [6p] 0 e t u p | [3a] 0 W u s a | [6p] - - -" },
	{ id = "builtin:jingle-bells", name = "Jingle Bells", artist = "J. Pierpont", bpm = 200, tags = { "built-in", "christmas", "easy" },
		sheet = "[8u] u u - | [8u] u u - | [8u] o t y | [8u] - - -\n[9i] i i i | [8i] u u u | [5u] y y u | [5y] - o -\n[8u] u u - | [8u] u u - | [8u] o t y | [8u] - - -\n[9i] i i i | [8i] u u u | [5o] o i y | [8t] - - -" },
}

local Lib = { entries = {}, byId = {}, songCache = {}, cacheOrder = {}, remoteCount = 0, status = "Loading..." }

-- accepts raw links and normal github.com links (repo, /tree/, /blob/, index.json) and turns them into the raw library folder
local function normalizeLibraryURL(url)
	url = (url or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if url == "" or url:find("YOUR_GITHUB_USER", 1, true) then
		return nil
	end
	url = url:gsub("index%.json.*$", "")
	local user, repo, rest = url:match("^https?://github%.com/([^/]+)/([^/]+)/?(.*)$")
	if user then
		repo = repo:gsub("%.git$", "")
		local branch, path = rest:match("^tree/([^/]+)/?(.*)$")
		if not branch then
			branch, path = rest:match("^blob/([^/]+)/?(.*)$")
		end
		branch, path = branch or "main", path or ""
		if path == "" then
			path = "library"
		end
		url = ("https://raw.githubusercontent.com/%s/%s/%s/%s"):format(user, repo, branch, path)
	end
	if url:sub(-1) ~= "/" then
		url ..= "/"
	end
	return url
end

local function libraryBase()
	return normalizeLibraryURL(S.LibraryURL) or normalizeLibraryURL(CONFIG.LibraryURL)
end

-- raw.githubusercontent.com/<user>/<repo>/<branch>/<path>/  ->  jsDelivr mirror of the same folder
local function mirrorBase(base)
	local user, repo, branch, rest = base:match("^https?://raw%.githubusercontent%.com/([^/]+)/([^/]+)/([^/]+)/(.*)$")
	if user then
		return ("https://cdn.jsdelivr.net/gh/%s/%s@%s/%s"):format(user, repo, branch, rest)
	end
	return nil
end

-- fetch a file from the library, trying cache-busted, plain and mirror URLs. returns body or nil, reason
function Lib.fetch(rel, bust)
	local base = libraryBase()
	if not base then
		return nil, "no library URL set"
	end
	local urls = {}
	if bust then
		urls[#urls + 1] = base .. rel .. "?t=" .. tostring(os.time())
	end
	urls[#urls + 1] = base .. rel
	local mirror = mirrorBase(base)
	if mirror then
		urls[#urls + 1] = mirror .. rel
	end
	local reasons = {}
	for _, url in ipairs(urls) do
		local body, why = httpGet(url)
		if body then
			return body
		end
		reasons[#reasons + 1] = why
	end
	return nil, table.concat(reasons, " || ")
end

function Lib.add(e)
	if Lib.byId[e.id] then
		return
	end
	e.tags = e.tags or {}
	e.search = (e.name .. " " .. (e.artist or "") .. " " .. table.concat(e.tags, " ")):lower()
	Lib.entries[#Lib.entries + 1] = e
	Lib.byId[e.id] = e
end

function Lib.load()
	Lib.entries, Lib.byId = {}, {}
	Lib.remoteCount = 0
	local base = libraryBase()
	local index
	if base then
		local body, why = Lib.fetch("index.json", true)
		if not body and normalizeLibraryURL(S.LibraryURL) ~= normalizeLibraryURL(CONFIG.LibraryURL) then
			local saved = S.LibraryURL
			S.LibraryURL = CONFIG.LibraryURL -- the saved link is broken: use the built-in one
			body, why = Lib.fetch("index.json", true)
			if body then
				saveSettings()
			else
				S.LibraryURL = saved
			end
		end
		local decodeErr
		if body then
			index, decodeErr = jdecode(body)
			if type(index) ~= "table" or type(index.songs) ~= "table" then
				why = "index.json unreadable: " .. tostring(decodeErr or "no songs list") .. " (got " .. #body .. " bytes: " .. body:sub(1, 30) .. ")"
				index = nil
			end
		end
		if index then
			FS.write(ROOT .. "/cache/index.json", body)
			Lib.status = "Online"
			Lib.error = nil
		else
			Lib.error = why
			warn("[PianoHub] library download failed: " .. tostring(why))
			index = jdecode(FS.read(ROOT .. "/cache/index.json"))
			Lib.status = index and "Offline (cached)" or "Library unreachable"
		end
	else
		Lib.status = "No library URL set"
	end
	if index and type(index.songs) == "table" then
		for _, s in ipairs(index.songs) do
			if type(s) == "table" and s.id and s.name then
				Lib.add({
					id = s.id, name = s.name, artist = s.artist or "Unknown", tags = s.tags or {},
					duration = s.duration or 0, count = s.count or 0, nps = s.nps or 0,
					hash = s.hash, added = s.added or 0, source = "remote",
				})
				Lib.remoteCount += 1
			end
		end
	end
	-- local json songs
	for _, path in ipairs(FS.list(ROOT .. "/songs")) do
		if path:lower():match("%.json$") then
			local data = jdecode(FS.read(path))
			if data and data.notes then
				local file = FS.basename(path)
				Lib.add({
					id = "local:" .. file, name = data.name or file, artist = data.artist or "Local",
					tags = (type(data.tags) == "table" and #data.tags > 0) and data.tags or { "local" }, duration = data.duration or 0, count = data.count or 0, nps = data.nps or 0,
					source = "local", path = path, added = os.time(),
				})
			end
		end
	end
	-- local midi files (ones already converted to songs/<name>.json are skipped)
	Lib.pendingMidi = {}
	for _, folder in ipairs({ "midi", "guitar" }) do
		for _, path in ipairs(FS.list(ROOT .. "/" .. folder)) do
			local lower = path:lower()
			local file = FS.basename(path)
			local jsonFile = (folder == "guitar" and "guitar_" or "") .. file:gsub("%.[Mm][Ii][Dd][Ii]?$", "") .. ".json"
			if lower:match("%.midi?$") and not Lib.byId["local:" .. jsonFile] then
				Lib.pendingMidi[#Lib.pendingMidi + 1] = { path = path, file = file, jsonFile = jsonFile }
				Lib.add({
					id = "midi:" .. file, name = file:gsub("%.[Mm][Ii][Dd][Ii]?$", ""):gsub("_", " "), artist = "Local MIDI",
					tags = folder == "guitar" and { "local", "guitar" } or { "local" }, duration = 0, count = 0, nps = 0,
					source = "midi", path = path, added = os.time(),
				})
			end
		end
	end
	for _, b in ipairs(BUILTIN) do
		Lib.add({ id = b.id, name = b.name, artist = b.artist, tags = b.tags, duration = 0, count = 0, nps = 0,
			source = "builtin", sheet = b.sheet, bpm = b.bpm, added = 0 })
	end
end

function Lib.remember(id, song)
	Lib.songCache[id] = song
	table.insert(Lib.cacheOrder, id)
	if #Lib.cacheOrder > 8 then
		Lib.songCache[table.remove(Lib.cacheOrder, 1)] = nil
	end
end

-- Turns every not-yet-converted MIDI in PianoHub/midi into PianoHub/songs/<name>.json, so the
-- .mid files can be deleted afterwards. Runs in the background, one file per frame.
function Lib.convertPending(onDone)
	local pending = Lib.pendingMidi or {}
	Lib.pendingMidi = {}
	if #pending == 0 or not FS.ok then
		return onDone and onDone(0, 0)
	end
	task.spawn(function()
		local done, failed = 0, 0
		for _, m in ipairs(pending) do
			local entry = Lib.byId["midi:" .. m.file]
			local ok, song = pcall(function()
				return Songs.parseMidi(assert(FS.read(m.path), "cannot read file"), entry and entry.name or m.file)
			end)
			if ok then
				local out = ROOT .. "/songs/" .. m.jsonFile
				song.tags = entry and entry.tags or { "local" }
				FS.write(out, Songs.encode(song))
				if entry then -- switch the library entry over to the converted file
					entry.source, entry.path = "local", out
					entry.duration, entry.count, entry.nps = song.duration, song.count, song.nps
					entry.artist = "Local"
					entry.search = (entry.name .. " local " .. table.concat(entry.tags, " ")):lower()
				end
				done += 1
			else
				failed += 1
				warn("[PianoHub] could not convert " .. m.file .. ": " .. tostring(song))
			end
			task.wait()
		end
		if onDone then
			onDone(done, failed)
		end
	end)
end

-- async: callback(song) or callback(nil, err)
function Lib.get(e, callback)
	if Lib.songCache[e.id] then
		return callback(Lib.songCache[e.id])
	end
	task.spawn(function()
		local ok, song = pcall(function()
			if e.source == "remote" then
				local base = libraryBase()
				local cachePath = ROOT .. "/cache/" .. e.id .. "_" .. tostring(e.hash or "0") .. ".json"
				local body = FS.read(cachePath)
				if not body then
					assert(base, "no library URL")
					local why
					body, why = Lib.fetch("songs/" .. e.id .. ".json", false)
					assert(body, "download failed: " .. tostring(why))
					FS.write(cachePath, body)
				end
				return Songs.fromData(assert(jdecode(body), "bad song file"), e)
			elseif e.source == "local" then
				return Songs.fromData(assert(jdecode(FS.read(e.path)), "bad song file"), e)
			elseif e.source == "midi" then
				local s = Songs.parseMidi(assert(FS.read(e.path), "cannot read file"), e.name)
				s.id = e.id
				e.duration, e.count, e.nps = s.duration, s.count, s.nps
				return s
			elseif e.source == "builtin" then
				local s = Songs.parseSheet(e.sheet, e.bpm, e.name)
				s.id, s.artist = e.id, e.artist
				e.duration, e.count, e.nps = s.duration, s.count, s.nps
				return s
			elseif e.source == "memory" then
				return e.song
			end
			error("unknown source")
		end)
		if ok then
			Lib.remember(e.id, song)
			callback(song)
		else
			callback(nil, tostring(song))
		end
	end)
end

---------------------------------------------------------------------------------------------------
-- player engine
---------------------------------------------------------------------------------------------------
local Player = {
	song = nil, entry = nil, events = {}, idx = 1, pos = 0, duration = 0,
	playing = false, paused = false, startAt = 0, muted = {}, queue = {}, history = {}, gen = 0,
	blockUntil = 0, ending = nil, justFinished = false,
}
local UI = {} -- filled in later (forward refs)
local Music, Perform, Live = {}, {}, {} -- defined after the player

local NOISE = { math.random() * 50, math.random() * 50, math.random() * 50 }
local function drift(x)
	return math.sin(x * 0.31 + NOISE[1]) * 0.5 + math.sin(x * 0.73 + NOISE[2]) * 0.3 + math.sin(x * 1.37 + NOISE[3]) * 0.2
end

function Player.bestTranspose(song)
	local best, bestScore = 0, -math.huge
	local lo, hi = VP_LOW, VP_HIGH
	if Guitar.active() then
		lo, hi = Guitar.range()
	end
	for tr = -12, 12 do
		local inRange = 0
		for _, n in ipairs(song.notes) do
			local p = n[2] + tr
			if p >= lo and p <= hi and not Player.muted[n[4]] then
				inRange += 1
			end
		end
		-- changing key only pays off if it rescues >3% of the notes; octave shifts keep the key
		local keyPenalty = (tr % 12 == 0) and 0 or #song.notes * 0.03
		local score = inRange - keyPenalty - math.abs(tr) * 0.01
		if score > bestScore then
			best, bestScore = tr, score
		end
	end
	return best
end

local function capGroup(group, cap)
	if #group <= cap then
		return group
	end
	local kept = { group[#group] } -- melody (top) first, then bass, then from the top down
	if cap > 1 then
		kept[2] = group[1]
	end
	for k = #group - 1, 2, -1 do
		if #kept >= cap then
			break
		end
		kept[#kept + 1] = group[k]
	end
	table.sort(kept, function(a, b)
		return a.p < b.p
	end)
	return kept
end

function Player.build(song)
	local H = S.Human
	local human = H.Enabled
	local rng = Random.new()
	local function gauss()
		local u1 = math.max(rng:NextNumber(), 1e-6)
		return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * rng:NextNumber())
	end

	local list = {}
	for _, n in ipairs(song.notes) do
		local p, tr = n[2], n[4]
		if not Player.muted[tr] then
			local handOk = S.Hand == "Both" or (S.Hand == "Right" and p >= S.Split) or (S.Hand == "Left" and p < S.Split)
			if handOk then
				local rp, key = resolvePitch(p + S.Transpose)
				if key then
					list[#list + 1] = { t = n[1], ot = n[1], p = rp, d = n[3], key = key }
				end
			end
		end
	end

	local out = {}
	local i, shift, prevT = 1, 0, 0
	while i <= #list do
		local j = i
		while j < #list and list[j + 1].t - list[i].t <= 30 do
			j += 1
		end
		local group, seen = {}, {}
		for k = i, j do
			local e = list[k]
			if not seen[e.p] then
				seen[e.p] = true
				group[#group + 1] = e
			end
		end
		table.sort(group, function(a, b)
			return a.p < b.p
		end)
		if human and H.Fingers then -- max 5 notes per hand
			local left, right = {}, {}
			for _, e in ipairs(group) do
				table.insert(e.p < S.Split and left or right, e)
			end
			group = {}
			for _, e in ipairs(capGroup(left, 5)) do
				group[#group + 1] = e
			end
			for _, e in ipairs(capGroup(right, 5)) do
				group[#group + 1] = e
			end
		end
		if S.MaxChord > 0 then
			group = capGroup(group, S.MaxChord)
		end

		if human then
			local first = group[1]
			if H.Hesitate > 0 and first.t - prevT > 650 and rng:NextNumber() < 0.6 then
				shift += rng:NextNumber() * H.Hesitate
			end
			prevT = first.t
			local base = first.t + shift + gauss() * H.Jitter * 0.6
			local n = #group
			local upward = rng:NextNumber() < 0.8
			for k, e in ipairs(group) do
				local rank = upward and (k - 1) or (n - k)
				local roll = n > 1 and (rank / (n - 1)) * H.Roll * (0.5 + rng:NextNumber() * 0.5) or 0
				e.t = base + roll + gauss() * H.Jitter * 0.25
				e.d = math.max(30, e.d * (1 + (rng:NextNumber() * 2 - 1) * H.HoldVar / 100))
				local miss = H.Miss / 100 * (n > 1 and 1.5 or 0.6)
				if n > 1 and k == n then
					miss *= 0.2 -- the melody note on top is rarely missed
				end
				if rng:NextNumber() < miss then
					e.skip = true
				elseif rng:NextNumber() < H.Wrong / 100 then
					local wp = e.p + (rng:NextNumber() < 0.5 and -1 or 1) * (rng:NextNumber() < 0.7 and 1 or 2)
					local rp, key = resolvePitch(wp)
					if key then
						out[#out + 1] = { t = e.t, ot = e.ot, p = rp, d = 80, key = key }
						if H.Correct then
							e.t += 70 + rng:NextNumber() * 110
							shift += 40 + rng:NextNumber() * 60 -- humans lose a little time fixing it
						else
							e.skip = true
						end
					end
				end
				if not e.skip then
					out[#out + 1] = e
				end
			end
		else
			for _, e in ipairs(group) do
				out[#out + 1] = e
			end
		end
		i = j + 1
	end

	table.sort(out, function(a, b)
		return a.t < b.t
	end)
	if Guitar.active() then
		out = Guitar.assign(out)
	end
	out = Perform.improvise(song, out, rng)
	table.sort(out, function(a, b)
		return a.t < b.t
	end)
	-- drop machine-gun repeats of the same physical key
	local final, last = {}, {}
	for _, e in ipairs(out) do
		local code = e.key.char or e.key.code
		if not last[code] or e.t - last[code] >= S.MinRepeat then
			last[code] = e.t
			final[#final + 1] = e
		end
	end
	local t0 = final[1] and math.min(final[1].t, 0) or 0
	for _, e in ipairs(final) do
		e.t -= t0
	end
	local duration = (#final > 0) and (final[#final].t + 400) or 0
	return final, duration
end

function Player.rebuild()
	if not Player.song then
		return
	end
	local ev = Player.events
	local lastOt = (Player.idx > 1 and ev[Player.idx - 1]) and ev[Player.idx - 1].ot or nil
	Player.events, Player.duration = Player.build(Player.song)
	if not lastOt then
		Player.idx, Player.pos = 1, 0
		return
	end
	local i = 1
	while i <= #Player.events and Player.events[i].ot <= lastOt do
		i += 1
	end
	Player.idx = i
	Player.pos = Player.events[i] and (Player.events[i].t - 1) or Player.duration
end

local rebuildQueued = false
function Player.requestRebuild()
	if rebuildQueued then
		return
	end
	rebuildQueued = true
	task.delay(0.15, function()
		rebuildQueued = false
		Player.rebuild()
		if UI.refreshNow then
			UI.refreshNow()
		end
	end)
end

function Player.load(song, entry)
	Keys.releaseAll()
	Player.song, Player.entry = song, entry
	Player.muted = {}
	local tags = (entry and entry.tags) or song.tags or {}
	if S.Guitar.AutoSwitch and table.find(tags, "guitar") and not Guitar.active() then
		S.Instrument = "Guitar"
		if UI.notify then
			UI.notify("Guitar song - switched to Guitar mode")
		end
		saveSettings()
	end
	if Guitar.active() and S.Guitar.TracksOnly then
		Player.muted = Guitar.autoMute(song)
	end
	if S.AutoTranspose then
		S.Transpose = Player.bestTranspose(song)
	end
	Player.events, Player.duration = Player.build(song)
	Player.idx, Player.pos = 1, 0
	Player.playing, Player.paused = false, false
	Player.ending, Player.blockUntil, Player.justFinished = nil, 0, false
	if entry then
		local rec = S.Recent
		for k = #rec, 1, -1 do
			if rec[k] == entry.id then
				table.remove(rec, k)
			end
		end
		table.insert(rec, 1, entry.id)
		while #rec > 40 do
			table.remove(rec)
		end
		saveSettings()
	end
	if UI.onSongLoaded then
		UI.onSongLoaded()
	end
end

function Player.start(delay)
	if not Player.song then
		return
	end
	local box = UIS:GetFocusedTextBox()
	if box then
		box:ReleaseFocus() -- otherwise our keystrokes would type into it
	end
	Player.gen += 1
	Player.playing, Player.paused = true, false
	Player.startAt = os.clock() + (delay or (Player.pos <= 0 and S.Countdown or 0))
	if not delay and S.Countdown > 0 and Player.pos <= 0 and UI.notify then
		UI.notify(("Starting in %ds  -  click into the game!"):format(S.Countdown))
	end
	if UI.refreshNow then
		UI.refreshNow()
	end
end

function Player.pause()
	if not Player.playing then
		return
	end
	Player.paused = not Player.paused
	if Player.paused then
		Keys.releaseAll()
	else
		local box = UIS:GetFocusedTextBox()
		if box then
			box:ReleaseFocus()
		end
	end
	if UI.refreshNow then
		UI.refreshNow()
	end
end

function Player.toggle()
	if not Player.song then
		if UI.playFirstVisible then
			UI.playFirstVisible()
		end
	elseif not Player.playing then
		Player.start()
	else
		Player.pause()
	end
end

function Player.stop()
	Player.playing, Player.paused = false, false
	Player.idx, Player.pos = 1, 0
	Player.ending, Player.blockUntil, Player.justFinished = nil, 0, false
	Player.gen += 1
	Perform.clear()
	Keys.releaseAll()
	if UI.refreshNow then
		UI.refreshNow()
	end
end

function Player.seek(frac)
	if not Player.song then
		return
	end
	Keys.releaseAll()
	local target = math.clamp(frac, 0, 1) * Player.duration
	local ev = Player.events
	local lo, hi = 1, #ev + 1
	while lo < hi do
		local mid = math.floor((lo + hi) / 2)
		if ev[mid].t < target then
			lo = mid + 1
		else
			hi = mid
		end
	end
	Player.idx, Player.pos = lo, math.max(target, 0.001)
	Player.startAt = 0
end

function Player.playEntry(e, fromHistory)
	if not e then
		return
	end
	if UI.notify then
		UI.notify("Loading " .. e.name .. "...")
	end
	Lib.get(e, function(song, err)
		if not song then
			if UI.notify then
				UI.notify("Failed: " .. tostring(err), true)
			end
			return
		end
		if Player.entry and not fromHistory then
			table.insert(Player.history, Player.entry)
			if #Player.history > 50 then
				table.remove(Player.history, 1)
			end
		end
		local from = Player.song
		local flowing = from and ((Player.playing and not Player.paused) or Player.justFinished)
		if flowing and S.Transition ~= "Off" then
			local oldKey = Music.current(from)
			Keys.releaseAll()
			Perform.clear()
			Player.playing = false
			Player.load(song, e)
			local secs = Perform.play((Perform.transition(oldKey, Music.current(song), S.Transition)))
			Player.start(secs + 0.15)
		else
			Player.load(song, e)
			Player.start()
		end
	end)
end

function Player.next(auto)
	if #Player.queue > 0 then
		return Player.playEntry(table.remove(Player.queue, 1))
	end
	local pool = (UI.visibleEntries and UI.visibleEntries()) or Lib.entries
	if #pool == 0 then
		return Player.stop()
	end
	if S.Shuffle then
		local pick = pool[math.random(1, #pool)]
		if #pool > 1 and Player.entry and pick.id == Player.entry.id then
			pick = pool[math.random(1, #pool)]
		end
		return Player.playEntry(pick)
	end
	local idx = 0
	for k, e in ipairs(pool) do
		if Player.entry and e.id == Player.entry.id then
			idx = k
			break
		end
	end
	if idx >= #pool then
		if auto and S.Loop ~= "All" then
			return Player.stop()
		end
		idx = 0
	end
	Player.playEntry(pool[idx + 1])
end

function Player.prev()
	if Player.song and Player.pos > 3000 then
		Player.seek(0)
		return
	end
	local e = table.remove(Player.history)
	if e then
		Player.playEntry(e, true)
	elseif Player.song then
		Player.seek(0)
	end
end

function Player.finished()
	Keys.releaseAll()
	Player.playing = false
	if S.Loop == "One" then
		Player.idx, Player.pos = 1, 0
		Player.events, Player.duration = Player.build(Player.song) -- fresh humanization each loop
		Player.start()
	elseif #Player.queue > 0 or S.Autoplay or S.Loop == "All" then
		Player.justFinished = true
		Player.next(true)
	else
		Player.stop()
	end
end

function Player.finishWithCadence()
	local key = Music.current()
	Player.ending = nil
	Player.playing = false
	Player.idx = #Player.events + 1
	Keys.releaseAll()
	local secs = Perform.play((Perform.endingNotes(key)))
	local gen = Player.gen
	task.delay(secs + 0.3, function()
		if Player.gen == gen and not Player.playing then
			Player.stop()
		end
	end)
end

function Player.step(dt)
	local now = os.clock()
	Keys.update(now)
	Perform.update(now)
	if Guitar.active() then
		Guitar.update(now)
	end
	if Live.speedTarget then -- smooth live tempo changes
		S.Speed += (Live.speedTarget - S.Speed) * math.min(1, dt * 3)
		if math.abs(Live.speedTarget - S.Speed) < 0.003 then
			S.Speed = Live.speedTarget
			Live.speedTarget = nil
			saveSettings()
		end
	end
	if not Player.playing or Player.paused or now < Player.startAt or now < Player.blockUntil then
		return
	end
	if S.PauseTyping and UIS:GetFocusedTextBox() then
		return
	end
	if Player.ending and now - Player.ending >= 2.6 then
		return Player.finishWithCadence()
	end
	local rate = S.Speed * Live.rate(now)
	local H = S.Human
	if H.Enabled and H.Drift > 0 then
		rate *= 1 + (H.Drift / 100) * drift(Player.pos / 1000)
	end
	Player.pos += dt * 1000 * rate
	local ev = Player.events
	while Player.idx <= #ev and ev[Player.idx].t <= Player.pos do
		local e = ev[Player.idx]
		Player.idx += 1
		local p, key = e.p, e.key
		local muted = (Live.muteL and p < S.Split) or (Live.muteR and p >= S.Split)
		if not muted then
			if Live.octave ~= 0 then
				local rp, k2 = resolvePitch(p + 12 * Live.octave)
				if k2 then
					p, key = rp, k2
				end
			end
			local hold = S.NoteMode == "Hold" and math.max(e.d / 1000 / S.Speed, 0.03) or (S.TapMs / 1000)
			local slipped = false
			if Live.slip then -- hit a neighbouring key, then the right one a moment later
				Live.slip = false
				local wp, wk = resolvePitch(p + (math.random() < 0.5 and -1 or 1))
				if wk then
					Keys.press(wk, 0.08)
					if UI.flashKey then
						UI.flashKey(wp)
					end
					Perform.play({ { 90 + math.random() * 70, p, hold * 1000 } }, 0)
					Player.blockUntil = now + 0.18
					slipped = true
				end
			end
			if slipped then
				break
			end
			Keys.press(key, hold)
			if Guitar.active() then
				Guitar.technique(e, now)
			end
			if UI.flashKey then
				UI.flashKey(p)
			end
		end
	end
	if Player.idx > #ev and Player.pos >= Player.duration then
		Player.finished()
	end
end

---------------------------------------------------------------------------------------------------
-- music theory: key detection, scales, chords
---------------------------------------------------------------------------------------------------
Music.MAJOR = { 0, 2, 4, 5, 7, 9, 11 }
Music.MINOR = { 0, 2, 3, 5, 7, 8, 10 }
Music.PROFILE_MAJ = { 6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88 }
Music.PROFILE_MIN = { 6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17 }
Music.CHORDS = {
	I = { 0, 4, 7 }, i = { 0, 3, 7 }, IV = { 5, 9, 12 }, iv = { 5, 8, 12 }, V = { 7, 11, 14 }, V7 = { 7, 11, 14, 17 },
}

-- Krumhansl-Schmuckler key finding on a duration-weighted pitch-class histogram
function Music.detect(song)
	if song.key then
		return song.key
	end
	local h = {}
	for i = 1, 12 do
		h[i] = 0
	end
	for _, n in ipairs(song.notes) do
		local pc = n[2] % 12 + 1
		h[pc] += math.min(n[3], 2000) + 50
	end
	local best, bestR = { tonic = 0, minor = false }, -math.huge
	for tonic = 0, 11 do
		for _, minor in ipairs({ false, true }) do
			local prof = minor and Music.PROFILE_MIN or Music.PROFILE_MAJ
			local sx, sy, sxx, syy, sxy = 0, 0, 0, 0, 0
			for i = 0, 11 do
				local x, y = h[(i + tonic) % 12 + 1], prof[i + 1]
				sx += x
				sy += y
				sxx += x * x
				syy += y * y
				sxy += x * y
			end
			local den = math.sqrt(math.max((12 * sxx - sx * sx) * (12 * syy - sy * sy), 1e-9))
			local r = (12 * sxy - sx * sy) / den
			if r > bestR then
				best, bestR = { tonic = tonic, minor = minor }, r
			end
		end
	end
	song.key = best
	return best
end

-- key of what is actually sounding (after transpose)
function Music.current(song)
	song = song or Player.song
	if not song then
		return { tonic = 0, minor = false }
	end
	local k = Music.detect(song)
	return { tonic = (k.tonic + S.Transpose) % 12, minor = k.minor }
end

function Music.keyName(k)
	return NOTE_NAMES[k.tonic + 1] .. (k.minor and " minor" or " major")
end

function Music.inScale(p, key)
	local pc = (p - key.tonic) % 12
	for _, s in ipairs(key.minor and Music.MINOR or Music.MAJOR) do
		if s == pc then
			return true
		end
	end
	return false
end

function Music.up(p, key)
	repeat
		p += 1
	until Music.inScale(p, key)
	return p
end

function Music.down(p, key)
	repeat
		p -= 1
	until Music.inScale(p, key)
	return p
end

function Music.root(key, p) -- the tonic at or below p
	return p - ((p - key.tonic) % 12)
end

function Music.chord(key, name, root)
	local out = {}
	for _, x in ipairs(Music.CHORDS[name]) do
		out[#out + 1] = root + x
	end
	return out
end

function Music.tonicChord(key)
	return key.minor and "i" or "I"
end

---------------------------------------------------------------------------------------------------
-- Perform: generated playing (warm-ups, transitions, flourishes, improv) on a real-time overlay
---------------------------------------------------------------------------------------------------
Perform.queue = {}
Perform.busyUntil = 0

function Perform.clear()
	Perform.queue = {}
	Perform.busyUntil = 0
end

-- notes = { {t_ms, pitch, dur_ms}, ... } starting now (not affected by song speed). returns seconds until done
function Perform.play(notes, delay)
	local base = os.clock() + (delay or 0.03)
	local rng = Random.new()
	local last = 0
	local jit = S.Human.Enabled and math.min(S.Human.Jitter, 25) * 0.4 or 0
	for _, n in ipairs(notes) do
		local t = math.max(0, n[1] + (rng:NextNumber() * 2 - 1) * jit)
		table.insert(Perform.queue, { at = base + t / 1000, p = n[2], hold = math.max((n[3] or 120) / 1000, 0.03) })
		last = math.max(last, n[1] + math.min(n[3] or 120, 400))
	end
	table.sort(Perform.queue, function(a, b)
		return a.at < b.at
	end)
	local finish = base + last / 1000
	Perform.busyUntil = math.max(Perform.busyUntil, finish)
	return finish - os.clock()
end

function Perform.update(now)
	local q = Perform.queue
	while q[1] and q[1].at <= now do
		local n = table.remove(q, 1)
		local p, key = resolvePitch(n.p)
		if key then
			Keys.press(key, n.hold)
			if UI.flashKey then
				UI.flashKey(p)
			end
		end
	end
end

function Perform.newSeq()
	local s = { notes = {}, t = 0 }
	function s.note(p, d, at)
		table.insert(s.notes, { at or s.t, p, d or 150 })
	end
	function s.chord(ps, d, roll)
		for k, p in ipairs(ps) do
			s.note(p, d, s.t + (k - 1) * (roll or 0))
		end
	end
	function s.wait(ms)
		s.t += ms
	end
	return s
end

function Perform.scaleRun(key, from, count, dir)
	local out, p = {}, from
	if not Music.inScale(p, key) then
		p = Music.up(p, key)
	end
	for i = 1, count do
		out[i] = p
		p = dir > 0 and Music.up(p, key) or Music.down(p, key)
	end
	return out
end

function Perform.arp(key, from, count, dir)
	local tones = key.minor and { 0, 3, 7 } or { 0, 4, 7 }
	local list = {}
	local base = Music.root(key, 24)
	for oct = 0, 8 do
		for _, x in ipairs(tones) do
			list[#list + 1] = base + oct * 12 + x
		end
	end
	local i = 1
	while list[i] and list[i] < from do
		i += 1
	end
	if dir < 0 and list[i] ~= from then
		i = math.max(1, i - 1)
	end
	local out = {}
	for _ = 1, count do
		if not list[i] then
			break
		end
		out[#out + 1] = list[i]
		i += dir
	end
	return out
end

local function homeRoot(key)
	local r = Music.root(key, 64)
	if r < 59 then
		r += 12
	end
	return r
end

function Perform.warmup(key, crazy)
	local s = Perform.newSeq()
	local rng = Random.new()
	local pace = crazy and 0.72 or 1
	local rh = homeRoot(key)
	-- 1) five-finger exercise, hands together, second pass faster
	for rep = 1, 2 do
		local step = (rep == 1 and 150 or 112) * pace
		local up = Perform.scaleRun(key, rh, 5, 1)
		for _, p in ipairs({ up[1], up[2], up[3], up[4], up[5], up[4], up[3], up[2], up[1] }) do
			s.note(p, step)
			s.note(p - 12, step)
			s.wait(step)
		end
		s.wait(260 + rng:NextNumber() * 260)
	end
	-- 2) two-octave scale in octaves, speeding up, then back down
	local sc = Perform.scaleRun(key, rh, 15, 1)
	local step = 100 * pace
	for i = 1, #sc do
		s.note(sc[i], step * 1.2)
		s.note(sc[i] - 12, step * 1.2)
		s.wait(step)
		step = math.max(step * 0.975, 42)
	end
	for i = #sc - 1, 1, -1 do
		s.note(sc[i], step * 1.2)
		s.note(sc[i] - 12, step * 1.2)
		s.wait(step)
	end
	s.chord({ rh - 12, rh }, 450)
	s.wait(520 + rng:NextNumber() * 400)
	-- 3) broken-chord arpeggio sweeping the keyboard
	local arp = Perform.arp(key, rh - 24, crazy and 14 or 10, 1)
	local astep = crazy and 58 or 82
	for _, p in ipairs(arp) do
		s.note(p, astep * 2)
		s.wait(astep)
	end
	for i = #arp - 1, 1, -1 do
		s.note(arp[i], astep * 2)
		s.wait(astep)
	end
	s.wait(450 + rng:NextNumber() * 350)
	-- 4) the show-off part, only before crazy songs
	if crazy then
		for p = rh - 12, rh + 24 do
			s.note(p, 55)
			s.wait(34)
		end
		for p = rh + 24, rh - 12, -1 do
			s.note(p, 55)
			s.wait(32)
		end
		s.wait(220)
		local a = Perform.scaleRun(key, rh + 12, 2, 1)
		for i = 1, 22 do
			s.note(i % 2 == 1 and a[1] or a[2], 45)
			s.wait(40)
		end
		s.wait(160)
		for _ = 1, 6 do
			s.chord({ rh - 24, rh - 12 }, 70)
			s.wait(85)
			s.chord({ rh + 12, rh + 24 }, 70)
			s.wait(85)
		end
		s.wait(380)
	end
	-- 5) cadence IV - V7 - I
	s.note(rh - 12 - 7, 500)
	s.chord(Music.chord(key, key.minor and "iv" or "IV", rh), 500, 22)
	s.wait(520)
	s.note(rh - 12 - 5, 500)
	s.chord(Music.chord(key, "V7", rh - 12), 500, 22)
	s.wait(520)
	s.note(rh - 24, 1200)
	s.chord(Music.chord(key, Music.tonicChord(key), rh), 1200, 30)
	s.wait(1200)
	return s.notes, s.t
end

-- little bridge between two songs, from the old key into the new one
function Perform.transition(oldKey, newKey, style)
	local s = Perform.newSeq()
	local rng = Random.new()
	if style == "Random" or not style then
		local styles = { "Cadence", "Glissando", "Playful", "Noodle" }
		style = styles[rng:NextInteger(1, #styles)]
	end
	local r, nr = homeRoot(oldKey), homeRoot(newKey)
	s.wait(180 + rng:NextNumber() * 220) -- lift the hands
	if style == "Cadence" then
		s.note(r - 5 - 12, 420)
		s.chord(Music.chord(oldKey, "V7", r - 12), 420, 25)
		s.wait(460)
		s.note(r - 24, 1000)
		s.chord(Music.chord(oldKey, Music.tonicChord(oldKey), r), 1000, 35)
		s.wait(1100)
	elseif style == "Glissando" then
		local run = Perform.scaleRun(oldKey, r - 12, 22, 1)
		for _, p in ipairs(run) do
			s.note(p, 60)
			s.wait(24)
		end
		s.wait(70)
		local down = Perform.scaleRun(newKey, run[#run], 15, -1)
		for _, p in ipairs(down) do
			s.note(p, 60)
			s.wait(26)
		end
		s.note(nr - 24, 800)
		s.chord(Music.chord(newKey, Music.tonicChord(newKey), nr - 12), 800, 30)
		s.wait(900)
	elseif style == "Playful" then -- "shave and a haircut ... two bits"
		local b = 230
		local third = oldKey.minor and 3 or 4
		s.note(r + 7, b * 0.9)
		s.wait(b)
		s.note(r + 2, b * 0.45)
		s.wait(b / 2)
		s.note(r + 2, b * 0.45)
		s.wait(b / 2)
		s.note(r + third, b * 0.9)
		s.wait(b)
		s.note(r + 2, b * 0.9)
		s.wait(b * 2 + rng:NextNumber() * 120)
		s.note(r - 1, b * 0.8)
		s.note(r - 5 - 12, b * 0.8)
		s.wait(b)
		s.note(r, 700)
		s.chord({ r - 24, r - 12 }, 700)
		s.wait(900)
	else -- "Noodle": old tonic arpeggio down, pivot on the new key's V7, land on the new tonic
		for _, p in ipairs(Perform.arp(oldKey, r + 12, 7, -1)) do
			s.note(p, 150)
			s.wait(105)
		end
		s.wait(70)
		for _, p in ipairs(Music.chord(newKey, "V7", nr - 12)) do
			s.note(p, 170)
			s.wait(100)
		end
		s.wait(60)
		s.note(nr - 24, 800)
		s.chord(Music.chord(newKey, Music.tonicChord(newKey), nr), 800, 30)
		s.wait(950)
	end
	return s.notes, s.t
end

function Perform.flourish(key, around)
	local s = Perform.newSeq()
	local kind = math.random(1, 3)
	if kind == 1 then
		local run = Perform.scaleRun(key, around, 9, 1)
		for _, p in ipairs(run) do
			s.note(p, 70)
			s.wait(52)
		end
		for i = #run - 1, 1, -1 do
			s.note(run[i], 70)
			s.wait(52)
		end
	elseif kind == 2 then
		local a = Perform.arp(key, around - 12, 10, 1)
		for _, p in ipairs(a) do
			s.note(p, 90)
			s.wait(58)
		end
		s.chord({ a[#a] - 12, a[#a] }, 320)
		s.wait(260)
	else
		local up, dn = Music.up(around, key), Music.down(around, key)
		for _, p in ipairs({ up, around, dn, around, up, around, up, around, up, around }) do
			s.note(p, 60)
			s.wait(52)
		end
	end
	return s.notes, s.t
end

function Perform.introNotes(key)
	local s = Perform.newSeq()
	local r = homeRoot(key) - 12
	s.note(r - 12, 900)
	for _, p in ipairs(Perform.arp(key, r, 7, 1)) do
		s.note(p, 320)
		s.wait(115)
	end
	s.wait(160)
	s.note(r - 5, 650)
	s.chord(Music.chord(key, "V7", r), 650, 30)
	s.wait(850)
	return s.notes, s.t
end

function Perform.endingNotes(key)
	local s = Perform.newSeq()
	local r = homeRoot(key) - 12
	for _, p in ipairs(Perform.arp(key, r - 12, 9, 1)) do
		s.note(p, 900)
		s.wait(62)
	end
	s.wait(130)
	s.chord({ r - 24, r - 12 }, 1500)
	s.chord(Music.chord(key, Music.tonicChord(key), r + 12), 1500, 22)
	s.wait(1500)
	return s.notes, s.t
end

-- "coded-in" improvisation, applied to every song when building its events
function Perform.improvise(song, out, rng)
	local I = S.Improv
	if not I.Enabled or #out == 0 then
		return out
	end
	local amt = I.Amount / 100
	local key = Music.current(song)
	table.sort(out, function(a, b)
		return a.t < b.t
	end)
	local groups = {}
	for _, e in ipairs(out) do
		local g = groups[#groups]
		if g and e.t - g.t <= 30 then
			table.insert(g.notes, e)
		else
			groups[#groups + 1] = { t = e.t, notes = { e } }
		end
	end
	local extra = {}
	local function add(t, p, d, ot)
		local rp, k = resolvePitch(p)
		if k then
			extra[#extra + 1] = { t = t, ot = ot, p = rp, d = d, key = k }
		end
	end
	for gi, g in ipairs(groups) do
		table.sort(g.notes, function(a, b)
			return a.p < b.p
		end)
		local top, low = g.notes[#g.notes], g.notes[1]
		local nextG, prevG = groups[gi + 1], groups[gi - 1]
		local gap = nextG and (nextG.t - g.t) or 1500
		local prevGap = prevG and (g.t - prevG.t) or 1500
		-- broken chords
		if I.Arpeggios and #g.notes >= 3 and gap >= 450 and rng:NextNumber() < 0.4 * amt then
			local step = math.min(85, gap * 0.5 / #g.notes)
			for k, e in ipairs(g.notes) do
				e.t = g.t + (k - 1) * step
			end
		end
		-- ornaments on longer melody notes
		if I.Ornaments and gap >= 260 and rng:NextNumber() < 0.4 * amt then
			local up = Music.up(top.p, key)
			local kind = rng:NextNumber()
			if kind < 0.45 then -- grace note
				add(top.t - 55, up, 45, top.ot)
			elseif kind < 0.7 and gap >= 650 then -- trill
				local n = math.floor(math.min(gap * 0.5, 560) / 68)
				for k = 1, n do
					add(top.t + k * 68, k % 2 == 1 and up or top.p, 50, top.ot)
				end
			else -- mordent
				add(top.t + 45, up, 40, top.ot)
				add(top.t + 90, top.p, math.max(60, top.d - 90), top.ot)
			end
		end
		-- little scale fills in the rests, leading into the next note
		if I.Fills and nextG and gap >= 900 and rng:NextNumber() < 0.5 * amt then
			local target = nextG.notes[1].p
			for _, e in ipairs(nextG.notes) do
				target = math.max(target, e.p)
			end
			local start = g.t + math.max(math.min(top.d, gap * 0.6), gap * 0.4)
			local avail = nextG.t - 60 - start
			local steps = math.min(8, math.floor(avail / 70))
			if steps >= 3 then
				local fromBelow = target > top.p
				local run, p = {}, target
				for _ = 1, steps do
					p = fromBelow and Music.down(p, key) or Music.up(p, key)
					table.insert(run, 1, p)
				end
				local stepMs = avail / steps
				for k, rp in ipairs(run) do
					add(start + (k - 1) * stepMs, rp, stepMs * 0.9, top.ot)
				end
			end
		end
		-- octave doubling at the start of phrases
		if I.Octaves and prevGap >= 500 and rng:NextNumber() < 0.45 * amt then
			if rng:NextNumber() < 0.5 then
				add(top.t, top.p + 12, top.d, top.ot)
			else
				add(low.t, low.p - 12, low.d, low.ot)
			end
		end
	end
	if I.Ending then
		local lg = groups[#groups]
		local notes = Perform.endingNotes(key)
		for _, n in ipairs(notes) do
			add(lg.t + 450 + n[1], n[2], n[3], math.huge)
		end
	end
	if I.Intro then
		local notes, len = Perform.introNotes(key)
		for _, e in ipairs(out) do
			e.t += len
		end
		for _, e in ipairs(extra) do
			e.t += len
		end
		for _, n in ipairs(notes) do
			add(n[1], n[2], n[3], -1)
		end
	end
	for _, e in ipairs(extra) do
		out[#out + 1] = e
	end
	return out
end

function Perform.warmupAndPlay()
	local song = Player.song
	local key = song and Music.current(song) or { tonic = 0, minor = false }
	local crazy = false
	if song then
		crazy = (song.nps or 0) >= 8
		if Player.entry and Player.entry.tags and table.find(Player.entry.tags, "crazy") then
			crazy = true
		end
	end
	local box = UIS:GetFocusedTextBox()
	if box then
		box:ReleaseFocus()
	end
	Keys.releaseAll()
	Perform.clear()
	Player.playing, Player.paused, Player.ending = false, false, nil
	Player.gen += 1
	if song then
		Player.idx, Player.pos = 1, 0
	end
	local secs = Perform.play((Perform.warmup(key, crazy)), 0.4)
	if UI.notify then
		UI.notify(crazy and "Warming up for something crazy..." or "Warming up...")
	end
	if song and S.WarmupPlay then
		Player.start(secs + 0.9 + math.random() * 0.6)
	end
end

---------------------------------------------------------------------------------------------------
-- Live: real-time controls while a song plays
---------------------------------------------------------------------------------------------------
Live.octave = 0
Live.muteL, Live.muteR = false, false
Live.speedTarget = nil
Live.dipStart = -100
Live.slip = false
Live.visible = nil -- nil = automatic

function Live.hesitate()
	if not Player.playing or Player.paused then
		return
	end
	Keys.releaseAll()
	Player.blockUntil = os.clock() + 0.35 + math.random() * 0.75
end

function Live.slipUp()
	Live.slip = true
end

function Live.redo() -- jump back to the start of the current phrase, like starting a bar over
	if not Player.song or not Player.playing then
		return
	end
	local ev = Player.events
	if #ev == 0 then
		return
	end
	local i = math.clamp(Player.idx - 1, 1, #ev)
	local target = Player.pos - 1200
	while i > 1 and ev[i].t > target do
		i -= 1
	end
	local guard = 0
	while i > 1 and ev[i].t - ev[i - 1].t < 350 and guard < 300 do
		i -= 1
		guard += 1
	end
	Keys.releaseAll()
	Player.idx = i
	Player.pos = ev[i].t - 1
	Player.blockUntil = os.clock() + 0.45 + math.random() * 0.4
end

function Live.flourish()
	if not Player.song then
		return
	end
	local around = 72
	local last = Player.events[math.max(1, Player.idx - 1)]
	if last then
		around = math.clamp(last.p, 55, 84)
	end
	Keys.releaseAll()
	local secs = Perform.play((Perform.flourish(Music.current(), around)))
	Player.blockUntil = math.max(Player.blockUntil, os.clock() + secs + 0.08)
end

function Live.rubato()
	Live.dipStart = os.clock()
end

function Live.bigEnding()
	if Player.playing and not Player.ending then
		Player.ending = os.clock()
	end
end

function Live.nudge(dir)
	Live.speedTarget = math.clamp((Live.speedTarget or S.Speed) + dir * 0.05, 0.25, 3)
end

function Live.rate(now)
	local r = 1
	local dip = now - Live.dipStart
	if dip < 2.4 then
		r *= 1 - 0.35 * math.sin(math.pi * dip / 2.4)
	end
	if Player.ending then
		r *= math.max(0.3, 1 - (now - Player.ending) / 2.6 * 0.7)
	end
	return r
end

function Live.kps(now)
	local r = Keys.recent
	while r[1] and r[1] < now - 1 do
		table.remove(r, 1)
	end
	return #r
end

---------------------------------------------------------------------------------------------------
-- UI kit
---------------------------------------------------------------------------------------------------
local ACCENTS = {
	Violet = Color3.fromRGB(124, 92, 255),
	Cyan = Color3.fromRGB(0, 184, 255),
	Pink = Color3.fromRGB(255, 82, 170),
	Green = Color3.fromRGB(52, 205, 120),
	Orange = Color3.fromRGB(255, 146, 48),
	Red = Color3.fromRGB(240, 72, 84),
}
local ACCENT_ORDER = { "Violet", "Cyan", "Pink", "Green", "Orange", "Red" }

local Theme = {
	Bg = Color3.fromRGB(14, 15, 20),
	Panel = Color3.fromRGB(21, 23, 30),
	Panel2 = Color3.fromRGB(28, 31, 40),
	Panel3 = Color3.fromRGB(36, 40, 52),
	Stroke = Color3.fromRGB(46, 50, 64),
	Text = Color3.fromRGB(236, 238, 246),
	Sub = Color3.fromRGB(148, 154, 174),
	Dim = Color3.fromRGB(96, 102, 122),
	Good = Color3.fromRGB(70, 210, 130),
	Bad = Color3.fromRGB(240, 80, 90),
	Gold = Color3.fromRGB(255, 200, 60),
	Accent = ACCENTS[S.Accent] or ACCENTS.Violet,
}

local FONT = Enum.Font.Gotham
local FONT_MED = Enum.Font.GothamMedium
local FONT_BOLD = Enum.Font.GothamBold

local accentRefs, refreshers = {}, {}
local layoutCounter = 0

local function new(class, props, kids)
	local o = Instance.new(class)
	if props then
		for k, v in pairs(props) do
			if k ~= "Parent" then
				o[k] = v
			end
		end
	end
	if kids then
		for _, c in ipairs(kids) do
			c.Parent = o
		end
	end
	if props and props.Parent then
		o.Parent = props.Parent
	end
	return o
end

local function corner(r)
	return new("UICorner", { CornerRadius = UDim.new(0, r or 6) })
end

local function stroke(color, thickness, transparency)
	return new("UIStroke", { Color = color or Theme.Stroke, Thickness = thickness or 1,
		Transparency = transparency or 0, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
end

local function padding(t, l, r, b)
	return new("UIPadding", { PaddingTop = UDim.new(0, t), PaddingLeft = UDim.new(0, l or t),
		PaddingRight = UDim.new(0, r or l or t), PaddingBottom = UDim.new(0, b or t) })
end

local function vlist(pad, dir, halign)
	return new("UIListLayout", { Padding = UDim.new(0, pad or 6), SortOrder = Enum.SortOrder.LayoutOrder,
		FillDirection = dir or Enum.FillDirection.Vertical, HorizontalAlignment = halign or Enum.HorizontalAlignment.Left })
end

local function accent(obj, prop)
	accentRefs[#accentRefs + 1] = { obj, prop }
	obj[prop] = Theme.Accent
	return obj
end

local function nextOrder()
	layoutCounter += 1
	return layoutCounter
end

local function text(props)
	props.BackgroundTransparency = 1
	props.Font = props.Font or FONT
	props.TextColor3 = props.TextColor3 or Theme.Text
	props.TextSize = props.TextSize or 13
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	props.TextTruncate = props.TextTruncate or Enum.TextTruncate.AtEnd
	return new("TextLabel", props)
end

local function tween(obj, t, goal)
	local tw = TweenService:Create(obj, TweenInfo.new(t, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), goal)
	tw:Play()
	return tw
end

local function hover(btn)
	local base
	btn.MouseEnter:Connect(function()
		base = btn.BackgroundColor3
		tween(btn, 0.12, { BackgroundColor3 = base:Lerp(Color3.new(1, 1, 1), 0.07) })
	end)
	btn.MouseLeave:Connect(function()
		if base then
			tween(btn, 0.12, { BackgroundColor3 = base })
		end
	end)
end

local function btn(props, onClick)
	props.AutoButtonColor = false
	props.Font = props.Font or FONT_MED
	props.TextSize = props.TextSize or 13
	props.TextColor3 = props.TextColor3 or Theme.Text
	props.BackgroundColor3 = props.BackgroundColor3 or Theme.Panel3
	local b = new("TextButton", props, { corner(6) })
	hover(b)
	if onClick then
		b.MouseButton1Click:Connect(onClick)
	end
	return b
end

local function fmtTime(sec)
	sec = math.max(0, math.floor(sec or 0))
	return ("%d:%02d"):format(math.floor(sec / 60), sec % 60)
end

local function stars(nps)
	nps = nps or 0
	local n = nps < 2.5 and 1 or nps < 4.5 and 2 or nps < 6.5 and 3 or nps < 9 and 4 or 5
	return string.rep("●", n) .. string.rep("○", 5 - n)
end

local function refreshAll()
	for _, f in ipairs(refreshers) do
		pcall(f)
	end
end

---------------------------------------------------------------------------------------------------
-- window
---------------------------------------------------------------------------------------------------
local gui = new("ScreenGui", {
	Name = "PianoHub_" .. tostring(math.random(1000, 9999)),
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 999,
})
if syn and syn.protect_gui then
	pcall(syn.protect_gui, gui)
end
do
	local parent = (gethui and gethui()) or game:GetService("CoreGui")
	if not pcall(function()
		gui.Parent = parent
	end) then
		gui.Parent = LP:WaitForChild("PlayerGui")
	end
end

local W, H = 660, 440
local main = new("Frame", {
	Name = "Main", Parent = gui, Size = UDim2.fromOffset(W, H), Position = UDim2.new(0.5, -W / 2, 0.5, -H / 2),
	BackgroundColor3 = Theme.Bg, ClipsDescendants = true,
}, { corner(10), stroke(Theme.Stroke, 1) })
local uiScale = new("UIScale", { Parent = main, Scale = S.Scale })

-- top bar
local top = new("Frame", { Parent = main, Size = UDim2.new(1, 0, 0, 42), BackgroundColor3 = Theme.Panel }, { corner(10) })
new("Frame", { Parent = top, Size = UDim2.new(1, 0, 0, 10), Position = UDim2.new(0, 0, 1, -10), BackgroundColor3 = Theme.Panel, BorderSizePixel = 0 })
local logo = new("Frame", { Parent = top, Size = UDim2.fromOffset(24, 24), Position = UDim2.fromOffset(12, 9) }, { corner(6) })
accent(logo, "BackgroundColor3")
text({ Parent = logo, Size = UDim2.fromScale(1, 1), Text = "♪", Font = FONT_BOLD, TextSize = 16, TextXAlignment = Enum.TextXAlignment.Center })
text({ Parent = top, Position = UDim2.fromOffset(44, 0), Size = UDim2.fromOffset(120, 42), Text = "PianoHub", Font = FONT_BOLD, TextSize = 16 })
text({ Parent = top, Position = UDim2.fromOffset(128, 2), Size = UDim2.fromOffset(60, 42), Text = "v" .. CONFIG.Version, TextColor3 = Theme.Dim, TextSize = 11 })
local statusDot = new("Frame", { Parent = top, Size = UDim2.fromOffset(8, 8), Position = UDim2.new(1, -250, 0.5, -4), BackgroundColor3 = Theme.Dim }, { corner(4) })
local statusText = text({ Parent = top, Position = UDim2.new(1, -236, 0, 0), Size = UDim2.fromOffset(160, 42), Text = "Loading library...", TextColor3 = Theme.Sub, TextSize = 12 })
local minimizeBtn = btn({ Parent = top, Size = UDim2.fromOffset(28, 26), Position = UDim2.new(1, -70, 0.5, -13), Text = "–", TextSize = 16, BackgroundColor3 = Theme.Panel2 })
local closeBtn = btn({ Parent = top, Size = UDim2.fromOffset(28, 26), Position = UDim2.new(1, -38, 0.5, -13), Text = "✕", TextSize = 12, BackgroundColor3 = Theme.Panel2 })

do -- dragging
	local dragging, dragStart, startPos
	top.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, dragStart, startPos = true, input.Position, main.Position
		end
	end)
	bind(UIS.InputChanged, function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - dragStart
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
	bind(UIS.InputEnded, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
end

-- sidebar
local SIDE_W, BAR_H = 138, 64
local sidebar = new("Frame", { Parent = main, Position = UDim2.fromOffset(0, 42), Size = UDim2.new(0, SIDE_W, 1, -42 - BAR_H), BackgroundColor3 = Theme.Panel, BorderSizePixel = 0 },
	{ padding(10, 8), vlist(4) })
local pages = new("Frame", { Parent = main, Position = UDim2.fromOffset(SIDE_W, 42), Size = UDim2.new(1, -SIDE_W, 1, -42 - BAR_H), BackgroundTransparency = 1, ClipsDescendants = true })

local tabs, currentTab = {}, nil
local function selectTab(name)
	for n, t in pairs(tabs) do
		local on = n == name
		t.page.Visible = on
		tween(t.button, 0.15, { BackgroundTransparency = on and 0 or 1, TextColor3 = on and Theme.Text or Theme.Sub })
		t.bar.Visible = on
	end
	currentTab = name
end

local function makePage(name, icon, scrolling)
	local b = btn({ Parent = sidebar, Size = UDim2.new(1, 0, 0, 34), Text = "   " .. icon .. "   " .. name, TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundColor3 = Theme.Panel3, BackgroundTransparency = 1, TextColor3 = Theme.Sub, LayoutOrder = nextOrder() })
	local bar = new("Frame", { Parent = b, Size = UDim2.new(0, 3, 0.6, 0), Position = UDim2.new(0, 0, 0.2, 0), Visible = false }, { corner(2) })
	accent(bar, "BackgroundColor3")
	local page
	if scrolling then
		page = new("ScrollingFrame", { Parent = pages, Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0,
			CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 4,
			ScrollBarImageColor3 = Theme.Stroke, Visible = false }, { padding(12, 12, 14, 12), vlist(8) })
	else
		page = new("Frame", { Parent = pages, Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false })
	end
	tabs[name] = { button = b, page = page, bar = bar }
	b.MouseButton1Click:Connect(function()
		selectTab(name)
	end)
	return page
end

---------------------------------------------------------------------------------------------------
-- controls
---------------------------------------------------------------------------------------------------
local C = {}

function C.section(parent, title, sub)
	local f = new("Frame", { Parent = parent, Size = UDim2.new(1, 0, 0, sub and 34 or 22), BackgroundTransparency = 1, LayoutOrder = nextOrder() })
	text({ Parent = f, Size = UDim2.new(1, 0, 0, 18), Position = UDim2.fromOffset(0, 4), Text = title:upper(), Font = FONT_BOLD, TextSize = 11, TextColor3 = Theme.Sub })
	if sub then
		text({ Parent = f, Size = UDim2.new(1, 0, 0, 14), Position = UDim2.fromOffset(0, 20), Text = sub, TextSize = 11, TextColor3 = Theme.Dim })
	end
	return f
end

local function row(parent, h)
	return new("Frame", { Parent = parent, Size = UDim2.new(1, 0, 0, h or 38), BackgroundColor3 = Theme.Panel2, LayoutOrder = nextOrder() }, { corner(7) })
end

function C.toggle(parent, label, get, set, hint)
	local r = row(parent, hint and 46 or 38)
	text({ Parent = r, Position = UDim2.fromOffset(12, hint and 6 or 0), Size = UDim2.new(1, -70, 0, hint and 18 or 38), Text = label, Font = FONT_MED })
	if hint then
		text({ Parent = r, Position = UDim2.fromOffset(12, 24), Size = UDim2.new(1, -70, 0, 14), Text = hint, TextSize = 11, TextColor3 = Theme.Dim })
	end
	local pill = new("TextButton", { Parent = r, Size = UDim2.fromOffset(38, 20), Position = UDim2.new(1, -50, 0.5, -10), Text = "", AutoButtonColor = false, BackgroundColor3 = Theme.Stroke }, { corner(10) })
	local knob = new("Frame", { Parent = pill, Size = UDim2.fromOffset(16, 16), Position = UDim2.fromOffset(2, 2), BackgroundColor3 = Theme.Text }, { corner(8) })
	local function render()
		local on = get()
		tween(pill, 0.15, { BackgroundColor3 = on and Theme.Accent or Theme.Stroke })
		tween(knob, 0.15, { Position = on and UDim2.fromOffset(20, 2) or UDim2.fromOffset(2, 2) })
	end
	local function click()
		set(not get())
		render()
		saveSettings()
	end
	pill.MouseButton1Click:Connect(click)
	local hit = new("TextButton", { Parent = r, Size = UDim2.new(1, -60, 1, 0), BackgroundTransparency = 1, Text = "" })
	hit.MouseButton1Click:Connect(click)
	render()
	refreshers[#refreshers + 1] = render
	return r
end

function C.slider(parent, label, min, max, step, get, set, fmt)
	local r = row(parent, 50)
	text({ Parent = r, Position = UDim2.fromOffset(12, 6), Size = UDim2.new(1, -100, 0, 18), Text = label, Font = FONT_MED })
	local val = text({ Parent = r, Position = UDim2.new(1, -92, 0, 6), Size = UDim2.fromOffset(80, 18), Text = "", TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = Theme.Sub })
	local bar = new("Frame", { Parent = r, Position = UDim2.new(0, 12, 0, 33), Size = UDim2.new(1, -24, 0, 5), BackgroundColor3 = Theme.Stroke }, { corner(3) })
	local fill = new("Frame", { Parent = bar, Size = UDim2.new(0, 0, 1, 0) }, { corner(3) })
	accent(fill, "BackgroundColor3")
	local knob = new("Frame", { Parent = bar, Size = UDim2.fromOffset(13, 13), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, 0, 0.5, 0), BackgroundColor3 = Theme.Text }, { corner(7) })
	local hit = new("TextButton", { Parent = r, Position = UDim2.new(0, 6, 0, 24), Size = UDim2.new(1, -12, 0, 22), BackgroundTransparency = 1, Text = "" })
	local function render()
		local v = get()
		local a = math.clamp((v - min) / (max - min), 0, 1)
		fill.Size = UDim2.new(a, 0, 1, 0)
		knob.Position = UDim2.new(a, 0, 0.5, 0)
		val.Text = fmt and fmt(v) or tostring(v)
	end
	local dragging = false
	local function update(x)
		local a = math.clamp((x - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1), 0, 1)
		local v = min + a * (max - min)
		v = math.floor(v / step + 0.5) * step
		v = math.clamp(tonumber(("%.4f"):format(v)), min, max)
		if v ~= get() then
			set(v)
			saveSettings()
		end
		render()
	end
	hit.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			update(input.Position.X)
		end
	end)
	bind(UIS.InputChanged, function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			update(input.Position.X)
		end
	end)
	bind(UIS.InputEnded, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
	render()
	refreshers[#refreshers + 1] = render
	return r
end

function C.cycle(parent, label, options, get, set, hint)
	local r = row(parent, hint and 46 or 38)
	text({ Parent = r, Position = UDim2.fromOffset(12, hint and 6 or 0), Size = UDim2.new(1, -150, 0, hint and 18 or 38), Text = label, Font = FONT_MED })
	if hint then
		text({ Parent = r, Position = UDim2.fromOffset(12, 24), Size = UDim2.new(1, -150, 0, 14), Text = hint, TextSize = 11, TextColor3 = Theme.Dim })
	end
	local b = btn({ Parent = r, Size = UDim2.fromOffset(124, 26), Position = UDim2.new(1, -134, 0.5, -13), Text = "", BackgroundColor3 = Theme.Panel3 })
	local function render()
		b.Text = "‹  " .. tostring(get()) .. "  ›"
	end
	local function shift(dir)
		local cur, idx = get(), 1
		for k, o in ipairs(options) do
			if o == cur then
				idx = k
			end
		end
		set(options[(idx - 1 + dir) % #options + 1])
		render()
		saveSettings()
	end
	b.MouseButton1Click:Connect(function()
		shift(1)
	end)
	b.MouseButton2Click:Connect(function()
		shift(-1)
	end)
	render()
	refreshers[#refreshers + 1] = render
	return r
end

function C.buttons(parent, list, h)
	local r = new("Frame", { Parent = parent, Size = UDim2.new(1, 0, 0, h or 32), BackgroundTransparency = 1, LayoutOrder = nextOrder() })
	local n = #list
	local made = {}
	for k, item in ipairs(list) do
		local b = btn({ Parent = r, Size = UDim2.new(1 / n, -6 * (n - 1) / n, 1, 0), Position = UDim2.new((k - 1) / n, 6 * (k - 1) / n, 0, 0),
			Text = item[1], BackgroundColor3 = item.accent and Theme.Accent or Theme.Panel3 }, item[2])
		if item.accent then
			accent(b, "BackgroundColor3")
		end
		made[k] = b
	end
	return r, made
end

function C.input(parent, label, placeholder, get, set, multiline)
	local r = row(parent, multiline and 150 or 62)
	text({ Parent = r, Position = UDim2.fromOffset(12, 6), Size = UDim2.new(1, -24, 0, 18), Text = label, Font = FONT_MED })
	local box = new("TextBox", {
		Parent = r, Position = UDim2.fromOffset(10, 28), Size = UDim2.new(1, -20, 1, -36), BackgroundColor3 = Theme.Bg,
		Text = get and get() or "", PlaceholderText = placeholder or "", PlaceholderColor3 = Theme.Dim, TextColor3 = Theme.Text,
		Font = multiline and Enum.Font.Code or FONT, TextSize = 12, ClearTextOnFocus = false, MultiLine = multiline or false,
		TextWrapped = multiline or false, TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = multiline and Enum.TextYAlignment.Top or Enum.TextYAlignment.Center, ClipsDescendants = true,
	}, { corner(5), padding(4, 8), stroke(Theme.Stroke) })
	if set then
		box.FocusLost:Connect(function()
			set(box.Text)
			saveSettings()
		end)
	end
	return r, box
end

local listeningBind = nil
function C.keybind(parent, label, key)
	local r = row(parent, 38)
	text({ Parent = r, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -150, 1, 0), Text = label, Font = FONT_MED })
	local b = btn({ Parent = r, Size = UDim2.fromOffset(124, 26), Position = UDim2.new(1, -134, 0.5, -13), Text = "" })
	local function render()
		b.Text = S.Keys[key] ~= "" and S.Keys[key] or "None"
	end
	b.MouseButton1Click:Connect(function()
		b.Text = "press a key..."
		listeningBind = function(code)
			S.Keys[key] = (code == Enum.KeyCode.Backspace or code == Enum.KeyCode.Escape) and "" or code.Name
			render()
			saveSettings()
		end
	end)
	render()
	refreshers[#refreshers + 1] = render
	return r
end

function C.note(parent, str)
	local l = text({ Parent = parent, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Text = str, TextSize = 11,
		TextColor3 = Theme.Dim, TextWrapped = true, TextTruncate = Enum.TextTruncate.None, LayoutOrder = nextOrder() })
	return l
end

---------------------------------------------------------------------------------------------------
-- notifications
---------------------------------------------------------------------------------------------------
local toastHolder = new("Frame", { Parent = gui, AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -16, 1, -16), Size = UDim2.fromOffset(300, 400), BackgroundTransparency = 1 },
	{ new("UIListLayout", { Padding = UDim.new(0, 6), VerticalAlignment = Enum.VerticalAlignment.Bottom, HorizontalAlignment = Enum.HorizontalAlignment.Right, SortOrder = Enum.SortOrder.LayoutOrder }) })

function UI.notify(msg, isError)
	if not S.Notify and not isError then
		return
	end
	local f = new("Frame", { Parent = toastHolder, Size = UDim2.fromOffset(280, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 1, LayoutOrder = nextOrder() }, { corner(8), padding(10, 14), stroke(isError and Theme.Bad or Theme.Stroke) })
	local strip = new("Frame", { Parent = f, Size = UDim2.new(0, 3, 1, 0), Position = UDim2.fromOffset(-8, 0), BackgroundColor3 = isError and Theme.Bad or Theme.Accent }, { corner(2) })
	local l = text({ Parent = f, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Text = msg, TextWrapped = true,
		TextTruncate = Enum.TextTruncate.None, TextTransparency = 1, TextSize = 12 })
	tween(f, 0.25, { BackgroundTransparency = 0 })
	tween(l, 0.25, { TextTransparency = 0 })
	task.delay(isError and 5 or 3, function()
		tween(f, 0.3, { BackgroundTransparency = 1 })
		tween(l, 0.3, { TextTransparency = 1 })
		strip.Visible = false
		task.wait(0.32)
		f:Destroy()
	end)
end

---------------------------------------------------------------------------------------------------
-- now-playing bar (bottom)
---------------------------------------------------------------------------------------------------
local nowBar = new("Frame", { Parent = main, Position = UDim2.new(0, 0, 1, -BAR_H), Size = UDim2.new(1, 0, 0, BAR_H), BackgroundColor3 = Theme.Panel, BorderSizePixel = 0 })
new("Frame", { Parent = nowBar, Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = Theme.Stroke, BorderSizePixel = 0 })
local nowTitle = text({ Parent = nowBar, Position = UDim2.fromOffset(14, 12), Size = UDim2.fromOffset(170, 18), Text = "Nothing playing", Font = FONT_BOLD })
local nowArtist = text({ Parent = nowBar, Position = UDim2.fromOffset(14, 32), Size = UDim2.fromOffset(170, 16), Text = "Pick a song from the library", TextSize = 11, TextColor3 = Theme.Sub })

local ctrl = new("Frame", { Parent = nowBar, Position = UDim2.new(0, 196, 0, 6), Size = UDim2.fromOffset(224, 30), BackgroundTransparency = 1 })
local prevBtn = btn({ Parent = ctrl, Size = UDim2.fromOffset(30, 28), Position = UDim2.fromOffset(0, 1), Text = "⏮", BackgroundColor3 = Theme.Panel2 }, function()
	Player.prev()
end)
local playBtn = btn({ Parent = ctrl, Size = UDim2.fromOffset(44, 30), Position = UDim2.fromOffset(36, 0), Text = "▶", TextSize = 15 }, function()
	Player.toggle()
end)
accent(playBtn, "BackgroundColor3")
local stopBtn = btn({ Parent = ctrl, Size = UDim2.fromOffset(30, 28), Position = UDim2.fromOffset(86, 1), Text = "■", BackgroundColor3 = Theme.Panel2 }, function()
	Player.stop()
end)
local nextBtn = btn({ Parent = ctrl, Size = UDim2.fromOffset(30, 28), Position = UDim2.fromOffset(120, 1), Text = "⏭", BackgroundColor3 = Theme.Panel2 }, function()
	Player.next()
end)
btn({ Parent = ctrl, Size = UDim2.fromOffset(30, 28), Position = UDim2.fromOffset(156, 1), Text = "🔥", BackgroundColor3 = Theme.Panel2 }, function()
	Perform.warmupAndPlay()
end)
btn({ Parent = ctrl, Size = UDim2.fromOffset(34, 28), Position = UDim2.fromOffset(190, 1), Text = "LIVE", TextSize = 10, Font = FONT_BOLD, BackgroundColor3 = Theme.Panel2 }, function()
	Live.visible = not Live.shown
end)
local _ = prevBtn and stopBtn and nextBtn

local timeLeft = text({ Parent = nowBar, Position = UDim2.new(0, 196, 0, 40), Size = UDim2.fromOffset(36, 16), Text = "0:00", TextSize = 11, TextColor3 = Theme.Sub })
local timeRight = text({ Parent = nowBar, Position = UDim2.new(1, -50, 0, 40), Size = UDim2.fromOffset(36, 16), Text = "0:00", TextSize = 11, TextColor3 = Theme.Sub, TextXAlignment = Enum.TextXAlignment.Right })
local progBg = new("Frame", { Parent = nowBar, Position = UDim2.new(0, 234, 0, 46), Size = UDim2.new(1, -290, 0, 5), BackgroundColor3 = Theme.Stroke }, { corner(3) })
local progFill = new("Frame", { Parent = progBg, Size = UDim2.new(0, 0, 1, 0) }, { corner(3) })
accent(progFill, "BackgroundColor3")
local progHit = new("TextButton", { Parent = nowBar, Position = UDim2.new(0, 230, 0, 38), Size = UDim2.new(1, -282, 0, 20), BackgroundTransparency = 1, Text = "" })
progHit.MouseButton1Down:Connect(function(x)
	Player.seek((x - progBg.AbsolutePosition.X) / math.max(progBg.AbsoluteSize.X, 1))
end)

local quick = text({ Parent = nowBar, Position = UDim2.new(0, 430, 0, 8), Size = UDim2.new(1, -444, 0, 26), Text = "", TextSize = 11, TextColor3 = Theme.Sub, TextXAlignment = Enum.TextXAlignment.Right })

local function quickText()
	local parts = { ("%.2gx"):format(S.Speed), (S.Transpose >= 0 and "+" or "") .. S.Transpose .. " st", S.NoteMode }
	if S.Instrument == "Guitar" then
		table.insert(parts, 1, "🎸 " .. S.Guitar.Tuning)
	end
	if S.Human.Enabled then
		parts[#parts + 1] = "Human: " .. S.Human.Preset
	end
	if S.Improv.Enabled then
		parts[#parts + 1] = "Improv"
	end
	if S.Loop ~= "Off" then
		parts[#parts + 1] = "Loop " .. S.Loop
	end
	if S.Shuffle then
		parts[#parts + 1] = "Shuffle"
	end
	return table.concat(parts, "  ·  ")
end

---------------------------------------------------------------------------------------------------
-- pages
---------------------------------------------------------------------------------------------------
local libraryPage = makePage("Library", "♫", false)
local playerPage = makePage("Player", "▶", true)
local queuePage = makePage("Queue", "☰", true)
local humanPage = makePage("Humanize", "✋", true)
local performPage = makePage("Perform", "✦", true)
local guitarPage = makePage("Guitar", "🎸", true)
local importPage = makePage("Import", "⇩", true)
local settingsPage = makePage("Settings", "⚙", true)

-- sidebar footer: song count
local sideInfo = text({ Parent = sidebar, Size = UDim2.new(1, 0, 0, 40), Text = "", TextSize = 11, TextColor3 = Theme.Dim, TextWrapped = true,
	TextTruncate = Enum.TextTruncate.None, TextYAlignment = Enum.TextYAlignment.Bottom, LayoutOrder = 9999 })

local reloadBtn, visible
do
---------------------------------------------------------------- Library page
local Filter = { query = "", chip = "All" }
local searchBox = new("TextBox", {
	Parent = libraryPage, Position = UDim2.fromOffset(12, 12), Size = UDim2.new(1, -176, 0, 32), BackgroundColor3 = Theme.Panel2,
	PlaceholderText = "🔍  Search songs, composers, tags...", PlaceholderColor3 = Theme.Dim, Text = "", TextColor3 = Theme.Text,
	Font = FONT, TextSize = 13, ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left,
}, { corner(7), padding(0, 12), stroke(Theme.Stroke) })
local SORTS = { "A-Z", "Artist", "Newest", "Shortest", "Longest", "Easiest", "Hardest" }
local sortBtn = btn({ Parent = libraryPage, Position = UDim2.new(1, -158, 0, 12), Size = UDim2.fromOffset(104, 32), Text = "Sort: " .. S.Sort, TextSize = 12, BackgroundColor3 = Theme.Panel2 })
reloadBtn = btn({ Parent = libraryPage, Position = UDim2.new(1, -48, 0, 12), Size = UDim2.fromOffset(36, 32), Text = "⟳", TextSize = 16, BackgroundColor3 = Theme.Panel2 })

local chipBar = new("ScrollingFrame", { Parent = libraryPage, Position = UDim2.fromOffset(12, 52), Size = UDim2.new(1, -24, 0, 28), BackgroundTransparency = 1,
	BorderSizePixel = 0, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.X, ScrollBarThickness = 0, ScrollingDirection = Enum.ScrollingDirection.X },
	{ vlist(6, Enum.FillDirection.Horizontal) })
local countLabel = text({ Parent = libraryPage, Position = UDim2.fromOffset(14, 84), Size = UDim2.new(1, -28, 0, 16), Text = "", TextSize = 11, TextColor3 = Theme.Dim })
local songList = new("ScrollingFrame", { Parent = libraryPage, Position = UDim2.fromOffset(12, 104), Size = UDim2.new(1, -18, 1, -110), BackgroundTransparency = 1,
	BorderSizePixel = 0, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 4, ScrollBarImageColor3 = Theme.Stroke },
	{ vlist(5), padding(0, 0, 6, 6) })

visible = {}
local MAX_ROWS = 350

local function matches(e)
	local chip = Filter.chip
	if chip == "★ Favorites" then
		if not S.Favorites[e.id] then
			return false
		end
	elseif chip == "Recent" then
		local found = false
		for _, id in ipairs(S.Recent) do
			if id == e.id then
				found = true
				break
			end
		end
		if not found then
			return false
		end
	elseif chip ~= "All" then
		local tagged = false
		for _, t in ipairs(e.tags) do
			if t == chip:lower() then
				tagged = true
				break
			end
		end
		if not tagged then
			return false
		end
	end
	for word in Filter.query:lower():gmatch("%S+") do
		if not e.search:find(word, 1, true) then
			return false
		end
	end
	return true
end

local function sortEntries(list)
	local s = S.Sort
	if Filter.chip == "Recent" then
		local rank = {}
		for k, id in ipairs(S.Recent) do
			rank[id] = k
		end
		table.sort(list, function(a, b)
			return (rank[a.id] or 999) < (rank[b.id] or 999)
		end)
		return
	end
	table.sort(list, function(a, b)
		if s == "Artist" and a.artist ~= b.artist then
			return a.artist:lower() < b.artist:lower()
		elseif s == "Newest" and a.added ~= b.added then
			return (a.added or 0) > (b.added or 0)
		elseif s == "Shortest" and a.duration ~= b.duration then
			return a.duration < b.duration
		elseif s == "Longest" and a.duration ~= b.duration then
			return a.duration > b.duration
		elseif s == "Easiest" and a.nps ~= b.nps then
			return a.nps < b.nps
		elseif s == "Hardest" and a.nps ~= b.nps then
			return a.nps > b.nps
		end
		return a.name:lower() < b.name:lower()
	end)
end

function UI.visibleEntries()
	return visible
end

local rowPool = {}
local function makeRow(e, order)
	local isNow = Player.entry and Player.entry.id == e.id
	local r = new("TextButton", { Parent = songList, Size = UDim2.new(1, 0, 0, 46), BackgroundColor3 = isNow and Theme.Panel3 or Theme.Panel2, Text = "",
		AutoButtonColor = false, LayoutOrder = order }, { corner(7) })
	hover(r)
	if isNow then
		local bar = new("Frame", { Parent = r, Size = UDim2.new(0, 3, 0.6, 0), Position = UDim2.new(0, 0, 0.2, 0) }, { corner(2) })
		accent(bar, "BackgroundColor3")
	end
	text({ Parent = r, Position = UDim2.fromOffset(12, 6), Size = UDim2.new(1, -130, 0, 18), Text = e.name, Font = FONT_MED })
	local info = { e.artist }
	if e.duration and e.duration > 0 then
		info[#info + 1] = fmtTime(e.duration)
	end
	if e.nps and e.nps > 0 then
		info[#info + 1] = stars(e.nps)
	end
	if e.source ~= "remote" then
		info[#info + 1] = e.source
	end
	text({ Parent = r, Position = UDim2.fromOffset(12, 25), Size = UDim2.new(1, -130, 0, 15), Text = table.concat(info, "  ·  "), TextSize = 11, TextColor3 = Theme.Sub })
	local fav = btn({ Parent = r, Size = UDim2.fromOffset(30, 30), Position = UDim2.new(1, -112, 0.5, -15), Text = S.Favorites[e.id] and "★" or "☆",
		TextColor3 = S.Favorites[e.id] and Theme.Gold or Theme.Dim, TextSize = 16, BackgroundColor3 = Theme.Panel2 })
	fav.MouseButton1Click:Connect(function()
		S.Favorites[e.id] = (not S.Favorites[e.id]) or nil
		fav.Text = S.Favorites[e.id] and "★" or "☆"
		fav.TextColor3 = S.Favorites[e.id] and Theme.Gold or Theme.Dim
		saveSettings()
	end)
	btn({ Parent = r, Size = UDim2.fromOffset(30, 30), Position = UDim2.new(1, -78, 0.5, -15), Text = "+", TextSize = 17, BackgroundColor3 = Theme.Panel3 }, function()
		table.insert(Player.queue, e)
		UI.notify("Queued: " .. e.name)
		if UI.renderQueue then
			UI.renderQueue()
		end
	end)
	local play = btn({ Parent = r, Size = UDim2.fromOffset(36, 30), Position = UDim2.new(1, -44, 0.5, -15), Text = "▶" }, function()
		Player.playEntry(e)
	end)
	accent(play, "BackgroundColor3")
	r.MouseButton1Click:Connect(function()
		Player.playEntry(e)
	end)
	r.MouseButton2Click:Connect(function()
		table.insert(Player.queue, e)
		UI.notify("Queued: " .. e.name)
		if UI.renderQueue then
			UI.renderQueue()
		end
	end)
	return r
end

function UI.renderList()
	for _, r in ipairs(rowPool) do
		r:Destroy()
	end
	rowPool = {}
	visible = {}
	for _, e in ipairs(Lib.entries) do
		if matches(e) then
			visible[#visible + 1] = e
		end
	end
	sortEntries(visible)
	for k = 1, math.min(#visible, MAX_ROWS) do
		rowPool[k] = makeRow(visible[k], k)
	end
	countLabel.Text = ("%d song%s%s"):format(#visible, #visible == 1 and "" or "s", #visible > MAX_ROWS and ("  (showing first %d - search to narrow)"):format(MAX_ROWS) or "")
	if #visible == 0 then
		rowPool[1] = text({ Parent = songList, Size = UDim2.new(1, 0, 0, 60), Text = Filter.chip == "★ Favorites" and "No favorites yet - press ☆ on a song." or "No songs found.",
			TextColor3 = Theme.Dim, TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 1 })
	end
end

local chipButtons = {}
function UI.renderChips()
	for _, c in ipairs(chipButtons) do
		c:Destroy()
	end
	chipButtons = {}
	local counts = {}
	for _, e in ipairs(Lib.entries) do
		for _, t in ipairs(e.tags) do
			counts[t] = (counts[t] or 0) + 1
		end
	end
	local tags = {}
	for t, n in pairs(counts) do
		if t ~= "mutopia" and t ~= "built-in" then
			tags[#tags + 1] = { t, n }
		end
	end
	table.sort(tags, function(a, b)
		return a[2] > b[2]
	end)
	local chips = { "All", "★ Favorites", "Recent" }
	if counts.guitar then
		chips[#chips + 1] = "Guitar"
	end
	for k = 1, math.min(#tags, 10) do
		if tags[k][1] ~= "guitar" then
			chips[#chips + 1] = tags[k][1]:sub(1, 1):upper() .. tags[k][1]:sub(2)
		end
	end
	for k, name in ipairs(chips) do
		local on = Filter.chip == name
		local b = btn({ Parent = chipBar, Size = UDim2.fromOffset(0, 26), AutomaticSize = Enum.AutomaticSize.X, Text = name, TextSize = 12,
			BackgroundColor3 = on and Theme.Accent or Theme.Panel2, TextColor3 = on and Theme.Text or Theme.Sub, LayoutOrder = k }, function()
			Filter.chip = name
			UI.renderChips()
			UI.renderList()
		end)
		padding(0, 12).Parent = b
		chipButtons[#chipButtons + 1] = b
	end
end

do
	local token = 0
	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		token += 1
		local my = token
		task.delay(0.2, function()
			if my == token then
				Filter.query = searchBox.Text
				UI.renderList()
			end
		end)
	end)
end
sortBtn.MouseButton1Click:Connect(function()
	local idx = table.find(SORTS, S.Sort) or 1
	S.Sort = SORTS[idx % #SORTS + 1]
	sortBtn.Text = "Sort: " .. S.Sort
	saveSettings()
	UI.renderList()
end)

function UI.showGuitarChip()
	Filter.chip = "Guitar"
	UI.renderChips()
	UI.renderList()
	selectTab("Library")
end

function UI.playFirstVisible()
	if visible[1] then
		Player.playEntry(visible[1])
	end
end

end
local npArtist, npName, npStats
do
---------------------------------------------------------------- Player page
local npCard = new("Frame", { Parent = playerPage, Size = UDim2.new(1, 0, 0, 74), BackgroundColor3 = Theme.Panel2, LayoutOrder = nextOrder() }, { corner(8) })
local npGrad = new("UIGradient", { Parent = npCard, Rotation = 0, Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 1) }) })
local npAccent = new("Frame", { Parent = npCard, Size = UDim2.fromScale(1, 1), BackgroundTransparency = 0.85, ZIndex = 0 }, { corner(8) })
accent(npAccent, "BackgroundColor3")
local _ = npGrad
npName = text({ Parent = npCard, Position = UDim2.fromOffset(14, 10), Size = UDim2.new(1, -28, 0, 22), Text = "No song loaded", Font = FONT_BOLD, TextSize = 17 })
npArtist = text({ Parent = npCard, Position = UDim2.fromOffset(14, 33), Size = UDim2.new(1, -28, 0, 16), Text = "Choose something in the Library tab", TextColor3 = Theme.Sub, TextSize = 12 })
npStats = text({ Parent = npCard, Position = UDim2.fromOffset(14, 52), Size = UDim2.new(1, -28, 0, 14), Text = "", TextColor3 = Theme.Dim, TextSize = 11 })

-- live keyboard visualizer (C2..C7)
local kb = new("Frame", { Parent = playerPage, Size = UDim2.new(1, 0, 0, 58), BackgroundColor3 = Theme.Panel2, LayoutOrder = nextOrder() }, { corner(8), padding(6, 6) })
local kbInner = new("Frame", { Parent = kb, Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 })
local keyFrames = {}
do
	local whites = 0
	for p = VP_LOW, VP_HIGH do
		if not BLACK[p % 12] then
			whites += 1
		end
	end
	local wIndex = 0
	for p = VP_LOW, VP_HIGH do
		if not BLACK[p % 12] then
			local f = new("Frame", { Parent = kbInner, Size = UDim2.new(1 / whites, -1, 1, 0), Position = UDim2.new(wIndex / whites, 0, 0, 0),
				BackgroundColor3 = Color3.fromRGB(225, 228, 238), BorderSizePixel = 0 }, { corner(2) })
			keyFrames[p] = { f, f.BackgroundColor3 }
			wIndex += 1
		end
	end
	wIndex = 0
	for p = VP_LOW, VP_HIGH do
		if BLACK[p % 12] then
			local f = new("Frame", { Parent = kbInner, Size = UDim2.new(0.6 / whites, 0, 0.6, 0), Position = UDim2.new((wIndex - 0.3) / whites, 0, 0, 0),
				BackgroundColor3 = Color3.fromRGB(24, 26, 34), BorderSizePixel = 0, ZIndex = 2 }, { corner(2) })
			keyFrames[p] = { f, f.BackgroundColor3 }
		else
			wIndex += 1
		end
	end
end

function UI.flashKey(p)
	local k = keyFrames[p]
	if not k or not playerPage.Visible then
		return
	end
	k[1].BackgroundColor3 = Theme.Accent
	tween(k[1], 0.35, { BackgroundColor3 = k[2] })
end

C.section(playerPage, "Playback")
C.slider(playerPage, "Speed", 0.25, 3, 0.05, function()
	return S.Speed
end, function(v)
	S.Speed = v
	Live.speedTarget = nil
end, function(v)
	return ("%.2fx"):format(v)
end)
C.slider(playerPage, "Transpose", -24, 24, 1, function()
	return S.Transpose
end, function(v)
	S.Transpose = v
	Player.requestRebuild()
end, function(v)
	return (v > 0 and "+" or "") .. v .. " semitones"
end)
C.toggle(playerPage, "Auto transpose", function()
	return S.AutoTranspose
end, function(v)
	S.AutoTranspose = v
	if v and Player.song then
		S.Transpose = Player.bestTranspose(Player.song)
		Player.requestRebuild()
		refreshAll()
	end
end, "Pick the shift that fits the most notes on the 61 keys")
C.cycle(playerPage, "Out-of-range notes", { "Fold", "Drop", "88-Key" }, function()
	return S.RangeMode
end, function(v)
	S.RangeMode = v
	Player.requestRebuild()
end, "Fold = move into range by octaves · 88-Key = Ctrl+key pianos")
C.cycle(playerPage, "Note style", { "Tap", "Hold" }, function()
	return S.NoteMode
end, function(v)
	S.NoteMode = v
end, "Hold keeps keys down for the real note length")
C.slider(playerPage, "Tap length", 10, 150, 5, function()
	return S.TapMs
end, function(v)
	S.TapMs = v
end, function(v)
	return v .. " ms"
end)

C.section(playerPage, "Notes")
C.cycle(playerPage, "Hands", { "Both", "Right", "Left" }, function()
	return S.Hand
end, function(v)
	S.Hand = v
	Player.requestRebuild()
end, "Play only notes above / below the split point")
C.slider(playerPage, "Hand split point", 48, 72, 1, function()
	return S.Split
end, function(v)
	S.Split = v
	Player.requestRebuild()
end, function(v)
	return noteName(v)
end)
C.slider(playerPage, "Max notes per chord", 0, 10, 1, function()
	return S.MaxChord
end, function(v)
	S.MaxChord = v
	Player.requestRebuild()
end, function(v)
	return v == 0 and "unlimited" or tostring(v)
end)
C.slider(playerPage, "Min repeat gap (same key)", 0, 120, 5, function()
	return S.MinRepeat
end, function(v)
	S.MinRepeat = v
	Player.requestRebuild()
end, function(v)
	return v .. " ms"
end)

local tracksSection = C.section(playerPage, "Tracks", "Click to mute / unmute a MIDI track")
local tracksRow = new("Frame", { Parent = playerPage, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = nextOrder() },
	{ new("UIGridLayout", { CellSize = UDim2.fromOffset(150, 28), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })

function UI.renderTracks()
	for _, c in ipairs(tracksRow:GetChildren()) do
		if c:IsA("GuiButton") then
			c:Destroy()
		end
	end
	local song = Player.song
	local show = song and song.trackCount > 1
	tracksSection.Visible, tracksRow.Visible = show, show
	if not show then
		return
	end
	for t = 0, song.trackCount - 1 do
		local nm = song.tracks[t + 1]
		local prog = song.programs and song.programs[t + 1]
		local inst = prog and ((prog >= 24 and prog <= 31) and "🎸" or (prog >= 32 and prog <= 39) and "bass" or (prog < 8) and "piano" or "") or ""
		local label = ("T%d %s %s"):format(t + 1, inst, (nm and nm ~= "") and nm or "")
		local b = btn({ Parent = tracksRow, Text = label, TextSize = 11, LayoutOrder = t, TextTruncate = Enum.TextTruncate.AtEnd })
		local function render()
			local on = not Player.muted[t]
			b.BackgroundColor3 = on and Theme.Accent or Theme.Panel3
			b.TextColor3 = on and Theme.Text or Theme.Dim
		end
		b.MouseButton1Click:Connect(function()
			Player.muted[t] = (not Player.muted[t]) or nil
			render()
			Player.requestRebuild()
		end)
		render()
	end
end

C.section(playerPage, "After a song")
C.cycle(playerPage, "Loop", { "Off", "One", "All" }, function()
	return S.Loop
end, function(v)
	S.Loop = v
end)
C.toggle(playerPage, "Autoplay next song", function()
	return S.Autoplay
end, function(v)
	S.Autoplay = v
end)
C.toggle(playerPage, "Shuffle", function()
	return S.Shuffle
end, function(v)
	S.Shuffle = v
end)

end
do
---------------------------------------------------------------- Queue page
C.section(queuePage, "Up next", "Right-click a song or press + in the library to queue it")
C.buttons(queuePage, {
	{ "Shuffle queue", function()
		local q = Player.queue
		for k = #q, 2, -1 do
			local j = math.random(1, k)
			q[k], q[j] = q[j], q[k]
		end
		UI.renderQueue()
	end },
	{ "Clear queue", function()
		Player.queue = {}
		UI.renderQueue()
	end },
	{ "Play queue", function()
		if #Player.queue > 0 then
			Player.playEntry(table.remove(Player.queue, 1))
			UI.renderQueue()
		end
	end, accent = true },
})
local queueList = new("Frame", { Parent = queuePage, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = nextOrder() }, { vlist(5) })
C.section(queuePage, "History")
local historyList = new("Frame", { Parent = queuePage, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = nextOrder() }, { vlist(5) })

local function queueRow(parent, e, k, buttons)
	local r = new("Frame", { Parent = parent, Size = UDim2.new(1, 0, 0, 36), BackgroundColor3 = Theme.Panel2, LayoutOrder = k }, { corner(6) })
	text({ Parent = r, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -140, 1, 0), Text = ("%d.  %s  ·  %s"):format(k, e.name, e.artist), TextSize = 12 })
	for i, b in ipairs(buttons) do
		btn({ Parent = r, Size = UDim2.fromOffset(28, 26), Position = UDim2.new(1, -34 * i, 0.5, -13), Text = b[1], BackgroundColor3 = Theme.Panel3 }, b[2])
	end
end

function UI.renderQueue()
	for _, c in ipairs(queueList:GetChildren()) do
		if not c:IsA("UIListLayout") then
			c:Destroy()
		end
	end
	for _, c in ipairs(historyList:GetChildren()) do
		if not c:IsA("UIListLayout") then
			c:Destroy()
		end
	end
	local q = Player.queue
	if #q == 0 then
		text({ Parent = queueList, Size = UDim2.new(1, 0, 0, 30), Text = "Queue is empty.", TextColor3 = Theme.Dim, LayoutOrder = 1 })
	end
	for k, e in ipairs(q) do
		queueRow(queueList, e, k, {
			{ "✕", function()
				table.remove(q, k)
				UI.renderQueue()
			end },
			{ "↓", function()
				if k < #q then
					q[k], q[k + 1] = q[k + 1], q[k]
					UI.renderQueue()
				end
			end },
			{ "↑", function()
				if k > 1 then
					q[k], q[k - 1] = q[k - 1], q[k]
					UI.renderQueue()
				end
			end },
		})
	end
	local h = Player.history
	for k = #h, math.max(1, #h - 14), -1 do
		local e = h[k]
		queueRow(historyList, e, #h - k + 1, { { "▶", function()
			Player.playEntry(e)
		end } })
	end
end

end
do
---------------------------------------------------------------- Humanize page
local PRESETS = {
	Natural = { Jitter = 10, Roll = 16, Drift = 3, Miss = 0.4, Wrong = 0.3, Correct = true, HoldVar = 15, Hesitate = 70, Fingers = true },
	Expressive = { Jitter = 16, Roll = 30, Drift = 7, Miss = 0.6, Wrong = 0.4, Correct = true, HoldVar = 25, Hesitate = 160, Fingers = true },
	Sloppy = { Jitter = 28, Roll = 40, Drift = 9, Miss = 2, Wrong = 1.5, Correct = true, HoldVar = 35, Hesitate = 220, Fingers = true },
	Beginner = { Jitter = 40, Roll = 55, Drift = 12, Miss = 3.5, Wrong = 3, Correct = true, HoldVar = 40, Hesitate = 380, Fingers = true },
}

C.section(humanPage, "Humanizer", "Makes playback look like a real person is at the keys")
C.toggle(humanPage, "Play like a human", function()
	return S.Human.Enabled
end, function(v)
	S.Human.Enabled = v
	Player.requestRebuild()
end, "Off = perfect, robotic timing")

C.section(humanPage, "Presets")
local function applyPreset(name)
	for k, v in pairs(PRESETS[name]) do
		S.Human[k] = v
	end
	S.Human.Preset = name
	S.Human.Enabled = true
	saveSettings()
	refreshAll()
	Player.requestRebuild()
	UI.notify("Humanizer preset: " .. name)
end
C.buttons(humanPage, {
	{ "Natural", function()
		applyPreset("Natural")
	end },
	{ "Expressive", function()
		applyPreset("Expressive")
	end },
	{ "Sloppy", function()
		applyPreset("Sloppy")
	end },
	{ "Beginner", function()
		applyPreset("Beginner")
	end },
})

local function hset(key, rebuild)
	return function(v)
		S.Human[key] = v
		S.Human.Preset = "Custom"
		if rebuild ~= false then
			Player.requestRebuild()
		end
	end
end
local function hget(key)
	return function()
		return S.Human[key]
	end
end
local function ms(v)
	return v .. " ms"
end
local function pct(v)
	return ("%.1f%%"):format(v)
end

C.section(humanPage, "Timing")
C.slider(humanPage, "Timing jitter", 0, 60, 1, hget("Jitter"), hset("Jitter"), ms)
C.slider(humanPage, "Chord roll (strum)", 0, 80, 1, hget("Roll"), hset("Roll"), ms)
C.slider(humanPage, "Tempo drift (rubato)", 0, 20, 0.5, hget("Drift"), hset("Drift", false), pct)
C.slider(humanPage, "Phrase hesitation", 0, 500, 10, hget("Hesitate"), hset("Hesitate"), ms)
C.slider(humanPage, "Hold length variance", 0, 60, 1, hget("HoldVar"), hset("HoldVar"), pct)
C.section(humanPage, "Mistakes")
C.slider(humanPage, "Missed notes", 0, 6, 0.1, hget("Miss"), hset("Miss"), pct)
C.slider(humanPage, "Wrong notes", 0, 5, 0.1, hget("Wrong"), hset("Wrong"), pct)
C.toggle(humanPage, "Correct wrong notes", hget("Correct"), hset("Correct"), "Hit the right key right after a slip, like a person would")
C.toggle(humanPage, "10-finger limit", hget("Fingers"), hset("Fingers"), "Max 5 notes per hand - drops impossible chords")
C.note(humanPage, "Each play generates fresh random variation, so no two runs are identical. Changes apply live.")

end
do
---------------------------------------------------------------- Import page
local sheetText, sheetName, sheetBpm = "", "My sheet", 120
C.section(importPage, "Virtual Piano sheet", "Paste letters like  [tu] y t | [8o] p a ...")
local _, sheetBox = C.input(importPage, "Sheet", "Paste sheet here...", function()
	return ""
end, nil, true)
sheetBox:GetPropertyChangedSignal("Text"):Connect(function()
	sheetText = sheetBox.Text
end)
C.input(importPage, "Name", "Song name", function()
	return sheetName
end, function(v)
	sheetName = v ~= "" and v or "My sheet"
end)
C.slider(importPage, "Sheet tempo", 40, 400, 5, function()
	return sheetBpm
end, function(v)
	sheetBpm = v
end, function(v)
	return v .. " BPM"
end)

local function playMemory(song)
	local e = { id = song.id, name = song.name, artist = song.artist, tags = { "imported" }, duration = song.duration, count = song.count,
		nps = song.nps, source = "memory", song = song, added = os.time() }
	Lib.remember(e.id, song)
	Player.load(song, e)
	Player.start()
	selectTab("Player")
end

local function saveLocal(song)
	if not FS.ok then
		return UI.notify("Your executor has no file access", true)
	end
	local file = (song.name:gsub("[^%w%-_ ]", ""):gsub("%s+", "_")) .. ".json"
	FS.write(ROOT .. "/songs/" .. file, Songs.encode(song))
	Lib.load()
	UI.renderChips()
	UI.renderList()
	UI.notify("Saved to library: " .. song.name)
end

C.buttons(importPage, {
	{ "Play now", function()
		local ok, song = pcall(Songs.parseSheet, sheetText, sheetBpm, sheetName)
		if ok then
			playMemory(song)
		else
			UI.notify(tostring(song), true)
		end
	end, accent = true },
	{ "Save to library", function()
		local ok, song = pcall(Songs.parseSheet, sheetText, sheetBpm, sheetName)
		if ok then
			saveLocal(song)
		else
			UI.notify(tostring(song), true)
		end
	end },
})

C.section(importPage, "From a link", "Direct link to a .mid file or a PianoHub .json song")
local importUrl = ""
C.input(importPage, "URL", "https://...", function()
	return ""
end, function(v)
	importUrl = v
end)
local function loadUrl(thenSave)
	local url = importUrl
	if url == "" then
		return UI.notify("Paste a URL first", true)
	end
	UI.notify("Downloading...")
	task.spawn(function()
		local body = httpGet(url)
		if not body then
			return UI.notify("Download failed", true)
		end
		local name = (url:match("([^/?#]+)[^/]*$") or "song"):gsub("%.%w+$", ""):gsub("%%20", " "):gsub("_", " ")
		local ok, song = pcall(function()
			if body:sub(1, 4) == "MThd" or body:find("MThd", 1, true) == 1 then
				return Songs.parseMidi(body, name)
			end
			return Songs.fromData(assert(jdecode(body), "not a MIDI or song file"), { name = name, artist = "Imported" })
		end)
		if not ok then
			return UI.notify(tostring(song), true)
		end
		song.id = "url:" .. url
		if thenSave then
			saveLocal(song)
		else
			playMemory(song)
		end
	end)
end
C.buttons(importPage, {
	{ "Play now", function()
		loadUrl(false)
	end, accent = true },
	{ "Save to library", function()
		loadUrl(true)
	end },
})

C.section(importPage, "Local files")
C.note(importPage, ("Drop .mid files into  workspace/%s/midi/  (inside your executor's folder) and press Rescan. Each MIDI is converted once and saved to  workspace/%s/songs/  - after that you can delete the .mid files.")
	:format(ROOT, ROOT))
C.buttons(importPage, {
	{ "Rescan local files", function()
		UI.reloadLibrary()
	end },
	{ "Export current song", function()
		if Player.song then
			saveLocal(Player.song)
		else
			UI.notify("Nothing loaded", true)
		end
	end },
})
C.note(importPage, "Want a song for everyone? Use the Discord bot: /addsong with a .mid attached. It shows up in every user's library the next time PianoHub loads.")

end
do
---------------------------------------------------------------- Settings page
C.section(settingsPage, "Library")
C.input(settingsPage, "Library URL (raw GitHub 'library/' folder)", "https://raw.githubusercontent.com/<user>/<repo>/main/library/", function()
	return S.LibraryURL
end, function(v)
	S.LibraryURL = v
end)
C.buttons(settingsPage, {
	{ "Reload library", function()
		UI.reloadLibrary()
	end, accent = true },
	{ "Clear song cache", function()
		for _, p in ipairs(FS.list(ROOT .. "/cache")) do
			FS.delete(p)
		end
		Lib.songCache, Lib.cacheOrder = {}, {}
		UI.notify("Cache cleared")
	end },
})

C.section(settingsPage, "Behaviour")
C.slider(settingsPage, "Countdown before playing", 0, 5, 1, function()
	return S.Countdown
end, function(v)
	S.Countdown = v
end, function(v)
	return v == 0 and "off" or (v .. " s")
end)
C.toggle(settingsPage, "Pause while typing in chat", function()
	return S.PauseTyping
end, function(v)
	S.PauseTyping = v
end, "Stops keystrokes from going into the chat box")
C.toggle(settingsPage, "Notifications", function()
	return S.Notify
end, function(v)
	S.Notify = v
end)

C.section(settingsPage, "Hotkeys", "Click, then press a key. Backspace = unbind")
C.keybind(settingsPage, "Show / hide window", "Toggle")
C.keybind(settingsPage, "Play / pause", "PlayPause")
C.keybind(settingsPage, "Stop", "Stop")
C.keybind(settingsPage, "Next song", "Next")
C.keybind(settingsPage, "Previous song", "Prev")
C.keybind(settingsPage, "Live: hesitate", "Hesitate")
C.keybind(settingsPage, "Live: flourish", "Flourish")
C.keybind(settingsPage, "Live: big ending", "Ending")
C.keybind(settingsPage, "Show / hide live panel", "Live")
C.keybind(settingsPage, "Warm up", "Warmup")

C.section(settingsPage, "Appearance")
C.cycle(settingsPage, "Accent color", ACCENT_ORDER, function()
	return S.Accent
end, function(v)
	S.Accent = v
	Theme.Accent = ACCENTS[v]
	for _, r in ipairs(accentRefs) do
		pcall(function()
			r[1][r[2]] = Theme.Accent
		end)
	end
	refreshAll()
	UI.renderChips()
end)
C.slider(settingsPage, "UI scale", 0.7, 1.3, 0.05, function()
	return S.Scale
end, function(v)
	S.Scale = v
	uiScale.Scale = v
end, function(v)
	return ("%d%%"):format(math.floor(v * 100 + 0.5))
end)

C.section(settingsPage, "Tools")
C.buttons(settingsPage, {
	{ "Release stuck keys", function()
		Keys.releaseAll()
		UI.notify("All keys released")
	end },
	{ "Unload PianoHub", function()
		Hub.Unload()
	end },
})
C.note(settingsPage, ("PianoHub v%s  ·  files: workspace/%s/  ·  file access: %s"):format(CONFIG.Version, ROOT, FS.ok and "yes" or "no"))

end
do
---------------------------------------------------------------- Guitar page
do
	local function reapply()
		if Player.song then
			if S.AutoTranspose then
				S.Transpose = Player.bestTranspose(Player.song)
			end
			Player.muted = (Guitar.active() and S.Guitar.TracksOnly) and Guitar.autoMute(Player.song) or {}
			UI.renderTracks()
		end
		Player.requestRebuild()
		refreshAll()
	end

	C.section(guitarPage, "Instrument", "Pick Guitar when you're sitting at a guitar")
	C.cycle(guitarPage, "Play on", { "Piano", "Guitar" }, function()
		return S.Instrument
	end, function(v)
		S.Instrument = v
		Keys.releaseAll()
		reapply()
	end, "Guitar: each key row is a string, keys to the right are higher frets")
	C.cycle(guitarPage, "Tuning (match the game)", Guitar.TUNING_ORDER, function()
		return S.Guitar.Tuning
	end, function(v)
		S.Guitar.Tuning = v
		reapply()
	end, "Must be the same as the TUNING button in the game")
	C.toggle(guitarPage, "Switch to guitar for guitar songs", function()
		return S.Guitar.AutoSwitch
	end, function(v)
		S.Guitar.AutoSwitch = v
	end, "Songs tagged 'guitar' flip the instrument automatically")

	C.section(guitarPage, "Playing")
	C.toggle(guitarPage, "Guitar tracks only", function()
		return S.Guitar.TracksOnly
	end, function(v)
		S.Guitar.TracksOnly = v
		reapply()
	end, "Mutes vocals, bass, piano etc. when the MIDI has guitar parts")
	C.toggle(guitarPage, "Strum chords", function()
		return S.Guitar.Strum
	end, function(v)
		S.Guitar.Strum = v
		Player.requestRebuild()
	end, "Alternating down / up strokes")
	C.slider(guitarPage, "Strum speed", 4, 40, 1, function()
		return S.Guitar.StrumMs
	end, function(v)
		S.Guitar.StrumMs = v
		Player.requestRebuild()
	end, function(v)
		return v .. " ms / string"
	end)
	C.slider(guitarPage, "Max finger stretch", 3, 7, 1, function()
		return S.Guitar.Stretch
	end, function(v)
		S.Guitar.Stretch = v
		Player.requestRebuild()
	end, function(v)
		return v .. " frets"
	end)
	C.toggle(guitarPage, "Vibrato on long notes", function()
		return S.Guitar.Vibrato
	end, function(v)
		S.Guitar.Vibrato = v
	end, "Holds Ctrl while long notes ring")
	C.toggle(guitarPage, "Palm-mute short low notes", function()
		return S.Guitar.PalmMute
	end, function(v)
		S.Guitar.PalmMute = v
	end, "Holds Space for quick notes on the E, A and D strings")
	C.note(guitarPage, "In the game: keep CAPS (octave) off. RING on lets notes ring across strings, off cuts them.")

	C.section(guitarPage, "Guitar songs", "Library songs tagged guitar + your workspace/" .. ROOT .. "/guitar folder")
	C.buttons(guitarPage, {
		{ "Rescan", function()
			UI.reloadLibrary()
		end },
		{ "Show in Library", function()
			UI.showGuitarChip()
		end },
	})
	local list = new("Frame", { Parent = guitarPage, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
		LayoutOrder = nextOrder() }, { vlist(5) })

	function UI.renderGuitarList()
		for _, c in ipairs(list:GetChildren()) do
			if not c:IsA("UIListLayout") then
				c:Destroy()
			end
		end
		local songs = {}
		for _, e in ipairs(Lib.entries) do
			if table.find(e.tags or {}, "guitar") then
				songs[#songs + 1] = e
			end
		end
		table.sort(songs, function(a, b)
			return a.name:lower() < b.name:lower()
		end)
		if #songs == 0 then
			text({ Parent = list, Size = UDim2.new(1, 0, 0, 30), Text = "No guitar songs yet - see below for where to get them.", TextColor3 = Theme.Dim, LayoutOrder = 1 })
		end
		for k, e in ipairs(songs) do
			if k > 200 then
				break
			end
			local r = new("Frame", { Parent = list, Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = Theme.Panel2, LayoutOrder = k }, { corner(6) })
			text({ Parent = r, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -130, 1, 0), TextSize = 12,
				Text = ("%s  ·  %s%s"):format(e.name, e.artist, (e.duration or 0) > 0 and ("  ·  " .. fmtTime(e.duration)) or "") })
			btn({ Parent = r, Size = UDim2.fromOffset(30, 28), Position = UDim2.new(1, -112, 0.5, -14), Text = "🔥", BackgroundColor3 = Theme.Panel3 }, function()
				Player.playEntry(e)
				task.delay(0.3, function()
					if Player.entry == e then
						Perform.warmupAndPlay()
					end
				end)
			end)
			btn({ Parent = r, Size = UDim2.fromOffset(30, 28), Position = UDim2.new(1, -78, 0.5, -14), Text = "+", TextSize = 16, BackgroundColor3 = Theme.Panel3 }, function()
				table.insert(Player.queue, e)
				UI.notify("Queued: " .. e.name)
				UI.renderQueue()
			end)
			local play = btn({ Parent = r, Size = UDim2.fromOffset(36, 28), Position = UDim2.new(1, -44, 0.5, -14), Text = "▶" }, function()
				Player.playEntry(e)
			end)
			accent(play, "BackgroundColor3")
		end
	end

	C.section(guitarPage, "Where to get guitar songs")
	C.note(guitarPage, "1. Put any .mid file in  workspace/" .. ROOT .. "/guitar/  and press Rescan. It is converted once and saved, so you can delete the .mid afterwards.")
	C.note(guitarPage, "2. MuseScore (musescore.com): open a guitar score in the free MuseScore Studio app, then File > Export > MIDI. Solo / fingerstyle / 'guitar only' arrangements sound best.")
	C.note(guitarPage, "3. Guitar Pro tabs (.gp, .gp5, .gpx - Ultimate Guitar, GProTab): open them in the free TuxGuitar or MuseScore Studio and export as MIDI.")
	C.note(guitarPage, "4. Full-band MIDIs work too: 'Guitar tracks only' keeps just the guitar parts. Use Player > Tracks to pick parts by hand.")
	C.note(guitarPage, "5. To share a song with everyone: Discord bot  /addsong  with  instrument: Guitar.")
end

---------------------------------------------------------------- Perform page
C.section(performPage, "Warm up", "Scales, arpeggios and finger exercises in the song's key, then the song")
UI.keyLabel = C.note(performPage, "Key: -")
C.buttons(performPage, {
	{ "🔥  Warm up now", function()
		Perform.warmupAndPlay()
	end, accent = true },
})
C.toggle(performPage, "Start the song after warming up", function()
	return S.WarmupPlay
end, function(v)
	S.WarmupPlay = v
end, "Crazy songs (fast or tagged crazy) get a longer, flashier warm-up")

C.section(performPage, "Switching songs", "How it moves from one song into the next")
C.cycle(performPage, "Transition", { "Off", "Random", "Cadence", "Glissando", "Playful", "Noodle" }, function()
	return S.Transition
end, function(v)
	S.Transition = v
end, "Cadence · Glissando · Playful (shave & a haircut) · Noodle")

C.section(performPage, "Improv", "Adds its own touches to every song - new each time it plays")
C.toggle(performPage, "Improvise", function()
	return S.Improv.Enabled
end, function(v)
	S.Improv.Enabled = v
	Player.requestRebuild()
end)
C.slider(performPage, "Amount", 0, 100, 5, function()
	return S.Improv.Amount
end, function(v)
	S.Improv.Amount = v
	Player.requestRebuild()
end, function(v)
	return v .. "%"
end)
local function improvToggle(label, field, hint)
	C.toggle(performPage, label, function()
		return S.Improv[field]
	end, function(v)
		S.Improv[field] = v
		Player.requestRebuild()
	end, hint)
end
improvToggle("Ornaments", "Ornaments", "Grace notes, trills and mordents on long notes")
improvToggle("Fills", "Fills", "Little scale runs in the rests that lead into the next phrase")
improvToggle("Broken chords", "Arpeggios", "Rolls some held chords instead of playing them as blocks")
improvToggle("Octave doubling", "Octaves", "Doubles the melody or bass at the start of phrases")
improvToggle("Improvised intro", "Intro", "A short lead-in in the song's key before it starts")
improvToggle("Big finish", "Ending", "Ends every song with an arpeggio and a final chord")

C.section(performPage, "Live panel", "Separate window with real-time controls while you play")
C.toggle(performPage, "Show automatically while playing", function()
	return S.LiveAuto
end, function(v)
	S.LiveAuto = v
	Live.visible = nil
end)
C.buttons(performPage, {
	{ "Open live panel", function()
		Live.visible = true
	end },
	{ "Hide live panel", function()
		Live.visible = false
	end },
})
C.note(performPage, "Hotkeys (change them in Settings): F5 hesitate · F6 flourish · F7 big ending · F8 show/hide live panel.")

---------------------------------------------------------------- Live panel (separate window)
do
	local LW, LH = 300, 362
	local panel = new("Frame", { Parent = gui, Size = UDim2.fromOffset(LW, LH), Position = UDim2.new(1, -LW - 24, 0.5, -LH / 2),
		BackgroundColor3 = Theme.Bg, Visible = false, ClipsDescendants = true }, { corner(10), stroke(Theme.Stroke) })
	local lscale = new("UIScale", { Parent = panel, Scale = S.Scale })
	local head = new("Frame", { Parent = panel, Size = UDim2.new(1, 0, 0, 36), BackgroundColor3 = Theme.Panel }, { corner(10) })
	new("Frame", { Parent = head, Size = UDim2.new(1, 0, 0, 10), Position = UDim2.new(0, 0, 1, -10), BackgroundColor3 = Theme.Panel, BorderSizePixel = 0 })
	local dot = new("Frame", { Parent = head, Size = UDim2.fromOffset(9, 9), Position = UDim2.new(0, 12, 0.5, -4), BackgroundColor3 = Theme.Bad }, { corner(5) })
	text({ Parent = head, Position = UDim2.fromOffset(28, 0), Size = UDim2.fromOffset(40, 36), Text = "LIVE", Font = FONT_BOLD, TextSize = 13 })
	local title = text({ Parent = head, Position = UDim2.fromOffset(70, 0), Size = UDim2.new(1, -110, 1, 0), Text = "", TextColor3 = Theme.Sub, TextSize = 12 })
	btn({ Parent = head, Size = UDim2.fromOffset(26, 24), Position = UDim2.new(1, -32, 0.5, -12), Text = "✕", TextSize = 11, BackgroundColor3 = Theme.Panel2 }, function()
		Live.visible = false
	end)

	do -- drag
		local dragging, dragStart, startPos
		head.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging, dragStart, startPos = true, input.Position, panel.Position
			end
		end)
		bind(UIS.InputChanged, function(input)
			if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				local d = input.Position - dragStart
				panel.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
			end
		end)
		bind(UIS.InputEnded, function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = false
			end
		end)
	end

	local body = new("Frame", { Parent = panel, Position = UDim2.fromOffset(10, 44), Size = UDim2.new(1, -20, 1, -52), BackgroundTransparency = 1 }, { vlist(6) })

	local prog = new("Frame", { Parent = body, Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1, LayoutOrder = 1 })
	local pbg = new("Frame", { Parent = prog, Position = UDim2.new(0, 0, 0.5, -2), Size = UDim2.new(1, -92, 0, 4), BackgroundColor3 = Theme.Stroke }, { corner(2) })
	local pfill = new("Frame", { Parent = pbg, Size = UDim2.new(0, 0, 1, 0) }, { corner(2) })
	accent(pfill, "BackgroundColor3")
	local ptime = text({ Parent = prog, Position = UDim2.new(1, -86, 0, 0), Size = UDim2.fromOffset(86, 16), Text = "", TextSize = 11,
		TextColor3 = Theme.Sub, TextXAlignment = Enum.TextXAlignment.Right })

	local trow = new("Frame", { Parent = body, Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, LayoutOrder = 2 })
	text({ Parent = trow, Size = UDim2.fromOffset(56, 30), Text = "Tempo", Font = FONT_MED, TextSize = 12 })
	btn({ Parent = trow, Position = UDim2.fromOffset(58, 2), Size = UDim2.fromOffset(30, 26), Text = "−" }, function()
		Live.nudge(-1)
	end)
	local tval = text({ Parent = trow, Position = UDim2.fromOffset(90, 0), Size = UDim2.fromOffset(60, 30), Text = "1.00x", Font = FONT_BOLD,
		TextXAlignment = Enum.TextXAlignment.Center })
	btn({ Parent = trow, Position = UDim2.fromOffset(152, 2), Size = UDim2.fromOffset(30, 26), Text = "+" }, function()
		Live.nudge(1)
	end)
	btn({ Parent = trow, Position = UDim2.new(1, -90, 0, 2), Size = UDim2.fromOffset(90, 26), Text = "〰 Rubato", TextSize = 12 }, Live.rubato)

	local function grid(order, cols, h)
		return new("Frame", { Parent = body, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = order },
			{ new("UIGridLayout", { CellSize = UDim2.new(1 / cols, -5, 0, h), CellPadding = UDim2.fromOffset(5, 5), SortOrder = Enum.SortOrder.LayoutOrder }) })
	end
	local function plain(parent, label, order, onClick) -- no hover tween: these get recoloured every frame
		local b = new("TextButton", { Parent = parent, Text = label, TextSize = 12, Font = FONT_MED, TextColor3 = Theme.Text, AutoButtonColor = false,
			BackgroundColor3 = Theme.Panel3, LayoutOrder = order }, { corner(6) })
		b.MouseButton1Click:Connect(onClick)
		return b
	end

	local toggles = {}
	local tg = grid(3, 4, 28)
	local function toggleBtn(label, get, set)
		local b = plain(tg, label, #toggles + 1, function()
			set(not get())
		end)
		toggles[#toggles + 1] = { b, get }
	end
	toggleBtn("L hand", function()
		return not Live.muteL
	end, function(v)
		Live.muteL = not v
	end)
	toggleBtn("R hand", function()
		return not Live.muteR
	end, function(v)
		Live.muteR = not v
	end)
	toggleBtn("Improv", function()
		return S.Improv.Enabled
	end, function(v)
		S.Improv.Enabled = v
		saveSettings()
		Player.requestRebuild()
		refreshAll()
	end)
	toggleBtn("Human", function()
		return S.Human.Enabled
	end, function(v)
		S.Human.Enabled = v
		saveSettings()
		Player.requestRebuild()
		refreshAll()
	end)

	local og = grid(4, 3, 28)
	local octBtns = {}
	for k, o in ipairs({ -1, 0, 1 }) do
		local b = plain(og, o == 0 and "Normal" or (o < 0 and "Octave ↓" or "Octave ↑"), k, function()
			Live.octave = o
		end)
		octBtns[#octBtns + 1] = { b, o }
	end

	text({ Parent = body, Size = UDim2.new(1, 0, 0, 14), Text = "ACTIONS", Font = FONT_BOLD, TextSize = 10, TextColor3 = Theme.Dim, LayoutOrder = 5 })
	local ag = grid(6, 2, 30)
	local actions = {
		{ "⏸  Hesitate", Live.hesitate },
		{ "✗  Slip-up", Live.slipUp },
		{ "↺  Redo phrase", Live.redo },
		{ "✦  Flourish", Live.flourish },
		{ "🔥  Warm up", Perform.warmupAndPlay },
		{ "↷  Next song", function()
			Player.next()
		end },
		{ "♛  Big ending", Live.bigEnding },
		{ "■  Stop", function()
			Player.stop()
		end },
	}
	for k, a in ipairs(actions) do
		btn({ Parent = ag, Text = a[1], TextSize = 12, LayoutOrder = k }, a[2])
	end
	local foot = text({ Parent = body, Size = UDim2.new(1, 0, 0, 16), Text = "", TextSize = 11, TextColor3 = Theme.Dim, LayoutOrder = 7 })

	function Live.refresh(now)
		local show = Live.visible
		if show == nil then
			show = S.LiveAuto and Player.song ~= nil and (Player.playing or Perform.busyUntil > now)
		end
		Live.shown = show
		panel.Visible = show
		if not show then
			return
		end
		lscale.Scale = S.Scale
		title.Text = Player.song and Player.song.name or "Nothing loaded"
		local dur = Player.duration > 0 and Player.duration or 1
		pfill.Size = UDim2.new(math.clamp(Player.pos / dur, 0, 1), 0, 1, 0)
		ptime.Text = fmtTime(Player.pos / 1000) .. " / " .. fmtTime(Player.duration / 1000)
		tval.Text = ("%.2fx"):format(Live.speedTarget or S.Speed)
		for _, t in ipairs(toggles) do
			local on = t[2]()
			t[1].BackgroundColor3 = on and Theme.Accent or Theme.Panel3
			t[1].TextColor3 = on and Theme.Text or Theme.Dim
		end
		for _, o in ipairs(octBtns) do
			o[1].BackgroundColor3 = (Live.octave == o[2]) and Theme.Accent or Theme.Panel3
		end
		local state = "playing"
		if Perform.busyUntil > now and not Player.playing then
			state = "performing…"
		elseif not Player.playing then
			state = "stopped"
		elseif Player.paused then
			state = "paused"
		elseif now < Player.startAt then
			state = "about to start…"
		elseif now < Player.blockUntil then
			state = "hesitating…"
		elseif Player.ending then
			state = "ending…"
		end
		foot.Text = ("%s  ·  %d keys/s  ·  %s"):format(Music.keyName(Music.current()), Live.kps(now), state)
		dot.BackgroundTransparency = (Player.playing and not Player.paused) and (0.5 + 0.5 * math.sin(now * 6)) or 0.6
	end
end
end

---------------------------------------------------------------------------------------------------
-- live refresh
---------------------------------------------------------------------------------------------------
function UI.onSongLoaded()
	local s = Player.song
	nowTitle.Text = s.name
	nowArtist.Text = s.artist
	npName.Text = s.name
	npArtist.Text = s.artist
	npStats.Text = ("%d notes  ·  %s  ·  %.1f notes/s  ·  %s  ·  %d track%s"):format(s.count, fmtTime(s.duration), s.nps, stars(s.nps),
		s.trackCount, s.trackCount == 1 and "" or "s")
	UI.renderTracks()
	if UI.keyLabel then
		UI.keyLabel.Text = ("Key: %s  ·  %s"):format(Music.keyName(Music.current(s)),
			((s.nps or 0) >= 8) and "crazy - expect a big warm-up" or "normal warm-up")
	end
	refreshAll()
	if libraryPage.Visible then
		UI.renderList()
	end
	if UI.renderQueue then
		UI.renderQueue()
	end
end

function UI.refreshNow()
	local playing = Player.playing and not Player.paused
	playBtn.Text = playing and "❚❚" or "▶"
	quick.Text = quickText()
end

function UI.reloadLibrary()
	statusText.Text = "Loading library..."
	statusDot.BackgroundColor3 = Theme.Gold
	task.spawn(function()
		Lib.load()
		local online = Lib.status == "Online"
		statusDot.BackgroundColor3 = online and Theme.Good or (Lib.remoteCount > 0 and Theme.Gold or Theme.Bad)
		statusText.Text = ("%s  ·  %d songs"):format(Lib.status, #Lib.entries)
		sideInfo.Text = ("%d songs\n%d online · %d local"):format(#Lib.entries, Lib.remoteCount, #Lib.entries - Lib.remoteCount)
		UI.renderChips()
		UI.renderList()
		if UI.renderGuitarList then
			UI.renderGuitarList()
		end
		Lib.convertPending(function(done, failed)
			if done > 0 then
				if UI.renderGuitarList then
					UI.renderGuitarList()
				end
				UI.notify(("Converted %d MIDI file%s - saved in %s/songs. You can delete the .mid files now."):format(done, done == 1 and "" or "s", ROOT))
				UI.renderList()
			end
			if failed > 0 then
				UI.notify(("%d MIDI file%s could not be read (see console)"):format(failed, failed == 1 and "" or "s"), true)
			end
		end)
		if Lib.status == "No library URL set" then
			UI.notify("Set your library URL in Settings to load the full song library.", true)
		elseif Lib.error then
			UI.notify("Couldn't download the song library: " .. tostring(Lib.error):sub(1, 220), true)
		end
	end)
end
reloadBtn.MouseButton1Click:Connect(UI.reloadLibrary)

local lastUi = 0
bind(RunService.Heartbeat, function(dt)
	Player.step(dt)
	local now = os.clock()
	if now - lastUi > 0.1 then
		lastUi = now
		local dur = Player.duration > 0 and Player.duration or 1
		local frac = math.clamp(Player.pos / dur, 0, 1)
		progFill.Size = UDim2.new(frac, 0, 1, 0)
		timeLeft.Text = fmtTime(Player.pos / 1000)
		timeRight.Text = fmtTime(Player.duration / 1000)
		local playing = Player.playing and not Player.paused
		playBtn.Text = playing and "❚❚" or "▶"
		quick.Text = quickText()
		if Live.refresh then
			Live.refresh(now)
		end
	end
end)

---------------------------------------------------------------------------------------------------
-- window controls + hotkeys
---------------------------------------------------------------------------------------------------
local minimized = false
minimizeBtn.MouseButton1Click:Connect(function()
	minimized = not minimized
	tween(main, 0.25, { Size = minimized and UDim2.fromOffset(W, 42 + BAR_H) or UDim2.fromOffset(W, H) })
	sidebar.Visible = not minimized
	pages.Visible = not minimized
	nowBar.Position = minimized and UDim2.new(0, 0, 0, 42) or UDim2.new(0, 0, 1, -BAR_H)
end)
closeBtn.MouseButton1Click:Connect(function()
	main.Visible = false
	UI.notify(("Hidden - press %s to show PianoHub again"):format(S.Keys.Toggle ~= "" and S.Keys.Toggle or "your toggle key"))
end)

bind(UIS.InputBegan, function(input, gameProcessed)
	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	if listeningBind then
		local f = listeningBind
		listeningBind = nil
		f(input.KeyCode)
		return
	end
	if gameProcessed or UIS:GetFocusedTextBox() then
		return
	end
	local name = input.KeyCode.Name
	local K = S.Keys
	if name == K.Toggle then
		main.Visible = not main.Visible
	elseif name == K.PlayPause then
		Player.toggle()
	elseif name == K.Stop then
		Player.stop()
	elseif name == K.Next then
		Player.next()
	elseif name == K.Prev then
		Player.prev()
	elseif name == K.Hesitate then
		Live.hesitate()
	elseif name == K.Flourish then
		Live.flourish()
	elseif name == K.Ending then
		Live.bigEnding()
	elseif name == K.Live then
		Live.visible = not Live.shown
	elseif name == K.Warmup then
		Perform.warmupAndPlay()
	end
end)

function Hub.Unload()
	Player.playing = false
	Keys.releaseAll()
	for _, c in ipairs(Hub.conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	Hub.conns = {}
	pcall(function()
		gui:Destroy()
	end)
	if genv.PianoHub == Hub then
		genv.PianoHub = nil
	end
end

Hub.Player, Hub.Library, Hub.Songs, Hub.Settings = Player, Lib, Songs, S
Hub.Music, Hub.Perform, Hub.Live, Hub.Guitar = Music, Perform, Live, Guitar

---------------------------------------------------------------------------------------------------
-- go
---------------------------------------------------------------------------------------------------
selectTab("Library")
UI.renderQueue()
UI.renderTracks()
UI.refreshNow()
main.Size = UDim2.fromOffset(W, 0)
tween(main, 0.35, { Size = UDim2.fromOffset(W, H) })
UI.reloadLibrary()
UI.notify(("PianoHub loaded  ·  %s toggles the window"):format(S.Keys.Toggle))
