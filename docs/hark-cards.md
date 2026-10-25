# Chat cards in the Hark style (v1.13.92)

Based on the hark.com study (2026-10-24). Theme tokens only (Palette, AppText, Radii, Space), SubMotion timings,
reduced motion respected, directional layout (RTL).

| Output | Widget | Look |
| --- | --- | --- |
| Card still being written | `CardShimmer` (motion.dart) | one faded status pill with a short line ("Writing a summary"), no skeleton |
| Pictures, video, sound full screen | `openMediaLightbox` (media_lightbox.dart) | the one viewer: frosted chat behind, Close / file name / Share / Download, chevrons + swipe, pinch and double-tap zoom, account fallback for files made on another phone |
| Video | `InlineVideo` (video_inline.dart, `video_player` 2.9.2) | poster + outlined play glyph, plays inline, thin scrub bar, corner = full screen |
| Page being written | `PageBuildCard` (page_cards.dart) | title, phase word + m:ss, line count, last lines of source in mono, then "Page built" + Open page |
| Finished page | `PageCard` (hark_cards.dart) | thumbnail, serif title, "Page built by SubMac", Open page (in-app preview with Share and Publish); hold = Publish / Share |
| Products / options | `ProductGridCard` (hark_cards.dart) | title, hairline, rows: 76px thumb, name, muted specs, price at the end; row opens the item, thumb opens the photo |
| 2-3 links | `LinkDeck` (output_cards.dart) | fanned deck of small cards (picture, title, source), middle on top |
| Email / text draft | `DraftCard` (hark_style.dart) | subject title, hairline, muted body, Copy corner button; hold = Share / Open in mail |
| Long text | `SummaryCard` + `openSummaryReader` | fixed preview with fade, serif title; reader overlay with Close, "Summary", More (Copy / Share) |
| Code | `CodeBlock` (markdown_view.dart) | darkest card fill, language label, Copy corner, monochrome mono |
| Charts and diagrams | `_DiagramFrame` (diagram_card.dart) | on the card fill; tap opens a large preview |
| Calendar event | `CalendarCard` (```event {"title","start","end","place"}```) | date (muted), time, hairline, title; tap opens the phone's calendar filled in; hold = Share (.ics) |
