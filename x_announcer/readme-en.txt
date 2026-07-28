X-ANNOUNCER for X-Plane 12 - quick reference
============================================

Cabin crew announcements in the passenger cabin: boarding, the safety
briefing, the calls after take-off, before descent and after landing.
The plugin follows the flight on its own and plays the right call at the
right moment.


INSTALL
-------
1. You need FlyWithLua NG+ 2.8.9 or newer.  Older builds cannot reach the
   X-Plane 12 sound system and the plugin will switch itself off.
2. Copy into the simulator:
      Resources/plugins/FlyWithLua/Scripts/x_announcer.lua
      Resources/plugins/FlyWithLua/Scripts/x_announcer/
   The x_announcer folder must sit next to x_announcer.lua.
3. Put your sound packs somewhere (see below) and start the simulator.
   config.ini is written on the first run.
4. Open the panel and check the path on the Library tab.  A folder called
   UA_Sounds in the root of C:, D: or E: is found automatically.

Updating: replace x_announcer.lua and the contents of the x_announcer
folder, but keep your config.ini - your settings live there.


SOUND PACKS
-----------
X-Announcer reads the same pack layout as MSFS Universal Announcer and the
Fenix announcement sets: one folder per airline, named with its ICAO code
(AFL, DLH, BAW...), with the call files inside.  You do not have to record
anything - ready-made packs are shared in the Universal Announcer Discord:

      https://discord.com/invite/P8ZYJgH3ZF

Layout:
      UA_Sounds/
          AFL/                 Aeroflot pack
              BoardingWelcome.ogg
              SafetyBriefing.ogg
              ...
          DLH/                 Lufthansa pack
          Default/             the fallback pack, used whenever the
                               airline pack has no file for a call

A pack may contain a language sub-folder (en-us, de-de, ru); pick which one
on the Settings tab.  OGG, MP3, WAV and FLAC all play.


OPENING THE PANEL
-----------------
Plugins > FlyWithLua > FlyWithLua Macros > "X-Announcer Control Panel".

That is the only menu FlyWithLua offers to scripts - a script cannot add its
own entry to the Plugins menu.  For quicker access, bind a key or a joystick
button to the command FlyWithLua/x_announcer/toggle_window (skip and
start_boarding are available as commands too).


TABS
----
Flight    the flight: current phase, what is playing, airline, controls
Library   the library: sound folder, airline choice, list of calls
Settings  settings: volumes, which calls to play, audio buses, SimBrief
Log       the journal: what played, and what did not, and why


FLIGHT TAB
----------
Airline           the airline (ICAO code and name)
Detected by       where it came from: livery - the livery folder name,
                  tail number, aircraft - the .acf name or description,
                  manual - you picked it, nothing recognised - no clue
                  found, running on Default.  The bracket says how it
                  matched: name, name (short form), or code XXX for an
                  ICAO code spelled out in the folder name
Voice pack        shown only when the airline was recognised but no pack
                  exists for it: "no pack for SBI - playing Default".
                  That is a missing pack, not a failed detection
Aircraft          type from acf_ICAO and the registration
Local time        cabin local time and the part of day: morning,
                  afternoon, evening, night
Seatbelt sign     ON / off plus the dataref in use; "not available" means
                  this aircraft exposes no seatbelt sign and the seatbelt
                  calls will not fire
cabin quiet       nothing is playing
queued: N         N calls waiting
background        background music is playing

Pin this to the screen
                  show that same phase ladder over the simulator view without
                  keeping the panel open - see THE ON-SCREEN WIDGET below.
                  Density, opacity and position are at the top of Settings

Buttons:
Mute announcer    silence the plugin entirely (becomes Un-mute)
Skip current      cut the current call and move on
Start boarding    begin boarding by hand
Reset flight      start the cycle over for a new flight


PHASES (the ladder at the bottom of the Flight tab)
---------------------------------------------------
Preflight         waiting for power and cabin lights
Boarding          boarding, welcomes and music
Doors & safety    doors to automatic, safety briefing
Takeoff           crew seated, cabin secure
Climb             the after take-off call
Cruise            level, reacting to the seatbelt sign
Descent           the call below 10,000 feet
Approach          crew to your seats
After landing     the welcome on the ground
Disembarking      deboarding, then the cycle resets itself

done / > now      already played / where we are
The grey line under the phase name is the condition for the next step.


LIBRARY TAB
-----------
Sound library folder   the folder holding the packs
Rescan                 re-read it from disk
Airline                Auto, or pick a pack by hand
N packs found          how many packs were found
Event / Files / Source call / how many files / where it comes from
                       a green code - from the airline pack,
                       Default - the fallback pack stepped in,
                       "-" in grey - no file at all
play                   listen to a call right now
stop                   cut it short
stop playback          the same from the tab header, with a timer, so it
                       is reachable whichever row you started from.
                       A preview does not count for the flight: the call
                       will still play later on its own trigger


SETTINGS TAB
------------
On-screen phase widget see THE ON-SCREEN WIDGET below.  It comes first
                       because the switch is also on the Flight tab; what
                       lives here is how the widget looks
announcements          announcement volume
boarding music         background music volume
music ducking          how far music drops under an announcement
Boarding music         play music while passengers board
Cabin ambience         cabin noise in flight
Arm / disarm doors     the door calls
Cabin dimming at night the cabin lighting calls after dark
Cabin reaction         the cabin's reaction to the touchdown
Captain's welcome      the captain's word during boarding
Start boarding auto    begin boarding without pressing anything
welcome repeat         seconds between repeated welcomes
SimBrief               see the next section
Audio routing          FMOD buses: interior, master, ui, com1.
                       Announcements and music must sit on different
                       buses or ducking cannot work.
Language sub-folder    the language folder inside a pack (en-us, ...)
Seatbelt sign dataref  your own seatbelt dataref if the search missed it
window text scale      text size in the panel, larger for VR


THE ON-SCREEN WIDGET
--------------------
A translucent plate over the simulator view.  It answers one question without
opening the panel: which phase are we in, and what is the announcer waiting for
before it moves to the next one.

It is off until you ask for it.  Two checkboxes turn it on and they are the
same switch: "Pin this to the screen" under the phase ladder on the Flight tab,
and "Show it over the sim" at the top of the Settings tab.

Show it over the sim   turn it on
density                three of them:

  minimal   one line: the phase, the next phase and the one thing missing
            CRUISE  ->  Descent
            waiting: below 11 000 ft

  medium    adds every condition for the next phase, with live values
            CRUISE
            next  Descent
            . below 11 000 ft   34000
            . descending        120 fpm

  full      adds the phase ladder around where you are
            done  Takeoff
            done  Climb
            > now Cruise
                  Descent
                  Approach

backing opacity        how solid the plate is; 0.00 leaves text only
from the left / top    where it sits, in pixels

The mark on the left of a condition is a dot while it is unmet and a green v
once it is satisfied.  While a call is playing the widget shows it and a timer
instead of the conditions.  Pause, replay, Mute and the emergency stop override
everything in red - which is the reason to glance at it when the cabin has gone
unexpectedly quiet.

The widget is painted over the picture and takes no clicks, so it can never
swallow one meant for a switch in the cockpit.  Move it with the position
sliders; it will not walk off the edge of the screen even if the offsets were
saved on a larger monitor.


SIMBRIEF
--------
When the livery folder gives nothing away - say it only carries a
registration - the airline can be taken from your SimBrief flight plan.

SimBrief pilot ID or username
        your numeric Pilot ID or your SimBrief account name.  The Pilot ID
        is in your account settings on simbrief.com.  Save to remember it.
Fetch latest plan
        ask for your most recent plan.  The plugin downloads it itself, a
        piece per frame, so the simulator never waits and never stutters;
        the answer usually takes a second or two.

Nothing is applied on its own.  The plugin shows what it found and waits:

        SBI1234   UUEE -> UNNT      callsign and route
        Airline        SBI - S7 Airlines
        Aircraft       A320  VP-BQK
        Plan generated 6 min ago    when the OFP was built

"Plan generated" is the line that matters.  It is green under half an hour
old, grey up to three hours, and red beyond that - a red line usually means
you loaded into the sim without re-generating the plan and this is still
yesterday's flight.

Use this airline    apply it; the airline is pinned (Airline on the
                    Library tab switches from Auto to this code)
Dismiss             throw it away and change nothing

To go back to automatic detection: Library tab, Airline > Auto.

What does the downloading.  Nothing external: sockets (LuaSocket) are built
into FlyWithLua itself, so the plugin fetches the plan on its own.  No curl,
no PowerShell, no scratch files in the plugin folder - all of that was needed
up to 1.1.2 and is gone.

The request goes over plain http rather than https.  Not out of laziness:
FlyWithLua carries no TLS at all - no ssl module and no binary half of one,
checked against what the plugin actually ships.  The SimBrief API answers over
http quite happily (the well-known vatsimbrief-helper script works the same
way).  The price is that your Pilot ID and your flight plan travel in the
clear, which was judged acceptable for a flight plan.

When something does go wrong the status line names it - "cannot reach
www.simbrief.com", "SimBrief answered 503", "SimBrief did not answer within
25 s" - rather than leaving you with a bare "no answer".


MESSAGES UNDER THE PHASE NAME
-----------------------------
muted                  announcements silenced by the button
clock frozen: paused   the sim is paused, the timers are stopped
clock frozen: replay   a replay is running, the plugin holds everything
stopped after repeated errors
                       the plugin switched itself off after 10 errors in a
                       row; the reason is in the Log tab, and reloading the
                       scripts (FlyWithLua > Reload all Lua scripts) clears it

Time acceleration and pause are handled: a call is not cut in half at 2x or
4x, and it does not silently run out during a pause.  Changing aircraft or
livery invalidates FlyWithLua's sound handles - the plugin drops them by
itself, and there is a Reload sound files button in the settings, next to
the count of used slots (there are 400).


IF IT IS SILENT
---------------
1. The Log tab explains itself.  "no sound file" means neither the airline
   pack nor Default has a file for that call.
2. The Library tab: check the folder and press Rescan.  The Source column
   should say something other than "-".
3. The play button next to a call tests the audio without flying.
4. Check the volumes on Settings, and whether Mute announcer is on.
5. FlyWithLua NG+ 2.8.9 or newer is required; older builds cannot reach the
   X-Plane 12 sound system and the plugin disables itself (the message goes
   to the simulator's Log.txt).


IF THE AIRLINE IS WRONG
-----------------------
Livery folders are named however their authors felt like, and some carry
nothing identifiable at all.  Your options:
1. Library tab, Airline - choose the pack by hand.
2. The SimBrief settings - take the airline from your flight plan.
3. Rename the livery folder so the ICAO code is a separate word, for
   example "AFL Aeroflot Skyteam".
The Detected by line on the Flight tab always shows what the plugin read
and how it matched.


FILES
-----
x_announcer.lua              the plugin
x_announcer/airlines.lua     the airline directory
x_announcer/config.ini       settings, commented in Russian
x_announcer/readme-en.txt    this file
x_announcer/spravka-ru.txt   the Russian reference
