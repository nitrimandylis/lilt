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
  seeded anchor, each as a star with a link traced from the previous one. A word
  reveals over its own sung length (ease-out cubic), gets a damped kick in size and
  tilt when it lands, and the current word pulses an expanding ring. Finished lines
  drift up and fade into a twinkling starfield. Colour comes from the album's
  artwork `bgColor`. Timing model studied from Verci's decompiled Constellation
  scene, reimplemented from scratch.

## Build

    ./build.sh                                # build/Lilt.app
    build/Lilt.app/Contents/MacOS/Lilt --selftest
    build/Lilt.app/Contents/MacOS/Lilt --preview /tmp/frame.png

## Where it is headed

- Verify Apple's word-level lyrics through Cider on a live song.
- More styles, a style picker in the menu.
- Spotify, if ever needed.
