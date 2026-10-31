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

- **Constellation** (v1, the only one): words land on a golden-angle spiral around a
  seeded anchor, each as a four-point star with a link traced from the previous one.
  A star grows over its word's sung length (ease-out cubic) and gets a damped kick in
  size and tilt when it lands; the whole scene shakes slightly with it. The current
  word is large, in the text colour, with a ring pulsing in the highlight colour;
  sung words shrink to secondary at 55%. No background or glow: 26 faint dust motes
  and one soft drop shadow over the wallpaper. Text is lowercase semibold.
  Look and timing studied from Verci's decompiled Constellation scene, reimplemented.

## Settings (menu bar)

- Colors: lyric text, highlight, secondary text (default white, white, white 70%),
  Auto Sync (highlight from the album's artwork colour), Reset.
- Font: SF Pro, SF Rounded, New York, Helvetica Neue.
- Show when unlocked, Cider token.

## Build

    ./build.sh                                # build/Lilt.app
    build/Lilt.app/Contents/MacOS/Lilt --selftest
    build/Lilt.app/Contents/MacOS/Lilt --preview /tmp/frame.png

## Where it is headed

- Verify Apple's word-level lyrics through Cider on a live song.
- More styles, a style picker in the menu.
- Spotify, if ever needed.
