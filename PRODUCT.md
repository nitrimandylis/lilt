# Lilt

A macOS menu-bar lyric player. It shows the lyrics of whatever is playing over the
lock screen (or always, with one toggle) and lights each word the moment it is sung.

## How it works

- **Now playing:** Cider's local API (port 10767) first, Music.app over AppleScript
  when Cider is not playing. Polled every 0.5 s, position predicted between polls.
- **Lyrics:** Apple Music, fetched through Cider's `amapi/run-v3` proxy.
  `syllable-lyrics` gives real word times; plain `lyrics` gives line times, which
  Lilt spreads over the words by letter count. Needs Cider running with an app
  token pasted in the menu, even when Music.app is the player.
- **Lock screen:** a click-through panel moved into a SkyLight space above the lock
  screen (Lakr233/SkyLightWindow, private API).
- **Display:** a `PreventUserIdleDisplaySleep` assertion while lyrics are up.

## Styles

- **Constellation** (v1, the only one): each line grows as a path, word to word, from
  an anchor kept clear of the previous line and heading away from it. Links never cross
  and never run through a word; labels sit on whichever side of their star is free,
  like a star chart. Each word is a four-point star with a link traced from the previous one.
  A star blooms over its word's sung length (at least 0.45 s, ease-out cubic) and
  settles with one soft 10% swing; text fades in over 0.5 s while drifting up. The current
  word is large, in the text colour, with a ring pulsing in the highlight colour;
  sung words shrink to secondary at 55%. No background or glow: 26 faint dust motes
  and one soft drop shadow over the wallpaper. Text is lowercase semibold.
  Look and timing studied from Verci's decompiled Constellation scene, reimplemented.

## Settings (menu bar)

- Colors: Auto Sync (on by default) builds all three colours from Apple's artwork
  palette, fetched from the catalog through Cider: the most colourful swatch is the
  highlight, paler versions of it are the text and sung-word colours. With it off:
  lyric text, highlight, secondary text pickers (default white, white, white 70%), Reset.
- Font: SF Pro, SF Rounded, New York, Helvetica Neue.
- Open lyrics window (a normal resizable black window for when the Mac is unlocked).
- Lyrics delay slider (-0.5 to +1.0 s); Bluetooth output adds +0.2 s automatically.
- Cider token.

## Build

    ./build.sh                                # build/Lilt.app
    build/Lilt.app/Contents/MacOS/Lilt --selftest
    build/Lilt.app/Contents/MacOS/Lilt --preview /tmp/frame.png

## Where it is headed

- Verify Apple's word-level lyrics through Cider on a live song.
- More styles, a style picker in the menu.
- Spotify, if ever needed.
