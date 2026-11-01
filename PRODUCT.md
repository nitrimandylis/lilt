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

Picked from the menu. Each is studied from Verci's decompiled scene of the same name and
rewritten from scratch; no Verci code or data tables are used.

- **Constellation**: each line is a seeded path of four-point stars (arc, wave, zigzag or
  hook) through the middle of the screen; star-chart labels, no crossings, no overlaps.
- **Ship**: the last 5 sung words stack into a ragged, tilted wall that slowly yaws,
  pitches and breathes in 3D; about 1 word in 5 sits on a highlight band.
- **Visual**: Ship at half the sway, with an SF Symbol popping in beside matched words.
- **Fisheye / Fisheye Visual**: previous, current and next word under a convex lens
  (k = 1 + 0.45 r^2.2), applied per row; Visual adds icons.
- **Codestyle / Codestyle Visual**: the line typed as code (a.b.c(d);) in bold monospace with
  syntax colours, letters springing in with a glow, a red blinking cursor, // comments and a
  "seen" caption now and then; Visual adds an icon before some rows.
- **Branches**: a wavy stem grows through the line; each word sprouts a branch with a node
  and its label, the head glowing with a trail; faint code glyphs drift behind.
- **Web**: a 12-spoke, 4-ring spider web; each word spins a strand from the hub to a node.

Icons come from macOS's own SF Symbols search index, with Apple's on-device word embedding
finding close words when there is no direct match.

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

- A real per-pixel Metal lens for Fisheye (needs Xcode's Metal toolchain).
- More styles, a style picker in the menu.
- Spotify, if ever needed.
