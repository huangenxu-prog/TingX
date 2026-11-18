# TingX — iOS audiobook application

## Source and attribution
Reference upstream: https://github.com/fengqiao57/abts (Flutter Android audiobook player).
Retain upstream copyright, license, and attribution when importing or adapting code. Do not claim upstream source is already imported.

## Product specification (2026-11-18)
- iOS-first, warm cream and muted brown minimalist interface; approved simple headphones-and-book icon.
- Bottom tabs: 播放器 / 发现 / 书架.
- Player: chapters, next/previous, ±15s, playback speed, sleep timer, background audio, resume progress.
- Discover: search; six-book 热门推荐; two-row horizontally paged category grid (four columns); separate 收藏榜, 热播榜, 高赞榜, each showing six books and 换一批.
- Ranking data must be grounded in real accessible Bilibili fields; no fabricated rankings, categories, completion states, or recommendations.
- Bookshelf: three-column cover grid with title and local progress.
- Detail: chapter list and play; no download or share.
- Settings: optional Bilibili login, never required. No TingX account, no cloud sync.
- Online streaming only; allow ephemeral playback buffering but no offline downloads, share buttons, or related user-facing workflows.
- Local bookshelf and progress.
- Preserve only verified completion badges; omit unknown status.

## Engineering gates
1. Inspect upstream LICENSE, dependencies, source tree, and Bilibili API usage.
2. Import upstream into TingX with attribution, then remove Android-only/download/share/analytics code and plugins.
3. Generate iOS Flutter runner and configure signing-neutral CI.
4. Verify iOS build, search, Bilibili stream URL resolution, audio playback, chapter transitions, and background controls.
5. Implement approved TingX UI and icon, then verify against design.
6. Build only when code compiles; report actual CI result, not assumptions.

## Current status

The isolated upstream iOS simulator probe reached Xcode and failed on a duplicate UmengCommonSdkPlugin declaration (Actions run 44216973352). Static analysis in that probe was allowed to fail.

Imported the upstream Bilibili network client, search/detail/stream service, and book, chapter, and audio models with attribution. The TingX package currently contains the data layer only. The runner, player integration, TingX UI, and end-to-end playback verification are pending.
