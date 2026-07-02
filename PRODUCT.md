# Product

## Register

product

## Users

Music producers on macOS, headed for public release (it began as the author's personal tool). They live in a DAW and bounce constantly; over years that becomes thousands of `.wav`/`.mp3` files scattered across project folders, cloud drives, and half-remembered naming schemes. They open WavCave next to their DAW session, in the studio, to bring order to that archive: group the versions of a song, name things properly, tag and collect, star keepers, and audition anything instantly.

The primary job on any screen is **organizing the library**: version grouping, combining, pinning the main take, tags, collections, artists. Finding and playing a song fast is the supporting act that makes organizing worth it.

## Product Purpose

WavCave surfaces every bounced audio file inside configured "bounce" folders across any number of roots, groups them into songs with version history, and makes the whole archive browsable, playable, and curatable in one native window. Everything stays on the user's machine. Success: a producer trusts WavCave as the canonical index of everything they've ever made, and tidying the archive feels effortless rather than like chores.

## Brand Personality

Native and invisible. Calm, instant, at home on macOS: the app should feel like Apple shipped it, and the user's music should feel like the content of the interface rather than data inside a web page. Three words: native, instant, unobtrusive.

References: Apple Music and Finder (system-native library management, effortless browsing); Linear and Raycast (keyboard-first speed, restrained polish, power-user density without clutter).

## Anti-references

- **Web-app-in-a-window**: Electron-y SaaS dashboards, card grids, gradients, marketing chrome inside the app. WavCave is a WKWebView app that must never read as one.
- **Pro-audio skeuomorphism**: knobs, brushed metal, fake LEDs, cramped plugin-UI density.
- **iTunes-era clutter**: overloaded toolbars, competing panes, feature sprawl on a single screen.

## Design Principles

1. **Feels like the OS shipped it.** Defer to macOS conventions: system fonts, system light/dark, native menus and shortcuts. When in doubt, do what Finder or Music would do.
2. **The library is the interface.** Songs, waveforms, and folders carry the screen; chrome recedes. Nothing decorative competes with the user's own work.
3. **Organization without ceremony.** Curating (rename, combine, pin, tag, collect, ignore) happens in place, one gesture from the row itself, never in a settings maze. A producer's mess goes in; order comes out.
4. **Speed is trust.** Instant search, keyboard-first navigation, silent background refresh. A tool for a daily habit can never feel like a web page loading.
5. **One window, one job.** Each surface has a single primary task; secondary actions stay discoverable but quiet (context menus, hover reveals, the ⌘F palette).

## Accessibility & Inclusion

No formal WCAG bar is set. Keep what the platform gives for free: system dark/light, `prefers-reduced-motion` support (already present for the scan animation), and full keyboard transport (Space/↑/↓/⌘F/⌘J) as an existing product strength worth preserving.
