# X-Announcer for X-Plane 12

Cabin crew announcements for X-Plane 12. A FlyWithLua script that follows the
flight on its own and plays what the cabin crew would say — boarding, boarding
music, the safety briefing, the seatbelt calls, the descent call, deboarding.

**It reads the sound packs you already have.** The pack layout is the same one
used by [MSFS Universal Announcer](https://github.com/fearlessfrog/MSFS_Universal_Announcer)
and the Fenix announcement sets: one folder per airline named with its ICAO
code, files named after the event, tags in square brackets. Nothing to convert,
nothing to re-encode. If you already keep a library from the MSFS side (say
`D:\UA_Sounds`), X-Announcer finds it by itself on the first run.

> **Where to get sound packs.** They are shared by the Universal Announcer
> community on Discord — <https://discord.com/invite/P8ZYJgH3ZF>.
> This repository ships the plugin only; the audio is not mine to redistribute.

[Русская версия документации](README.ru.md)

---

## Requirements

| | |
|---|---|
| X-Plane | 12 |
| [FlyWithLua NG+](https://forums.x-plane.org/index.php?/files/file/82888-flywithlua-ng-next-generation-plus-edition-for-x-plane-12-win-lin-mac/) | **2.8.9 or newer** — earlier builds have no FMOD access |

Nothing else. The optional SimBrief lookup uses LuaSocket, which is built into
FlyWithLua itself — no curl, no external tools, no scratch files.

Audio goes through X-Plane's own FMOD, so `.ogg`, `.wav`, `.mp3` and `.flac`
all play without external codecs, and the volume obeys the simulator's sound
settings.

## Install

Copy both items into the FlyWithLua scripts folder:

```
X-Plane 12/Resources/plugins/FlyWithLua/Scripts/
├── x_announcer.lua
└── x_announcer/
    ├── airlines.lua      airline directory, needed for automatic detection
    ├── readme-en.txt     the in-sim reference
    ├── spravka-ru.txt    the same in Russian
    └── config.ini        written on first run, every key commented
```

Then in X-Plane: **Plugins → FlyWithLua → FlyWithLua Macros → X-Announcer
Control Panel**. That nested path is the only menu FlyWithLua exposes to
scripts. For one-key access, bind `FlyWithLua/x_announcer/toggle_window` to a
key or a joystick button.

When updating, replace the files but keep your `config.ini`.

## Sound library

The path is set on the **Library** tab. Layout:

```
<library>/
├── Default/                       ← fallback when the airline has no file
│   ├── SafetyBriefing.ogg
│   └── en-us/AfterLanding.ogg     ← optional language sub-folder
├── AFL/
│   ├── BoardingWelcome.ogg
│   ├── AfterTakeoff[Night].ogg
│   ├── PreSafetyBriefing[A320].ogg
│   └── SafetyBriefing[2].ogg
└── BAW/…
```

Tags in the file name:

| Tag | Meaning |
|---|---|
| `[A320]`, `[B738]`, `[CRJ9]` | this aircraft type only, checked against `acf_ICAO` |
| `[Morning]` `[Afternoon]` `[Evening]` `[Night]` | this part of the day only, in cabin local time |
| `[1]`, `[2]`, … | variants of one call, chosen at random |
| `[Refueling]`, `[Deicing]` | recognised, but X-Plane has no trigger for them yet — kept as a low-priority fallback |

A file whose type and time-of-day tags match beats an untagged file; a file
tagged for a *different* type never plays. If the airline pack has no file for
a call, `Default` steps in.

Supported events: `BoardingWelcome`, `BoardingWelcomePilot`, `BoardingStarted`,
`BoardingMusic`, `BoardingComplete`, `DepartureDelayed`, `ArmDoors`,
`PreSafetyBriefing`, `SafetyBriefing`, `CabinDimTakeoff`, `CrewSeatsTakeoff`,
`CallCabinSecureTakeoff`, `AfterTakeoff`, `TopOfClimbPilot`, `FastenSeatbelt`,
`Turbulence`, `TopOfDescentPilot`, `DescentSeatbelts`, `CabinDimLanding`,
`BeforeLanding`, `CrewSeatsLanding`, `CallCabinSecureLanding`, `AfterLanding`,
`AfterLandingMusic`, `DisarmDoors`, `DisembarkStarted`, `LandingGreat`,
`LandingTerrible`, `CabinNoise`.

## Which airline is flying

Three ways, in order of authority:

1. **Manual** — pick a pack from the list on the Library tab.
2. **SimBrief** — fetch your latest OFP and take the airline from it. Nothing is
   applied automatically: the panel shows the callsign, the route, the aircraft
   and **how old the plan is**, and waits for you to accept it. The age is the
   point — the usual mistake is loading into the sim before re-generating the
   plan, so the line turns red once the OFP is more than three hours old.
3. **Automatic** — from the livery path (`acf_livery_path`), the registration,
   the `.acf` name and the aircraft description, matched against a directory of
   5,774 airlines (OpenFlights) plus a table of common spellings.

Detection matches on whole words first, then on a name glued to something else,
then on a shortened official name, and only then on a bare ICAO code standing
as its own word. That order matters, because livery folders are full of strings
that collide with real ICAO codes: `Thai Airways HS-TXS` must not become TXS,
`Air China` must not become AIR, and `Red Wings Airlines RA-73329` must not
become RED.

Recognising an airline and owning its voice pack are separate things. If the
livery says S7 and you have no S7 pack, the panel says so — `no pack for SBI -
playing Default` — instead of pretending nothing was recognised.

The Flight tab always shows what was read and how it matched, e.g.
`livery (name): [CFMLEAP] S7 AIRLINES RA-73466`.

## What plays, and when

| Event | Condition in X-Plane |
|---|---|
| BoardingWelcome | on the ground, engines off, beacon off, power/lights on. Repeats every N seconds (default 300) |
| BoardingMusic | between welcomes, on its own bus, ducked under announcements. Stops on beacon or engine start |
| CabinNoise | cabin ambience in flight, independent of boarding music; off on the ground |
| AfterLandingMusic | during deboarding, until the cycle resets |
| BoardingComplete | beacon on, or an engine started |
| ArmDoors | engine running / started moving |
| PreSafetyBriefing → SafetyBriefing | in sequence, after ArmDoors |
| CabinDimTakeoff | night, 10 s after the briefing ends |
| CrewSeatsTakeoff | on the ground, engines running, strobes or landing lights on |
| CallCabinSecureTakeoff | 5 s after CrewSeatsTakeoff finishes |
| AfterTakeoff | airborne, above 3000 ft AGL (or 150 s after lift-off) |
| TopOfClimbPilot | above 15,000 ft, vertical speed under 350 fpm for 25 s |
| FastenSeatbelt / Turbulence | seatbelt sign switched on in flight (180 s between triggers). Turbulence if the g-trace was rough beforehand |
| TopOfDescentPilot | descending 500 fpm or more above 20,000 ft for 25 s |
| DescentSeatbelts | below 10,000 ft on descent |
| CabinDimLanding | night, below 10,000 ft |
| BeforeLanding | below 5000 ft AGL on descent |
| CrewSeatsLanding | below 3000 ft AGL on descent |
| CallCabinSecureLanding | 10 s after CrewSeatsLanding |
| LandingGreat / LandingTerrible | by vertical speed at touchdown (under 180 fpm soft, over 400 fpm hard) |
| AfterLanding | on the ground, under 60 knots |
| DisarmDoors | engines off and stopped: parking brake set, or under 1 knot |
| DisembarkStarted | after DisarmDoors with the beacon off; 2 minutes later the cycle resets for the next flight |

### The seatbelt sign

Read from the first dataref that exists, verified against the aircraft binaries:

| Aircraft | Dataref | "on" |
|---|---|---|
| ToLiss A320 | `AirbusFBW/SeatBeltSignsOn` | 1 |
| 737NG Series V2 | `b737ng/equipment/alerts/crew/cabin/CRW_seatbelts_on` | 1 |
| Rotate MD-11 | `Rotate/aircraft/controls/seatbelts_lts` | 1 |
| Zibo 737 | `laminar/B738/toggle_switch/seatbelt_sign_pos` | 2 (0 off, 1 auto, 2 on) |
| everything else | `sim/cockpit2/switches/fasten_seat_belts`, `sim/cockpit/...` | 1 |

You can name your own dataref in the settings; the Flight tab shows which one
is in use and its current state.

X-Plane has no logo light dataref at all, so "the cabin is being prepared" is
inferred from electrical power and the navigation/taxi lights; logo lights are
used only when an add-on provides them.

## The panel

- **Flight** — the current phase, what is playing with a progress bar, the
  airline and how it was identified, aircraft type, cabin local time, the
  seatbelt sign, the phase ladder, and buttons: mute, skip, start boarding,
  reset flight.
- **Library** — the library path, rescan, airline choice, and a table of events
  showing how many files exist, which pack they come from, and a `play` button
  to audition a call in the sim. A preview does not count for the flight.
- **Settings** — how the on-screen widget looks, volumes and ducking, which calls
  to play, welcome repeat interval, SimBrief, FMOD buses, language sub-folder,
  seatbelt dataref, and panel text scale for VR.
- **Log** — what played and why, and why something did not.

### The on-screen widget

A translucent plate over the simulator view that says which phase you are in and
what the announcer is waiting for, so you never have to open the panel to find
out why the cabin has gone quiet. Three densities:

```
minimal   CRUISE  ->  Descent            medium   CRUISE
          waiting: below 11 000 ft                next  Descent
                                                  . below 11 000 ft   34000
full      done  Takeoff                           . descending        120 fpm
          done  Climb
          > now Cruise                   A dot means the condition is not met
                Descent                  yet, a green v means it is.  Pause,
                Approach                 replay and Mute override in red.
          next  Descent
          . below 11 000 ft   34000
```

It is off until you ask for it: tick **Pin this to the screen** under the phase
ladder on the Flight tab, or **Show it over the sim** at the top of Settings —
the same switch in both places. Density, opacity and position are adjustable, it
stays on screen whatever the offsets say, and it takes no clicks — it cannot
swallow one meant for a switch in the cockpit. It is drawn with FlyWithLua's graphics
module rather than as a second ImGui window on purpose: FlyWithLua calls
`ImGui::Begin()` itself before handing control to a window builder, and ImGui
samples the window background colour there, so the background alpha of an imgui
window cannot be reached from Lua at all.

Commands available for binding: `FlyWithLua/x_announcer/toggle_window`,
`FlyWithLua/x_announcer/skip`, `FlyWithLua/x_announcer/start_boarding`.

## Notes and limits

- The panel is in English. FlyWithLua draws its UI with the built-in ImGui
  bitmap font, which carries no Cyrillic glyphs and cannot be replaced from Lua.
- Time acceleration and pause are handled: a call is not cut in half at 4x and
  does not silently run out during a pause. Replay freezes the plugin entirely.
- Changing aircraft or livery invalidates FlyWithLua's sound handles; the
  plugin drops them by itself, and there is a manual "Reload sound files"
  button next to the count of used slots (400 total).
- Every callback runs inside `pcall`. A Lua error in a FlyWithLua callback stops
  the whole Lua engine — every other script in the sim goes down with it — and
  nothing this plugin does is worth that. After repeated failures it switches
  itself off and says so.
- No SimBrief/GSX-style ground services and no TTS: X-Plane has no equivalent
  to hook into.

## Development

The plugin is tested offline against a Lua interpreter, without launching the
simulator: the sim, FMOD, the file system and ImGui are stubbed, and whole
flights are flown at accelerated time.

```bash
pip install lupa
python tests/sim_test.py "D:\UA_Sounds"
```

120 checks covering the phase machine, the audio queue, pause and time
acceleration, config round-trips, airline detection against real livery folder
names, the phase widget, and the failure modes that can silence the plugin.

The SimBrief fetch is walked by a scriptable fake socket: an immediate connect
and a slow one, a partial send, an answer arriving 64 bytes at a time, a close
that carries the last piece and one that does not, six ways the request can
fail, an oversized answer, both timeouts, and a CRLF pasted into the pilot ID.

## Credits

- Sound pack format and the idea: the
  [MSFS Universal Announcer](https://github.com/fearlessfrog/MSFS_Universal_Announcer)
  project and its community.
- `x_announcer/airlines.lua` is built from the
  [OpenFlights](https://openflights.org/data.html) airline database, used under
  the Open Database License (ODbL).

## Licence

MIT — see [LICENSE](LICENSE).
