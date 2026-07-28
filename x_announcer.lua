--[[ ===========================================================================
  X-Announcer for X-Plane 12  --  FlyWithLua NG+ script
  ---------------------------------------------------------------------------
  Plays airline cabin announcements automatically, driven by the state of the
  flight.  Reads the same sound packs as the MSFS "Universal Announcer"
  (folder per airline ICAO code, .ogg files named after the event, optional
  [Tags] in the file name), so existing sound libraries work unchanged.

  Audio goes through X-Plane's own FMOD engine (FlyWithLua NG+ >= 2.8.9), which
  decodes OGG / WAV / MP3 / FLAC natively - no conversion needed.

  Install:
      <X-Plane 12>/Resources/plugins/FlyWithLua/Scripts/x_announcer.lua
      <X-Plane 12>/Resources/plugins/FlyWithLua/Scripts/x_announcer/

  Sound library layout:
      <library>/AFL/BoardingWelcome.ogg
      <library>/AFL/AfterTakeoff[Night].ogg
      <library>/BAW/SafetyBriefing[A320][2].ogg
      <library>/Default/en-us/AfterLanding.ogg

  License: MIT.  Airline data: OpenFlights (ODbL), see x_announcer/airlines.lua
=========================================================================== ]]

if not SUPPORTS_FLOATING_WINDOWS then
    logMsg("X-Announcer: FlyWithLua NG+ with floating windows is required.")
    return
end

if type(load_fmod_sound) ~= "function" then
    logMsg("X-Announcer: this FlyWithLua build has no FMOD support " ..
           "(needs NG+ 2.8.9 or newer). Script disabled.")
    return
end

local VERSION = "1.1.5"

----------------------------------------------------------------------------
-- 0.  Small helpers
----------------------------------------------------------------------------

local SEP = DIRECTORY_SEPARATOR or "/"

local function ends_with(s, suffix)
    return s:sub(-#suffix) == suffix
end

local function with_slash(path)
    if path == "" then return path end
    if ends_with(path, "/") or ends_with(path, "\\") then return path end
    return path .. SEP
end

local function join(dir, name)
    return with_slash(dir) .. name
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function round(v)
    return math.floor(v + 0.5)
end

local function mmss(sec)
    if not sec or sec < 0 then sec = 0 end
    return string.format("%d:%02d", math.floor(sec / 60), math.floor(sec % 60))
end

-- lfs_ffi ships with FlyWithLua NG+ and gives us reliable "is this a folder?".
local lfs = nil
do
    local ok, mod = pcall(require, "lfs_ffi")
    if ok and type(mod) == "table" and mod.attributes then lfs = mod end
end

local AUDIO_EXT = { ogg = true, wav = true, mp3 = true, flac = true, aiff = true, aif = true }

local function extension_of(name)
    local ext = name:match("%.([%a%d]+)$")
    return ext and ext:lower() or nil
end

-- directory_to_table() on something that is not a readable folder makes
-- FlyWithLua stop the whole Lua engine ("Can't read out the subfolder"), which
-- would take every other script down with it.  So paths are checked first, and
-- anything we cannot prove is a folder is treated as "not a folder".
local function is_readable_dir(path)
    if path == nil or path == "" then return false end
    if lfs then
        local attributes = lfs.attributes(path)
        return attributes ~= nil and attributes.mode == "directory"
    end
    -- No lfs: a name with a file extension is certainly not a folder, and
    -- os.rename(x, x) succeeds only for something that exists.
    if extension_of(path) then return false end
    return os.rename(path, path) == true
end

local function is_directory(path, name)
    if lfs then return is_readable_dir(path) end
    return extension_of(name) == nil
end

-- directory_to_table() returns files *and* folders, unsorted by kind.
local function list_dir(path)
    if not is_readable_dir(path) then return {}, {} end
    local names = directory_to_table(with_slash(path))
    local files, dirs = {}, {}
    for _, name in ipairs(names or {}) do
        if name ~= "." and name ~= ".." and name ~= "" then
            if is_directory(join(path, name), name) then
                dirs[#dirs + 1] = name
            else
                files[#files + 1] = name
            end
        end
    end
    return files, dirs
end

----------------------------------------------------------------------------
-- 1.  Logging (shown in the Log tab and in X-Plane's Log.txt)
----------------------------------------------------------------------------

local LOG_MAX = 200
local log_lines = {}

-- Two clocks on purpose:
--   sim_clock  - sim seconds, drives the flight phases ("levelled off for 25 s")
--   real_clock - wall-clock seconds, drives audio ("this file is 54 s long").
-- They diverge as soon as the user accelerates time: FMOD always plays at 1x, so
-- scheduling playback on sim time would cut announcements short at 2x and 4x.
local sim_clock  = 0.0
local real_clock = 0.0

local function log(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    log_lines[#log_lines + 1] = { t = sim_clock, msg = msg }
    while #log_lines > LOG_MAX do table.remove(log_lines, 1) end
    logMsg("X-Announcer: " .. msg)
end

----------------------------------------------------------------------------
-- 2.  Configuration
----------------------------------------------------------------------------

local BASE_DIR    = with_slash(SCRIPT_DIRECTORY) .. "x_announcer" .. SEP
local CONFIG_PATH = BASE_DIR .. "config.ini"

local cfg = {
    library          = with_slash(SCRIPT_DIRECTORY) .. "x_announcer" .. SEP .. "Sounds",
    language         = "en-us",   -- optional sub-folder inside a pack
    airline_mode     = "auto",    -- auto | manual
    airline_manual   = "Default",

    announce_bus     = "interior",-- interior | master | ui | com1
    music_bus        = "master",
    volume           = 0.85,
    music_volume     = 0.35,
    duck             = 0.25,      -- music volume multiplier while a PA plays

    enabled          = true,
    boarding_music   = true,
    cabin_noise      = false,
    auto_boarding    = true,      -- start boarding from lights/power, else manual
    boarding_repeat  = 300,       -- seconds between BoardingWelcome repeats
    pilot_welcome    = false,
    door_calls       = true,      -- ArmDoors / DisarmDoors
    night_dim        = true,      -- CabinDim* announcements
    landing_reaction = true,      -- LandingGreat / LandingTerrible
    seatbelt_dref    = "",        -- optional manual override
    window_scale     = 1.0,
    auto_find        = true,      -- look for an existing UA_Sounds folder
    music_max_loops  = 6,         -- see the note about FlyWithLua's FMOD memory
    simbrief_id      = "",        -- SimBrief pilot ID or account name
    widget           = false,     -- on-screen phase widget
    widget_mode      = "medium",  -- minimal | medium | full
    widget_opacity   = 0.55,      -- of the plate behind the text, 0 = none
    widget_x         = 20,        -- pixels from the left edge
    widget_y         = 60,        -- pixels from the top edge
}

local CFG_ORDER = {
    "library", "language", "airline_mode", "airline_manual",
    "announce_bus", "music_bus", "volume", "music_volume", "duck",
    "enabled", "boarding_music", "cabin_noise", "auto_boarding",
    "boarding_repeat", "pilot_welcome", "door_calls", "night_dim",
    "landing_reaction", "seatbelt_dref", "window_scale", "auto_find",
    "music_max_loops", "simbrief_id",
    "widget", "widget_mode", "widget_opacity", "widget_x", "widget_y",
}

local function config_load()
    local f = io.open(CONFIG_PATH, "r")
    if not f then return end
    for line in f:lines() do
        local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if key and cfg[key] ~= nil then
            local current = cfg[key]
            if type(current) == "boolean" then
                cfg[key] = (value == "true" or value == "1")
            elseif type(current) == "number" then
                cfg[key] = tonumber(value) or current
            else
                cfg[key] = value
            end
        end
    end
    f:close()
end

-- Russian help text for the config file.  The window itself has to stay in
-- English (FlyWithLua's built-in ImGui font has no Cyrillic glyphs), so the
-- file the user actually edits by hand explains itself in Russian.
local CFG_HELP = {
    library          = "папка со звуковыми паками (папка на авиакомпанию, как у MSFS Universal Announcer)",
    language         = "языковая подпапка внутри пака, если она есть: en-us, de-de, ru",
    airline_mode     = "auto - определять авиакомпанию по ливрее и борту, manual - брать airline_manual",
    airline_manual   = "код ICAO пака, который использовать принудительно",
    announce_bus     = "шина FMOD для объявлений: interior (салон), master, ui, com1",
    music_bus        = "шина FMOD для фоновой музыки, обязана отличаться от announce_bus",
    volume           = "громкость объявлений, 0.0 - 1.0",
    music_volume     = "громкость фоновой музыки, 0.0 - 1.0",
    duck             = "во сколько раз приглушать музыку на время объявления",
    enabled          = "false - объявления полностью выключены",
    boarding_music   = "играть музыку между приветствиями при посадке пассажиров",
    cabin_noise      = "фоновый шум салона в полёте, если файл CabinNoise есть в паке",
    auto_boarding    = "начинать посадку пассажиров самому по питанию и огням; false - только кнопкой",
    boarding_repeat  = "секунд между повторами приветствия при посадке",
    pilot_welcome    = "приветствие командира после приветствия бортпроводника",
    door_calls       = "объявления про двери: ArmDoors и DisarmDoors",
    night_dim        = "объявления про притушенный свет в салоне ночью",
    landing_reaction = "реакция салона на касание: LandingGreat или LandingTerrible",
    seatbelt_dref    = "свой датареф табло ремней; пусто - искать автоматически",
    window_scale     = "масштаб текста в окне, 1.0 - обычный; больше для VR",
    auto_find        = "искать готовую папку UA_Sounds, если в library паков не нашлось",
    music_max_loops  = "сколько раз зацикливать фоновый трек (FlyWithLua не освобождает память на каждом повторе)",
    simbrief_id      = "ваш SimBrief: числовой Pilot ID или имя учётной записи; пусто - не спрашивать SimBrief",
    widget           = "показывать виджет фазы полёта поверх экрана симулятора",
    widget_mode      = "плотность виджета: minimal - одна строка, medium - плюс условия перехода, full - плюс лестница фаз",
    widget_opacity   = "непрозрачность подложки виджета, 0.0 - без подложки, 1.0 - глухая",
    widget_x         = "отступ виджета от левого края экрана, пикселей",
    widget_y         = "отступ виджета от верхнего края экрана, пикселей",
}

local function config_save()
    local f = io.open(CONFIG_PATH, "w")
    if not f then
        log("cannot write %s", CONFIG_PATH)
        return
    end
    f:write("# Настройки X-Announcer для X-Plane 12.\n")
    f:write("# Файл переписывается плагином, когда вы меняете что-то в окне,\n")
    f:write("# поэтому свои комментарии сюда добавлять бесполезно.\n")
    f:write("# Правьте при выключенном симуляторе либо жмите Rescan в окне.\n")
    for _, key in ipairs(CFG_ORDER) do
        local help = CFG_HELP[key]
        if help then f:write("\n# " .. help .. "\n") end
        f:write(string.format("%s = %s\n", key, tostring(cfg[key])))
    end
    f:close()
end

----------------------------------------------------------------------------
-- 3.  Audio: registration, duration probing, playback, ducking
----------------------------------------------------------------------------

local snd_index    = {}   -- path -> FMOD sound index
local snd_count    = 0
local dur_cache    = {}   -- path -> seconds

local function u32le(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    if not d then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

local function u16le(s, i)
    local a, b = s:byte(i, i + 1)
    if not b then return nil end
    return a + b * 256
end

local function file_size(f)
    local cur = f:seek()
    local size = f:seek("end")
    f:seek("set", cur)
    return size
end

-- Ogg Vorbis: sample rate from the identification header, total samples from
-- the granule position of the last page.
local function duration_ogg(f)
    f:seek("set", 0)
    local head = f:read(8192) or ""
    if head:sub(1, 4) ~= "OggS" then return nil end
    local segments = head:byte(27)
    if not segments then return nil end
    local pkt = 28 + segments                       -- first packet, 1-based
    if head:sub(pkt, pkt + 6) ~= "\1vorbis" then return nil end
    local rate = u32le(head, pkt + 12)
    if not rate or rate == 0 then return nil end

    local size = file_size(f)
    local tail_len = math.min(size, 65536)
    f:seek("set", size - tail_len)
    local tail = f:read(tail_len) or ""

    local last, pos = nil, 1
    while true do
        local at = tail:find("OggS", pos, true)
        if not at then break end
        last, pos = at, at + 1
    end
    if not last then return nil end
    local lo = u32le(tail, last + 6)
    local hi = u32le(tail, last + 10)
    if not lo or not hi then return nil end
    return (lo + hi * 4294967296) / rate
end

-- RIFF/WAVE: walk the chunks, duration = data bytes / byte rate.
local function duration_wav(f)
    f:seek("set", 0)
    local head = f:read(12) or ""
    if head:sub(1, 4) ~= "RIFF" or head:sub(9, 12) ~= "WAVE" then return nil end
    local byte_rate = nil
    local pos = 12
    for _ = 1, 32 do
        f:seek("set", pos)
        local hdr = f:read(8)
        if not hdr or #hdr < 8 then break end
        local id   = hdr:sub(1, 4)
        local size = u32le(hdr, 5)
        if not size then break end
        if id == "fmt " then
            local fmt = f:read(math.min(size, 16)) or ""
            if #fmt >= 16 then byte_rate = u32le(fmt, 9) end
        elseif id == "data" then
            if byte_rate and byte_rate > 0 then return size / byte_rate end
            return nil
        end
        pos = pos + 8 + size + (size % 2)
    end
    return nil
end

-- MPEG audio: parse the first frame header, assume constant bit rate.
local MP3_BITRATE_V1L3 = { 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320 }
local MP3_BITRATE_V2L3 = { 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 }

local function duration_mp3(f)
    f:seek("set", 0)
    local head = f:read(10) or ""
    local start = 0
    if head:sub(1, 3) == "ID3" then
        local a, b, c, d = head:byte(7, 10)
        if d then start = 10 + (a * 2097152 + b * 16384 + c * 128 + d) end
    end
    f:seek("set", start)
    local buf = f:read(8192) or ""
    for i = 1, #buf - 4 do
        local b1, b2, b3 = buf:byte(i, i + 2)
        if b1 == 0xFF and b2 and math.floor(b2 / 32) == 7 then
            local version_bits = math.floor(b2 / 8) % 4        -- 3 = MPEG1, 2 = MPEG2
            local layer_bits   = math.floor(b2 / 2) % 4        -- 1 = Layer III
            local br_index     = math.floor(b3 / 16)
            if layer_bits == 1 and br_index > 0 and br_index < 15 then
                local table_ = (version_bits == 3) and MP3_BITRATE_V1L3 or MP3_BITRATE_V2L3
                local kbps = table_[br_index + 1]
                if kbps and kbps > 0 then
                    local size = file_size(f)
                    return (size - start - i) * 8 / (kbps * 1000)
                end
            end
        end
    end
    return nil
end

local function probe_duration(path)
    if dur_cache[path] then return dur_cache[path] end
    local seconds = nil
    local f = io.open(path, "rb")
    if f then
        local ext = extension_of(path)
        local ok, result
        if ext == "ogg" then
            ok, result = pcall(duration_ogg, f)
        elseif ext == "wav" or ext == "aiff" or ext == "aif" then
            ok, result = pcall(duration_wav, f)
        elseif ext == "mp3" then
            ok, result = pcall(duration_mp3, f)
        end
        if ok and type(result) == "number" and result > 0.05 and result < 7200 then
            seconds = result
        end
        if not seconds then
            -- last resort: assume ~128 kbit/s so the queue keeps moving
            seconds = clamp(file_size(f) / 16000, 2, 600)
        end
        f:close()
    end
    dur_cache[path] = seconds or 10
    return dur_cache[path]
end

-- FlyWithLua copies the file name into a 250 byte buffer; a longer path is
-- silently truncated and then fails to open, so such files are refused here.
local MAX_SOUND_PATH = 245
local SOUND_SLOTS    = 350          -- FlyWithLua's own table holds 400

local function snd_register(path)
    local idx = snd_index[path]
    if idx then return idx end
    if #path > MAX_SOUND_PATH then
        log("path too long for FlyWithLua (%d chars), skipped: %s", #path, path)
        return nil
    end
    if snd_count >= SOUND_SLOTS then
        log("FMOD sound slot limit reached, cannot load %s", path)
        return nil
    end
    idx = load_fmod_sound(path)
    if type(idx) ~= "number" then return nil end
    snd_index[path] = idx
    snd_count = snd_count + 1
    return idx
end

-- X-Plane rebuilds the FMOD banks when the aircraft changes, which invalidates
-- every index FlyWithLua handed out.  Playing a stale index is silent, with no
-- error to notice, so the cache is dropped whenever that can have happened.
local function forget_sounds()
    if snd_count == 0 then return end
    snd_index = {}
    snd_count = 0
    log("sound handles released, files will be re-registered on demand")
end

local function bus_play(bus, path)
    local idx = snd_register(path)
    if not idx then return false end
    if     bus == "interior" then play_sound_on_interior_bus(idx)
    elseif bus == "ui"       then play_sound_on_ui_bus(idx)
    elseif bus == "com1"     then play_sound_on_com1_bus(idx)
    else                          play_sound_on_master_bus(idx) end
    return true
end

local function bus_stop(bus)
    if     bus == "interior" then stop_sound_on_interior_bus()
    elseif bus == "ui"       then stop_sound_on_ui_bus()
    elseif bus == "com1"     then stop_sound_on_com1_bus()
    else                          stop_sound_on_master_bus() end
end

-- FlyWithLua's FMOD channel groups start at volume 0.0, so these have to be
-- written every cycle or nothing is audible.
local VOL_DREF = {
    interior = "FlyWithLua_InteriorChannelGroup/Volume",
    master   = "FlyWithLua_MasterChannelGroup/Volume",
    ui       = "FlyWithLua_UIChannelGroup/Volume",
    com1     = "FlyWithLua_Com1ChannelGroup/Volume",
}

local dref_cache = {}

local function find_dref(name)
    if name == nil or name == "" then return nil end
    local cached = dref_cache[name]
    if cached == nil then
        cached = XPLMFindDataRef(name) or false
        dref_cache[name] = cached
    end
    if cached == false then return nil end
    return cached
end

local function set_bus_volume(bus, value)
    local ref = find_dref(VOL_DREF[bus])
    if ref then XPLMSetDataf(ref, clamp(value, 0, 1)) end
end

----------------------------------------------------------------------------
-- 4.  Sound library: scanning and candidate selection
----------------------------------------------------------------------------

-- Canonical events.  Keys are lower-case for lookup, values are the display name.
local EVENTS = {
    "BoardingWelcome", "BoardingWelcomePilot", "BoardingStarted", "BoardingMusic",
    "BoardingComplete", "DepartureDelayed", "ArmDoors", "PreSafetyBriefing",
    "SafetyBriefing", "CabinDimTakeoff", "CrewSeatsTakeoff", "CallCabinSecureTakeoff",
    "AfterTakeoff", "TopOfClimbPilot", "FastenSeatbelt", "Turbulence",
    "TopOfDescentPilot", "DescentSeatbelts", "CabinDimLanding", "BeforeLanding",
    "CrewSeatsLanding", "CallCabinSecureLanding", "AfterLanding", "AfterLandingMusic",
    "DisarmDoors", "DisembarkStarted", "LandingGreat", "LandingTerrible", "CabinNoise",
}

local EVENT_BY_KEY = {}
for _, name in ipairs(EVENTS) do EVENT_BY_KEY[name:lower()] = name end
-- tolerate the spelling variants seen in community packs
EVENT_BY_KEY["fastenseatbelts"]   = "FastenSeatbelt"
EVENT_BY_KEY["cabindim"]          = "CabinDimTakeoff"
EVENT_BY_KEY["topofdecentpilot"]  = "TopOfDescentPilot"
EVENT_BY_KEY["disembarkstarted"]  = "DisembarkStarted"
EVENT_BY_KEY["welcomeaboard"]     = "BoardingWelcome"

local TIME_TAGS = { morning = true, afternoon = true, evening = true, night = true }
local CTX_TAGS  = { refueling = true, deicing = true, delayed = true }

-- "AfterTakeoff[Night][2].ogg" -> event, {tags}
local function parse_filename(filename)
    local ext = extension_of(filename)
    if not ext or not AUDIO_EXT[ext] then return nil end

    local base = filename:sub(1, #filename - #ext - 1)

    local tags = {}
    base = base:gsub("%[(.-)%]", function(tag)
        tags[#tags + 1] = trim(tag):lower()
        return ""
    end)

    -- some packs write "AfterTakeoff.ogg[A359][2].ogg"
    base = base:gsub("%.%a+$", "")
    base = trim(base)

    local event = EVENT_BY_KEY[base:lower()]
    if not event then
        -- "SafetyBriefing1" / "BoardingMusic 2" -> trailing variant number
        local stem, digits = base:match("^(.-)%s*(%d+)$")
        if stem then
            event = EVENT_BY_KEY[trim(stem):lower()]
            if event then tags[#tags + 1] = digits end
        end
    end
    if not event then return nil end

    local info = { event = event, aircraft = {}, time = {}, ctx = {}, variant = nil }
    for _, tag in ipairs(tags) do
        if TIME_TAGS[tag] then
            info.time[tag] = true
        elseif CTX_TAGS[tag] then
            info.ctx[tag] = true
        elseif tag:match("^%d+$") then
            info.variant = tonumber(tag)
        else
            info.aircraft[tag:upper()] = true
        end
    end
    return info
end

-- library.packs = { AFL = { events = { BoardingWelcome = { {path=..., info=...} } },
--                          files = 12, unknown = { "readme.txt" } } }
local library = { packs = {}, codes = {}, scanned_at = nil, root = "" }

local function is_locale_folder(name)
    local lower = name:lower()
    return lower:match("^%a%a$") ~= nil or lower:match("^%a%a[-_]%a%a$") ~= nil
end

local function scan_pack(pack_path, pack)
    local files, dirs = list_dir(pack_path)

    local function absorb(dir_path, name_list)
        for _, name in ipairs(name_list) do
            local info = parse_filename(name)
            if info then
                local list = pack.events[info.event]
                if not list then list = {} pack.events[info.event] = list end
                list[#list + 1] = { path = join(dir_path, name), name = name, info = info }
                pack.files = pack.files + 1
            elseif extension_of(name) and AUDIO_EXT[extension_of(name)] then
                pack.unknown[#pack.unknown + 1] = name
            end
        end
    end

    absorb(pack_path, files)

    -- one level of language sub-folders (en-us, de-de, ru, ...): take the one
    -- the user asked for, or the only one there is.
    local locales = {}
    for _, sub in ipairs(dirs) do
        if is_locale_folder(sub) then locales[#locales + 1] = sub end
    end
    local chosen = nil
    for _, sub in ipairs(locales) do
        if sub:lower() == cfg.language:lower() then chosen = sub end
    end
    if not chosen and #locales == 1 then chosen = locales[1] end
    if chosen then
        absorb(join(pack_path, chosen), (list_dir(join(pack_path, chosen))))
        pack.languages[chosen] = true
    end
end

local function scan_library()
    library = { packs = {}, codes = {}, scanned_at = sim_clock, root = cfg.library }
    if cfg.library == "" then return end
    if not is_readable_dir(cfg.library) then
        log("sound library folder not found: %s", cfg.library)
        return
    end

    local ok, files, dirs = pcall(list_dir, cfg.library)
    if not ok then
        log("sound library not readable: %s", cfg.library)
        return
    end
    files = files or {}
    dirs = dirs or {}

    for _, dir in ipairs(dirs) do
        local pack = { code = dir, events = {}, files = 0, unknown = {}, languages = {} }
        scan_pack(join(cfg.library, dir), pack)
        if pack.files > 0 then
            library.packs[dir:upper()] = pack
            library.codes[#library.codes + 1] = dir:upper()
        end
    end

    -- loose files directly in the library root are treated as the Default pack
    local root_pack = { code = "Default", events = {}, files = 0, unknown = {}, languages = {} }
    for _, name in ipairs(files) do
        local info = parse_filename(name)
        if info then
            local list = root_pack.events[info.event]
            if not list then list = {} root_pack.events[info.event] = list end
            list[#list + 1] = { path = join(cfg.library, name), name = name, info = info }
            root_pack.files = root_pack.files + 1
        end
    end
    if root_pack.files > 0 and not library.packs["DEFAULT"] then
        library.packs["DEFAULT"] = root_pack
        library.codes[#library.codes + 1] = "DEFAULT"
    end

    table.sort(library.codes)
    log("library scan: %d packs in %s", #library.codes, cfg.library)
end

----------------------------------------------------------------------------
-- 5.  Airline detection
----------------------------------------------------------------------------

local airlines = {}
do
    local path = BASE_DIR .. "airlines.lua"
    local chunk = loadfile(path)
    if chunk then
        local ok, data = pcall(chunk)
        if ok and type(data) == "table" then airlines = data end
    end
    if next(airlines) == nil then
        logMsg("X-Announcer: airlines.lua not found at " .. path ..
               " - automatic airline detection will be limited.")
    end
end

-- Common livery spellings that the OpenFlights names do not cover directly.
local ALIASES = {
    aeroflot = "AFL", pobeda = "PBD", s7 = "SBI", sevenairlines = "SBI",
    rossiya = "SDM", utair = "UTA", uralairlines = "SVR", ural = "SVR",
    nordwind = "NWS", redwings = "RWZ", azurair = "AZV", smartavia = "AUL",
    american = "AAL", delta = "DAL", united = "UAL", southwest = "SWA",
    jetblue = "JBU", alaska = "ASA", spirit = "NKS", frontier = "FFT",
    british = "BAW", britishairways = "BAW", ba = "BAW", speedbird = "BAW",
    lufthansa = "DLH", swiss = "SWR", austrian = "AUA", eurowings = "EWG",
    airfrance = "AFR", klm = "KLM", transavia = "TRA", iberia = "IBE",
    vueling = "VLG", airnostrum = "ANE", tap = "TAP", ita = "ITY",
    alitalia = "AZA", turkish = "THY", pegasus = "PGT", aegean = "AEE",
    ryanair = "RYR", easyjet = "EZY", wizz = "WZZ", wizzair = "WZZ",
    jet2 = "EXS", norwegian = "NAX", sas = "SAS", finnair = "FIN",
    icelandair = "ICE", aerlingus = "EIN", tui = "TOM", condor = "CFG",
    emirates = "UAE", etihad = "ETD", qatar = "QTR", flydubai = "FDB",
    saudia = "SVA", elal = "ELY", royaljordanian = "RJA", oman = "OMA",
    qantas = "QFA", qantaslink = "QLK", virginaustralia = "VOZ", jetstar = "JST",
    airnewzealand = "ANZ", airasia = "AXM", singapore = "SIA", cathay = "CPA",
    ana = "ANA", allnippon = "ANA", jal = "JAL", japanairlines = "JAL",
    korean = "KAL", asiana = "AAR", china = "CCA", airchina = "CCA",
    chinaeastern = "CES", chinasouthern = "CSN", eva = "EVA", chinaairlines = "CAL",
    thai = "THA", vietnam = "HVN", garuda = "GIA", philippine = "PAL",
    aircanada = "ACA", westjet = "WJA", aeromexico = "AMX", copa = "CMP",
    latam = "LAN", avianca = "AVA", gol = "GLO", azul = "AZU",
    ethiopian = "ETH", kenya = "KQA", southafrican = "SAA", egyptair = "MSR",
    royalairmaroc = "RAM", airindia = "AIC", indigo = "IGO", vistara = "VTI",
    swissair = "SWR", edelweiss = "EDW", airbaltic = "BTI", lot = "LOT",
    czech = "CSA", croatia = "CTN", airserbia = "ASL", bulgaria = "LZB",
    airastana = "KZR", uzbekistan = "UZB", azerbaijan = "AHY", flyone = "FIA",
}

local name_index = {}    -- normalised airline name -> ICAO
local name_list  = {}    -- { {norm=..., icao=...}, ... } sorted by length desc

local function normalise(s)
    return (s:lower():gsub("[^%a%d]", ""))
end

local STRIP_WORDS = {
    "airlines", "airline", "airways", "airway", "aviation", "aircompany",
    "international", "virtual", "company", "limited", "group", "cargo", "air",
}

-- The OpenFlights list contains carriers whose whole name is a generic word:
-- WAY is literally called "Airways", WHT is called "White".  Indexed as names
-- they hijack everything - "Thai Airways" became WAY, "full_white" became WHT.
-- They stay reachable by their ICAO code, just not by name.
local GENERIC_NAMES = {
    air = true, airway = true, airways = true, airline = true, airlines = true,
    aviation = true, cargo = true, express = true, charter = true, jet = true,
    jets = true, transport = true, white = true, black = true, blue = true,
    green = true, red = true, silver = true, gold = true, star = true,
    sky = true, one = true, house = true, classic = true, retro = true,
}

do
    for icao, entry in pairs(airlines) do
        local full = normalise(entry.n)
        if #full >= 4 and not GENERIC_NAMES[full] and not name_index[full] then
            name_index[full] = icao
        end

        local short = full
        for _, word in ipairs(STRIP_WORDS) do
            short = short:gsub(word, "")
        end
        if #short >= 4 and not GENERIC_NAMES[short] and not name_index[short] then
            name_index[short] = icao
        end
    end
    for alias, icao in pairs(ALIASES) do name_index[alias] = icao end
    for norm, icao in pairs(name_index) do
        name_list[#name_list + 1] = { norm = norm, icao = icao }
    end
    -- Longest first, and alphabetical among equals: name_index is a hash, so
    -- without the tie-break two runs of the same build could disagree.
    table.sort(name_list, function(a, b)
        if #a.norm ~= #b.norm then return #a.norm > #b.norm end
        return a.norm < b.norm
    end)
end

local function airline_name(icao)
    local entry = airlines[icao]
    return entry and entry.n or nil
end

-- Three-letter words that turn up in livery folder names and happen to collide
-- with real ICAO codes: engine variants, condition tags, filler words.  Without
-- this list "A320 NEO Air Serbia" resolves to whoever owns NEO or AIR.
local TOKEN_STOPLIST = {
    AIR = true, NEO = true, CEO = true, CFM = true, IAE = true, PWG = true,
    OLD = true, NEW = true, THE = true, AND = true, FOR = true, VIP = true,
    WIP = true, HOF = true, RED = true, MAX = true, XWB = true, WIN = true,
}

-- Words of a livery folder name.  Hyphens are deliberately NOT separators, so
-- registrations stay glued together: "HS-TXS" is one word and can never be
-- mistaken for the airline code TXS, while "AFL RA-73735" still offers "AFL".
local function words_of(text)
    local out = {}
    for word in text:gmatch("[^%s%[%]%(%)_,%./\\]+") do out[#out + 1] = word end
    return out
end

-- Try to find an airline in a free-form string (livery folder name, tail, ...)
-- Returns code, how, score.  A name match always outranks a bare three-letter
-- code: folder names are full of registrations and engine tags, and those used
-- to win simply because that branch ran first.
local function airline_from_text(text)
    if not text or text == "" then return nil end

    local code, how, score = nil, nil, 0
    local words = words_of(text)

    -- Pass 1: a run of consecutive words that is exactly an airline name.
    -- Word boundaries make this safe for short names, so "Thai Airways HS-TXS"
    -- can match "Thai" without "thai" being allowed to match anywhere at all.
    -- The longest run wins: "Thai Lion" beats the "Thai" inside it.
    for start = 1, #words do
        local run = ""
        for stop = start, #words do
            run = run .. normalise(words[stop])
            local icao = name_index[run]
            if icao and #run >= 3 and (1000 + #run) > score then
                code, how, score = icao, "name", 1000 + #run
            end
        end
    end

    -- Pass 2: the name glued to something else - "AirAsiaOld", "AeroflotSkyteam".
    -- name_list is sorted longest first, so the first hit is the most specific.
    local norm = normalise(text)
    if norm ~= "" then
        for _, item in ipairs(name_list) do
            if #item.norm >= 5 and (1000 + #item.norm) > score
               and norm:find(item.norm, 1, true) then
                code, how, score = item.icao, "name", 1000 + #item.norm
                break
            end
        end
    end

    -- Pass 3: the folder gives a shorter form of a longer official name -
    -- "Scandinavian Airlines" for "Scandinavian Airlines System".  Only for
    -- long runs, and only when nothing better was found, so it stays cheap.
    if score == 0 then
        local best_len = nil
        for start = 1, #words do
            local run = ""
            for stop = start, #words do
                run = run .. normalise(words[stop])
                -- "airlines" is eight characters long and prefixes a whole
                -- family of obscure carriers; generic runs are not evidence.
                if #run >= 8 and not GENERIC_NAMES[run] then
                    for _, item in ipairs(name_list) do
                        if #item.norm > #run and item.norm:sub(1, #run) == run
                           and (best_len == nil or #item.norm < best_len) then
                            best_len = #item.norm
                            code, how, score = item.icao, "name (short form)", 900 + #run
                        end
                    end
                end
            end
        end
    end

    -- An explicit ICAO code, but only as a standalone word.
    for _, word in ipairs(words_of(text)) do
        if #word == 3 and word:match("^%a%a%a$") then
            local up = word:upper()
            if not TOKEN_STOPLIST[up] and (library.packs[up] or airlines[up]) then
                local own = library.packs[up] and 700 or 500
                if own > score then code, how, score = up, "code " .. up, own end
            end
        end
    end

    if not code then return nil end
    return code, how, score
end

----------------------------------------------------------------------------
-- 6.  Sim state
----------------------------------------------------------------------------

local function geti(name, fallback)
    local ref = find_dref(name)
    if not ref then return fallback end
    return XPLMGetDatai(ref)
end

local function getf(name, fallback)
    local ref = find_dref(name)
    if not ref then return fallback end
    return XPLMGetDataf(ref)
end

local function getvi(name, count)
    local ref = find_dref(name)
    if not ref then return nil end
    return XPLMGetDatavi(ref, 0, count)
end

-- first dataref of a list that actually exists (aircraft add-ons differ)
local function first_dref(list)
    for _, name in ipairs(list) do
        if find_dref(name) then return name end
    end
    return nil
end

-- Seat belt sign, most specific first.  `on` is the value that means "lit":
-- the Zibo/laminar switch is a three-position knob (0 off, 1 auto, 2 on), the
-- others are plain on/off.
local SEATBELT_CANDIDATES = {
    { name = "AirbusFBW/SeatBeltSignsOn",                            on = 1 }, -- ToLiss
    { name = "b737ng/equipment/alerts/crew/cabin/CRW_seatbelts_on",  on = 1 }, -- 737NG Series
    { name = "Rotate/aircraft/controls/seatbelts_lts",               on = 1 }, -- MD-11
    { name = "laminar/B738/toggle_switch/seatbelt_sign_pos",         on = 2 }, -- Zibo
    { name = "sim/cockpit2/switches/fasten_seat_belts",              on = 1 },
    { name = "sim/cockpit/switches/fasten_seat_belts",               on = 1 },
}

-- X-Plane itself has no logo light dataref; only add-ons provide one.
local LOGO_CANDIDATES = {
    "laminar/B738/toggle_switch/logo_light",
    "Rotate/aircraft/controls/logo_lts",
}

local function first_seatbelt()
    if cfg.seatbelt_dref ~= "" and find_dref(cfg.seatbelt_dref) then
        return { name = cfg.seatbelt_dref, on = 1 }
    end
    for _, candidate in ipairs(SEATBELT_CANDIDATES) do
        if find_dref(candidate.name) then return candidate end
    end
    return nil
end

local seatbelt_dref, logo_dref = nil, nil

local sim = {}          -- refreshed every tick

local function read_sim()
    local s = sim
    s.paused        = geti("sim/time/paused", 0) == 1
    s.on_ground     = geti("sim/flightmodel/failures/onground_any", 1) == 1
    s.gs_kt         = getf("sim/flightmodel/position/groundspeed", 0) * 1.94384
    s.agl_ft        = getf("sim/flightmodel/position/y_agl", 0) * 3.28084
    s.alt_ft        = getf("sim/flightmodel/misc/h_ind", 0)
    s.vs_fpm        = getf("sim/flightmodel/position/vh_ind_fpm", 0)
    s.g_normal      = getf("sim/flightmodel/forces/g_nrml", 1)
    s.beacon        = geti("sim/cockpit2/switches/beacon_on", 0) == 1
    s.nav_lights    = geti("sim/cockpit2/switches/navigation_lights_on", 0) == 1
    s.strobe        = geti("sim/cockpit2/switches/strobe_lights_on", 0) == 1
    s.landing_light = geti("sim/cockpit2/switches/landing_lights_on", 0) == 1
    s.taxi_light    = geti("sim/cockpit2/switches/taxi_light_on", 0) == 1
    s.parkbrake     = getf("sim/flightmodel/controls/parkbrake", 0) > 0.5
    s.battery       = geti("sim/cockpit2/electrical/battery_on", 0) == 1

    s.logo = false
    if logo_dref then s.logo = geti(logo_dref, 0) == 1 end

    s.seatbelt = nil
    if seatbelt_dref then
        local ref = find_dref(seatbelt_dref.name)
        if ref then
            -- some aircraft expose the sign as int, some as a float switch position
            local value = XPLMGetDatai(ref)
            if value == 0 then
                local as_float = XPLMGetDataf(ref)
                if as_float and as_float >= seatbelt_dref.on - 0.5 then value = seatbelt_dref.on end
            end
            s.seatbelt = value >= seatbelt_dref.on
        end
    end

    -- ENGN_running is int[16]; the manual warns that reading past the end of an
    -- array dataref can take the simulator down without a word, so the count is
    -- clamped to the documented size.
    local engines = geti("sim/aircraft/engine/acf_num_engines", 2)
    engines = clamp(engines, 1, 16)
    local running = getvi("sim/flightmodel/engine/ENGN_running", engines)
    s.engines_running = 0
    if running then
        for i = 0, engines - 1 do
            if (running[i] or 0) == 1 then s.engines_running = s.engines_running + 1 end
        end
    end
    s.any_engine = s.engines_running > 0
    s.all_engines_off = s.engines_running == 0

    local local_sec = getf("sim/time/local_time_sec", 43200)
    s.local_hour = math.floor((local_sec % 86400) / 3600)
    if s.local_hour >= 5 and s.local_hour < 12 then
        s.daypart = "morning"
    elseif s.local_hour < 17 then
        s.daypart = "afternoon"
    elseif s.local_hour < 22 then
        s.daypart = "evening"
    else
        s.daypart = "night"
    end
    s.is_dark = (s.local_hour >= 21 or s.local_hour < 6)
    return s
end

----------------------------------------------------------------------------
-- 7.  Announcement selection and queue
----------------------------------------------------------------------------

-- code/name = who we fly for, pack = whose sounds we can actually play.
local current_airline = { code = "Default", source = "-", name = nil,
                          pack = "DEFAULT", has_pack = false }

local F = nil               -- per-flight memory, see reset_flight()

local queue        = {}     -- pending announcements
local now_playing  = nil    -- { event, path, started, duration }
local music        = nil    -- { event, path, started, duration }

local function candidate_score(entry)
    local info = entry.info
    local score = 0

    if next(info.aircraft) ~= nil then
        local plane = (PLANE_ICAO or ""):upper()
        local matched = false
        for tag in pairs(info.aircraft) do
            if plane ~= "" and (tag == plane or
               (#tag >= 3 and #plane >= 3 and (tag:find(plane, 1, true) == 1 or plane:find(tag, 1, true) == 1))) then
                matched = true
            end
        end
        if not matched then return nil end       -- wrong aircraft, never play
        score = score + 4
    end

    if next(info.time) ~= nil then
        if not info.time[sim.daypart] then return nil end
        score = score + 3
    end

    if next(info.ctx) ~= nil then
        -- context tags (refueling/deicing) are not detected in X-Plane yet,
        -- so keep them as a low-priority fallback instead of dropping them
        score = score - 1
    end

    return score
end

local function pick_file(pack_code, event)
    local pack = library.packs[pack_code and pack_code:upper() or ""]
    if not pack then return nil end
    local list = pack.events[event]
    if not list then return nil end

    local best, best_score = {}, nil
    for _, entry in ipairs(list) do
        local score = candidate_score(entry)
        if score ~= nil then
            if best_score == nil or score > best_score then
                best, best_score = { entry }, score
            elseif score == best_score then
                best[#best + 1] = entry
            end
        end
    end
    if #best == 0 then return nil end
    return best[math.random(#best)]
end

local function resolve_event(event)
    local entry = pick_file(current_airline.pack, event)
    if entry then return entry, current_airline.pack end
    entry = pick_file("Default", event)
    if entry then return entry, "Default" end
    return nil
end

-- Cached "which pack covers which event" view, rebuilt when the library or the
-- airline changes.  Keeps the UI stable (no re-rolled random variants per frame)
-- and keeps has_event() cheap.
local coverage = {}

local function rebuild_coverage()
    coverage = {}
    for _, event in ipairs(EVENTS) do
        local entry, pack = resolve_event(event)
        local own, fallback = 0, 0
        local airline_pack = library.packs[current_airline.pack]
        local default_pack = library.packs["DEFAULT"]
        if airline_pack and airline_pack.events[event] then own = #airline_pack.events[event] end
        if default_pack and default_pack.events[event] then fallback = #default_pack.events[event] end
        coverage[event] = {
            available = entry ~= nil,
            source    = pack,
            own       = own,
            fallback  = fallback,
        }
    end
end

local function has_event(event)
    local info = coverage[event]
    if info then return info.available end
    return resolve_event(event) ~= nil
end

-- How long a queued announcement stays relevant.  A "cabin secure" call that
-- is still waiting behind a long safety briefing must not play in the climb.
local EVENT_TTL = {
    BoardingWelcome        = 240,
    BoardingComplete       = 300,
    CrewSeatsTakeoff       = 150,
    CallCabinSecureTakeoff = 150,
    CabinDimTakeoff        = 240,
    FastenSeatbelt         = 120,
    Turbulence             = 120,
    BeforeLanding          = 120,
    CrewSeatsLanding       = 180,
    CallCabinSecureLanding = 180,
}

-- `manual` marks a preview started from the Library tab: it plays like any other
-- announcement but must not count as "this event has already been heard",
-- otherwise auditioning a file would let the flight skip a step.
local function enqueue(event, reason, manual)
    if not cfg.enabled then return false end
    local entry, pack = resolve_event(event)
    if not entry then
        log("%s: no sound file (%s)", event, reason or "")
        return false
    end
    local ttl = EVENT_TTL[event]
    queue[#queue + 1] = {
        event   = event,
        entry   = entry,
        pack    = pack,
        reason  = reason,
        manual  = manual,
        expires = (not manual) and ttl and (sim_clock + ttl) or nil,
    }
    return true
end

local function stop_announcement()
    if now_playing then
        -- mark it finished, otherwise everything waiting on this event
        -- (the "cabin secure" calls, the briefing chain) stays blocked forever
        if F and not now_playing.manual then F.ended[now_playing.event] = sim_clock end
        bus_stop(cfg.announce_bus)
        now_playing = nil
    end
end

local function stop_music()
    if music then
        bus_stop(cfg.music_bus)
        music = nil
    end
end

-- The caller decides whether this kind of background audio is switched on:
-- boarding music and cabin ambience are independent settings.
local function start_music(event)
    if music and music.event == event then return end
    local entry = resolve_event(event)
    if not entry then return end
    stop_music()
    if bus_play(cfg.music_bus, entry.path) then
        music = { event = event, path = entry.path, started = real_clock,
                  duration = probe_duration(entry.path), loops = 0 }
        log("music: %s (%s)", event, entry.name)
    end
end

local ANNOUNCEMENT_GAP = 0.6

local function audio_update()
    -- finished?  (playback is timed in real seconds, see the clocks above)
    if now_playing and real_clock >= now_playing.started + now_playing.duration then
        if F and not now_playing.manual then F.ended[now_playing.event] = sim_clock end
        now_playing = nil
        queue.gap_until = real_clock + ANNOUNCEMENT_GAP
    end

    -- throw away announcements that waited too long to still make sense
    local kept = 1
    while kept <= #queue do
        local item = queue[kept]
        if item.expires and sim_clock > item.expires then
            log("dropped %s (too late)", item.event)
            if F then F.ended[item.event] = sim_clock end
            table.remove(queue, kept)
        else
            kept = kept + 1
        end
    end

    if not now_playing and #queue > 0 and real_clock >= (queue.gap_until or 0) then
        local item = table.remove(queue, 1)
        if bus_play(cfg.announce_bus, item.entry.path) then
            now_playing = {
                event    = item.event,
                path     = item.entry.path,
                name     = item.entry.name,
                pack     = item.pack,
                manual   = item.manual,
                started  = real_clock,
                duration = probe_duration(item.entry.path),
            }
            log("play %s [%s] %s", item.event, item.pack, item.entry.name)
        end
    end

    -- Loop the background track.  FlyWithLua re-decodes the file on every play
    -- and never frees the previous copy, so long tracks are looped a limited
    -- number of times instead of forever.
    if music and real_clock >= music.started + music.duration - 0.15 then
        if music.loops >= cfg.music_max_loops then
            log("%s: loop limit reached, stopping background audio", music.event)
            music = nil
        elseif bus_play(cfg.music_bus, music.path) then
            music.started = real_clock
            music.loops = music.loops + 1
        else
            music = nil
        end
    end

    -- volumes and ducking
    set_bus_volume(cfg.announce_bus, cfg.enabled and cfg.volume or 0)
    if cfg.music_bus ~= cfg.announce_bus then
        local level = cfg.music_volume
        if now_playing then level = level * cfg.duck end
        set_bus_volume(cfg.music_bus, cfg.enabled and level or 0)
    end
end

----------------------------------------------------------------------------
-- 8.  Flight state machine
----------------------------------------------------------------------------

local PHASES = {
    { id = "PREFLIGHT",  label = "Preflight",     hint = "waiting for the battery or any exterior light" },
    { id = "BOARDING",   label = "Boarding",      hint = "beacon ON ends boarding" },
    { id = "PUSHBACK",   label = "Doors & safety",hint = "engine start arms the doors" },
    { id = "TAKEOFF",    label = "Takeoff",       hint = "strobes/landing lights = crew seats" },
    { id = "CLIMB",      label = "Climb",         hint = "3000 ft AGL = after takeoff PA" },
    { id = "CRUISE",     label = "Cruise",        hint = "seatbelt sign drives the PA" },
    { id = "DESCENT",    label = "Descent",       hint = "below 10000 ft = seatbelts PA" },
    { id = "APPROACH",   label = "Approach",      hint = "3000 ft AGL = crew seats" },
    { id = "TAXI_IN",    label = "After landing", hint = "engines off + brake = disarm" },
    { id = "DISEMBARK",  label = "Disembarking",  hint = "resets for the next flight" },
}

local PHASE_INDEX = {}
for i, p in ipairs(PHASES) do PHASE_INDEX[p.id] = i end

local function reset_flight(reason, start_phase)
    F = {
        phase          = start_phase or "PREFLIGHT",
        phase_since    = sim_clock,
        done           = {},          -- event -> time it was queued
        ended          = {},          -- event -> time playback finished
        boarding_open  = false,
        last_welcome   = -1e9,
        seatbelt_prev  = nil,
        last_seatbelt  = -1e9,
        level_since    = nil,
        descent_since  = nil,
        touchdown_fpm  = nil,
        touchdown_at   = nil,
        liftoff_at     = nil,
        turb_peak      = 0,
    }
    queue = {}
    stop_announcement()
    stop_music()
    log("flight reset (%s) -> %s", reason, F.phase)
end

local function set_phase(id)
    if F.phase == id then return end
    F.phase = id
    F.phase_since = sim_clock
    log("phase -> %s", id)
end

-- play once per flight
local function once(event, reason)
    if F.done[event] then return false end
    F.done[event] = sim_clock
    if enqueue(event, reason) then return true end
    F.ended[event] = sim_clock       -- nothing to play: unblock whatever waits on it
    return false
end

-- true once the file has actually finished playing (plus an optional pause)
local function finished(event, extra_delay)
    local t = F.ended[event]
    if not t then return false end
    return sim_clock >= t + (extra_delay or 0)
end

-- "Is the aeroplane awake yet?"  Deliberately generous, and deliberately not
-- called cabin power: study-level add-ons run their own electrical system and
-- many never drive X-Plane's generic battery dataref, so on a ToLiss the battery
-- reads off with the aircraft fully powered up and the nav lights are what
-- actually moves.  Any one of these counts, and the panel names which ones are
-- seen - being told "cabin power on" while the cabin is plainly powered is worse
-- than a slightly longer line.
local POWER_SIGNS = {
    { name = "battery", read = function(s) return s.battery end },
    { name = "nav",     read = function(s) return s.nav_lights end },
    { name = "logo",    read = function(s) return s.logo end },
    { name = "taxi",    read = function(s) return s.taxi_light end },
}

local function aircraft_powered(s)
    local on = {}
    for _, sign in ipairs(POWER_SIGNS) do
        if sign.read(s) then on[#on + 1] = sign.name end
    end
    return #on > 0, on
end

local function state_machine()
    local s = sim

    -- ---------------------------------------------------------------- ground
    if F.phase == "PREFLIGHT" then
        local power = aircraft_powered(s)
        if s.on_ground and s.all_engines_off and not s.beacon and s.gs_kt < 1 then
            if cfg.auto_boarding and power then
                F.boarding_open = true
                set_phase("BOARDING")
                once("BoardingStarted", "cabin ready")
            end
        end
        if s.on_ground and s.any_engine and s.beacon then
            -- script loaded with engines already running
            set_phase("PUSHBACK")
        elseif not s.on_ground then
            set_phase("CRUISE")
            F.done["BoardingWelcome"] = sim_clock
            F.done["SafetyBriefing"]  = sim_clock
            F.done["AfterTakeoff"]    = sim_clock
        end
    end

    if F.phase == "BOARDING" then
        if sim_clock - F.last_welcome >= cfg.boarding_repeat then
            if enqueue("BoardingWelcome", "boarding") then
                F.last_welcome = sim_clock
                F.done["BoardingWelcome"] = sim_clock
                if cfg.pilot_welcome and not F.done["BoardingWelcomePilot"] then
                    F.done["BoardingWelcomePilot"] = sim_clock
                    enqueue("BoardingWelcomePilot", "boarding")
                end
            else
                F.last_welcome = sim_clock   -- do not retry every second
            end
        end

        if cfg.boarding_music and not music and #queue == 0 and not now_playing then
            start_music("BoardingMusic")
        end

        if s.beacon or s.any_engine then
            stop_music()
            once("BoardingComplete", "beacon on")
            set_phase("PUSHBACK")
        end
    end

    if F.phase == "PUSHBACK" then
        if cfg.door_calls and (s.any_engine or s.gs_kt > 1) then
            once("ArmDoors", "engines running")
        end
        if (not cfg.door_calls or finished("ArmDoors")) and s.any_engine then
            if has_event("PreSafetyBriefing") then
                if once("PreSafetyBriefing", "taxi out") then return end
            end
            if finished("PreSafetyBriefing") or not has_event("PreSafetyBriefing") then
                once("SafetyBriefing", "taxi out")
            end
        end
        if cfg.night_dim and s.is_dark and finished("SafetyBriefing", 10) then
            once("CabinDimTakeoff", "night departure")
        end
        if s.on_ground and s.any_engine and (s.strobe or s.landing_light) then
            -- The phase moves whether or not there is a file to play.  Until
            -- 2026-07-28 this and the disembark transition were gated on the
            -- announcement actually going on the air, so a pack missing one file
            -- stalled the machine - harmless here, but fatal on the stand.
            once("CrewSeatsTakeoff", "lined up")
            set_phase("TAKEOFF")
        end
        if not s.on_ground then set_phase("TAKEOFF") end
    end

    if F.phase == "TAKEOFF" then
        if not s.on_ground then
            if not F.liftoff_at then F.liftoff_at = sim_clock end
            if s.agl_ft > 3000 or (sim_clock - F.liftoff_at) > 150 then
                once("AfterTakeoff", "airborne")
                set_phase("CLIMB")
            end
        end
    end

    if F.phase == "CLIMB" then
        if math.abs(s.vs_fpm) < 350 and s.alt_ft > 15000 then
            F.level_since = F.level_since or sim_clock
            if sim_clock - F.level_since > 25 then
                once("TopOfClimbPilot", "top of climb")
                set_phase("CRUISE")
            end
        else
            F.level_since = nil
        end
        if s.alt_ft < 10000 and s.vs_fpm < -400 then set_phase("DESCENT") end
    end

    if F.phase == "CRUISE" then
        if s.vs_fpm < -500 and s.alt_ft > 20000 then
            F.descent_since = F.descent_since or sim_clock
            if sim_clock - F.descent_since > 25 then
                once("TopOfDescentPilot", "top of descent")
            end
        else
            F.descent_since = nil
        end
        if s.alt_ft < 11000 and s.vs_fpm < -300 then set_phase("DESCENT") end
    end

    -- "cabin secure" follow-ups are checked in every phase: the crew-seats call
    -- can still be in the queue when the phase has already moved on.
    if F.done["CrewSeatsTakeoff"] and finished("CrewSeatsTakeoff", 5) then
        once("CallCabinSecureTakeoff", "cabin secure")
    end
    if F.done["CrewSeatsLanding"] and finished("CrewSeatsLanding", 10) then
        once("CallCabinSecureLanding", "cabin secure")
    end

    -- seatbelt sign PA works in every airborne phase
    if not s.on_ground and s.seatbelt ~= nil then
        if F.seatbelt_prev == false and s.seatbelt == true then
            if sim_clock - F.last_seatbelt > 180 and s.agl_ft > 5000 then
                F.last_seatbelt = sim_clock
                local turbulent = F.turb_peak > 0.35 and has_event("Turbulence")
                enqueue(turbulent and "Turbulence" or "FastenSeatbelt", "seatbelt sign")
                F.turb_peak = 0
            end
        end
        F.seatbelt_prev = s.seatbelt
    end

    if F.phase == "DESCENT" then
        if s.alt_ft < 10000 then
            once("DescentSeatbelts", "below 10000 ft")
            if cfg.night_dim and s.is_dark then once("CabinDimLanding", "night arrival") end
        end
        if s.agl_ft < 5000 and s.vs_fpm < -300 then once("BeforeLanding", "final") end
        if s.agl_ft < 3000 and s.vs_fpm < -300 then
            once("CrewSeatsLanding", "approach")
            set_phase("APPROACH")
        end
    end

    if F.phase == "APPROACH" then
        if s.on_ground and s.gs_kt < 60 then
            once("AfterLanding", "vacated")
            set_phase("TAXI_IN")
        end
    end

    -- Cabin reaction to the touchdown, checked in any phase: a short landing can
    -- put us in TAXI_IN well before the 8 second wait is over.
    if cfg.landing_reaction and F.touchdown_at and sim_clock - F.touchdown_at > 8 then
        local fpm = math.abs(F.touchdown_fpm or 0)
        local reason = string.format("touchdown %d fpm", round(F.touchdown_fpm or 0))
        if fpm < 180 then
            once("LandingGreat", reason)
        elseif fpm > 400 then
            once("LandingTerrible", reason)
        end
    end

    if F.phase == "TAXI_IN" then
        -- parking brake OR simply standing still: not every operator sets the
        -- brake on stand, some go straight to chocks
        if s.all_engines_off and (s.parkbrake or s.gs_kt < 1) then
            if cfg.door_calls then once("DisarmDoors", "on stand") end
            if (not cfg.door_calls or finished("DisarmDoors")) and not s.beacon then
                -- This is the one that mattered: the turnaround reset lives in
                -- DISEMBARK, so a pack without this file left the machine parked
                -- in TAXI_IN with every announcement marked as already heard,
                -- and the next flight of the session said nothing at all.
                once("DisembarkStarted", "doors open")
                set_phase("DISEMBARK")
            end
        end
    end

    if F.phase == "DISEMBARK" then
        if cfg.boarding_music and not music and #queue == 0 and not now_playing
           and has_event("AfterLandingMusic") then
            start_music("AfterLandingMusic")
        end
        if sim_clock - F.phase_since > 120 then
            stop_music()
            reset_flight("turnaround", "PREFLIGHT")
        end
    end

    -- Cabin ambience: airborne only, and it has to stop on the ground - otherwise
    -- it keeps looping through the turnaround and blocks the arrival track.
    if music and music.event == "CabinNoise" and (s.on_ground or not cfg.cabin_noise) then
        stop_music()
    elseif cfg.cabin_noise and not s.on_ground and not music and has_event("CabinNoise") then
        start_music("CabinNoise")
    end
end

-- What the state machine above is waiting for, in a form the on-screen widget
-- can draw: the conditions that move us to the NEXT phase, each with its live
-- value.  This mirrors state_machine() and lives next to it on purpose - the
-- test bench flies a whole flight and checks that a phase never advances while
-- this list still reports something unmet, which is what catches drift.
local function phase_conditions()
    if not F then return "-", {} end
    local s = sim

    local function yes(label, met, value)
        return { label = label, met = met and true or false, value = value or "" }
    end
    local function ft(v) return string.format("%d", round(v or 0)) end

    local p = F.phase

    if p == "PREFLIGHT" then
        -- The value column carries the diagnosis: which of the four the plugin
        -- can see, or - when it sees none - which ones it is watching.  On an
        -- aircraft whose battery switch never reaches X-Plane that is the
        -- difference between "flip the nav lights" and "the plugin is broken".
        local powered, on = aircraft_powered(s)
        local reading
        if powered then
            reading = table.concat(on, " + ")
        else
            local watched = {}
            for _, sign in ipairs(POWER_SIGNS) do
                -- Only add-ons publish a logo light; do not name one that is
                -- not there to be switched.
                if sign.name ~= "logo" or logo_dref then
                    watched[#watched + 1] = sign.name
                end
            end
            reading = "no " .. table.concat(watched, "/")
        end
        return "Boarding", {
            yes("on the ground",   s.on_ground),
            yes("engines off",     s.all_engines_off),
            yes("beacon off",      not s.beacon),
            yes("battery or any light on", powered, reading),
        }
    elseif p == "BOARDING" then
        return "Doors & safety", {
            yes("beacon on or engine started", s.beacon or s.any_engine),
        }
    elseif p == "PUSHBACK" then
        return "Takeoff", {
            yes("engine running",           s.any_engine),
            yes("strobes / landing lights", s.strobe or s.landing_light),
        }
    elseif p == "TAKEOFF" then
        return "Climb", {
            yes("airborne", not s.on_ground),
            yes("3000 ft AGL", s.agl_ft > 3000, ft(s.agl_ft)),
        }
    elseif p == "CLIMB" then
        local held = F.level_since and (sim_clock - F.level_since) or 0
        return "Cruise", {
            yes("above 15 000 ft",  s.alt_ft > 15000, ft(s.alt_ft)),
            yes("levelling off",    math.abs(s.vs_fpm or 0) < 350, ft(s.vs_fpm) .. " fpm"),
            yes("held 25 s",        held > 25, string.format("%d s", round(held))),
        }
    elseif p == "CRUISE" then
        return "Descent", {
            yes("below 11 000 ft", s.alt_ft < 11000, ft(s.alt_ft)),
            yes("descending",      (s.vs_fpm or 0) < -300, ft(s.vs_fpm) .. " fpm"),
        }
    elseif p == "DESCENT" then
        return "Approach", {
            yes("below 3000 ft AGL", s.agl_ft < 3000, ft(s.agl_ft)),
            yes("descending",        (s.vs_fpm or 0) < -300, ft(s.vs_fpm) .. " fpm"),
        }
    elseif p == "APPROACH" then
        return "After landing", {
            yes("on the ground", s.on_ground),
            yes("below 60 kt",   (s.gs_kt or 0) < 60, ft(s.gs_kt) .. " kt"),
        }
    elseif p == "TAXI_IN" then
        return "Disembarking", {
            yes("engines off",           s.all_engines_off),
            yes("brake set or stopped",  s.parkbrake or (s.gs_kt or 0) < 1),
            yes("beacon off",            not s.beacon),
        }
    elseif p == "DISEMBARK" then
        local left = 120 - (sim_clock - F.phase_since)
        return "Preflight", {
            yes("turnaround", left <= 0, string.format("%d s", round(math.max(left, 0)))),
        }
    end
    return "-", {}
end

-- The sim can drop the aircraft somewhere the state machine cannot reach on its
-- own: teleport to a gate from the map, "start a new flight here", a repaired
-- crash.  Without this the announcer sits in Cruise forever and says nothing.
local AIRBORNE_PHASES = {
    TAKEOFF = true, CLIMB = true, CRUISE = true, DESCENT = true, APPROACH = true,
}
local GROUND_PHASES = {
    PREFLIGHT = true, BOARDING = true, PUSHBACK = true, TAXI_IN = true, DISEMBARK = true,
}

local function resync_phase()
    local s = sim
    local wrong = nil

    if AIRBORNE_PHASES[F.phase] and s.on_ground and s.all_engines_off and s.gs_kt < 1 then
        wrong = "parked while the phase says airborne"
    elseif GROUND_PHASES[F.phase] and not s.on_ground and s.agl_ft > 3000 then
        wrong = "airborne while the phase says on the ground"
    end

    if not wrong then
        F.resync_since = nil
        return
    end

    F.resync_since = F.resync_since or sim_clock
    if sim_clock - F.resync_since < 20 then return end

    if s.on_ground then
        reset_flight(wrong, "PREFLIGHT")
    else
        reset_flight(wrong, "CRUISE")
        F.done["BoardingWelcome"] = sim_clock
        F.done["SafetyBriefing"]  = sim_clock
        F.done["AfterTakeoff"]    = sim_clock
    end
end

----------------------------------------------------------------------------
-- 9.  Airline resolution (runs on load, on request, and when the livery changes)
----------------------------------------------------------------------------

local livery_dref_ok = find_dref("sim/aircraft/view/acf_livery_path") ~= nil
if livery_dref_ok then
    dataref("XA_LIVERY_PATH", "sim/aircraft/view/acf_livery_path", "readonly")
else
    XA_LIVERY_PATH = ""
end

-- Who we think we are flying for is one question; which pack we can actually
-- play is another.  Keeping them apart is what stops a recognised airline from
-- silently turning into "Default" just because nobody made a pack for it.
local function apply_pack(a)
    local code = (a.code or "Default"):upper()
    a.code     = code
    a.name     = a.name or airline_name(code)
    a.has_pack = library.packs[code] ~= nil
    a.pack     = a.has_pack and code or "DEFAULT"
    return a
end

local function detect_airline()
    if cfg.airline_mode == "manual" then
        return apply_pack({ code = cfg.airline_manual, source = "manual" })
    end

    local livery = XA_LIVERY_PATH or ""
    livery = livery:gsub("[/\\]+$", "")
    local leaf = livery:match("([^/\\]+)$") or ""

    -- Without dropping the extension "A320.acf" offers the word "acf", which is
    -- a real ICAO code (a Canarian flight school) and won every time.
    local acf = (AIRCRAFT_FILENAME or ""):gsub("%.%a+$", "")

    local candidates = {
        { text = leaf,             label = "livery" },
        { text = PLANE_TAILNUMBER, label = "tail number" },
        { text = acf,              label = "aircraft file" },
        { text = PLANE_DESCRIP,    label = "aircraft" },
    }

    for _, candidate in ipairs(candidates) do
        local code, how = airline_from_text(candidate.text)
        if code then
            return apply_pack({
                code   = code,
                source = candidate.label .. " (" .. (how or "") .. "): " .. tostring(candidate.text),
            })
        end
    end

    return apply_pack({ code = "Default", source = "nothing recognised" })
end

local function resolve_airline()
    current_airline = detect_airline()
    rebuild_coverage()
end

----------------------------------------------------------------------------
-- 9b.  SimBrief - optional, and never applied without being asked
----------------------------------------------------------------------------
-- LuaSocket is compiled into FlyWithLua itself - luaopen_socket_core is in the
-- binary - so this needs nothing installed.  What is NOT in the binary is any
-- kind of TLS: there is no luaopen_ssl of any name and no ssl module anywhere in
-- the plugin folder.  So the request goes over plain http, which the SimBrief
-- API answers directly (200, no redirect to https, no HSTS).  That means the
-- pilot ID and the flight plan travel in the clear; a flight plan is not worth
-- protecting, and Artyom said so explicitly when this was weighed.
--
-- Up to 1.1.2 the download was handed to curl instead, precisely to keep https.
-- Doing it here costs nothing at all in the frame: the socket is non-blocking
-- and pumped a bit at a time, whereas spawning curl froze the frame for as long
-- as the OS took to create a process.
local socket_ok, socket = pcall(require, "socket")
if not socket_ok then socket = nil end

local SB_HOST  = "www.simbrief.com"
local SB_PORT  = 80
local SB_PATH  = "/api/xml.fetcher.php?json=1&"
local SB_TIMEOUT   = 25
-- Connecting gets its own, shorter budget: a host that cannot be reached should
-- say so long before the whole fetch gives up.
local SB_CONNECT_TIMEOUT = 8
local SB_MAX_BYTES = 8 * 1024 * 1024   -- a full OFP with navlog is well under this
-- Read per frame.  At 30 fps this is several megabytes a second, so a 1.3 MB
-- plan lands in a fraction of a second, and copying that much costs nothing.
local SB_READ_CHUNK = 256 * 1024

local simbrief = {
    status  = "idle",     -- idle | fetching | ready | error
    message = "",
    started = 0,
    plan    = nil,        -- what SimBrief answered, waiting for a yes/no
    -- connect -> connecting -> send -> receive, driven from the frame callback
    stage   = nil,
    sock    = nil,
    request = nil,
    sent    = 0,
    buf     = nil,
    nbuf    = 0,
}

-- Up to 1.1.2 the fetch left a generated script and its scratch files in the
-- plugin folder.  Nothing writes them any more, and a dead simbrief_fetch.cmd
-- lying around reads like a symptom - it cost real time during one diagnosis.
for _, stale in ipairs({ "simbrief_fetch.cmd", "simbrief_fetch.sh",
                         "simbrief.part", "simbrief.err", "simbrief.json" }) do
    os.remove(BASE_DIR .. stale)
end

-- The pilot id is pasted by the user and goes straight into the request line, so
-- anything outside a plain identifier is dropped rather than escaped.  This is
-- what keeps a CR or LF in the field from writing headers of its own.  SimBrief
-- ids are alphanumeric; nothing legitimate is lost.
local function simbrief_id()
    return (tostring(cfg.simbrief_id or ""):gsub("[^%w_%-%.]", ""))
end

-- A scoped reader rather than a JSON parser.  SimBrief repeats key names across
-- sections - origin and destination both carry icao_code - so a value is only
-- ever read from inside the section it belongs to.
local function json_section(text, name)
    local _, open = text:find('"' .. name .. '"%s*:%s*{')
    if not open then return nil end
    local depth, i, n = 1, open + 1, #text
    local in_string, escaped = false, false
    while i <= n do
        local c = text:sub(i, i)
        if in_string then
            if escaped then escaped = false
            elseif c == "\\" then escaped = true
            elseif c == '"' then in_string = false end
        elseif c == '"' then in_string = true
        elseif c == "{" then depth = depth + 1
        elseif c == "}" then
            depth = depth - 1
            if depth == 0 then return text:sub(open + 1, i - 1) end
        end
        i = i + 1
    end
    return nil
end

local function json_value(text, key)
    if not text then return nil end
    local v = text:match('"' .. key .. '"%s*:%s*"([^"]*)"')
    if v then return v end
    return text:match('"' .. key .. '"%s*:%s*(%-?[%d%.]+)')
end

local function simbrief_parse(raw)
    if not raw or raw == "" then return nil, "empty answer" end

    local fetch  = json_section(raw, "fetch")
    local status = fetch and json_value(fetch, "status") or nil
    if status and status:lower():find("error") then
        -- "Error: Unknown UserID" and friends are worth showing verbatim
        return nil, status
    end

    local general = json_section(raw, "general")
    local airline = general and json_value(general, "icao_airline") or nil
    if not airline or airline == "" then
        return nil, "the plan carries no airline code"
    end

    local params = json_section(raw, "params")
    local origin = json_section(raw, "origin")
    local dest   = json_section(raw, "destination")
    local atc    = json_section(raw, "atc")
    local acf    = json_section(raw, "aircraft")

    return {
        airline   = airline:upper(),
        flight    = general and json_value(general, "flight_number") or "",
        callsign  = atc and json_value(atc, "callsign") or "",
        origin    = origin and json_value(origin, "icao_code") or "",
        dest      = dest and json_value(dest, "icao_code") or "",
        aircraft  = acf and json_value(acf, "icaocode") or "",
        reg       = acf and json_value(acf, "reg") or "",
        generated = tonumber(params and json_value(params, "time_generated") or "") or 0,
    }
end

-- Every exit from a fetch goes through these two, so a half-open socket can
-- never be left behind for the next attempt to trip over.
local function simbrief_close()
    if simbrief.sock then pcall(function() simbrief.sock:close() end) end
    simbrief.sock, simbrief.stage = nil, nil
    simbrief.buf, simbrief.nbuf = nil, 0
end

local function simbrief_fail(fmt, ...)
    simbrief_close()
    simbrief.status  = "error"
    simbrief.message = string.format(fmt, ...)
    log("simbrief: %s", simbrief.message)
end

local function simbrief_finish(raw)
    local head_end = raw:find("\r\n\r\n", 1, true)
    if not head_end then
        simbrief_fail("the answer was not an HTTP reply")
        return
    end
    local code = raw:sub(1, head_end):match("^HTTP/%d%.%d%s+(%d%d%d)")
    if code ~= "200" then
        simbrief_fail("SimBrief answered %s", code or "something unreadable")
        return
    end

    local plan, err = simbrief_parse(raw:sub(head_end + 4))
    if not plan then
        simbrief_fail("%s", err or "could not read the answer")
        return
    end

    simbrief.plan    = plan
    simbrief.status  = "ready"
    simbrief.message = ""
    log("simbrief: %s%s %s-%s, generated %s", plan.airline, plan.flight,
        plan.origin, plan.dest,
        plan.generated > 0 and os.date("!%Y-%m-%d %H:%M UTC", plan.generated) or "?")
end

local function simbrief_start()
    local id = simbrief_id()
    if id == "" then
        simbrief.status  = "error"
        simbrief.message = "set your SimBrief pilot ID or username first"
        return
    end
    if simbrief.status == "fetching" then return end
    if not socket then
        simbrief.status  = "error"
        simbrief.message = "this FlyWithLua has no LuaSocket, so SimBrief is out of reach"
        log("simbrief: %s", simbrief.message)
        return
    end

    -- SimBrief takes either the numeric pilot id or the account name
    local key = id:match("^%d+$") and "userid" or "username"

    -- HTTP/1.0 with Connection: close on purpose.  Asked that way the server
    -- sends the body straight through and closes, so "read until the connection
    -- ends" is the whole framing; over HTTP/1.1 the same answer comes back
    -- chunked and would need a chunk decoder for nothing.
    simbrief.request = string.format(
        "GET %s%s=%s HTTP/1.0\r\nHost: %s\r\nUser-Agent: X-Announcer/%s\r\n"
        .. "Accept: application/json\r\nConnection: close\r\n\r\n",
        SB_PATH, key, id, SB_HOST, VERSION)
    simbrief.sent    = 0
    simbrief.buf     = {}
    simbrief.nbuf    = 0
    simbrief.stage   = "connect"
    simbrief.status  = "fetching"
    simbrief.message = "asking SimBrief..."
    simbrief.started = os.time()
    log("simbrief: fetching the latest plan for %s=%s", key, id)
end

-- Driven from the frame callback rather than the once-a-second tick: a plan is
-- well over a megabyte, and at 30 fps this walks through it in a fraction of a
-- second.  Every step is non-blocking, so no single frame waits for the network.
local function simbrief_pump()
    if simbrief.status ~= "fetching" then return end

    if os.time() - simbrief.started > SB_TIMEOUT then
        simbrief_fail("SimBrief did not answer within %d s", SB_TIMEOUT)
        return
    end

    if simbrief.stage == "connect" then
        local sock = socket.tcp()
        if not sock then
            simbrief_fail("could not open a socket")
            return
        end
        sock:settimeout(0)
        simbrief.sock = sock
        -- The name lookup inside connect() is the one step here that can block.
        -- The OS resolver caches it, so it costs anything only on the first
        -- fetch after X-Plane starts, and then only milliseconds.
        local ok, err = sock:connect(SB_HOST, SB_PORT)
        if ok then
            simbrief.stage = "send"
        elseif err == "timeout" or err == "Operation already in progress" then
            simbrief.stage = "connecting"
        else
            simbrief_fail("cannot reach %s (%s)", SB_HOST, tostring(err))
        end
        return
    end

    if simbrief.stage == "connecting" then
        -- Deliberately NOT socket.select(): its own manual warns that "a known
        -- bug in WinSock causes select to fail on non-blocking TCP sockets" and
        -- that it "may return a socket as writable even though the socket is not
        -- ready for sending" - and Windows is the platform this runs on most.
        -- getpeername() has no such caveat: it answers only once the connection
        -- really stands, and nil until then.
        if simbrief.sock:getpeername() then
            simbrief.stage = "send"
        elseif os.time() - simbrief.started > SB_CONNECT_TIMEOUT then
            simbrief_fail("cannot reach %s - is the network up?", SB_HOST)
        end
        return
    end

    if simbrief.stage == "send" then
        -- The request is a couple of hundred bytes and goes in one piece in
        -- practice, but a partial send is legal and is resumed from where it got.
        local sent, err, last = simbrief.sock:send(simbrief.request, simbrief.sent + 1)
        if sent then
            simbrief.sent = sent
            if sent >= #simbrief.request then simbrief.stage = "receive" end
        elseif err == "timeout" then
            simbrief.sent = last or simbrief.sent
        else
            simbrief_fail("could not send the request (%s)", tostring(err))
        end
        return
    end

    -- Belt and braces: a Lua error in a callback stops the whole FlyWithLua
    -- engine, so an unexpected state ends the fetch instead of indexing nil.
    if simbrief.stage ~= "receive" or not simbrief.sock then
        simbrief_fail("the fetch lost its way (stage %s)", tostring(simbrief.stage))
        return
    end

    local data, err, partial = simbrief.sock:receive(SB_READ_CHUNK)
    local piece = data or partial
    if piece and #piece > 0 then
        simbrief.nbuf = simbrief.nbuf + #piece
        simbrief.buf[#simbrief.buf + 1] = piece
        if simbrief.nbuf > SB_MAX_BYTES then
            simbrief_fail("the answer was far too large to be a flight plan")
            return
        end
    end

    if err == "closed" then
        -- Connection: close means the end of the connection is the end of the
        -- body: everything collected is the answer.
        local raw = table.concat(simbrief.buf)
        simbrief_close()
        if raw == "" then
            simbrief_fail("SimBrief closed the connection without answering")
        else
            simbrief_finish(raw)
        end
    elseif err and err ~= "timeout" then
        simbrief_fail("the connection broke (%s)", tostring(err))
    end
end

-- Only ever called from the confirmation button.  A plan that is still loaded
-- from yesterday's flight must not be able to change anything on its own.
local function simbrief_apply()
    local plan = simbrief.plan
    if not plan then return end
    cfg.airline_mode   = "manual"
    cfg.airline_manual = plan.airline
    config_save()
    resolve_airline()
    simbrief.status  = "idle"
    simbrief.plan    = nil
    simbrief.message = "airline pinned to " .. plan.airline
    log("simbrief: airline pinned to %s", plan.airline)
end

----------------------------------------------------------------------------
-- 10.  Callbacks
----------------------------------------------------------------------------

local last_time_ref = nil
local last_livery   = nil
local tick_accum    = 0

-- Monotonic seconds from the sim; falls back to os.clock() if neither dataref
-- is present, so the queue can never stall.
local CLOCK_DREFS = {
    "sim/network/misc/network_time_sec",
    "sim/time/total_running_time_sec",
}
local clock_dref = nil

local function sim_time()
    if clock_dref then return getf(clock_dref, 0) end
    return os.clock()
end

local last_wall     = nil
local frozen_reason = nil     -- "paused" / "replay" / nil

-- The manual warns that do_every_frame "can slow down the simulator at a
-- glance", so this callback stays deliberately thin: two clocks, the touchdown
-- sampling that genuinely needs frame rate, and the audio queue at ~4 Hz.
-- Pause and replay are re-read a few times per second, not every frame.
local FREEZE_CHECK_FRAMES = 10
local freeze_accum = FREEZE_CHECK_FRAMES
local frozen_cached = nil

local function frame_body()
    -- Before every guard below.  A fetch is asked for on the ground, often with
    -- the sim paused, and it has nothing to do with flight state - the pause
    -- must not leave it half-finished with a socket open.
    simbrief_pump()

    -- Clocks.  Both stop while the sim is paused or replaying, otherwise the
    -- announcer would "play" through a pause and come out of it mid-sentence.
    local t     = sim_time()
    local wall  = os.time()

    freeze_accum = freeze_accum + 1
    if freeze_accum >= FREEZE_CHECK_FRAMES then
        freeze_accum = 0
        local paused = geti("sim/time/paused", 0) == 1
        local replay = geti("sim/time/is_in_replay", 0) == 1
                    or geti("sim/operation/prefs/replay_mode", 0) == 1
        frozen_cached = paused and "paused" or (replay and "replay" or nil)
    end

    local new_reason = frozen_cached
    if new_reason ~= frozen_reason then
        if new_reason then log("clock frozen: %s", new_reason)
        else log("clock running again") end
        frozen_reason = new_reason
    end

    if last_time_ref and not frozen_reason then
        local dt = t - last_time_ref
        if dt > 0 and dt < 5 then sim_clock = sim_clock + dt end
        if last_wall then
            local dwall = wall - last_wall
            if dwall > 0 and dwall < 30 then real_clock = real_clock + dwall end
        end
    end
    last_time_ref = t
    last_wall = wall
    if frozen_reason then return end

    -- touchdown vertical speed has to be sampled at frame rate
    local on_ground = geti("sim/flightmodel/failures/onground_any", 1) == 1
    if F then
        if not on_ground then
            F.last_vs = getf("sim/flightmodel/position/vh_ind_fpm", 0)
            local g = math.abs(getf("sim/flightmodel/forces/g_nrml", 1) - 1)
            if g > F.turb_peak then F.turb_peak = g end
            F.was_airborne = true
        elseif F.was_airborne then
            F.was_airborne = false
            F.touchdown_fpm = F.last_vs
            F.touchdown_at = sim_clock
            log("touchdown at %d fpm", round(F.touchdown_fpm or 0))
        end
    end

    tick_accum = tick_accum + 1
    if tick_accum >= 15 then       -- ~4 Hz, enough for the queue
        tick_accum = 0
        audio_update()
    end
end

local function tick_body()
    if not F then return end
    read_sim()

    if frozen_reason then return end

    if XA_LIVERY_PATH ~= last_livery then
        last_livery = XA_LIVERY_PATH
        forget_sounds()          -- the FMOD banks are rebuilt with the aircraft
        resolve_airline()
        log("airline: %s (%s), pack %s", current_airline.code,
            current_airline.source, current_airline.pack)
    end

    resync_phase()

    if cfg.enabled then state_machine() end
end

-- A Lua error inside a FlyWithLua callback stops the whole Lua engine - every
-- other script in the sim goes down with it.  Nothing this plugin does is worth
-- that, so each callback runs inside pcall and the plugin switches itself off
-- if it keeps failing.
local guard = { stopped = false }

local function guarded(what, body)
    -- The counter is per callback: the frame callback runs dozens of times per
    -- second, and a shared counter would reset the tick's failures every frame.
    local errors = 0
    return function(...)
        if guard.stopped then return end
        local ok, err = pcall(body, ...)
        if ok then
            errors = 0
            return
        end
        errors = errors + 1
        log("%s failed: %s", what, tostring(err))
        if errors >= 10 then
            guard.stopped = true
            log("stopping the announcer after 10 consecutive errors; "
                .. "fix the cause and reload the Lua scripts")
            pcall(stop_announcement)
            pcall(stop_music)
        end
    end
end

xa_frame = guarded("frame callback", frame_body)
xa_tick  = guarded("state tick", tick_body)
-- The widget builder is assigned further down, once it exists; the draw
-- callback is guarded like the others because an error here would take the
-- whole Lua engine down with every other script in the sim.
xa_draw  = guarded("widget draw", function() if xa_draw_widget then xa_draw_widget() end end)

----------------------------------------------------------------------------
-- 11.  User interface
----------------------------------------------------------------------------

local COL = {
    accent   = 0xFF4AC2FF,   -- ABGR - seatbelt-sign amber
    text     = 0xFFEDEDED,
    muted    = 0xFFA0938A,
    dim      = 0xFF6E645C,
    ok       = 0xFF8FD87B,
    warn     = 0xFF6B6BFF,
}

local ui = {
    window        = nil,
    filter        = "",
    library_input = nil,
    airline_input = "",
    show_unknown  = false,
}

local function push_text(color) imgui.PushStyleColor(imgui.constant.Col.Text, color) end
local function pop_text()       imgui.PopStyleColor() end

local function text_col(color, str)
    push_text(color)
    imgui.TextUnformatted(str)
    pop_text()
end

local function label_value(label, value, value_color)
    push_text(COL.muted)
    imgui.TextUnformatted(label)
    pop_text()
    imgui.SameLine(140)
    text_col(value_color or COL.text, value)
end

local function draw_flight_tab()
    local phase_index = PHASE_INDEX[F.phase] or 1

    -- focal element: the current phase, big and amber
    imgui.Dummy(0, 4)
    imgui.SetWindowFontScale(1.6 * cfg.window_scale)
    text_col(COL.accent, string.upper(PHASES[phase_index].label))
    imgui.SetWindowFontScale(1.0 * cfg.window_scale)
    text_col(COL.dim, PHASES[phase_index].hint)

    -- anything that is currently holding the announcer back says so here
    if guard.stopped then
        text_col(COL.warn, "stopped after repeated errors - see the Log tab, "
                        .. "then reload the Lua scripts")
    elseif frozen_reason then
        text_col(COL.warn, "clock frozen: " .. frozen_reason)
    elseif not cfg.enabled then
        text_col(COL.warn, "muted")
    end
    imgui.Dummy(0, 6)

    -- now playing
    if now_playing then
        local elapsed = real_clock - now_playing.started
        push_text(COL.text)
        imgui.TextUnformatted(now_playing.event)
        pop_text()
        imgui.SameLine()
        text_col(COL.muted, string.format("  %s / %s   [%s]",
            mmss(elapsed), mmss(now_playing.duration), now_playing.pack))
        imgui.PushStyleColor(imgui.constant.Col.PlotHistogram, COL.accent)
        imgui.ProgressBar(clamp(elapsed / math.max(now_playing.duration, 0.1), 0, 1), -1, 6, "")
        imgui.PopStyleColor()
    elseif #queue > 0 then
        text_col(COL.muted, string.format("queued: %d", #queue))
        imgui.Dummy(0, 6)
    else
        text_col(COL.dim, music and ("background: " .. music.event) or "cabin quiet")
        imgui.Dummy(0, 6)
    end

    imgui.Separator()
    imgui.Dummy(0, 4)

    label_value("Airline", string.format("%s  %s", current_airline.code,
        current_airline.name and ("- " .. current_airline.name) or ""), COL.text)
    label_value("Detected by", current_airline.source, COL.muted)
    -- Recognising the airline and owning its voice pack are different things.
    -- Say so, otherwise a correct detection reads like a failed one.
    if current_airline.code ~= "DEFAULT" and not current_airline.has_pack then
        label_value("Voice pack", "no pack for " .. current_airline.code ..
                    " - playing Default", COL.warn)
    end
    label_value("Aircraft", string.format("%s  %s", PLANE_ICAO or "?",
        (PLANE_TAILNUMBER and PLANE_TAILNUMBER ~= "") and ("(" .. PLANE_TAILNUMBER .. ")") or ""), COL.muted)
    label_value("Local time", string.format("%02d:00  %s", sim.local_hour or 0, sim.daypart or ""), COL.muted)
    label_value("Seatbelt sign", seatbelt_dref and
        ((sim.seatbelt and "ON" or "off") .. "  " .. seatbelt_dref.name) or "not available",
        sim.seatbelt and COL.accent or COL.muted)

    imgui.Dummy(0, 6)
    imgui.Separator()
    imgui.Dummy(0, 4)

    -- signature element: the announcement ladder
    if imgui.BeginChild("ladder", 0, 150, false) then
        for i, phase in ipairs(PHASES) do
            local marker, color
            if i < phase_index then
                marker, color = "  done  ", COL.dim
            elseif i == phase_index then
                marker, color = "> now   ", COL.accent
            else
                marker, color = "        ", COL.muted
            end
            push_text(color)
            imgui.TextUnformatted(marker .. phase.label)
            pop_text()
        end
        imgui.EndChild()
    end

    -- The widget is this ladder in miniature, so its switch belongs against the
    -- ladder rather than seven sections down the Settings tab, where the first
    -- release hid it well enough that nobody found it.
    imgui.Dummy(0, 2)
    local pin_changed, pin_value = imgui.Checkbox("Pin this to the screen", cfg.widget)
    if pin_changed then cfg.widget = pin_value config_save() end
    imgui.SameLine()
    text_col(COL.dim, cfg.widget
        and ("  " .. cfg.widget_mode .. " - size and place it on the Settings tab")
        or  "  draws the phase over the cockpit view")

    imgui.Dummy(0, 4)
    imgui.Separator()
    imgui.Dummy(0, 4)

    if imgui.Button(cfg.enabled and "Mute announcer" or "Un-mute", 130, 22) then
        cfg.enabled = not cfg.enabled
        if not cfg.enabled then stop_announcement() stop_music() end
        config_save()
    end
    imgui.SameLine()
    if imgui.Button("Skip current", 110, 22) then
        stop_announcement()
        queue.gap_until = real_clock
    end
    imgui.SameLine()
    if imgui.Button("Start boarding", 120, 22) then
        reset_flight("manual boarding", "BOARDING")
        F.boarding_open = true
        F.last_welcome = -1e9
    end
    imgui.SameLine()
    if imgui.Button("Reset flight", 100, 22) then
        reset_flight("manual", "PREFLIGHT")
    end
end

local function draw_library_tab()
    text_col(COL.muted, "Sound library folder")
    imgui.SetNextItemWidth(-90)
    local changed, value = imgui.InputText("##library", ui.library_input or cfg.library, 512)
    if changed then ui.library_input = value end
    imgui.SameLine()
    if imgui.Button("Rescan", 80, 20) then
        if ui.library_input and ui.library_input ~= "" then
            cfg.library = trim(ui.library_input)
        end
        config_save()
        scan_library()
        resolve_airline()
    end

    imgui.Dummy(0, 4)

    -- airline selector
    text_col(COL.muted, "Airline")
    imgui.SetNextItemWidth(220)
    local preview = (cfg.airline_mode == "auto")
        and ("Auto - " .. current_airline.code)
        or  cfg.airline_manual
    if imgui.BeginCombo("##airline", preview) then
        if imgui.Selectable("Auto (from livery / tail number)", cfg.airline_mode == "auto") then
            cfg.airline_mode = "auto"
            resolve_airline()
            config_save()
        end
        for _, code in ipairs(library.codes) do
            local name = airline_name(code)
            local caption = name and (code .. "  -  " .. name) or code
            if imgui.Selectable(caption, cfg.airline_mode == "manual" and cfg.airline_manual == code) then
                cfg.airline_mode = "manual"
                cfg.airline_manual = code
                resolve_airline()
                config_save()
            end
        end
        imgui.EndCombo()
    end
    imgui.SameLine()
    text_col(COL.dim, string.format("%d packs found", #library.codes))

    -- a stop that is always in reach, whichever row started the playback
    if now_playing then
        imgui.SameLine()
        if imgui.SmallButton("stop playback") then
            stop_announcement()
            queue = {}
        end
        imgui.SameLine()
        push_text(COL.accent)
        imgui.TextUnformatted(string.format("%s  %s / %s", now_playing.event,
            mmss(real_clock - now_playing.started), mmss(now_playing.duration)))
        pop_text()
    end

    imgui.Dummy(0, 6)
    imgui.Separator()
    imgui.Dummy(0, 4)

    local pack = library.packs[current_airline.pack]
    local default_pack = library.packs["DEFAULT"]

    if not pack and not default_pack then
        text_col(COL.warn, "No sound pack for this airline and no Default folder.")
        return
    end

    if imgui.BeginChild("events", 0, 240, false) then
        if imgui.BeginTable("events_table", 4,
                imgui.constant.TableFlags.RowBg + imgui.constant.TableFlags.SizingStretchProp) then
            imgui.TableSetupColumn("Event", 0, 0.42, 0)
            imgui.TableSetupColumn("Files", 0, 0.12, 0)
            imgui.TableSetupColumn("Source", 0, 0.26, 0)
            imgui.TableSetupColumn("", 0, 0.20, 0)
            imgui.TableHeadersRow()

            for _, event in ipairs(EVENTS) do
                local info = coverage[event] or {}
                local count = (info.own or 0) > 0 and info.own or (info.fallback or 0)

                imgui.TableNextRow()
                imgui.TableNextColumn()
                push_text(info.available and COL.text or COL.dim)
                imgui.TextUnformatted(event)
                pop_text()

                imgui.TableNextColumn()
                text_col(info.available and COL.muted or COL.dim, tostring(count))

                imgui.TableNextColumn()
                text_col(info.source == current_airline.pack and COL.ok or COL.muted,
                         info.source or "-")

                imgui.TableNextColumn()
                if info.available then
                    imgui.PushID("play" .. event)
                    if now_playing and now_playing.event == event then
                        if imgui.SmallButton("stop") then
                            stop_announcement()
                            queue = {}
                        end
                    elseif imgui.SmallButton("play") then
                        -- an explicit "play this" outranks the mute switch,
                        -- otherwise the button does nothing and looks broken
                        if not cfg.enabled then
                            cfg.enabled = true
                            log("un-muted for test playback")
                        end
                        stop_announcement()
                        queue = {}
                        enqueue(event, "manual test", true)
                        audio_update()
                    end
                    imgui.PopID()
                end
            end
            imgui.EndTable()
        end
        imgui.EndChild()
    end
end

local BUSES = { "interior", "master", "ui", "com1" }

-- The two roles must never share a bus: stopping one would stop the other and
-- ducking would silence the announcement itself.  So the bus already taken by
-- the other role is simply not offered.
local function bus_combo(label, key, other_key)
    imgui.SetNextItemWidth(120)
    if imgui.BeginCombo(label, cfg[key]) then
        for _, bus in ipairs(BUSES) do
            if bus ~= cfg[other_key] then
                if imgui.Selectable(bus, cfg[key] == bus) then
                    -- whatever is playing lives on the old bus and would keep
                    -- looping there, silent and unstoppable
                    if key == "music_bus" then stop_music() else stop_announcement() end
                    set_bus_volume(cfg[key], 0)
                    cfg[key] = bus
                    config_save()
                end
            end
        end
        imgui.EndCombo()
    end
end

-- Every script in the sim shares one Lua state, so this stays a local rather
-- than a global the way the callbacks have to be.
local WIDGET_MODES = {
    { id = "minimal", hint = "one line: the phase and the one thing being waited for" },
    { id = "medium",  hint = "adds every condition for the next phase, with live values" },
    { id = "full",    hint = "adds the phase ladder around where you are now" },
}

-- How old the plan is, in the words a dispatcher would use.  This line is the
-- whole reason the plan is not applied automatically: the usual mistake is
-- loading into the sim before re-generating the OFP, and a timestamp alone
-- makes that easy to miss.
local function plan_age_text(seconds)
    if seconds < 0 then return "just now" end
    if seconds < 90 then return string.format("%d s ago", math.floor(seconds)) end
    if seconds < 5400 then return string.format("%d min ago", math.floor(seconds / 60 + 0.5)) end
    return string.format("%.1f h ago", seconds / 3600)
end

local function plan_age_colour(seconds)
    if seconds < 1800 then return COL.ok end       -- half an hour: this is the flight
    if seconds < 10800 then return COL.muted end   -- three hours: probably still it
    return COL.warn                                -- older than that: check before using
end

local function draw_simbrief_section()
    local changed, value

    text_col(COL.muted, "SimBrief pilot ID or username")
    imgui.SetNextItemWidth(160)
    changed, value = imgui.InputText("##sbid", cfg.simbrief_id, 64)
    if changed then cfg.simbrief_id = value end
    imgui.SameLine()
    if imgui.Button("Save##sbid", 60, 20) then config_save() end
    imgui.SameLine()
    if imgui.Button("Fetch latest plan", 130, 20) then
        config_save()
        simbrief_start()
    end

    if simbrief.status == "fetching" then
        text_col(COL.muted, "  asking SimBrief...")
    elseif simbrief.status == "error" then
        text_col(COL.warn, "  " .. simbrief.message)
    elseif simbrief.message ~= "" then
        text_col(COL.ok, "  " .. simbrief.message)
    end

    local plan = simbrief.plan
    if simbrief.status == "ready" and plan then
        local age = os.time() - (plan.generated > 0 and plan.generated or os.time())

        imgui.Dummy(0, 4)
        imgui.Separator()
        imgui.Dummy(0, 4)

        -- The flight itself leads: this is what the user checks first.
        local route = (plan.origin ~= "" and plan.dest ~= "")
            and (plan.origin .. " -> " .. plan.dest) or ""
        text_col(COL.accent, string.format("%s   %s",
            plan.callsign ~= "" and plan.callsign or (plan.airline .. plan.flight), route))

        label_value("Airline", string.format("%s  %s", plan.airline,
            airline_name(plan.airline) and ("- " .. airline_name(plan.airline)) or ""), COL.text)
        if plan.aircraft ~= "" or plan.reg ~= "" then
            label_value("Aircraft", plan.aircraft .. (plan.reg ~= "" and ("  " .. plan.reg) or ""), COL.muted)
        end
        label_value("Plan generated", plan.generated > 0
            and plan_age_text(age) or "unknown", plan_age_colour(age))

        if plan.airline == current_airline.code then
            text_col(COL.dim, "  same airline as now - nothing would change")
        end

        imgui.Dummy(0, 4)
        if imgui.Button("Use this airline", 140, 22) then simbrief_apply() end
        imgui.SameLine()
        if imgui.Button("Dismiss", 90, 22) then
            simbrief.plan   = nil
            simbrief.status = "idle"
        end
    end
end

local function draw_settings_tab()
    local changed, value

    text_col(COL.muted, "On-screen phase widget")
    changed, value = imgui.Checkbox("Show it over the sim", cfg.widget)
    if changed then cfg.widget = value config_save() end
    imgui.SameLine()
    text_col(COL.dim, "  same switch as on the Flight tab")

    imgui.SetNextItemWidth(160)
    if imgui.BeginCombo("density", cfg.widget_mode) then
        for _, mode in ipairs(WIDGET_MODES) do
            if imgui.Selectable(mode.id, cfg.widget_mode == mode.id) then
                cfg.widget_mode = mode.id
                config_save()
            end
        end
        imgui.EndCombo()
    end
    -- The hint used to be a tooltip on each entry, through imgui.SetTooltip -
    -- which FlyWithLua does not bind, so it took the whole panel down the moment
    -- this list was opened.  Hover hints are still possible the long way round
    -- (imgui.BeginTooltip / EndTooltip, as FlyWithLua's own imgui_demo.lua does
    -- it), but on the line is better anyway: a hint nobody has to hover to find.
    for _, mode in ipairs(WIDGET_MODES) do
        if mode.id == cfg.widget_mode then
            imgui.SameLine()
            text_col(COL.dim, "  " .. mode.hint)
        end
    end

    imgui.SetNextItemWidth(200)
    changed, value = imgui.SliderFloat("backing opacity", cfg.widget_opacity, 0, 1, "%.2f")
    if changed then cfg.widget_opacity = value config_save() end
    imgui.SetNextItemWidth(120)
    changed, value = imgui.SliderInt("from the left", round(cfg.widget_x), 0, 2000, "%d px")
    if changed then cfg.widget_x = value config_save() end
    imgui.SetNextItemWidth(120)
    changed, value = imgui.SliderInt("from the top", round(cfg.widget_y), 0, 1400, "%d px")
    if changed then cfg.widget_y = value config_save() end

    imgui.Dummy(0, 6)
    imgui.Separator()
    imgui.Dummy(0, 4)

    text_col(COL.muted, "Volume")
    imgui.SetNextItemWidth(200)
    changed, value = imgui.SliderFloat("announcements", cfg.volume, 0, 1, "%.2f")
    if changed then cfg.volume = value config_save() end
    imgui.SetNextItemWidth(200)
    changed, value = imgui.SliderFloat("boarding music", cfg.music_volume, 0, 1, "%.2f")
    if changed then cfg.music_volume = value config_save() end
    imgui.SetNextItemWidth(200)
    changed, value = imgui.SliderFloat("music ducking", cfg.duck, 0, 1, "%.2f")
    if changed then cfg.duck = value config_save() end

    imgui.Dummy(0, 6)
    imgui.Separator()
    imgui.Dummy(0, 4)

    text_col(COL.muted, "Announcements")
    changed, value = imgui.Checkbox("Boarding music", cfg.boarding_music)
    if changed then cfg.boarding_music = value if not value then stop_music() end config_save() end
    changed, value = imgui.Checkbox("Cabin ambience in flight", cfg.cabin_noise)
    if changed then
        cfg.cabin_noise = value
        if not value and music and music.event == "CabinNoise" then stop_music() end
        config_save()
    end
    changed, value = imgui.Checkbox("Arm / disarm doors calls", cfg.door_calls)
    if changed then cfg.door_calls = value config_save() end
    changed, value = imgui.Checkbox("Cabin dimming at night", cfg.night_dim)
    if changed then cfg.night_dim = value config_save() end
    changed, value = imgui.Checkbox("Cabin reaction to the landing", cfg.landing_reaction)
    if changed then cfg.landing_reaction = value config_save() end
    changed, value = imgui.Checkbox("Captain's welcome during boarding", cfg.pilot_welcome)
    if changed then cfg.pilot_welcome = value config_save() end
    changed, value = imgui.Checkbox("Start boarding automatically", cfg.auto_boarding)
    if changed then cfg.auto_boarding = value config_save() end

    imgui.SetNextItemWidth(200)
    changed, value = imgui.SliderInt("welcome repeat (s)", round(cfg.boarding_repeat), 60, 900, "%d")
    if changed then cfg.boarding_repeat = value config_save() end

    imgui.Dummy(0, 6)
    imgui.Separator()
    imgui.Dummy(0, 4)

    draw_simbrief_section()

    imgui.Dummy(0, 6)
    imgui.Separator()
    imgui.Dummy(0, 4)

    text_col(COL.muted, "Audio routing (FMOD bus)")
    bus_combo("announcements##bus", "announce_bus", "music_bus")
    bus_combo("music##bus", "music_bus", "announce_bus")

    imgui.Dummy(0, 4)
    text_col(COL.muted, "Language sub-folder")
    imgui.SetNextItemWidth(120)
    changed, value = imgui.InputText("##lang", cfg.language, 32)
    if changed then cfg.language = value end
    imgui.SameLine()
    if imgui.Button("Apply##lang", 70, 20) then
        config_save()
        scan_library()
        resolve_airline()     -- also rebuilds the event coverage cache
    end

    imgui.Dummy(0, 4)
    text_col(COL.muted, "Seatbelt sign dataref override")
    imgui.SetNextItemWidth(-80)
    changed, value = imgui.InputText("##sbdref", cfg.seatbelt_dref, 200)
    if changed then cfg.seatbelt_dref = value end
    imgui.SameLine()
    if imgui.Button("Use##sb", 70, 20) then
        config_save()
        seatbelt_dref = first_seatbelt()
        log("seatbelt dataref: %s", seatbelt_dref and seatbelt_dref.name or "none")
    end

    imgui.Dummy(0, 4)
    imgui.SetNextItemWidth(200)
    changed, value = imgui.SliderFloat("window text scale", cfg.window_scale, 0.8, 2.0, "%.2f")
    if changed then cfg.window_scale = value config_save() end

    imgui.Dummy(0, 6)
    imgui.Separator()
    imgui.Dummy(0, 4)

    text_col(COL.muted, "Sound handles")
    if imgui.Button("Reload sound files", 150, 22) then
        stop_announcement()
        stop_music()
        forget_sounds()
    end
    imgui.SameLine()
    local slots_left = SOUND_SLOTS - snd_count
    text_col(slots_left < 50 and COL.warn or COL.dim,
        string.format("%d of %d slots used", snd_count, SOUND_SLOTS))
    imgui.TextUnformatted("")
    text_col(COL.dim, "use this if the aircraft changed and announcements went silent")
end

local function draw_log_tab()
    if imgui.Button("Clear", 70, 20) then log_lines = {} end
    imgui.SameLine()
    text_col(COL.dim, string.format("FlyWithLua %s / announcer %s / %d sounds loaded",
        tostring(PLUGIN_VERSION or "?"), VERSION, snd_count))
    imgui.Separator()
    if imgui.BeginChild("log", 0, 330, false) then
        for i = #log_lines, 1, -1 do
            local line = log_lines[i]
            text_col(COL.muted, string.format("[%s] %s", mmss(line.t), line.msg))
        end
        imgui.EndChild()
    end
end

local function build_ui()
    imgui.SetWindowFontScale(cfg.window_scale)

    if not F then reset_flight("startup") end

    if imgui.BeginTabBar("xa_tabs") then
        if imgui.BeginTabItem("Flight") then
            draw_flight_tab()
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem("Library") then
            draw_library_tab()
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem("Settings") then
            draw_settings_tab()
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem("Log") then
            draw_log_tab()
            imgui.EndTabItem()
        end
        imgui.EndTabBar()
    end
end

-- Same protection as the flight callbacks: a broken widget must not take the
-- Lua engine down.  FlyWithLua unwinds its own ImGui stack after the builder
-- returns, so bailing out mid-draw is safe.
xa_build_ui = guarded("window", build_ui)

-- FlyWithLua keeps its own checkmark for the macro menu entry and never learns
-- that the window was closed with its own [X] button.  The menu then shows the
-- panel as open while it is gone, and the next click only clears the mark.
-- activate_macro()/deactivate_macro() re-run the macro code, so the sync is
-- guarded against re-entry.
-- Shown at Plugins > FlyWithLua > FlyWithLua Macros.  FlyWithLua offers no way
-- to put an entry directly into the Plugins menu: add_macro() and
-- add_ATC_macro() are the only menu calls it exposes.
local MACRO_NAME = "X-Announcer Control Panel"
local macro_syncing = false

local function sync_macro(active)
    if macro_syncing then return end
    macro_syncing = true
    if active then activate_macro(MACRO_NAME) else deactivate_macro(MACRO_NAME) end
    macro_syncing = false
end

-- The manual is explicit: inside on_close it is illegal to touch the window
-- handle and forbidden to create a new window.  So the handle is dropped first,
-- and sync_macro() can then only reach the no-op branch of xa_hide().
function xa_on_close()
    ui.window = nil
    sync_macro(false)
end

function xa_show()
    if ui.window then return end
    -- float_wnd_create(width, height, decoration, use_imgui): decoration 1 is the
    -- native X-Plane frame with drag and resize, the last flag switches the
    -- window to imgui rendering.
    ui.window = float_wnd_create(660, 520, 1, true)
    float_wnd_set_title(ui.window, "X-Announcer " .. VERSION)
    float_wnd_set_imgui_builder(ui.window, "xa_build_ui")
    float_wnd_set_onclose(ui.window, "xa_on_close")
    -- decoration 1 lets the user resize; below this the fixed-height panes and
    -- the event table start overlapping
    float_wnd_set_resizing_limits(ui.window, 520, 400, 1600, 1200)
    sync_macro(true)          -- opened by command or button: tick the menu entry
end

function xa_hide()
    if ui.window then
        local wnd = ui.window
        ui.window = nil       -- destroy fires xa_on_close(); do not recurse
        float_wnd_destroy(wnd)
    end
    sync_macro(false)
end

function xa_toggle()
    if ui.window then xa_hide() else xa_show() end
end

----------------------------------------------------------------------------
-- 11b.  The on-screen widget
----------------------------------------------------------------------------
-- Answers one question over the cockpit view without opening the panel: which
-- phase are we in, and what is the announcer waiting for.
--
-- Drawn with the graphics module rather than as a second imgui window on
-- purpose.  FlyWithLua calls ImGui::Begin() itself before handing control to a
-- window builder, and ImGui samples the window background colour there, so the
-- background alpha of an imgui window cannot be reached from Lua at all.
-- graphics.set_color() goes straight to glColor4f and takes a real alpha.

local graphics_ok = pcall(require, "graphics")

-- RGB floats matching COL above, plus the alpha the plate is drawn with.
local WCOL = {
    accent = { 1.00, 0.76, 0.29 },
    text   = { 0.93, 0.93, 0.93 },
    muted  = { 0.63, 0.58, 0.54 },
    dim    = { 0.43, 0.39, 0.36 },
    ok     = { 0.48, 0.85, 0.56 },
    warn   = { 1.00, 0.42, 0.42 },
}

local WIDGET_LINE = 14        -- Helvetica 12 with a little air
local WIDGET_PAD  = 8

-- Build the widget as a list of coloured lines, then draw it.  Keeping the two
-- apart means the layout can be tested without any of the drawing calls.
local function widget_lines()
    local out = {}
    local function add(colour, text) out[#out + 1] = { c = colour, t = text } end

    -- draw_flight_tab keeps its own copy; this one is not in scope here.
    local index = PHASE_INDEX[F.phase] or 1
    local phase = PHASES[index]
    local head  = string.upper((phase and phase.label) or "-")

    if guard.stopped then
        add("accent", head) add("warn", "stopped after repeated errors")
        return out
    elseif frozen_reason then
        add("accent", head) add("warn", "clock frozen: " .. frozen_reason)
        return out
    elseif not cfg.enabled then
        add("accent", head) add("warn", "muted")
        return out
    end

    local next_label, conditions = phase_conditions()
    local mode = cfg.widget_mode

    if now_playing then
        add("accent", head)
        add("text", string.format("> %s   %s / %s", now_playing.event,
            mmss(real_clock - now_playing.started), mmss(now_playing.duration)))
        if mode == "minimal" then return out end
    elseif mode == "minimal" then
        local waiting
        for _, c in ipairs(conditions) do
            if not c.met then waiting = c break end
        end
        add("accent", string.format("%s  ->  %s", head, next_label))
        add("muted", waiting and ("waiting: " .. waiting.label) or "ready")
        return out
    else
        add("accent", head)
    end

    if mode == "full" then
        add("dim", "")
        for i, p in ipairs(PHASES) do
            if i >= index - 2 and i <= index + 2 then
                if i < index then      add("dim",    "done  " .. p.label)
                elseif i == index then add("accent", "> now " .. p.label)
                else                   add("muted",  "      " .. p.label) end
            end
        end
    end

    add("dim", "")
    add("muted", "next  " .. next_label)
    for _, c in ipairs(conditions) do
        local mark = c.met and "v " or ". "
        local line = mark .. c.label
        if c.value ~= "" then line = line .. "   " .. c.value end
        add(c.met and "ok" or "muted", line)
    end
    return out
end

function xa_draw_widget()
    if not cfg.widget or not graphics_ok or not F then return end

    local lines = widget_lines()
    if #lines == 0 then return end

    local width = 0
    for _, l in ipairs(lines) do
        local w = measure_string(l.t, "Helvetica_12") or (#l.t * 6)
        if w > width then width = w end
    end
    width = width + WIDGET_PAD * 2

    local screen_h = SCREEN_HIGHT or SCREEN_HEIGHT or 1080
    local screen_w = SCREEN_WIDTH or 1920
    local height = #lines * WIDGET_LINE + WIDGET_PAD * 2
    -- Kept on screen whatever the saved offsets say: a resolution change, or a
    -- slider pushed too far, would otherwise draw the widget into the void and
    -- look exactly like the widget being broken.
    local left = clamp(cfg.widget_x, 0, math.max(0, screen_w - width))
    local top  = screen_h - clamp(cfg.widget_y, 0, math.max(0, screen_h - height))

    -- Other scripts draw too and may leave the state however they like.
    XPLMSetGraphicsState(0, 0, 0, 1, 1, 0, 0)

    local alpha = clamp(cfg.widget_opacity, 0, 1)
    if alpha > 0 then
        graphics.set_color(0.05, 0.05, 0.05, alpha)
        graphics.draw_rectangle(left, top - height, left + width, top)
    end

    local y = top - WIDGET_PAD - WIDGET_LINE + 3
    for _, l in ipairs(lines) do
        local c = WCOL[l.c] or WCOL.text
        if l.t ~= "" then
            graphics.set_color(c[1], c[2], c[3], 1.0)
            draw_string_Helvetica_12(left + WIDGET_PAD, y, l.t)
        end
        y = y - WIDGET_LINE
    end
end

function xa_skip()
    stop_announcement()
    queue.gap_until = real_clock
end

function xa_start_boarding()
    reset_flight("command", "BOARDING")
    F.last_welcome = -1e9
end

----------------------------------------------------------------------------
-- 12.  Boot
----------------------------------------------------------------------------

math.randomseed(os.time())

config_load()

if not file_exists(CONFIG_PATH) then config_save() end

-- Places an MSFS Universal Announcer library is commonly kept; only used when
-- the configured folder holds no packs at all.
local LIBRARY_GUESSES = {
    "D:\\UA_Sounds", "C:\\UA_Sounds", "E:\\UA_Sounds",
    with_slash(SYSTEM_DIRECTORY or "") .. "UA_Sounds",
}

seatbelt_dref = first_seatbelt()
logo_dref  = first_dref(LOGO_CANDIDATES)
clock_dref = first_dref(CLOCK_DREFS)

scan_library()

-- Nothing there?  Look for an existing MSFS Universal Announcer library.
if #library.codes == 0 and cfg.auto_find then
    for _, guess in ipairs(LIBRARY_GUESSES) do
        local dirs = nil
        local ok = pcall(function() local _ _, dirs = list_dir(guess) end)
        if ok and dirs and #dirs > 0 then
            cfg.library = guess
            scan_library()
            if #library.codes > 0 then
                log("using existing sound library at %s", guess)
                config_save()
                break
            end
        end
    end
end

ui.library_input = cfg.library
read_sim()
reset_flight("startup")
resolve_airline()
last_livery = XA_LIVERY_PATH

log("ready - airline %s, %d packs, seatbelt dataref %s",
    current_airline.code, #library.codes,
    seatbelt_dref and seatbelt_dref.name or "none")

-- Handles for the FlyWithLua console and the offline test bench, e.g.
--   XA_DEBUG.duration("D:/UA_Sounds/AFL/BoardingWelcome.ogg")
XA_DEBUG = {
    duration = probe_duration,
    airline  = function() return current_airline end,
    macro    = function() return MACRO_NAME end,
    widget   = function() return widget_lines() end,
    waiting  = function() local n, c = phase_conditions() return n, c end,
    simbrief = function() return simbrief end,
    sb_parse = simbrief_parse,
    sb_id    = simbrief_id,
    sb_start = simbrief_start,
    sb_pump    = function() return simbrief_pump() end,
    sb_request = function() return simbrief.request end,
    library  = function() return library end,
    state    = function() return F end,
    queue    = function() return queue, now_playing, music end,
    window   = function() return ui.window end,
    preview  = function(event)
        stop_announcement()
        queue = {}
        enqueue(event, "manual test", true)
        audio_update()
    end,
    stop     = function() stop_announcement() queue = {} end,
    rescan   = function() scan_library() resolve_airline() end,
    config   = cfg,
    save     = config_save,
    reload   = config_load,
}

do_every_frame("xa_frame()")
do_often("xa_tick()")
do_every_draw("xa_draw()")

create_command("FlyWithLua/x_announcer/toggle_window",
    "X-Announcer: show/hide window", "xa_toggle()", "", "")
create_command("FlyWithLua/x_announcer/skip",
    "X-Announcer: skip current announcement", "xa_skip()", "", "")
create_command("FlyWithLua/x_announcer/start_boarding",
    "X-Announcer: start boarding", "xa_start_boarding()", "", "")

add_macro(MACRO_NAME, "xa_show()", "xa_hide()", "deactivate")
