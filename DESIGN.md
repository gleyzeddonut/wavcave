---
name: WavCave
description: Native macOS library for every bounce you've ever made
colors:
  signal-blue: "#0a84ff"
  studio-ink: "#1d1d1f"
  fog: "#6e6e73"
  mist: "#98989f"
  gallery: "#f5f5f7"
  surface-white: "#ffffff"
  inset-gray: "#f0f0f3"
  hairline: "#e6e6eb"
  hairline-strong: "#d6d6dc"
  tape-amber: "#e0922f"
  star-amber: "#f5a623"
  reel-green: "#34c759"
  alert-red: "#e0453a"
typography:
  display:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI', Helvetica, Arial, sans-serif"
    fontSize: "22px"
    fontWeight: 700
    letterSpacing: "-0.01em"
  title:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI', Helvetica, Arial, sans-serif"
    fontSize: "16px"
    fontWeight: 600
    lineHeight: 1.25
    letterSpacing: "-0.01em"
  body:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.5
  label:
    fontFamily: "'SF Mono', 'SFMono-Regular', ui-monospace, Menlo, Monaco, 'Roboto Mono', monospace"
    fontSize: "10.5px"
    fontWeight: 400
    letterSpacing: "0.05em"
rounded:
  sm: "8px"
  md: "11px"
  lg: "13px"
  pill: "999px"
spacing:
  xs: "6px"
  sm: "10px"
  md: "14px"
  lg: "22px"
components:
  button-primary:
    backgroundColor: "{colors.signal-blue}"
    textColor: "#ffffff"
    rounded: "9px"
    padding: "8px 14px"
  button-primary-hover:
    backgroundColor: "#0a78ec"
  button-ghost:
    backgroundColor: "transparent"
    textColor: "{colors.fog}"
    rounded: "9px"
    padding: "8px 10px"
  row:
    backgroundColor: "{colors.surface-white}"
    textColor: "{colors.studio-ink}"
    rounded: "12px"
    padding: "11px 14px 11px 12px"
  chip:
    backgroundColor: "{colors.inset-gray}"
    textColor: "{colors.fog}"
    rounded: "6px"
    padding: "3px 6px"
  input-search:
    backgroundColor: "{colors.surface-white}"
    textColor: "{colors.studio-ink}"
    rounded: "{rounded.md}"
    padding: "11px 14px 11px 38px"
---

# Design System: WavCave

## 1. Overview

**Creative North Star: "The Invisible Shelf"**

WavCave's interface is shelving: it holds the user's music and otherwise disappears. The system speaks fluent macOS (system font stacks, system light and dark, system blue) so the app reads as something Apple could have preinstalled, not as a web page in a window. Density is moderate and list-driven; a row of the library, with its waveform-ready play control and metadata, is the atomic unit of the whole product.

The system explicitly rejects the three anti-references in PRODUCT.md: web-app-in-a-window SaaS chrome, pro-audio skeuomorphism, and iTunes-era clutter. No gradients-as-decoration, no fake hardware, no competing toolbars. Controls are quiet and precise: they whisper at rest, reveal on hover, and answer instantly.

**Key Characteristics:**
- Native macOS voice: system fonts, system blue, honest light/dark themes
- List-first density; the song row is the atomic unit
- Flat surfaces with hairline borders; shadows only when something floats
- One accent color carries every interactive and "now playing" signal
- Keyboard-first: Space, ↑/↓, ⌘F, ⌘J are first-class citizens

## 2. Colors

A restrained palette: tinted grays for structure, one blue for everything alive.

### Primary
- **Signal Blue** (#0a84ff): the single interactive voice. Playing states, selection, links, primary buttons, focus rings, the cloud badge. If it's blue, you can act on it or it's playing right now.

### Neutral
- **Studio Ink** (#1d1d1f): primary text.
- **Fog** (#6e6e73): secondary text (paths, sublabels, counters).
- **Mist** (#98989f): tertiary text, icons at rest, placeholders.
- **Gallery** (#f5f5f7): the page background.
- **Surface White** (#ffffff): rows, cards, inputs, menus.
- **Inset Gray** (#f0f0f3): wells, segmented controls, chips, hover fills.
- **Hairline / Hairline Strong** (#e6e6eb / #d6d6dc): borders and dividers; the entire depth system.

### Tertiary
- **Tape Amber** (#e0922f): MP3 and vocal chips. **Star Amber** (#f5a623): starred songs. **Reel Green** (#34c759): "connected / alive" dots. **Alert Red** (#e0453a): destructive actions only.

**Dark counterparts** (system dark mode): background #1c1c1e, surfaces #2c2c2e, insets #3a3a3c, ink #f5f5f7, hairlines #39393c/#4a4a4e, star amber #ffd60a, green #30d158. Signal Blue is constant across themes.

### Named Rules
**The One Blue Rule.** Signal Blue is the only color allowed to mean "interactive" or "playing". Never introduce a second interactive hue; never use Signal Blue decoratively.

## 3. Typography

**Display/Title Font:** SF Pro Display via `-apple-system` (Segoe UI / Helvetica fallback)
**Body Font:** same system stack
**Label/Mono Font:** SF Mono (ui-monospace, Menlo fallback)

**Character:** one system family doing all the talking, differentiated by weight and size; SF Mono carries anything data-like (paths, dates, counts, keyboard hints), which is what makes rows scan like a well-set index.

### Hierarchy
- **Display** (700, 22–28px, tight -0.01em): panel titles, empty-state headlines.
- **Title** (600, 16px, 1.25): song names in rows; the loudest text in the main view.
- **Body** (400–600, 13–13.5px): buttons, menus, sidebar, messages.
- **Label** (400–700, 9.5–11.5px, mono, often uppercase +0.05em): file paths, dates, sizes, stat labels, chips, kbd hints.

### Named Rules
**The System Voice Rule.** Never load a webfont. If the type doesn't ship with macOS, it doesn't ship with WavCave.
**The Mono-Means-Data Rule.** SF Mono is reserved for machine facts (paths, timestamps, counts, BPM). Prose and controls stay in the system sans.

## 4. Elevation

Flat by doctrine. Depth at rest comes from hairline borders and background tints (Surface White on Gallery, Inset Gray wells), never from shadows. Real shadows exist only when something genuinely floats above the page.

### Shadow Vocabulary
- **Hairline ring** (`0 0 0 .5px rgba(0,0,0,.04), 0 1px 1.5px rgba(0,0,0,.05)`): the resting "shadow" of inputs and controls; reads as a crisp edge, not a lift.
- **Floating layer** (`0 12px 32px rgba(0,0,0,.18), 0 0 0 .5px rgba(0,0,0,.04)`): context menus, the ⌘F palette, side panels, the selection bar. Reserved for true overlays.

### Named Rules
**The Hairline Rule.** If it doesn't float, it doesn't cast. Rows, cards, and bars get borders and tints; only overlays get shadows.

## 5. Components

Quiet and precise: controls whisper until needed, reveal on hover, and never look raised or glossy.

### Buttons
- **Shape:** gently rounded (9px)
- **Primary:** Signal Blue fill, white text, 8px 14px padding; hover darkens to #0a78ec. One per surface at most.
- **Ghost:** transparent, Fog text; hover fills with 5% black. The default for secondary actions.
- **Danger:** Alert Red fill, confirmation-dialog only.

### Chips
- **Style:** Inset Gray fill, hairline border, 6px radius, mono 9.5px; tinted variants (blue INST, amber VOX/MP3) use 10–14% alpha fills of their hue with matching text.
- **Roots/filters:** pill-shaped (999px) with an embedded ✕ affordance.

### Rows (the signature component)
- **Corner Style:** 12px
- **Background:** Surface White on Gallery; version rows nest at #fafafc with a 30px indent
- **States:** hover = hairline-strong border + faint ring; playing = 6% Signal Blue wash + blue play button; selected = inset 2px Signal Blue ring
- **Anatomy:** circular play control (34px), format tag, title + mono path crumbs, meta column (date/size), hover-revealed icon actions
- **Border:** 1px Hairline at rest; `content-visibility: auto` keeps thousand-row libraries fast

### Inputs / Fields
- **Style:** Surface White, hairline border, 11px radius, 15px text, icon inset left
- **Focus:** Signal Blue border + 3px 16%-alpha blue ring; no glow

### Navigation (sidebar)
- **Style:** 13px system sans rows, 8px radius hover fill (Inset Gray); active = 12% Signal Blue fill, blue text, 600 weight; mono counts right-aligned; disclosure chevrons rotate 90° on expand.

### Transport bar
- Fixed bottom strip on tinted surface with hairline top border; circular buttons (38px, 46px primary blue), inline waveform canvas in an Inset Gray well, mono time counter, kbd hint cluster.

## 6. Do's and Don'ts

### Do:
- **Do** route every interactive signal through Signal Blue (#0a84ff); rarity and consistency are what make it legible.
- **Do** keep both themes first-class: every new surface ships with its dark values (#1c1c1e / #2c2c2e family) in the same change.
- **Do** use hover-reveal for secondary row actions; the row at rest shows only what identifies the song.
- **Do** keep transitions at 0.12s ease-out; state feedback, not choreography, and respect `prefers-reduced-motion`.
- **Do** put machine facts (paths, dates, BPM, counts) in SF Mono at label size.

### Don't:
- **Don't** build "web-app-in-a-window": no SaaS dashboard chrome, no card grids, no gradients, no marketing sections inside the app (PRODUCT.md anti-reference, verbatim).
- **Don't** reach for pro-audio skeuomorphism: no knobs, brushed metal, fake LEDs, or cramped plugin-UI density.
- **Don't** recreate iTunes-era clutter: one job per surface; secondary actions live in context menus and hover reveals, not in ever-growing toolbars.
- **Don't** load webfonts, use `#000`/`#fff` raw in new work (use Studio Ink / Surface White tokens), or add colored side-stripe borders, gradient text, or glassmorphism.
- **Don't** cast shadows on resting surfaces. If it looks lifted but doesn't float, the Hairline Rule is being broken.
