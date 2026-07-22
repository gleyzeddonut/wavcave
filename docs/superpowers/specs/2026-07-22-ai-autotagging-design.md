# AI Auto-Tagging (Genre + Mood) — Design

Date: 2026-07-22
Status: Implemented 2026-07-22

## Purpose

Automatically tag songs in the WavCave library with genre and mood/energy tags by
analyzing the actual audio with Gemini. The library is the user's own unreleased
bounces, so tags must come from listening to the audio, not from a lookup of
released music. This is an explicitly online, opt-in feature — it is the one
exception to WavCave's local-only rule, and the UI treats it that way (nothing
uploads without an explicit user action).

## Decisions already made

- **Provider:** Gemini (audio-native, free-tier key). The provider call is
  isolated behind one function so a second provider can be added later.
- **Scope of tags:** genre + mood/energy. Not full descriptions.
- **Triggers:** manual per-song action + batch "Tag library" action. Never
  automatic/background.
- **Tag identity:** AI tags share the normal tag pool visually but are stored
  separately and marked with ✦. Re-running replaces only AI tags; manual tags
  are never touched.

## Architecture

Backend-driven. `Server.swift` gains one endpoint:

```
GET /autotag?path=<song file path>
→ 200 {"tags": {"genres": ["house", "deep house"], "moods": ["dark", "hypnotic"]}}
→ 4xx/5xx {"error": "<reason>", "kind": "no_key" | "rate_limited" | "decode_failed" | "provider_error" | "offline" | "online"}
```

The endpoint, like all others, requires the per-launch auth token.

### Snippet extraction (Swift, AVFoundation)

- Input: the file path of the song's pinned/main version (the frontend decides
  which version to send; it always sends the main take).
- Take a ~45 s window centered on the midpoint of the track (whole track if
  shorter than 45 s).
- Export mono AAC (`AVAssetExportSession`, m4a container, ~64 kbps) to a temp
  file, read it, delete it. Expected payload ≈ 300 KB.
- Any decode/export failure → `decode_failed`.

### Gemini call

- `POST https://generativelanguage.googleapis.com/v1beta/models/<MODEL>:generateContent`
  with the API key header, one text part (the prompt) and one `inlineData` part
  (`mimeType: "audio/mp4"`, base64 snippet).
- `MODEL` is a single constant in `Server.swift` (current Flash-tier model;
  one-line bump when Google ships a newer one).
- The base URL is overridable via env var `BF_GEMINI_BASE` so tests can point at
  a local stub. The API key comes from durable settings key `geminiKey`; env
  var `BF_GEMINI_KEY` overrides for dev/tests.
- Prompt asks for strict JSON: 1–2 genres and 1–2 moods, each chosen ONLY from
  the controlled taxonomy below, lowercase. Response is parsed defensively: strip code fences, parse
  JSON, drop any tag not in the taxonomy, cap at 2+2. If nothing valid
  survives, return `provider_error`.
- Timeout ~30 s. HTTP 429 or quota errors map to `rate_limited`.

### Controlled taxonomy

Lives in `Server.swift` next to the prompt (single source of truth; the
frontend never needs the list — it just renders what comes back).

Genres (~40): hip hop, trap, drill, boom bap, lo-fi, r&b, soul, funk, pop,
indie pop, rock, indie rock, punk, metal, folk, country, singer-songwriter,
jazz, blues, gospel, classical, cinematic, ambient, house, deep house, tech
house, techno, trance, dubstep, drum and bass, garage, breakbeat, electro,
synthwave, edm, disco, reggae, dancehall, afrobeats, latin, world.

Moods (~12): dark, moody, uplifting, chill, aggressive, melancholic, dreamy,
energetic, hypnotic, playful, epic, romantic.

## Storage & UI (index.html)

- New localStorage map `bf_ai_tags` (`songKey -> [tags]`), loaded/saved exactly
  like `bf_tags`. Manual `bf_tags` is never written by auto-tagging.
- Everywhere tags render (row chips, context menu, tag filters, ⌘F palette
  metadata), display the union of manual + AI tags. AI tags render with a
  leading ✦ and slightly muted styling.
- Tag editor behavior: AI tags appear as chips alongside manual ones. Deleting
  an AI chip removes it from `bf_ai_tags`. If the user types/edits a tag that
  matches an AI tag, it moves to the manual pool (promotion) and leaves the AI
  pool.
- Filtering/search treats AI and manual tags identically.

## Triggers & batch flow

- **Per song:** context menu gains "Auto-tag with AI". Runs immediately; on
  success the row's tags update in place.
- **Batch:** a "Tag library with AI" action in the settings/overflow area.
  Queues every song whose main version has no AI tags. Concurrency 2, retry
  with exponential backoff on `rate_limited` (respecting free-tier RPM),
  cancelable. Quiet progress text ("Tagging 214 of 890…"). At the end, a
  summary toast: tagged N, skipped M (with reasons available).
- Songs that fail with `decode_failed` are skipped and listed in the summary.
  The skip list is in-memory only (per app launch): re-running the batch in the
  same session skips them; a fresh launch tries them again.

## Setup & error states

- First invocation with no key stored: a small inline settings prompt asks for
  a Gemini API key, links to Google AI Studio's free key page, and saves via
  the existing durable-settings endpoint (key `geminiKey`).
- `no_key` → open the key prompt. `offline`/`provider_error` → toast with the
  reason. `rate_limited` during batch → pause with countdown, then resume;
  never silently drop songs.

## Testing

- pytest (existing suite pattern, boots the real backend):
  - stub Gemini HTTP server; backend pointed at it via `BF_GEMINI_BASE`,
    key via `BF_GEMINI_KEY`.
  - happy path returns parsed, taxonomy-filtered tags.
  - missing key → `no_key`.
  - model returns junk / fenced JSON / out-of-taxonomy tags → cleaned or
    `provider_error`.
  - undecodable file → `decode_failed`.
  - 429 from stub → `rate_limited`.
  - endpoint rejects requests without the auth token.
- Frontend merge/promotion/replace logic is small and pure; keep it in
  clearly named functions so it can be eyeballed and exercised manually
  (consistent with the existing UI's test approach).

## Out of scope (YAGNI)

- Other providers (OpenAI etc.) — seam exists, not built.
- Automatic/background tagging on scan.
- Mood-based smart playlists, "sounds like" search, BPM/key detection.
- Editing the taxonomy from the UI.

## Implementation notes (deviations from this spec)

- Rate-limit backoff is a flat 30 s wait, retried up to 4× per song — not exponential.
- Snippet export uses the fixed `AVAssetExportPresetAppleM4A` preset (stereo), not
  mono ~64 kbps; payloads are larger than the ~300 KB estimate but far under limits.
- The batch summary reports counts only; a per-song failure list was not built.
- Added error kind `online` (HTTP 409): the file is a cloud placeholder that hasn't
  been downloaded; the batch counts it as skipped rather than forcing a download.
