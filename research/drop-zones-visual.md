# Drop Zones — visual reference (Seam 1.14.x, observed 2026-09-12)

Source: user's phone video `IMG_1794.MOV` (17.6 s, 30 fps) of Seam's island while dragging a
PNG screenshot from Finder to the notch, dropping it into the stash, hovering the stash and
dragging the file back out; plus a screen recording (island invisible — private space — but it
shows the drag cursor path and the drag-out image). Key frames are in `reference/drop-zones/`.
All sizes are estimates from photos (±10 %), scaled against the standard peek width
(notch 185 + 2×56 = 297 pt) and the notch (185×32 pt).

## 1. Zones view (a file drag is in flight and the cursor is over/near the island)

- The island expands into a dark panel of roughly **280×140 pt** (bottom corners ~24 pt like the
  music expanded view). Appears when the dragged file gets close to the notch (in the recording
  the panel was already open when the cursor was ~40 pt below the notch); disappears when the
  drag ends or leaves.
- Inside: **two zone cards side by side**, inset ~14 pt from the panel edges, gap ~8 pt, height
  ~100 pt: left **AirDrop** (AirDrop wave symbol, label "AirDrop"), right **File Stash**
  (tray symbol `tray.and.arrow.down.fill`-like, label "File Stash"). Icon ~28 pt centred, label
  ~12 pt semibold below it; both in system blue.
- Card chrome: **dashed rounded border** (blue, ~1.5 pt, dash ≈ 4/4, corner radius ~12) with a
  faint blue translucent fill. The **targeted card widens** (≈ 160 pt vs ≈ 80 pt for the other)
  with a spring; the non-targeted card stays fully drawn but reads dimmer (opacity ≈ 0.6). With
  no card targeted the widths are equal.
- Drag cursor keeps the Finder's green "+" badge (copy operation), i.e. `NSDragOperation.copy`.

Frames: `zones-airdrop-targeted.jpg`, `zones-stash-targeted.jpg`, `zones-timeline-4fps-from-3s.jpg`.

## 2. Drop → settle

- On drop the panel keeps its size and shows **one full-width dashed card** whose header is
  `tray` + **"1 File"** (icon and label in a row, top-centre of the card, ~13 pt semibold blue);
  the dropped thumbnail is drawn inside the card (still fading/settling). This confirmation stays
  **≈ 1 s** (`stashSettleTask`), then the island **collapses to the bare notch** (~0.5 s), then the
  next card is shown — the stash peek (in the video Seam briefly showed the coding-agent peek in
  between because Claude Code was active; card order is Seam's stack logic).

Frames: `after-drop-settle.jpg`, `settle-timeline-4fps-from-6.5s.jpg`.

## 3. Stash peek (compact, files present)

- Standard peek geometry (297×32). **Left slot: file thumbnail** (QuickLook thumbnail of the
  screenshot, ~24×18 pt, corner radius ~4, looks like a stacked card for one file; multiple files
  presumably fan out — `StackedThumbnails`). **Right slot: count badge** — blue circle outline
  (~18 pt, stroke ~1.5) with the number inside (~11 pt semibold, blue).

Frame: `stash-peek.jpg`.

## 4. Stash hover (expanded)

- Same width as the peek, height grows to **≈ 76 pt** (notch + one text row). The thumbnail and
  badge stay in place; a centred caption row appears under the notch: blue `tray` glyph +
  **"1 file · 89 KB"** (~12 pt medium, light grey text). No buttons visible in this state; the
  cursor becomes a drag handle over the thumbnail.

Frame: `stash-hover.jpg`.

## 5. Drag out

- Dragging the thumbnail starts a file drag whose **drag image is the plain file icon** (generic
  PNG document icon in the screen recording), not the thumbnail. While this drag is in flight the
  island shows the zones panel again but with **only the stash card, full width, labelled
  "1 File"** (AirDrop hidden for drags that originate from the stash).
- Dropping into Finder **copies** the file (green "+" badge) and **empties the stash**: the island
  collapsed and moved on to the next card (coding agent).

Frames: `drag-out-zone.jpg`, screen recording frames (PNG icon cursor).

## Open items (need a second video or the binary research)

- Multi-file look of the thumbnail stack (fan angles, offsets) and the caption plural
  ("3 files · 1.2 MB"?).
- Whether a right-click menu exists on the stash card (Seam strings mention "Copy to Clipboard",
  "Clear"/"Remove" — see `drop-zones-mechanics.md`).
- Third zone ("Add to Stash" / "Replace Stash") layout when enabled — not recorded.
- Exact timing of the panel opening: proximity radius vs. immediate on drag start.
