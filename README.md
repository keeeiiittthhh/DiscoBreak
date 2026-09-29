# DiscoBreak

Hover the notch. A disco ball drops over everything on screen, throws light across
your windows, and the music starts. Move away and it retracts.

The notch is dead space — the menu bar wraps around it and nothing lives in the
middle. This puts something there.

<img src="docs/icon.png" width="96" alt="DiscoBreak icon">

## Install

Download the DMG from Releases, drag DiscoBreak to Applications, open it.

It has no Dock icon. Look for the mirror-ball glyph in the menu bar — that's
settings, Test Drop, pause and quit.

Until the app is notarized, macOS will warn on first open. Right-click the app →
Open → Open.

## What it does and does not ask for

Nothing to approve on first launch.

- The pointer is polled 20 times a second via `NSEvent.mouseLocation`. No event
  tap, so no Accessibility permission.
- **The screen is never captured.** The light is computed from mirror-ball
  geometry, not read off your display. There is no Screen Recording prompt
  because there is no Screen Recording.
- The music is one exception. Controlling Spotify triggers macOS's standard
  one-time Automation prompt, the first time the ball drops with a playlist set.
  Say no and the show simply runs silent.
- The camera is the other, and only if you ask for it. Turning on **Reflect the
  room** for the Hyperreal ball triggers the Camera prompt. The camera then runs
  only while the ball is down; frames go straight to the GPU and are never
  recorded or saved. Say no and the mirrors reflect studio lights.

## The light

A real mirror ball is roughly 400 flat mirrors in latitude rows. At any instant
the ones facing the lamp *and* aimed at the wall throw a spot — about 105 of
them, as stretched ellipses, all sweeping together as the ball turns.

DiscoBreak runs that as actual reflection math every frame: rotate each tile
normal, cull the ones facing away, reflect the light vector, intersect the
screen plane, and size the ellipse by the angle the beam lands at. The field
moves as one because it is one, and the ball turns at 2.4 RPM like a real motor
rather than the frantic spin most fakes use.

See [`ReflectionSolver.swift`](Sources/DiscoBreak/Rendering/ReflectionSolver.swift).

## Three balls

Settings → Look, or the menu bar icon → Ball. The first two throw the same
light field and differ in how the sphere is drawn; the third is drawn and lit
on the GPU from scratch.

- **Hyperreal** — about a thousand flat mirrors, each tipped a degree or two
  off true, with thin grout between them. Drawn with Metal: every tile, every
  speck of light, every haze beam and every glint is worked out on the GPU from
  one tile buffer, in eight draw calls a frame. Instead of wedges it throws a few
  hundred soft specks, found by reflecting the lamp in each tile and
  following the ray to the screen; they sweep as it turns, flicker a little,
  and run warm, cool or — one in four — coloured. Only the brightest mirrors bloom. Hangs 30%
  bigger and 30% lower than the other two, from a thin cord. It blocks the
  lamp, so a soft shadow falls down and to the left of it and follows it as it
  swings. While it is down the rest of the screen dims (Settings → Look → Dim
  screen, 0–85%, default 45%), a little less around the ball, so the light
  shows even over white windows.
  Optional: **Reflect the room** puts your camera's picture on the mirrors, so
  the room and you are scattered across them. Off by default, asks for camera
  access when you turn it on, runs only while the ball is down, and records
  nothing. Without it the mirrors reflect soft studio lights.
  Frames run on their own thread at the display's rate (120Hz on ProMotion),
  and stop when the ball retracts or the screen is hidden. Measured on an M2 Pro
  at full Retina: about 0.3 ms of GPU and 0.01 ms of CPU per frame.

- **Mirror tiles** (default) — several hundred square mirrors placed on a real
  sphere and turned in 3D by a `CATransformLayer`. Tiles go round the back and
  cull themselves; the silhouette squashes them. The turn is one hardware
  animation and a sixth of the mirrors twinkle on their own; no per-frame CPU
  either way. Geometry follows Bojan's
  [CSS 3D Disco Ball](https://codepen.io/bojan-c/pen/VxbLmX).
- **Classic** — a painted disc with a facet grid scrolling across it. More
  layers than the 3D ball, but flat and on one animation, so it is the cheaper
  of the two. What shipped in v1.

See [`MirrorBall3D.swift`](Sources/DiscoBreak/Rendering/MirrorBall3D.swift) and
[`HyperrealBall.swift`](Sources/DiscoBreak/Rendering/HyperrealBall.swift).

## Music

Paste a Spotify playlist link into Settings → Music. On hover it shuffles and
plays; when the ball retracts it pauses and puts back whatever you were
listening to, at the volume you had it at.

Spotify is the only source. Nothing plays from disk and no audio ships in the
app, so there is no track to license and nothing of yours to bundle by accident.
No playlist, or no Spotify installed, means a silent show — the light still runs.

Spotify Premium recommended; nothing here handles ad breaks.

## Settings

Menu bar icon → Settings…, or edit
`~/Library/Application Support/DiscoBreak/settings.json` directly. Partial files
are fine — anything you leave out keeps its default, and so does anything it
cannot read. Values are the ones the settings window shows, spelling and
capitals included: `"ballStyle"` takes `"Mirror tiles"` or `"Classic"`, and
`"hyperrealBall": true` hangs the third ball instead (`"ballCamera": true` turns
on its room reflection, `"dimBackground"` sets Dim screen from `0` to `0.85`).
Sliders apply live.

| Tab | Controls |
|---|---|
| Look | ball (Classic, Mirror tiles, Hyperreal), camera reflection and dim screen for Hyperreal, ball size, drop distance, light intensity, spot count, spread |
| Motion | rotation speed, frame rate, drop bounce and speed |
| Music | playlist, shuffle, volume |
| Behaviour | launch at login, multi-display, hot zone padding, exit delay |

On a Mac without a notch, the hot zone is a 185×32pt strip at the top centre of
the screen instead.

With more than one display attached, the ball hangs on the built-in screen and
the others get the light field. Every display sweeps in lockstep because each
derives its angle from the same clock. Turn it off in Behaviour.

Under Low Power Mode or thermal pressure the frame rate and spot count step
down automatically — see [`EnergyBudget.swift`](Sources/DiscoBreak/EnergyBudget.swift).

## Build

```bash
swift build
./Scripts/bundle.sh            # -> build/DiscoBreak.app
./Scripts/release.sh           # -> build/DiscoBreak-<version>.dmg
```

Swift Package Manager, no `.xcodeproj`. macOS 14+. AppKit and Core Animation
only — no Metal, no shaders. Two assets: the app icon, and the menu bar glyph
(`Resources/menubar-icon.svg`, drawn in Figma and loaded as a template image so
macOS tints it to match the menu bar).

To sign and notarize a real release:

```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="discobreak" ./Scripts/release.sh
```

## Rights

Nothing third-party ships in this app. There is no bundled audio at all — the
music comes from your own Spotify account, through Spotify's own player. The app
icon is generated by [`Scripts/make-icon.swift`](Scripts/make-icon.swift), and
the menu bar glyph was drawn for the project.

## License

[MIT](LICENSE) © 2026 Keith Joseph.
