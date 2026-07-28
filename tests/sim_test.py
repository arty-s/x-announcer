"""Offline test-bench for x_announcer.lua.

Runs the script inside LuaJIT 2.1 (the interpreter FlyWithLua NG+ uses) with the
FlyWithLua API stubbed out, then flies complete simulated flights and checks
which announcements come out, in which order.

    python tests/sim_test.py [path-to-sound-library]
"""

import os
import shutil
import sys
import tempfile

from lupa.luajit21 import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SCRIPT = os.path.join(ROOT, "x_announcer.lua")
DEFAULT_LIBRARY = r"D:\UA_Sounds"

failures = []


def check(condition, message):
    print("   %s %s" % ("PASS" if condition else "FAIL", message))
    if not condition:
        failures.append(message)


class Sim:
    """Holds the fake dataref values and records audio calls."""

    def __init__(self):
        self.values = {
            "sim/time/paused": 0,
            "sim/network/misc/network_time_sec": 0.0,
            "sim/flightmodel/failures/onground_any": 1,
            "sim/flightmodel/position/groundspeed": 0.0,
            "sim/flightmodel/position/y_agl": 0.0,
            "sim/flightmodel/misc/h_ind": 500.0,
            "sim/flightmodel/position/vh_ind_fpm": 0.0,
            "sim/flightmodel/forces/g_nrml": 1.0,
            "sim/cockpit2/switches/beacon_on": 0,
            "sim/cockpit2/switches/navigation_lights_on": 0,
            "sim/cockpit2/switches/strobe_lights_on": 0,
            "sim/cockpit2/switches/landing_lights_on": 0,
            "sim/cockpit2/switches/taxi_light_on": 0,
            "sim/flightmodel/controls/parkbrake": 1.0,
            "sim/cockpit2/electrical/battery_on": 0,
            "sim/cockpit2/switches/fasten_seat_belts": 0,
            "sim/aircraft/engine/acf_num_engines": 2,
            "sim/time/local_time_sec": 9 * 3600.0,
            "sim/aircraft/view/acf_livery_path": 0,   # string dataref, value comes via dataref()
            "FlyWithLua_InteriorChannelGroup/Volume": 0.0,
            "FlyWithLua_MasterChannelGroup/Volume": 0.0,
            "FlyWithLua_UIChannelGroup/Volume": 0.0,
            "FlyWithLua_Com1ChannelGroup/Volume": 0.0,
        }
        self.arrays = {"sim/flightmodel/engine/ENGN_running": [0, 0]}
        self.played = []          # (t, bus, filename)
        self.played_wall = []     # wall-clock second of each play
        self.volume_trace = []    # (t, music volume) while a PA is playing
        self.log = []

    # --- dataref plumbing -------------------------------------------------
    def find(self, name):
        return name if (name in self.values or name in self.arrays) else None

    def get_i(self, ref):
        return int(self.values.get(ref, 0))

    def get_f(self, ref):
        return float(self.values.get(ref, 0.0))

    def set_f(self, ref, value):
        self.values[ref] = float(value)

    def get_vi(self, ref, offset, count):
        data = self.arrays.get(ref, [])
        return {i: (data[i] if i < len(data) else 0) for i in range(offset, offset + count)}

    # --- convenience ------------------------------------------------------
    @property
    def t(self):
        return self.values["sim/network/misc/network_time_sec"]

    ALIAS = {
        "on_ground": "sim/flightmodel/failures/onground_any",
        "gs_ms": "sim/flightmodel/position/groundspeed",
        "agl_m": "sim/flightmodel/position/y_agl",
        "alt_ft": "sim/flightmodel/misc/h_ind",
        "vs_fpm": "sim/flightmodel/position/vh_ind_fpm",
        "g": "sim/flightmodel/forces/g_nrml",
        "beacon": "sim/cockpit2/switches/beacon_on",
        "nav": "sim/cockpit2/switches/navigation_lights_on",
        "strobe": "sim/cockpit2/switches/strobe_lights_on",
        "landing": "sim/cockpit2/switches/landing_lights_on",
        "taxi": "sim/cockpit2/switches/taxi_light_on",
        "parkbrake": "sim/flightmodel/controls/parkbrake",
        "battery": "sim/cockpit2/electrical/battery_on",
        "seatbelt": "sim/cockpit2/switches/fasten_seat_belts",
    }

    def set(self, **kwargs):
        for key, value in kwargs.items():
            if key == "engines":
                self.arrays["sim/flightmodel/engine/ENGN_running"] = [1, 1] if value else [0, 0]
            elif key == "local_hour":
                self.values["sim/time/local_time_sec"] = value * 3600.0
            else:
                self.values[self.ALIAS[key]] = value

    def announcements(self):
        return [name for _, bus, name in self.played if bus == "interior" and name != "<stop>"]

    def music_tracks(self):
        return [name for _, bus, name in self.played if bus == "master" and name != "<stop>"]


def build_runtime(sim, library, config_extra="", livery_path=""):
    livery = [livery_path]
    lua = LuaRuntime(unpack_returned_tuples=True)
    g = lua.globals()

    tmp = tempfile.mkdtemp(prefix="xa_test_")
    pkg = os.path.join(tmp, "x_announcer")
    os.makedirs(pkg)
    shutil.copy(os.path.join(ROOT, "x_announcer", "airlines.lua"),
                os.path.join(pkg, "airlines.lua"))
    with open(os.path.join(pkg, "config.ini"), "w", encoding="utf-8") as f:
        f.write("library = %s\n" % library)
        f.write(config_extra)

    g.SUPPORTS_FLOATING_WINDOWS = True
    # The real value, not the intuitive one: FlyWithLua sets DIRECTORY_SEPARATOR
    # from XPLMGetDirectorySeparator(), which with native paths is "/" on Windows
    # too.  The bench used to hand out "\\" here, which no X-Plane ever does, and
    # that is precisely why it missed the SimBrief bug in 1.1.0.
    g.DIRECTORY_SEPARATOR = "/"
    g.SCRIPT_DIRECTORY = tmp + "/"
    g.SYSTEM_DIRECTORY = tmp + "/"
    g.PLUGIN_VERSION = "2.8.10"
    g.PLANE_ICAO = "A320"
    g.PLANE_TAILNUMBER = "VP-BKA"
    g.PLANE_DESCRIP = "Airbus A320"
    g.AIRCRAFT_FILENAME = "A320.acf"

    def directory_to_table(path):
        path = path.rstrip("\\/")
        try:
            names = sorted(os.listdir(path))
        except OSError:
            names = []
        return lua.table_from(names)

    def load_fmod_sound(path):
        load_fmod_sound.counter += 1
        load_fmod_sound.paths[load_fmod_sound.counter] = path
        return load_fmod_sound.counter
    load_fmod_sound.counter = -1
    load_fmod_sound.paths = {}

    def make_player(bus):
        def play(index):
            sim.played.append((round(sim.t, 1), bus,
                               os.path.basename(load_fmod_sound.paths.get(index, "?"))))
            sim.played_wall.append(float(lua.globals().XA_TEST_WALL))
        return play

    def make_stopper(bus):
        def stop():
            sim.played.append((round(sim.t, 1), bus, "<stop>"))
        return stop

    g.directory_to_table = directory_to_table
    g.logMsg = lambda msg: sim.log.append(str(msg))
    g.load_fmod_sound = load_fmod_sound
    for bus in ("interior", "master", "ui", "com1"):
        g["play_sound_on_%s_bus" % bus] = make_player(bus)
        g["stop_sound_on_%s_bus" % bus] = make_stopper(bus)

    g.XPLMFindDataRef = sim.find
    g.XPLMGetDatai = sim.get_i
    g.XPLMGetDataf = sim.get_f
    g.XPLMSetDataf = sim.set_f
    g.XPLMGetDatavi = lambda ref, offset, count: lua.table_from(sim.get_vi(ref, offset, count))

    def dataref_stub(var_name, path, *rest):
        # FlyWithLua publishes string datarefs as a global; mimic that
        if path == "sim/aircraft/view/acf_livery_path":
            lua.globals()[var_name] = livery[0]

    g.dataref = dataref_stub

    for name in ("do_every_frame", "do_often", "do_sometimes", "do_every_draw",
                 "create_command", "float_wnd_set_title",
                 "float_wnd_set_imgui_builder", "float_wnd_set_onclose",
                 "float_wnd_set_resizing_limits", "float_wnd_destroy",
                 "XPLMSetGraphicsState", "draw_string_Helvetica_12"):
        g[name] = lambda *args: None
    g.float_wnd_create = lambda *args: 1

    # The widget draws with the graphics module: a real screen size, a crude
    # text measurer, and a record of what was painted.
    g.SCREEN_WIDTH = 1920
    g.SCREEN_HIGHT = 1080
    g.measure_string = lambda text, *rest: len(text) * 6.0
    lua.execute("""
        GRAPHICS_CALLS = {}
        package = package or {}
        package.loaded = package.loaded or {}
        graphics = {
            set_color = function(r, g, b, a)
                GRAPHICS_CALLS[#GRAPHICS_CALLS + 1] =
                    string.format("color %.2f %.2f %.2f %.2f", r, g, b, a or 1)
            end,
            draw_rectangle = function(x1, y1, x2, y2)
                GRAPHICS_CALLS[#GRAPHICS_CALLS + 1] =
                    string.format("rect %d %d %d %d", x1, y1, x2, y2)
            end,
        }
        package.loaded["graphics"] = graphics
    """)

    # Python callables are userdata in Lua; wrap them so type(f) == "function".
    lua.execute("""
        local names = {
            "directory_to_table", "logMsg", "load_fmod_sound",
            "XPLMFindDataRef", "XPLMGetDatai", "XPLMGetDataf", "XPLMSetDataf",
            "XPLMGetDatavi", "dataref", "do_every_frame", "do_often",
            "do_every_draw", "create_command", "add_macro", "float_wnd_create",
            "XPLMSetGraphicsState", "draw_string_Helvetica_12", "measure_string",
            "play_sound_on_interior_bus", "play_sound_on_master_bus",
            "play_sound_on_ui_bus", "play_sound_on_com1_bus",
            "stop_sound_on_interior_bus", "stop_sound_on_master_bus",
            "stop_sound_on_ui_bus", "stop_sound_on_com1_bus",
        }
        for _, name in ipairs(names) do
            local callable = _G[name]
            _G[name] = function(...) return callable(...) end
        end
    """)

    # minimal imgui stub so the UI builder can be exercised
    lua.execute("""
        local calls = {}
        local returns = {
            Begin = true, BeginChild = true, BeginCombo = false, BeginTabBar = true,
            BeginTabItem = true, BeginTable = true, Button = false, SmallButton = false,
            Selectable = false, TableNextColumn = true, CollapsingHeader = true,
        }
        CLICK_EVERYTHING = false
        local stub = setmetatable({}, { __index = function(_, key)
            return function(...)
                calls[#calls + 1] = key
                if key == "InputText" or key == "SliderFloat"
                   or key == "SliderInt" or key == "Checkbox" then
                    return CLICK_EVERYTHING, (select(2, ...))
                end
                if CLICK_EVERYTHING and (key == "Button" or key == "SmallButton"
                                         or key == "Selectable" or key == "BeginCombo") then
                    return true
                end
                local r = returns[key]
                if r ~= nil then return r end
                return nil
            end
        end })
        stub.constant = setmetatable({}, { __index = function()
            return setmetatable({}, { __index = function() return 0 end })
        end })
        imgui = stub
        IMGUI_CALLS = calls
    """)

    # The script times playback on the wall clock (FMOD always plays at 1x), and
    # the bench compresses whole flights into a fraction of a real second.  So the
    # wall clock is made controllable too - and can be driven at a rate different
    # from sim time, which is how the sim's time acceleration is emulated.
    lua.execute("XA_TEST_WALL = 0 os.time = function() return XA_TEST_WALL end")

    # Nothing in the bench may actually reach the network or spawn a process.
    lua.execute("OS_EXEC_CALLS = {} "
                "os.execute = function(cmd) "
                "  OS_EXEC_CALLS[#OS_EXEC_CALLS + 1] = tostring(cmd) return 0 end")

    # Faithful macro stubs: FlyWithLua runs the macro's own code when the entry is
    # registered and again on every activate_macro()/deactivate_macro() call, so a
    # careless sync would recurse.  MACRO_MENU mirrors the checkmark in the menu.
    lua.execute("""
        MACROS = {}
        MACRO_MENU = {}
        MACRO_CALLS = {}
        function add_macro(name, on, off, state)
            MACROS[name] = { on = on, off = off }
            if state == "activate" then
                MACRO_MENU[name] = true
                loadstring(on)()
            else
                MACRO_MENU[name] = false
                loadstring(off)()
            end
        end
        function activate_macro(name)
            MACRO_CALLS[#MACRO_CALLS + 1] = "on"
            MACRO_MENU[name] = true
            if MACROS[name] then loadstring(MACROS[name].on)() end
        end
        function deactivate_macro(name)
            MACRO_CALLS[#MACRO_CALLS + 1] = "off"
            MACRO_MENU[name] = false
            if MACROS[name] then loadstring(MACROS[name].off)() end
        end
    """)
    return lua, tmp


def run_script(lua):
    with open(SCRIPT, "r", encoding="utf-8") as f:
        source = f.read()
    loader = lua.eval("function(src) return loadstring(src, '@x_announcer.lua') end")
    chunk = loader(source)
    if chunk is None:
        raise SystemExit("SYNTAX ERROR in x_announcer.lua")
    chunk()


def advance(lua, sim, seconds, fps=30, sim_rate=1.0):
    """Run `seconds` of wall time: frame callback at fps, tick at 1 Hz.

    sim_rate emulates X-Plane's time acceleration: sim time advances that many
    times faster than the wall clock, exactly as it does at 2x or 4x.
    """
    g = lua.globals()
    step = 1.0 / fps
    for i in range(int(seconds * fps)):
        sim.values["sim/network/misc/network_time_sec"] += step * sim_rate
        g.XA_TEST_WALL = int(g.XA_TEST_WALL + 1) if (i + 1) % fps == 0 else g.XA_TEST_WALL
        g.xa_frame()
        if i % fps == 0:
            g.xa_tick()


def fly(lua, sim, boarding_seconds=20):
    """A complete short-haul flight."""
    sim.set(battery=1, nav=1)
    advance(lua, sim, boarding_seconds)
    sim.set(beacon=1)
    advance(lua, sim, 6)
    sim.set(engines=True)
    advance(lua, sim, 200)                       # push, start, briefing
    sim.set(gs_ms=8.0, taxi=1)
    advance(lua, sim, 120)
    sim.set(strobe=1, landing=1)                 # line-up
    advance(lua, sim, 40)
    sim.set(on_ground=0, agl_m=200, alt_ft=2000, vs_fpm=2200, gs_ms=90)
    advance(lua, sim, 20)
    sim.set(agl_m=1300, alt_ft=5000)
    advance(lua, sim, 60)
    sim.set(agl_m=9000, alt_ft=30000, vs_fpm=100)
    advance(lua, sim, 60)
    sim.set(vs_fpm=0, alt_ft=35000, agl_m=10600) # top of climb
    advance(lua, sim, 60)
    sim.set(seatbelt=1)                          # turbulence
    advance(lua, sim, 30)
    sim.set(seatbelt=0)
    advance(lua, sim, 20)
    sim.set(vs_fpm=-1800, alt_ft=24000, agl_m=7000)
    advance(lua, sim, 40)
    sim.set(alt_ft=9000, agl_m=2600)
    advance(lua, sim, 60)
    sim.set(alt_ft=4000, agl_m=1200, vs_fpm=-800, landing=1)
    advance(lua, sim, 40)
    sim.set(alt_ft=2500, agl_m=800)
    advance(lua, sim, 40)
    sim.set(vs_fpm=-150)
    advance(lua, sim, 2)
    sim.set(on_ground=1, agl_m=0, alt_ft=500, vs_fpm=0, gs_ms=60)
    advance(lua, sim, 30)
    sim.set(gs_ms=8)
    advance(lua, sim, 60)
    sim.set(gs_ms=0, engines=False, parkbrake=1.0)
    advance(lua, sim, 60)
    sim.set(beacon=0)
    advance(lua, sim, 90)


def order_ok(sequence, expected):
    """Every event in `expected` appears, in this relative order."""
    position = 0
    for want in expected:
        found = False
        while position < len(sequence):
            if sequence[position].startswith(want):
                found = True
                position += 1
                break
            position += 1
        if not found:
            return False, want
    return True, None


def scenario_day_manual(library):
    print("\n=== scenario 1: daytime flight, airline pinned to AFL ===")
    sim = Sim()
    lua, tmp = build_runtime(
        sim, library, "airline_mode = manual\nairline_manual = AFL\nauto_find = false\n")
    run_script(lua)
    fly(lua, sim)

    events = sim.announcements()
    for t, bus, name in sim.played:
        if name != "<stop>":
            print("      %7.1fs %-8s %s" % (t, bus, name))

    ok, missing = order_ok(events, [
        "BoardingWelcome", "BoardingComplete", "ArmDoors", "PreSafetyBriefing",
        "SafetyBriefing", "CrewSeatsTakeoff", "CallCabinSecureTakeoff",
        "AfterTakeoff", "DescentSeatbelts", "CrewSeatsLanding",
        "CallCabinSecureLanding", "AfterLanding", "DisarmDoors", "DisembarkStarted",
    ])
    check(ok, "full announcement sequence in order (missing: %s)" % missing)
    check(any("[Morning]" in e for e in events), "time-of-day tag [Morning] selected")
    check(not any(e.startswith("CabinDim") for e in events), "no cabin dimming in daylight")
    check(any("A320" in e for e in events), "aircraft-tagged file [A320] selected")
    check(all("[A319]" not in e and "[A321]" not in e for e in events),
          "files tagged for other aircraft are rejected")
    check("FastenSeatbelt.ogg" in events or "Turbulence.ogg" in events,
          "seatbelt sign transition announced")
    check(sim.values["FlyWithLua_InteriorChannelGroup/Volume"] > 0,
          "announcement bus volume is set (FlyWithLua starts at 0)")
    shutil.rmtree(tmp, ignore_errors=True)


def scenario_night_auto(library):
    print("\n=== scenario 2: night flight, airline detected from livery ===")
    sim = Sim()
    lua, tmp = build_runtime(
        sim, library,
        "airline_mode = auto\nboarding_repeat = 120\nauto_find = false\n",
        livery_path="Aircraft/Airbus A320/liveries/Aeroflot Skyteam/")
    run_script(lua)

    sim.set(local_hour=23)
    fly(lua, sim, boarding_seconds=420)

    events = sim.announcements()
    music = sim.music_tracks()
    for t, bus, name in sim.played:
        if name != "<stop>":
            print("      %7.1fs %-8s %s" % (t, bus, name))

    resolved = lua.eval("function() local a = XA_DEBUG.airline() return a.code .. ' | ' .. a.source end")()
    print("      detection:", resolved)
    check(resolved.startswith("AFL"), "livery 'Aeroflot Skyteam' resolved to AFL")
    check(any("[Night]" in e for e in events), "time-of-day tag [Night] selected")
    check(any(e.startswith("CabinDim") for e in events), "cabin dimming announced at night")
    check(len(music) >= 1, "boarding music played on its own bus")
    check(sim.values["FlyWithLua_MasterChannelGroup/Volume"] >= 0, "music bus volume written")
    shutil.rmtree(tmp, ignore_errors=True)


def scenario_no_library():
    print("\n=== scenario 3: empty/missing sound library ===")
    sim = Sim()
    empty = tempfile.mkdtemp(prefix="xa_empty_")
    lua, tmp = build_runtime(
        sim, empty, "airline_mode = manual\nairline_manual = AFL\nauto_find = false\n")
    run_script(lua)
    fly(lua, sim)
    check(len(sim.announcements()) == 0, "nothing plays, no crash")
    lua.globals().xa_build_ui()
    check(len(lua.globals().IMGUI_CALLS) > 50, "UI still renders (%d imgui calls)"
          % len(lua.globals().IMGUI_CALLS))
    shutil.rmtree(tmp, ignore_errors=True)
    shutil.rmtree(empty, ignore_errors=True)


def scenario_durations(library):
    print("\n=== scenario 4: audio duration probing ===")
    sim = Sim()
    lua, tmp = build_runtime(sim, library, "auto_find = false\n")
    run_script(lua)

    probe = lua.eval("function(p) return XA_DEBUG.duration(p) end")
    samples = []
    for root, _dirs, files in os.walk(library):
        for name in files:
            if name.lower().endswith((".ogg", ".mp3", ".wav")):
                samples.append(os.path.join(root, name))
        if len(samples) > 12:
            break

    import subprocess
    checked = 0
    for path in samples[:8]:
        mine = probe(path)
        try:
            out = subprocess.run(
                ["ffprobe", "-v", "quiet", "-show_entries", "format=duration",
                 "-of", "csv=p=0", path],
                capture_output=True, text=True, timeout=20)
            real = float(out.stdout.strip())
        except Exception:
            continue
        checked += 1
        delta = abs(mine - real)
        print("      %-42s mine %6.2fs  ffprobe %6.2fs  delta %.2fs"
              % (os.path.basename(path)[:42], mine, real, delta))
        check(delta < 0.5, "duration within 0.5s for %s" % os.path.basename(path))
    if checked == 0:
        print("      (ffprobe not available - skipped)")
    shutil.rmtree(tmp, ignore_errors=True)


def scenario_mid_flight(library):
    print("\n=== scenario 5: script (re)loaded while already airborne ===")
    sim = Sim()
    sim.set(on_ground=0, agl_m=10000, alt_ft=34000, vs_fpm=0, gs_ms=230,
            beacon=1, nav=1, engines=True, parkbrake=0.0)
    lua, tmp = build_runtime(
        sim, library, "airline_mode = manual\nairline_manual = AFL\nauto_find = false\n")
    run_script(lua)
    advance(lua, sim, 30)

    phase = lua.eval("function() return XA_DEBUG.state().phase end")()
    print("      phase after load:", phase)
    check(phase == "CRUISE", "starts in cruise instead of replaying boarding")
    check(not any(e.startswith("Boarding") for e in sim.announcements()),
          "no boarding announcements in mid-air")

    # descend and land: the arrival half must still work
    sim.set(vs_fpm=-1800, alt_ft=9000, agl_m=2600)
    advance(lua, sim, 60)
    sim.set(alt_ft=3000, agl_m=800, vs_fpm=-700, landing=1)
    advance(lua, sim, 60)
    sim.set(on_ground=1, agl_m=0, vs_fpm=0, gs_ms=30, alt_ft=500)
    advance(lua, sim, 60)
    events = sim.announcements()
    check(any(e.startswith("DescentSeatbelts") for e in events), "descent PA still plays")
    check(any(e.startswith("AfterLanding") for e in events), "after-landing PA still plays")

    # user commands must not blow up
    lua.globals().xa_skip()
    lua.globals().xa_start_boarding()
    lua.globals().xa_toggle()
    lua.globals().xa_toggle()
    check(True, "skip / start-boarding / window commands run without error")
    shutil.rmtree(tmp, ignore_errors=True)


def scenario_ui_clicks(library):
    print("\n=== scenario 6: every control in the window pressed ===")
    sim = Sim()
    lua, tmp = build_runtime(
        sim, library, "airline_mode = manual\nairline_manual = AFL\nauto_find = false\n")
    run_script(lua)
    advance(lua, sim, 5)

    lua.globals().CLICK_EVERYTHING = True
    for _ in range(3):          # tabs, buttons, combos, sliders, checkboxes
        lua.globals().xa_build_ui()
        advance(lua, sim, 2)
    lua.globals().CLICK_EVERYTHING = False
    lua.globals().xa_build_ui()

    check(True, "no Lua error with every widget activated")
    print("      config after clicking:",
          lua.eval("function() local c = XA_DEBUG.config "
                   "return string.format('bus=%s music=%s vol=%.2f', "
                   "c.announce_bus, c.music_bus, c.volume) end")())
    shutil.rmtree(tmp, ignore_errors=True)


def scenario_config_roundtrip(library):
    print("\n=== scenario 7: config.ini with Russian comments survives a round trip ===")
    sim = Sim()
    lua, tmp = build_runtime(
        sim, library, "airline_mode = manual\nairline_manual = AFL\nauto_find = false\n")
    run_script(lua)

    lua.execute("XA_DEBUG.config.volume = 0.42 "
                "XA_DEBUG.config.boarding_repeat = 123 "
                "XA_DEBUG.config.cabin_noise = true "
                "XA_DEBUG.save()")
    path = os.path.join(tmp, "x_announcer", "config.ini")
    text = open(path, encoding="utf-8").read()
    print("      " + "\n      ".join(text.splitlines()[:6]))

    check("Настройки X-Announcer" in text, "file header written in Russian")
    check(text.count("\n# ") >= 15, "every key documented in Russian (%d comments)"
          % text.count("\n# "))

    lua.execute("XA_DEBUG.config.volume = 0 XA_DEBUG.config.boarding_repeat = 0 "
                "XA_DEBUG.config.cabin_noise = false XA_DEBUG.reload()")
    values = lua.eval("function() local c = XA_DEBUG.config "
                      "return c.volume, c.boarding_repeat, tostring(c.cabin_noise) end")()
    print("      re-read:", values)
    check(list(values) == [0.42, 123, "true"],
          "float / int / bool re-read correctly past the comments")
    shutil.rmtree(tmp, ignore_errors=True)


def make_fixture_library(source_library):
    """A pack that actually contains the rarely-shipped events, so the checks
    below test behaviour instead of an empty folder."""
    donor = None
    for root, _dirs, files in os.walk(source_library):
        for name in files:
            path = os.path.join(root, name)
            if name.lower().endswith(".ogg") and os.path.getsize(path) < 400_000:
                donor = path
                break
        if donor:
            break
    if not donor:
        return None

    root = tempfile.mkdtemp(prefix="xa_fixture_")
    pack = os.path.join(root, "TST")
    os.makedirs(pack)
    for event in ("BoardingWelcome", "BoardingMusic", "BoardingComplete", "ArmDoors",
                  "SafetyBriefing", "CrewSeatsTakeoff", "AfterTakeoff", "DescentSeatbelts",
                  "CrewSeatsLanding", "AfterLanding", "DisarmDoors", "DisembarkStarted",
                  "CabinNoise", "LandingGreat", "LandingTerrible", "AfterLandingMusic"):
        shutil.copy(donor, os.path.join(pack, event + ".ogg"))
    return root


def scenario_regressions(library):
    print("\n=== scenario 8: fixed defects stay fixed ===")
    fixture = make_fixture_library(library)

    # --- cabin ambience is independent of the boarding-music setting ---------
    sim = Sim()
    lua, tmp = build_runtime(
        sim, fixture,
        "airline_mode = manual\nairline_manual = TST\nauto_find = false\n"
        "boarding_music = false\ncabin_noise = true\n")
    run_script(lua)
    sim.set(battery=1, nav=1, beacon=1, engines=True, parkbrake=0.0)
    advance(lua, sim, 10)
    sim.set(on_ground=0, agl_m=3000, alt_ft=12000, vs_fpm=1500, gs_ms=150)
    advance(lua, sim, 30)
    ambience = [n for _, bus, n in sim.played if bus == "master" and n != "<stop>"]
    boarding = [n for n in ambience if "BoardingMusic" in n]
    check(any("CabinNoise" in n for n in ambience),
          "ambience plays with the boarding-music switch off")
    check(not boarding, "boarding music stays off when its switch is off")

    # --- ambience stops on the ground ---------------------------------------
    sim.set(on_ground=1, agl_m=0, alt_ft=500, vs_fpm=0, gs_ms=20)
    advance(lua, sim, 20)
    still_playing = lua.eval("function() local _, _, m = XA_DEBUG.queue() "
                             "return m ~= nil and m.event or 'none' end")()
    check(still_playing != "CabinNoise",
          "ambience stops after touchdown (background now: %s)" % still_playing)
    shutil.rmtree(tmp, ignore_errors=True)

    # --- skipping an announcement must not block the chain behind it --------
    sim = Sim()
    lua, tmp = build_runtime(
        sim, library, "airline_mode = manual\nairline_manual = AFL\nauto_find = false\n")
    run_script(lua)
    sim.set(battery=1, nav=1)
    advance(lua, sim, 10)
    sim.set(beacon=1, engines=True, parkbrake=0.0)
    advance(lua, sim, 20)
    for _ in range(6):                    # skip whatever is playing, repeatedly
        lua.globals().xa_skip()
        advance(lua, sim, 5)
    advance(lua, sim, 120)
    events = sim.announcements()
    check(any(e.startswith("SafetyBriefing") for e in events),
          "briefing chain survives Skip current (%s)" % ", ".join(events[-3:]))
    shutil.rmtree(tmp, ignore_errors=True)

    # --- quick roll-out: landing reaction still plays ------------------------
    sim = Sim()
    lua, tmp = build_runtime(
        sim, fixture, "airline_mode = manual\nairline_manual = TST\nauto_find = false\n")
    run_script(lua)
    sim.set(on_ground=0, agl_m=900, alt_ft=3000, vs_fpm=-700, gs_ms=80,
            beacon=1, engines=True, landing=1, parkbrake=0.0)
    advance(lua, sim, 40)
    sim.set(vs_fpm=-120)
    advance(lua, sim, 2)
    sim.set(on_ground=1, agl_m=0, alt_ft=500, vs_fpm=0, gs_ms=25)  # straight below 60 kt
    advance(lua, sim, 30)
    events = sim.announcements()
    reaction = [e for e in events if e.startswith("Landing")]
    check(any(e.startswith("AfterLanding") for e in events), "after-landing PA on a short roll-out")
    check(reaction == ["LandingGreat.ogg"],
          "smooth touchdown gets the cabin reaction even below 60 kt in 8 s (%s)"
          % (reaction or "nothing"))

    # --- engines off without the parking brake still disarms ----------------
    sim.set(gs_ms=0, engines=False, parkbrake=0.0)
    advance(lua, sim, 30)
    sim.set(beacon=0)
    advance(lua, sim, 40)
    events = sim.announcements()
    check(any(e.startswith("DisarmDoors") or e.startswith("Disembark") for e in events),
          "arrival sequence completes without the parking brake")
    shutil.rmtree(tmp, ignore_errors=True)

    # --- Library tab: preview plays, stops, and leaves the flight alone ------
    sim = Sim()
    lua, tmp = build_runtime(
        sim, library, "airline_mode = manual\nairline_manual = AFL\nauto_find = false\n")
    run_script(lua)
    lua.execute("XA_DEBUG.preview('SafetyBriefing')")
    advance(lua, sim, 3)
    playing = lua.eval("function() local _, p = XA_DEBUG.queue() "
                       "return p ~= nil and p.event or 'none' end")()
    check(playing == "SafetyBriefing", "preview starts (playing: %s)" % playing)

    ended = lua.eval("function() return XA_DEBUG.state().ended['SafetyBriefing'] ~= nil end")()
    check(not ended, "preview does not mark the event as heard by the flight")

    lua.execute("XA_DEBUG.stop()")
    stopped = lua.eval("function() local _, p = XA_DEBUG.queue() return p == nil end")()
    stop_calls = [n for _, _, n in sim.played if n == "<stop>"]
    check(stopped and stop_calls, "stop button silences it immediately (%d bus stops)"
          % len(stop_calls))

    ended = lua.eval("function() return XA_DEBUG.state().ended['SafetyBriefing'] ~= nil end")()
    check(not ended, "stopping a preview still leaves the flight state clean")
    shutil.rmtree(tmp, ignore_errors=True)

    # --- a bad library path must not kill the Lua engine ---------------------
    for label, bad_path in (("missing folder", r"D:\definitely\not\here"),
                            ("a file, not a folder", SCRIPT)):
        sim = Sim()
        lua, tmp = build_runtime(
            sim, bad_path, "airline_mode = manual\nairline_manual = AFL\nauto_find = false\n")
        run_script(lua)
        advance(lua, sim, 5)
        listed = lua.eval("function() return #XA_DEBUG.library().codes end")()
        complained = any("not found" in line for line in sim.log)
        check(listed == 0 and complained,
              "%s: scan refused, engine alive, complaint logged" % label)
        lua.globals().xa_build_ui()
        shutil.rmtree(tmp, ignore_errors=True)

    # --- menu checkmark follows the window ----------------------------------
    sim = Sim()
    lua, tmp = build_runtime(
        sim, library, "airline_mode = manual\nairline_manual = AFL\nauto_find = false\n")
    run_script(lua)
    lua.execute("MACRO_CALLS = {}")
    lua.globals().xa_show()
    lua.globals().xa_on_close()          # user clicks [X] on the window
    calls = list(lua.eval("function() return unpack(MACRO_CALLS) end")())
    has_window = lua.eval("function() return XA_DEBUG.window() ~= nil end")()
    print("      macro calls:", calls)
    # Ask the plugin for its own menu caption: hardcoding it here meant a rename
    # showed up as a mysterious failure in the checkmark logic.
    menu = lua.eval("function() return MACRO_MENU[XA_DEBUG.macro()] end")()
    check(calls == ["on", "off"] and menu is False,
          "opening ticks the menu entry, closing unticks it (menu now: %s)" % menu)
    check(not has_window, "window handle cleared after close")
    lua.globals().xa_show()
    check(lua.eval("function() return XA_DEBUG.window() ~= nil end")(),
          "next click opens the window instead of only clearing the mark")
    shutil.rmtree(tmp, ignore_errors=True)
    if fixture:
        shutil.rmtree(fixture, ignore_errors=True)


def scenario_survival(library):
    print("\n=== scenario 9: what could silently stop the announcer ===")
    base = "airline_mode = manual\nairline_manual = AFL\nauto_find = false\n"

    def boot(extra="", lib=library):
        sim = Sim()
        lua, tmp = build_runtime(sim, lib, base + extra)
        run_script(lua)
        return sim, lua, tmp

    # --- time acceleration: FMOD still plays at 1x --------------------------
    sim, lua, tmp = boot()
    lua.execute("XA_DEBUG.preview('BoardingWelcome')")
    advance(lua, sim, 3, sim_rate=4.0)
    duration = lua.eval("function() local _, p = XA_DEBUG.queue() return p and p.duration or 0 end")()
    advance(lua, sim, max(int(duration) - 6, 1), sim_rate=4.0)
    still_playing = lua.eval("function() local _, p = XA_DEBUG.queue() return p ~= nil end")()
    check(still_playing,
          "at 4x sim rate a %.0fs file is still playing after %.0fs of wall time"
          % (duration, duration - 3))
    advance(lua, sim, 8, sim_rate=4.0)
    check(not lua.eval("function() local _, p = XA_DEBUG.queue() return p ~= nil end")(),
          "and it does finish once the wall clock catches up")
    shutil.rmtree(tmp, ignore_errors=True)

    # --- pause freezes playback, it does not run through it -----------------
    sim, lua, tmp = boot()
    lua.execute("XA_DEBUG.preview('BoardingWelcome')")
    advance(lua, sim, 3)
    duration_left = lua.eval("function() local _, p = XA_DEBUG.queue() "
                             "return p and p.duration or 10 end")()
    sim.values["sim/time/paused"] = 1
    advance(lua, sim, 120)
    paused_still_playing = lua.eval("function() local _, p = XA_DEBUG.queue() return p ~= nil end")()
    check(paused_still_playing, "a 2 minute pause does not consume the announcement")
    sim.values["sim/time/paused"] = 0
    advance(lua, sim, int(duration_left) + 10)
    check(not lua.eval("function() local _, p = XA_DEBUG.queue() return p ~= nil end")(),
          "playback resumes and completes after the pause")
    shutil.rmtree(tmp, ignore_errors=True)

    # --- replay must not fly a second, phantom flight -----------------------
    sim, lua, tmp = boot()
    sim.values["sim/time/is_in_replay"] = 1
    fly(lua, sim)
    check(not sim.announcements(), "replay produces no announcements")
    phase = lua.eval("function() return XA_DEBUG.state().phase end")()
    check(phase == "PREFLIGHT", "replay leaves the phase untouched (%s)" % phase)
    shutil.rmtree(tmp, ignore_errors=True)

    # --- teleported to a gate while the phase says airborne -----------------
    sim, lua, tmp = boot()
    sim.set(on_ground=0, agl_m=10000, alt_ft=34000, gs_ms=230, engines=True,
            beacon=1, parkbrake=0.0)
    advance(lua, sim, 30)
    check(lua.eval("function() return XA_DEBUG.state().phase end")() == "CRUISE",
          "airborne start puts us in cruise")
    sim.set(on_ground=1, agl_m=0, alt_ft=500, gs_ms=0, engines=False,
            parkbrake=1.0, beacon=0)          # teleport to a stand
    advance(lua, sim, 40)
    phase = lua.eval("function() return XA_DEBUG.state().phase end")()
    check(phase in ("PREFLIGHT", "BOARDING"),
          "parked aircraft re-syncs out of cruise (now %s)" % phase)
    sim.set(battery=1, nav=1)
    advance(lua, sim, 20)
    check(any(e.startswith("Boarding") for e in sim.announcements()),
          "and the next flight starts announcing again")
    shutil.rmtree(tmp, ignore_errors=True)

    # --- an error inside the callbacks must not kill the Lua engine ---------
    sim, lua, tmp = boot()
    lua.execute("XA_DEBUG.config.boarding_repeat = {}")   # breaks the comparison
    sim.set(battery=1, nav=1)
    advance(lua, sim, 30)
    failures_logged = [line for line in sim.log if "failed" in line]
    check(failures_logged, "callback error is caught and logged, engine alive")
    stopped = [line for line in sim.log if "stopping the announcer" in line]
    check(stopped, "after repeated failures the plugin switches itself off")
    lua.globals().xa_build_ui()          # must not raise into the host either
    check(True, "window still renders with the announcer stopped")
    shutil.rmtree(tmp, ignore_errors=True)

    # --- files FlyWithLua cannot load are skipped, not played into the void --
    deep = tempfile.mkdtemp(prefix="xa_deep_")
    nested = os.path.join(deep, "A" * 60, "B" * 60, "C" * 60, "TST")
    os.makedirs(nested)
    donor = None
    for root, _dirs, files in os.walk(library):
        for name in files:
            if name.lower().endswith(".ogg"):
                donor = os.path.join(root, name)
                break
        if donor:
            break
    shutil.copy(donor, os.path.join(nested, "BoardingWelcome.ogg"))
    sim, lua, tmp = boot("", lib=os.path.dirname(nested))
    lua.execute("XA_DEBUG.config.airline_manual = 'TST' XA_DEBUG.rescan() "
                "XA_DEBUG.preview('BoardingWelcome')")
    advance(lua, sim, 3)
    long_path = [line for line in sim.log if "path too long" in line]
    check(long_path, "over-long path refused with an explanation (%d chars)"
          % (len(nested) + len("\\BoardingWelcome.ogg")))
    shutil.rmtree(tmp, ignore_errors=True)
    shutil.rmtree(deep, ignore_errors=True)

    # --- livery change invalidates the FMOD handles -------------------------
    sim, lua, tmp = boot()
    lua.execute("XA_DEBUG.preview('BoardingWelcome')")
    advance(lua, sim, 3)
    before = len(sim.played)
    lua.execute("XA_LIVERY_PATH = 'Aircraft/A320/liveries/Some Other Airline/'")
    advance(lua, sim, 3)
    released = [line for line in sim.log if "sound handles released" in line]
    check(released, "sound handles dropped when the aircraft/livery changes")
    lua.execute("XA_DEBUG.preview('BoardingWelcome')")
    advance(lua, sim, 3)
    check(len(sim.played) > before, "playback works again after re-registering")
    shutil.rmtree(tmp, ignore_errors=True)


# Real livery folder names, taken off disk from ToLiss, Zibo, Laminar, Rotate
# and FlightFactor aircraft.  The expected code is what a human reads off the
# folder name; DEFAULT means "nothing in there names an airline".
LIVERY_CASES = [
    ("[CFMLEAP] S7 AIRLINES RA-73466", "SBI"),
    ("AFL RA-73735", "AFL"),
    ("4K Aeroflot RA-73735", "AFL"),
    ("SHAR ROSSIYA RA-73194", "SDM"),
    ("Turkish Airlines 8K", "THY"),
    ("Thai Airways HS-TXS", "THA"),
    ("A320 NEO Air Serbia", "ASL"),
    ("[LEAP] A20N Ural Airlines RA-73820", "SVR"),
    ("AirAsiaOld 9M-AHR", "AXM"),
    ("Lufthansa Old", "DLH"),
    ("[CFM] Aeroflot HOF DOBROLET", "AFL"),
    ("(IAE) Yamal", "LLM"),
    ("Ryanair", "RYR"),
    ("Air China", "CCA"),
    ("China Eastern", "CES"),
    ("80NG - Nordwind RA-73314", "NWS"),
    ("764 Turkish Airlines", "THY"),
    ("767 British Airways", "BAW"),
    ("Red Wings Airlines RA-73329", "RWZ"),
    ("Lufthansa_Cargo D-ALCN (RETRO)", "GEC"),
    ("Southwest", "SWA"),
    ("Aerolineas Argentinas", "ARG"),
    ("Scandinavian Airlines", "SAS"),
    ("CathayPacific", "CPA"),
    ("VirginAtlantic", "VIR"),
    ("Laminar House", "DEFAULT"),
    ("full_white", "DEFAULT"),
]


def resolve_livery(library, folder):
    """Boot the plugin with one livery path and report what it decided."""
    sim = Sim()
    lua, tmp = build_runtime(
        sim, library,
        "airline_mode = auto\nauto_find = false\n",
        livery_path="Aircraft/Test/liveries/%s/" % folder)
    run_script(lua)
    got = lua.eval(
        "function() local a = XA_DEBUG.airline() "
        "return a.code .. '\\t' .. a.pack .. '\\t' .. tostring(a.source) end")()
    shutil.rmtree(tmp, ignore_errors=True)
    code, pack, source = got.split("\t", 2)
    return code, pack, source


def scenario_livery_detection(library):
    print("\n=== scenario 10: airline detection from real livery folders ===")
    wrong = []
    for folder, want in LIVERY_CASES:
        code, _, source = resolve_livery(library, folder)
        if code != want:
            wrong.append("%s -> %s (wanted %s) via %s" % (folder, code, want, source))
    for item in wrong:
        print("      ", item)
    check(not wrong, "all %d livery folders resolve correctly" % len(LIVERY_CASES))

    # Same build, same answer: name_index is a hash table, and the ordering of
    # equal-length names used to leak into the verdict.
    twice = [resolve_livery(library, f)[0] for f, _ in LIVERY_CASES[:6]]
    again = [resolve_livery(library, f)[0] for f, _ in LIVERY_CASES[:6]]
    check(twice == again, "detection is deterministic across runs")

    # The defect Artyom hit: S7 is recognised, we own no S7 pack, and that used
    # to be reported as "not detected" instead of "detected, no pack".
    code, pack, _ = resolve_livery(library, "[CFMLEAP] S7 AIRLINES RA-73466")
    check(code == "SBI", "S7 livery is recognised as SBI")
    check(pack == "DEFAULT", "and falls back to the Default pack for audio")

    # A three-letter word must never outrank the airline name next to it.
    for folder, want in (("Air China", "CCA"), ("Red Wings Airlines RA-73329", "RWZ"),
                         ("Thai Airways HS-TXS", "THA")):
        code, _, _ = resolve_livery(library, folder)
        check(code == want, "'%s' is not hijacked by a stray code (%s)" % (folder, code))


# Shaped like a real SimBrief answer: field names verified against the parsers
# in flybywiresim/aircraft and lyestarzalt/x-dispatch.  Note that origin and
# destination both carry "icao_code" and that "name" appears in three places -
# that is exactly what a naive whole-document search gets wrong.
SIMBRIEF_OK = """{
  "fetch":{"userid":"123456","status":"Success","time":"0.21"},
  "params":{"request_id":"9","user_id":"123456","time_generated":"%d",
            "airac":"2408","units":"KGS"},
  "general":{"icao_airline":"SBI","flight_number":"1234","costindex":"20",
             "initial_altitude":"36000","route":"DIBEL A5 NEKET"},
  "origin":{"icao_code":"UUEE","iata_code":"SVO","name":"Sheremetyevo","plan_rwy":"24C"},
  "destination":{"icao_code":"UNNT","iata_code":"OVB","name":"Tolmachevo","plan_rwy":"07"},
  "alternate":{"icao_code":"UNBG","name":"Barnaul"},
  "aircraft":{"icaocode":"A320","reg":"VP-BQK","name":"Airbus A320"},
  "atc":{"callsign":"SBI1234","initial_spd":"250"}
}"""

SIMBRIEF_ERR = ('{"fetch":{"userid":"","static_id":"",'
                '"status":"Error: Unknown UserID","time":"0.0003"}}')


def scenario_simbrief(library):
    print("\n=== scenario 11: reading a SimBrief flight plan ===")
    sim = Sim()
    lua, tmp = build_runtime(
        sim, library, "airline_mode = auto\nauto_find = false\n")
    run_script(lua)

    parse = lua.globals().XA_DEBUG.sb_parse
    generated = 1753000000
    plan = parse(SIMBRIEF_OK % generated)
    check(plan is not None, "a well-formed plan is accepted")
    if plan:
        print("      %s  %s -> %s  %s %s" % (plan["callsign"], plan["origin"],
                                             plan["dest"], plan["aircraft"], plan["reg"]))
        check(plan["airline"] == "SBI", "airline read from general.icao_airline")
        check(plan["flight"] == "1234", "flight number read")
        check(plan["callsign"] == "SBI1234", "callsign read from the atc section")
        check(plan["origin"] == "UUEE", "origin icao_code read from the origin section")
        check(plan["dest"] == "UNNT",
              "destination icao_code is not confused with the origin's")
        check(plan["aircraft"] == "A320" and plan["reg"] == "VP-BQK",
              "aircraft type and registration read")
        check(int(plan["generated"]) == generated, "generation timestamp read")

    bad, err = parse(SIMBRIEF_ERR)
    print("      error case:", err)
    check(bad is None and err and "Unknown UserID" in err,
          "SimBrief's own error text is passed through, not swallowed")

    empty, err2 = parse('{"fetch":{"status":"Success"},"general":{"flight_number":"7"}}')
    check(empty is None and err2 is not None,
          "a plan with no airline code is refused with a reason")

    truncated, err3 = parse('{"general":{"icao_airline":"AFL"')
    check(truncated is None or truncated["airline"] == "AFL",
          "a half-written answer never raises")

    # The pilot id is pasted by the user and lands inside a shell command.
    lua.execute("XA_DEBUG.config.simbrief_id = 'abc\\\" & del /q x' "
                "XA_TEST_ID = XA_DEBUG.sb_id()")
    cleaned = lua.globals().XA_TEST_ID
    print("      sanitised id:", repr(cleaned))
    check(all(c.isalnum() or c in "_-." for c in cleaned),
          "quotes and shell metacharacters are stripped from the pilot ID")

    # --- the platform decision, both branches ------------------------------
    # 1.1.0 read the platform off DIRECTORY_SEPARATOR and so wrote a /bin/sh
    # script on Windows, which nothing there can run.  The decision now takes its
    # inputs as arguments, so the branch this machine is not running can be asked
    # about too.
    is_windows = lua.globals().XA_DEBUG.is_windows
    WIN_CONF, POSIX_CONF = "\\\n;\n?\n!\n-\n", "/\n;\n?\n!\n-\n"
    cases = [
        (WIN_CONF,   "E:\\SteamLibrary/steamapps/common/X-Plane 12/", True,
         "Windows with native paths on - the shape that shipped broken"),
        (WIN_CONF,   "E:\\SteamLibrary\\steamapps\\", True,
         "Windows with native paths off"),
        (POSIX_CONF, "/home/pilot/X-Plane 12/Resources/", False,
         "Linux is not mistaken for Windows"),
        (POSIX_CONF, "/Users/pilot/X-Plane 12/Resources/", False,
         "macOS is not mistaken for Windows"),
        (POSIX_CONF, "D:/X-Plane 12/Resources/", True,
         "a drive letter alone is enough, whatever LuaJIT claims"),
    ]
    for conf, script_dir, want, why in cases:
        check(bool(is_windows(conf, script_dir)) == want, why)

    shutil.rmtree(tmp, ignore_errors=True)


def scenario_simbrief_launch(library):
    """What actually gets written to disk and run, on this machine."""
    print("\n=== scenario 11b: the SimBrief fetch script ===")
    sim = Sim()
    lua, tmp = build_runtime(
        sim, library, "airline_mode = auto\nauto_find = false\nsimbrief_id = 123456\n")
    run_script(lua)
    g = lua.globals()

    on_windows = bool(g.XA_DEBUG.sb_windows())
    script = g.XA_DEBUG.sb_script()
    print("      platform: %s" % ("Windows" if on_windows else "POSIX"))
    print("      script:   %s" % script)
    check(on_windows == (os.name == "nt"),
          "the platform is read correctly with DIRECTORY_SEPARATOR = '/'")
    check(script.endswith(".cmd" if on_windows else ".sh"),
          "the fetch script is a %s" % (".cmd" if on_windows else ".sh"))

    # Clicking Fetch must not stall the frame: the command is written now and run
    # from the next tick, after the panel has repainted with "asking SimBrief...".
    g.XA_DEBUG.sb_start()
    calls = list(g.OS_EXEC_CALLS.values())
    check(len(calls) == 0, "clicking Fetch does not run a process inside the frame")
    check(g.XA_DEBUG.simbrief().status == "fetching",
          "the panel says it is fetching straight away")
    g.xa_tick()
    calls = list(g.OS_EXEC_CALLS.values())
    check(len(calls) == 1, "the fetch is launched on the next tick")
    if calls:
        print("      command:  %s" % calls[0])
        if on_windows:
            check(calls[0].startswith('start "" /b'),
                  "Windows launches it detached with start /b")
            check("/" not in calls[0].split('"')[-2],
                  "the path handed to cmd.exe uses backslashes")
        else:
            check(calls[0].startswith("sh ") and calls[0].endswith("&"),
                  "POSIX launches it detached with sh ... &")

    body = ""
    if os.path.exists(script):
        with open(script, "r", encoding="utf-8", errors="replace") as f:
            body = f.read()
    check(body != "", "the fetch script was written to disk")
    for line in body.splitlines():
        print("      | %s" % line)
    if on_windows:
        check("#!/bin/sh" not in body, "no /bin/sh script on Windows - the 1.1.0 bug")
        check("curl.exe" in body and "move /y" in body, "cmd.exe syntax is used")
        check("\\simbrief.part" in body and "\\simbrief.json" in body,
              "move gets backslash paths, which is what cmd.exe understands")
    else:
        check(body.startswith("#!/bin/sh"), "a shell script is written")
        check("curl " in body and " && mv " in body, "sh syntax is used")
    check("simbrief.com" in body and "userid=123456" in body,
          "the request goes to SimBrief with the configured pilot ID")
    check(" -L" not in body and "--max-filesize" in body,
          "redirects stay off and the answer size stays capped")

    shutil.rmtree(tmp, ignore_errors=True)


def widget_text(lua):
    """The widget as plain lines, the way it would be drawn."""
    return list(lua.eval(
        "function() local out = {} "
        "for i, l in ipairs(XA_DEBUG.widget()) do out[i] = l.c .. '|' .. l.t end "
        "return out end")().values())


def scenario_widget(library):
    print("\n=== scenario 12: the on-screen phase widget ===")
    sim = Sim()
    lua, tmp = build_runtime(
        sim, library,
        "airline_mode = manual\nairline_manual = AFL\nauto_find = false\n"
        "widget = true\nwidget_mode = medium\n")
    run_script(lua)

    # Parked and cold: the widget should say what boarding is waiting for.
    sim.set(on_ground=1, engines=0, beacon=0, gs_ms=0, battery=0,
            nav=0, taxi=0)
    advance(lua, sim, 3)
    lines = widget_text(lua)
    print("      " + "\n      ".join(lines))
    check(any(l.startswith("accent|PREFLIGHT") for l in lines),
          "the phase leads the widget")
    check(any("cabin power on" in l for l in lines),
          "the missing condition is named")

    # The condition list must not drift from the state machine: whenever every
    # condition reads as met, the phase is expected to move on.
    fly(lua, sim, boarding_seconds=60)
    check(True, "a full flight runs with the widget enabled")

    # Density: minimal is one or two lines, full is the longest.
    counts = {}
    for mode in ("minimal", "medium", "full"):
        lua.execute("XA_DEBUG.config.widget_mode = '%s'" % mode)
        counts[mode] = len(widget_text(lua))
    print("      lines per mode:", counts)
    check(counts["minimal"] <= counts["medium"] <= counts["full"],
          "minimal <= medium <= full in height (%s)" % counts)
    check(counts["minimal"] <= 2, "minimal really is a one-liner (%d lines)"
          % counts["minimal"])

    # A frozen clock or a muted announcer must win over everything else: that is
    # the whole reason to glance at the widget.
    lua.execute("XA_DEBUG.config.enabled = false")
    lines = widget_text(lua)
    check(any(l == "warn|muted" for l in lines), "muted is called out in red")
    lua.execute("XA_DEBUG.config.enabled = true")

    # Offsets saved on a bigger monitor, or a slider dragged to the end, must not
    # park the widget outside the screen - that is indistinguishable from the
    # widget being broken, which is how this feature was received the first time.
    lua.execute("XA_DEBUG.config.widget_mode = 'medium' "
                "XA_DEBUG.config.widget_x = 5000 XA_DEBUG.config.widget_y = 5000 "
                "GRAPHICS_CALLS = {} xa_draw()")
    rects = [c for c in lua.globals().GRAPHICS_CALLS.values() if c.startswith("rect")]
    check(len(rects) == 1, "the widget still paints with impossible offsets")
    if rects:
        x1, y1, x2, y2 = (int(v) for v in rects[0].split()[1:])
        print("      clamped plate: x %d..%d  y %d..%d  (screen 1920x1080)" % (x1, x2, y1, y2))
        check(x1 >= 0 and x2 <= 1920, "the plate stays inside the screen horizontally")
        check(y1 >= 0 and y2 <= 1080, "the plate stays inside the screen vertically")

    shutil.rmtree(tmp, ignore_errors=True)


def scenario_widget_matches_machine(library):
    print("\n=== scenario 13: the widget never lies about the phase ===")
    sim = Sim()
    lua, tmp = build_runtime(
        sim, library,
        "airline_mode = manual\nairline_manual = AFL\nauto_find = false\n"
        "widget = true\n")
    run_script(lua)

    def phase():
        return lua.eval("function() return XA_DEBUG.state().phase end")()

    def all_met():
        conditions = lua.eval("function() local _, c = XA_DEBUG.waiting() return c end")()
        items = list(conditions.values())
        return bool(items) and all(c["met"] for c in items)

    # Fly a whole flight one step at a time.  If every condition for the next
    # phase reads as satisfied, the state machine must agree and move on.
    FT = 0.3048
    KT = 0.5144
    sim.set(on_ground=1, engines=0, beacon=0, gs_ms=0, battery=1)
    lies = []
    steps = [
        dict(on_ground=1, engines=0, beacon=0, gs_ms=0, battery=1),
        dict(beacon=1, engines=2),
        dict(strobe=1, landing=1),
        dict(on_ground=0, agl_m=4000 * FT, alt_ft=4000, vs_fpm=2000),
        dict(agl_m=16000 * FT, alt_ft=16000, vs_fpm=100),
        dict(agl_m=35000 * FT, alt_ft=35000, vs_fpm=0),
        dict(agl_m=10500 * FT, alt_ft=10500, vs_fpm=-1800),
        dict(agl_m=2500 * FT, alt_ft=2500, vs_fpm=-700),
        dict(on_ground=1, gs_ms=40 * KT, agl_m=0, alt_ft=0, vs_fpm=0),
        dict(engines=0, parkbrake=1, beacon=0, gs_ms=0),
    ]
    for step in steps:
        sim.set(**step)
        before = phase()
        satisfied = all_met()
        advance(lua, sim, 30)
        after = phase()
        if satisfied and before == after:
            lies.append("%s: all conditions met but the phase stayed put" % before)
    for item in lies:
        print("      ", item)
    check(not lies, "whenever the widget says every condition is met, the phase moves")

    shutil.rmtree(tmp, ignore_errors=True)


def main():
    library = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_LIBRARY
    if not os.path.isdir(library):
        raise SystemExit("sound library not found: %s" % library)

    scenario_day_manual(library)
    scenario_night_auto(library)
    scenario_no_library()
    scenario_mid_flight(library)
    scenario_ui_clicks(library)
    scenario_config_roundtrip(library)
    scenario_regressions(library)
    scenario_survival(library)
    scenario_livery_detection(library)
    scenario_simbrief(library)
    scenario_simbrief_launch(library)
    scenario_widget(library)
    scenario_widget_matches_machine(library)
    scenario_durations(library)

    print("\n==================================================")
    if failures:
        print("FAILED %d check(s):" % len(failures))
        for item in failures:
            print("  -", item)
        sys.exit(1)
    print("all checks passed")


if __name__ == "__main__":
    main()
