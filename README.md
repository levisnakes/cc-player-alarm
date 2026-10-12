# CC Player Alarm

ComputerCraft base security for an Advanced Peripherals Player Detector. When a player who isn't on the allowed list comes within range, it:

- shows **INTRUDER ALERT** with a live radar, their distance, compass direction and time on site,
- turns on a redstone alarm,
- rings a speaker,
- sends a toast to every allowed player who's online (if a Chat Box is attached),
- warns again if they get close.

Every visit is logged with the time it started, how long it lasted and the closest the player got.

It also toasts the allowed list when a player on `WATCH_JOINS` joins the server (default: `Mechanoo`).

## Monitor controls

- **- / +**: zoom the radar (view only; detection range stays `RANGE`).
- **LOG**: full visit log with repeat visitors; **BACK** returns.
- **Tap a player** in the Nearby list: their coordinates, direction, time here, closest distance and past visits.
- **MUTE**: silences the siren and speaker for `MUTE_MINUTES`. It's locked until an allowed player right-clicks the Player Detector, so an intruder can't silence it from the monitor. An intruder right-clicking the detector sends an alert instead. Mute/unmute any time from the computer. Made for a 3 wide, 4 tall monitor with a DirectGPU block; plain monitor text works too.

![Screen preview](preview.png)

## Install

```
wget https://raw.githubusercontent.com/levisnakes/cc-player-alarm/main/player_alarm.lua startup.lua
```

## Setup

1. Put the Player Detector, and optionally a Chat Box and a speaker, next to the computer or on its wired-modem cable.
2. Put a monitor (3 wide, 4 tall) and a DirectGPU block on the computer.
3. Edit the top of the file: `ALLOWED` names, `RANGE`, `ALARM_SIDE`, `UTC_OFFSET` for local times in the log.
4. Stand on top of the Player Detector by yourself and press **Calibrate** on the computer. This gives the radar real directions. Before you do, distances are still exact but blips are placed at a fixed angle per player.

The computer screen lists nearby players with an **Allow** button, lets you add or remove allowed names, and clear the log. Everything on the monitor except MUTE only changes the view, and MUTE needs the detector unlock.
