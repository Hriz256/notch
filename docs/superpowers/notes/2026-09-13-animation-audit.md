# Animation audit — every motion in Notch, and what it should be

Date: 2026-09-13 · Branch: `feature/animations` · Scope: **analysis only, no code changed.**

The ask, verbatim: «Я хочу, чтобы у нас были сочные, плавные и красивые анимации в духе Apple.»

This audit was written from the source, not from a running build: every "today" line below is a
curve and a duration that is actually in the code, with the file it lives in. Nothing here has
been eyeballed at 120 Hz — where a proposal is a judgement call about *feel* rather than about
mechanics, it says so.

---

## 0. The yardstick

The rules the proposals are measured against, taken from how the Dynamic Island, the macOS
volume/brightness HUD and Seam actually move:

1. **Shape changes are springs, ~0.35–0.5 s response, 0.75–0.85 damping.** In the modern
   spelling (macOS 26, which is our floor) that is `.spring(duration: 0.4, bounce: 0.15)`;
   Apple's own `.snappy` is `duration 0.3, bounce 0.15` and `.smooth` is `0.3, bounce 0`.
2. **Content is faster than shape, ~0.2 s, and starts at the same instant.** Content that waits
   for the shape reads as two objects. Content that finishes long before the shape reads as a
   picture inside an inflating box.
3. **Collapse is the same gesture played quicker and flatter** — same family, ~0.75× the
   response, damping ≥ 0.9. Never a different feel, never a different anchor.
4. **Content enters by fading and scaling slightly (0.96 → 1), anchored where the shape grows
   from** — for us, the notch, i.e. `anchor: .top`. Blur is a garnish, ≤ 3 pt at these sizes.
5. **Nothing the user reads as physical uses `linear` or `easeInOut`.** Reserve `linear` for
   things that genuinely are constant-rate (a marquee, a progress fill).
6. **Everything is interruptible and retargets from its current value and velocity.** Springs do
   this for free; ease curves do not — they restart, which is the classic "it popped" bug.
7. **Idle costs nothing.** A motion that is on screen for minutes must be handed to the render
   server once, not re-committed per frame.

---

# Part A — what to change in the motion that exists

## A1. Collapsed → peek → expanded (the island's own shape)

**Today** (`Surface/TransitionChoreographer.swift`, `Surface/SurfaceView.swift`)
`geometry = .spring(response: 0.42, dampingFraction: 0.78)` for any change that grows on either
axis; `collapseGeometry = .spring(response: 0.38, dampingFraction: 1.0)` when it grows on
neither. Applied twice on the root `ZStack` (`.animation(animation, value: layout)` and
`.animation(animation, value: presenter.state)`). The frame is interpolated by
`IslandFrame` (an `Animatable` `ViewModifier`) with a per-axis floor at the notch, and the top
flare animates in lockstep with `NotchShape.animatableData`. Radii (6/8/12 top, 10/14/24 bottom)
ride the same spring.

**This is the best-built part of the app and the closest to Apple already.** The
floor-inside-`animatableData` trick is exactly right, and it is why the island never exposes the
notch edges mid-spring.

**What feels un-Apple**
- 0.42 / 0.78 is a touch slow and a touch loose for a 32 pt → 170 pt move. The Dynamic Island's
  grow lands around 0.35–0.38 with slightly more damping; 0.78 puts visible wobble on the bottom
  corners of a 380 pt card.
- `dampingFraction: 1.0` on the collapse is *over*-corrected. The reason given in the comment —
  an undershoot drawing the island inside the notch — is already impossible: `IslandFrame.clamped`
  floors every interpolated frame at the notch size. A critically damped spring reads as "the
  air went out of it"; the collapse ends by creeping rather than arriving.

**Proposal**
- `geometry = .spring(response: 0.38, dampingFraction: 0.82)` — very slightly quicker, visibly
  more settled.
- `collapseGeometry = .spring(response: 0.30, dampingFraction: 0.92)` — the same gesture, 0.8×
  the response, flat enough not to bounce but fast enough to *arrive*. The clamp keeps it honest.
- Collapse the two `.animation` modifiers into one transaction keyed on a single value
  (`layout` already changes whenever `state` does that matters), so there is exactly one
  transaction in charge of the shape.
- Interruptibility: already correct (spring → spring retargets with velocity preserved). Worth a
  test that `geometryAnimation(from:to:)` returns the collapse curve for a mid-expand reversal.

## A2. Content entering and leaving with the shape

**Today** `contentIn = .easeOut(duration: 0.18).delay(0.06)`, `contentOut = .easeIn(duration: 0.12)`,
transition = `opacity + scaleEffect(0.94) + blur(6)`, default (centre) anchor
(`TransitionChoreographer.IslandContentTransition`, applied in `SurfaceView.contentTransition`).

**What feels un-Apple — this is the single biggest offender.**
- **The 60 ms delay.** The shape starts, and for four frames at 60 Hz the island is an empty
  black box. That is literally the "content arrives after the shape" the owner objects to.
- **The exit is 3× faster than the collapse.** Content is gone in 120 ms while the shape takes
  380 ms to shrink: for a quarter of a second the user watches an *empty* panel deflate. The
  Dynamic Island keeps its content on screen, scaling down with the shape, right to the end.
- **Ease curves for a physical move.** They do not retarget: reverse a promote mid-flight and the
  content restarts its fade instead of turning around.
- **Centre anchor.** The content scales about the panel's middle while the shape grows from the
  notch at the top. Two different origins is exactly the cue that says "two objects".
- **6 pt blur at 0.18 s** is a smear, not a focus pull, at 13 pt type.

**Proposal**
- `contentIn = .spring(response: 0.26, dampingFraction: 0.9)`, **no delay**.
- `contentOut = .spring(response: 0.22, dampingFraction: 1.0)` — still quicker than the shape,
  but overlapping it rather than finishing before it starts.
- Transition: `opacity + scale(0.96, anchor: .top) + blur(2.5)`, and add `offset(y: -4)` on the
  active side so content emerges *from under the notch* rather than materialising in place.
- Reduce Motion unchanged in shape (opacity only), but the reduced curves should also lose the
  delay.

## A3. Which curve a transition gets

**Today** `IslandLayout.shrinks(to:)` — "grows on neither axis" — picks the collapse curve, and
equal layouts count as shrinking.

**What feels un-Apple.** A *page swipe* between two cards of the same width but different height
(Code 380×170 → stash 380×124) is judged a collapse and gets the flat curve; the same swipe in
the other direction is judged a grow and gets the bouncy one. The user feels the two directions
of one gesture behave differently, which is unjustifiable — a page turn is neither a grow nor a
collapse.

**Proposal.** A third curve, `pageChange = .spring(response: 0.34, dampingFraction: 0.86)`,
chosen when the presentation id changes while the mode does not. `geometryAnimation` grows a
third case; it is a pure function and gets Swift Testing coverage (grow / collapse / page /
equal-layout).

## A4. Hover promote and demote

**Today** `IslandPresenter.hoverEnterDelay = 120 ms`, `hoverExitDelay = 350 ms`; the visual is
A1 + A2 verbatim.

**What feels un-Apple.** The timings are right (120 ms is about where macOS menu-bar extras
open; 350 ms exit stops flicker on a diagonal pointer path). The *feel* problem is entirely A2's
delay + empty-box-collapse, which hover exercises more than anything else in the app: the user
hovers dozens of times an hour. Fixing A2 fixes hover.

**Proposal.** No timing change. One small addition, noted in B4: the island currently gives no
acknowledgement at the moment of a *click* (`toggleHoverPromotion`), only at the end of the
animation.

## A5. Page swipe (two-finger cycle through the card stack)

**Today** `SwipeGestureRecognizer` fires a discrete `cycle(.next/.previous)` after 4 pt of
travel; the presenter pins a new card; `SurfaceView.content` swaps subtree identity
(`.id("expanded-\(current.id)")`) so the old card leaves on `contentOut` and the new one enters
on `contentIn` — the **same symmetric fade+scale in both directions** — while the shape springs to
the new card's size.

**What feels un-Apple.** There is no direction in the motion at all. A leftward flick and a
rightward flick produce identical pixels. Every paged surface Apple ships — Control Center pages,
Notification Center, the Dynamic Island's own stacked activities — moves content along the axis
of the gesture. Today the swipe reads as "the island blinked", and the stack dots (A7) don't move
either, so nothing confirms which way the user went.

**Proposal.** Record the direction on the presenter when `cycle` succeeds (a one-shot
`lastCycleDirection`), and give the content an asymmetric, direction-aware transition: insert
from `offset(x: ±14)` + opacity, remove to `offset(x: ∓14)` + opacity, on `pageChange` (A3).
**Keep the offset small (≤ 16 pt) and inside the existing `clipShape`** so it reads as content
sliding under the island's own edge, never as a panel sliding in from outside — that is the
rejected "separate shape" look, and 14 pt is far below the threshold where it appears.
Reduce Motion: opacity only, no offset.

## A6. Alert peek in and out (HUD, Code completion, track change)

**Today** an alert wins `IslandPresenter.current` and the island re-resolves. Three cases:
- **from collapsed** → a real grow on the geometry spring. Good.
- **HUD while another peek is up** → the presentation asks for 96 pt slots (spec), so the island
  widens from 297 pt to 377 pt on the geometry spring. Good; this is the Seam behaviour.
- **Code completion alert while a 56 pt peek is up** → `IslandLayout.resolve` produces an
  *identical* size. The shape does not move at all; the content crossfades in place.

**What feels un-Apple.** The third case is the common one and it is silent: an agent finishing —
the event the app exists to announce — produces a 180 ms crossfade in a box that never twitches.
The Dynamic Island never swaps an activity without the pill reacting; it widens and settles.

**Proposal (change).** On an *arrival* — a new presentation id taking the island while it is
already showing another at the same size — play a one-shot shape beat: target width
+8 pt for ~90 ms, then settle, on `.spring(response: 0.32, dampingFraction: 0.62)`. It is the
island's own `IslandFrame`, one value, no new layer, so there is no separate-shape risk by
construction. See B1 for the fuller "squash" version and its risk note.

**Also found:** `MusicViewModel.isShowingTrackChange` is set and expired on a 2.5 s timer and
**no view reads it** (grep: the symbol appears only in `MusicViewModel.swift`). The spec's
"track change peek" therefore has no visible motion today. Listed as an addition (B12) rather
than a change, because there is nothing to change.

## A7. Stack dots

**Today** (`SurfaceView.stackDots`) one 3 pt circle per card, expanded only, opacity 1 vs 0.35,
`.animation(contentIn, value: index)` — i.e. an eased opacity crossfade, nothing else moves.

**What feels un-Apple.** Page indicators everywhere in the system have a *size* difference and
the selection travels; ours blinks. Combined with A5 it means the swipe has no feedback at all.

**Proposal.** Active dot 4 pt / inactive 3 pt, opacity as today, both animated on
`.spring(response: 0.3, dampingFraction: 0.8)`; the group enters/leaves with the panel rather
than appearing at full strength. Cost: nil (n ≤ 4 circles, one spring).

## A8. Drop Zones — grow, target, settle, poof, hover

**Today** panel grow uses the island's own geometry spring (correct and deliberate: the panel is
the island, which is why it reads as growing out of the notch — `ZonesView` is the presentation's
`expanded`, and the mirror-window dance exists to preserve exactly this). Targeting/width
`.spring(response: 0.3, dampingFraction: 0.8)` (spec §3.3). Card insert `.opacity + .scale(0.95)`.
Dropped thumbnails `scale 1.12 → 1`, `.easeOut(0.3)` (spec). Poof `scale → 0.6 + opacity → 0`,
`.easeOut(0.25)` (spec, Seam-observed). Hover lift 6 pt / scale 1.06,
`.spring(0.25, 0.7)` (spec).

**What feels un-Apple — one thing only.** The thumbnails' entrance is the emotional peak of the
whole feature (the moment the user's file lands) and it is an `easeOut`: it decelerates into the
target and stops dead. `1.12 → 1` wants to *settle*, i.e. overshoot slightly under it and come
back — that is what makes a drop feel caught rather than parked.

**Proposal.** Swap that one curve for `.spring(response: 0.34, dampingFraction: 0.62)` —
comparable settling time (~0.35 s), one small overshoot. **This changes a spec constant**, so the
spec line gains: *"settle is a spring rather than an easeOut: the tiles are caught, not
parked."* Everything else in this feature stays exactly as specced — see "What I will not touch".

## A9. Music visualizer bars

**Today** (`MusicFeature/Views/VisualizerBars.swift`) four bars, `.frame(height:)` toggled between
two height sets by a `phase` bool, `.easeInOut(duration: 0.35 + i*0.07).repeatForever(autoreverses: true)`;
a paused island replaces the repeat with a single `.easeOut(0.2)` to 3 pt resting dots.

**What feels un-Apple, and what it costs.** The animated property is a **frame height**, which is
layout: SwiftUI re-runs layout for that subtree on every displayed frame, on the main thread, for
as long as music plays — and the Music peek is the island's default state, so this is the app's
steady-state cost, not a transient one. (This is a stronger candidate for the "~5 % while the
island is busy" figure in the backlog than the thinking dots, which are already Core Animation.)
Visually, a two-state `easeInOut` toggle is a metronome; the differing per-bar durations are what
save it from looking synchronised.

**Proposal.** Draw each bar at its maximum height and animate `scaleEffect(y:, anchor: .center)`
instead — a transform, which the render server can own outright, with identical pixels and no
per-frame layout. Keep the staggered durations. Same for the expanded card's copy. This is a
correctness/CPU fix as much as a motion one, and `heights`/scale math gets a unit test.

## A10. Music marquee

**Today** (`MarqueeText.swift`) `.linear(distance/30 s).delay(1.2).repeatForever(autoreverses: false)`
on an `offset`, two labels 32 pt apart so the wrap is seamless; edge-fade mask only while
scrolling.

**Verdict: leave it.** Constant rate is correct for a marquee (Apple's own do the same), the
pause-before-start is right, the wrap is invisible. The known wart — it scrolls while paused — is
a behaviour bug already in the backlog, not a motion-quality one.

## A11. Code agent glyphs (thinking dots, and the four timeline glyphs)

**Today**
- `ThinkingDots` — three 3 pt circles, per-dot `offset(y:)` on
  `.easeInOut(0.45).repeatForever(autoreverses: true).delay(index * 0.15)`, started once in
  `onAppear`. This is already the Core Animation form the backlog asked for; **the backlog item
  "consider a CA-only animation" appears to be done.**
- `EditingGlyph`, `ReadingGlyph`, `RunningGlyph`, `WaitingGlyph` — each wraps its body in
  `TimelineView(.animation)` and derives sway/trim/blink from `context.date`.

**What feels un-Apple / what it costs.** `TimelineView(.animation)` re-runs its body **every
displayed frame** (120 Hz on this hardware) for as long as the glyph is on screen, and these
glyphs are on screen for essentially the whole of a working session, in the peek slot *and* again
in the expanded header. The comment justifying them ("on screen for a tool call or two") does not
match how a session actually looks. Each of the four is expressible as a plain animatable
property: sway = `offset`/`rotationEffect` on an autoreversing spring-free `easeInOut` repeat,
the write ramp and the type ramp = a `trim`/width on `.linear(period).repeatForever(autoreverses: false)`,
the cursor blink = `opacity` on a repeating step.

**Proposal.** Convert all four to repeating property animations (the `ThinkingDots` pattern), so
the island stops committing SwiftUI bodies at display rate while an agent works. **Honest
tradeoff:** the timelines were chosen because a `repeatForever` restarts when SwiftUI re-creates
the view, and the Code card *is* re-presented on every hook event. The mitigation is to give the
glyph a stable identity independent of the model (`.id(kind)`) so the model's churn cannot
restart it — which is worth verifying on a real session before committing, since a glyph that
visibly restarts mid-cycle is worse than one that costs CPU.

Reduce Motion is already honoured in `GlyphMotion.isReduced` and must stay.

## A12. Small progress motions (session ring, usage bars, HUD bar)

**Today** `SessionRing` `trim` `.easeOut(0.3)`; `UsageBarRow` fill `.easeOut(0.3)`; `HUDBarView`
fill `.easeOut(0.12)` with `reduceMotion ? nil` (spec §2).

**Verdict.** The two 0.3 s ones are fine — a poll landing is data arriving, not a physical event,
and `easeOut` is the right register. The HUD's 0.12 is a spec constant and matches the system
HUD's near-immediate bar; **leave it as the default**, and see B8 for the optional "juicy" variant
with a one-line spec change if the owner wants it.

## A13. Reduce Motion is sampled once, at window build

**Today** `TransitionChoreographer.current()` is read in `SurfaceController.buildWindow` and in
`applyMirror`, i.e. at startup and at screen changes. Toggling Reduce Motion while the app runs
does **not** change the island's geometry curves until a display reconfiguration. The feature
views read it fresh (`GlyphMotion`, `MotionPreference`, `@Environment` in HUD), so the app is
also internally inconsistent about it. Both facts are already in the backlog; they belong in this
audit because "we honour Reduce Motion" is currently only two-thirds true.

**Proposal.** Observe `NSWorkspace.didChangeAccessibilityDisplayOptionsNotification` and rebuild
the choreographer into the root view; standardise on one mechanism (the `@Environment` one, with
a value injected at the root) repo-wide.

## A14. Track-change peek — specced, implemented in the model, invisible

Covered under A6. `isShowingTrackChange` has no reader. Either delete the flag or give it the
motion the spec describes (B12).

---

# Part B — what to add

Each item: where · trigger · curve · Reduce Motion · honest cost/risk.

### B1. Arrival squash — the island reacts when a card takes it over
- **Where** the island shape itself (`IslandFrame`, one extra animatable scalar).
- **Trigger** a new presentation id becomes `current` while the island is already visible
  (completion alert, HUD replacing a HUD, a card arriving behind a swipe).
- **Motion** width +8 pt / height +3 pt for ~90 ms then settle, on
  `.spring(response: 0.32, dampingFraction: 0.6)`. Anchored at the notch, so the top edge
  never moves.
- **Reduce Motion** skipped entirely; the content crossfade alone.
- **Cost/risk** one spring on a value already animated; zero CPU. Risk is *taste*: overdone it
  becomes a twitchy notch. It moves the same shape, so no separate-shape risk. Recommend
  shipping it small and letting the owner ask for more.

### B2. Bounce on the completion check
- **Where** `CompletedGlyph` (`ActivityKind.swift`).
- **Trigger** the tick appears when a session finishes.
- **Motion** keep the 0.35 s `trim` draw, add `scaleEffect` 0.8 → 1.06 → 1 on
  `.spring(response: 0.3, dampingFraction: 0.55)` starting at 60 % of the draw.
- **Reduce Motion** draw only, no scale (the existing `GlyphMotion.isReduced` path).
- **Cost/risk** one-shot, three properties, nil cost. No risk. This is the cheapest "juice" in
  the app.

### B3. Symbol morphs (speaker → muted, play → pause)
- **Where** `HUDLeadingView`'s `Image(systemName:)`; `TransportControls`' play/pause button.
- **Trigger** volume crossing the mute threshold or the kind changing; playback toggling.
- **Motion** `.contentTransition(.symbolEffect(.replace.downUp))` — the system's own morph,
  available on our macOS 26 floor.
- **Reduce Motion** SF Symbols' replace effect degrades to a cross-fade automatically; can be
  forced to `.replace.offUp` → plain swap under the setting.
- **Cost/risk** nil; drawn by the symbol renderer. No separate-shape risk. Highest
  Apple-ness-per-line in this document.

### B4. Press feedback on everything tappable
- **Where** `TransportControls` (three buttons, currently `.buttonStyle(.plain)` with no
  pressed state at all), `CaffeinateButton`, and the island's own tap-to-expand.
- **Trigger** mouse-down / mouse-up.
- **Motion** a shared `ButtonStyle`: `scaleEffect(0.88)` + `opacity(0.7)` on press,
  `.spring(response: 0.25, dampingFraction: 0.65)` on release. For the island itself: a 0.5 pt
  inward squash of the *shape* on mouse-down, released on the expand.
- **Reduce Motion** opacity only.
- **Cost/risk** nil for the buttons. The island squash is the risky half — it moves the notch
  silhouette on every click; propose, do not implement, until the owner has seen the buttons.

### B5. "Waiting for you" pulse on the island
- **Where** the island shape; today only `AgentIcon` dims 1 → 0.6 on a 0.9 s repeat.
- **Trigger** a session enters `.waiting` (permission prompt).
- **Motion** two beats then stop: width +6 pt, `.spring(0.4, 0.6)`, 700 ms apart — the
  attention-getting shape of a system alert, not a heartbeat.
- **Reduce Motion** nothing; the amber glyph already carries the meaning.
- **Cost/risk** a *continuous* breathe would be the wrong call — a notch that never stops moving
  is the definition of "lives its own life", which the owner has already rejected once. Two beats
  and silence is the Apple behaviour; recommend only the bounded version.

### B6. Content parallax / matched geometry during the grow
- **Where** `SurfaceView.content` + each feature's peek and expanded views.
- **Trigger** every peek ↔ expanded transition.
- **Motion** today the peek subtree is *replaced* by the expanded subtree (different `.id`), so
  the two crossfade. Drop Zones already dodges this by rebuilding a real `PeekRow` at the top of
  its expanded card, so the glyphs appear exactly where they were — which is why the stash card
  is the best-feeling expansion in the app today. The general version is
  `matchedGeometryEffect` between a presentation's leading/trailing glyphs and their counterparts
  in the expanded card, in a namespace owned by `SurfaceView`, so Music's 18 pt artwork
  physically travels and grows into the 56 pt artwork.
- **Reduce Motion** fall back to today's crossfade.
- **Cost/risk** **the highest-risk item here, and the one I would not implement without a visual
  check.** The views are `AnyView`-erased across module boundaries, so the namespace has to be
  threaded through `Presentation`; and a matched-geometry pair whose source is removed on a
  different curve than its destination arrives on is the classic way to produce a jump — the
  exact "a separate shape slid out" failure the owner rejected. Proposed, not implemented.
  The cheap 80 % of it is to adopt the Drop Zones pattern everywhere: **every expanded card
  starts with a real `PeekRow` at the card's width.** That is a layout change, not an animation
  change, and it is safe.

### B7. Rubber-band on a swipe that goes nowhere
- **Where** `SurfaceView` / `IslandPresenter.cycle`.
- **Trigger** a swipe arrives and the stack has fewer than two cards (today logged as
  "cycle ignored" and otherwise silent).
- **Motion** content offsets 8 pt in the swipe direction and springs back,
  `.spring(response: 0.3, dampingFraction: 0.7)`. The shape does not move.
- **Reduce Motion** nothing.
- **Cost/risk** nil; needs a direction plumbed out of the recogniser for the no-op case, which
  A5 already adds. Small, and it answers "did my gesture register?" — which today it does not.

### B8. HUD bar overshoot
- **Where** `HUDBarView`.
- **Trigger** volume/brightness change.
- **Motion** `.spring(response: 0.24, dampingFraction: 0.72)` instead of `.easeOut(0.12)` — the
  fill runs slightly past the new level and settles.
- **Reduce Motion** unchanged (`nil`, as today).
- **Cost/risk** nil in CPU. **It contradicts the spec's stated constant and, more importantly,
  the system HUD it imitates — macOS's own bar does not overshoot.** Offer it to the owner as a
  deliberate departure ("juicier than macOS"), do not adopt it silently.

### B9. Stash tiles fan in with staggered springs
- **Where** `ThumbnailStack` (settle card) and `StashThumbnailRow` (expanded row).
- **Trigger** files land after a drop; the row appearing on hover-expand.
- **Motion** per-tile `.spring(response: 0.34, dampingFraction: 0.62).delay(index * 0.045)`,
  newest first, each from `scale 1.12` (settle) or `scale 0.92, opacity 0` (row).
- **Reduce Motion** all tiles at rest, opacity only — as today.
- **Cost/risk** nil; ≤ 7 tiles, one-shot. Pairs with A8. The only risk is the stagger reading as
  slow: cap the total added latency at ~0.2 s.

### B10. Shimmer while the agent thinks
- **Where** the Code card's header, behind the stage word.
- **Trigger** `stage == .thinking`.
- **Motion** a 120 pt-wide, 12 % white gradient sweeping across the header every 2.2 s,
  `.linear(2.2).repeatForever(autoreverses: false)` on an `offset` (CA-promotable; **not** a
  `TimelineView`).
- **Reduce Motion** off.
- **Cost/risk** one repeating transform: cheap. But thinking is the state a session spends most
  of its life in, and the existing design deliberately made it the *quietest* glyph in the set
  for exactly that reason. A shimmer running for ten minutes is a distraction. **Recommend
  against**, or gate it to the first 10 s of a thinking run. Listed because it was asked about.

### B11. Numbers that roll instead of cutting
- **Where** `FileCountCircle` ("3"), the Code header's elapsed clock, the HUD's percentage-free
  label, `UsageBarRow`'s figures.
- **Trigger** any numeric change.
- **Motion** `.contentTransition(.numericText(countsDown:))` with the value's own animation.
- **Reduce Motion** the modifier degrades to an opacity swap on its own.
- **Cost/risk** nil; system-drawn. The elapsed clock ticks once a second, so it must use
  `.numericText()` with a cheap animation or it will look busy — apply to the count badge and the
  usage figures first, the clock last.

### B12. Track-change peek (the spec's, finally visible)
- **Where** Music's peek slots, gated on the existing (currently unread) `isShowingTrackChange`.
- **Trigger** the title/artist/artwork changes while playing; already timed to 2.5 s.
- **Motion** the island widens to fit the new title (a `peekSlotWidth` bump, exactly the
  mechanism the HUD already uses), the old artwork cross-dissolves and the new title slides up
  8 pt into place on `.spring(0.32, 0.85)`; the artwork tint behind the expanded card
  cross-fades over 0.4 s rather than cutting.
- **Reduce Motion** cross-fade only, no widening.
- **Cost/risk** medium build cost (a peek variant, not just a curve), zero CPU. No
  separate-shape risk — it is the island's own width animation. This is the "Seam track change"
  the spec promised and the app never shipped.

### B13. The stack dot travels
- **Where** `SurfaceView.stackDots`.
- **Trigger** a swipe or a Cards-menu pick.
- **Motion** instead of two opacities crossfading, a single bright dot that *moves* between
  positions (`matchedGeometryEffect` inside one `VStack`, or an offset), on `pageChange`.
- **Reduce Motion** opacity only, as today.
- **Cost/risk** nil. Small and safe, and it is the confirmation A5's swipe is missing.

### B14. Poof particles — considered and rejected
A literal macOS "poof" cloud on drag-out was considered (Seam's own is a scale+fade, which we
already match). Drawing particles means a `TimelineView` or a `Canvas` running per frame for
0.25 s and a visual vocabulary nothing else in the island uses. Not worth it; the current poof is
already Seam-accurate.

---

## What I will *not* touch

- **Drop Zones' Seam-exact constants**: leave 300 ms, settle 400 ms, poof 250 ms / scale 0.6,
  hover lift spring(0.25, 0.7) at 6 pt / 1.06, targeting spring(0.3, 0.8), AirDrop delay 300 ms.
  They came from frame-by-frame reference footage; changing them is changing the product, not the
  feel. The single exception I would argue for is A8's entrance curve, and only with the spec
  edited in the same commit.
- **HUD hold 1.5 s** and the 96 pt slot width — both are parity with the system HUD.
- **The marquee** (A10) — linear is right.
- **`ThinkingDots`** — already the cheap, correct form.
- **The mirror-window machinery** (`MirrorSwap`, `setSurfaceMirrored`) — it exists precisely to
  keep the panel growing out of the notch instead of reading as a separate window, which is the
  failure mode the owner rejected. Nothing in this audit goes near it.
- **`IslandFrame`'s clamp-inside-`animatableData`** — the thing keeping the notch edges hidden
  during every spring. Untouchable.
- **Anything that makes the island move while the user is not acting**, beyond the bounded
  two-beat waiting pulse (B5) and the existing playing/thinking indicators.

---

## Ranked shortlist — the ten I would do first

1. **Kill the 60 ms content delay and the early content exit (A2)** — content enters *with* the
   shape and shrinks *with* it, on springs, anchored at the notch. The single biggest cause of
   "two objects" today.
2. **Anchor content growth at the notch and soften the entrance (A2)** — `scale 0.96, anchor:
   .top`, `offset(y: -4)`, blur 6 → 2.5: the panel unfolds from the hardware instead of appearing
   in mid-air.
3. **Retune the two geometry springs (A1)** — grow 0.38/0.82, collapse 0.30/0.92: less wobble on
   a wide card, a collapse that arrives instead of creeping.
4. **Give the page swipe a direction (A5, on A3's new `pageChange` curve)** — ±14 pt directional
   content slide inside the clip, one curve for both directions of a page turn.
5. **Make the stack dots move and size (A7 + B13)** — the confirmation the swipe has never had.
6. **Symbol morphs for speaker and play/pause (B3)** — three lines, system-drawn, instantly
   reads as Apple.
7. **Visualizer bars: animate a transform, not a frame height (A9)** — identical pixels, and the
   app's steady-state main-thread cost drops while music plays.
8. **Arrival squash when a card takes the island (B1)** — the completion alert stops being a
   silent crossfade; small, same shape, no separate-shape risk.
9. **Press feedback on the transport buttons (B4, buttons only)** — currently there is literally
   none; a 0.88 scale on a spring is what every Apple control does.
10. **Settle the dropped thumbnails on a spring, and stagger them (A8 + B9)** — the emotional
    peak of Drop Zones stops parking and starts landing. Requires a one-line spec edit.

Just below the line, deliberately: **the four timeline glyphs → CA animations (A11)** — the
biggest CPU win available, held back only because a glyph that visibly restarts is worse than one
that costs CPU, and that needs a real session to judge; **matched-geometry peek → expanded (B6)**
— the most Apple thing in this document and the most likely to reproduce the rejected
"separate shape"; **the HUD bar overshoot (B8)** — juicier than macOS, which may be the wrong
kind of juicy.

---

## Implemented (island core)

Branch `motion/island-core`, everything under `NotchKit/Sources/IslandCore`. Final values as
shipped; the springs all live in `TransitionChoreographer.Spring`, one place.

| Item | What landed | Values |
| --- | --- | --- |
| A2 (shortlist 1) | Content enters and leaves *with* the shape. No delay in, no early exit. | `contentIn` spring 0.26 / 0.9, `contentOut` spring 0.22 / 1.0 |
| A2 (shortlist 2) | Content unfolds from under the notch instead of appearing mid-air. | `scale 0.96 anchor .top`, `offset(y: -4 → 0)`, `blur 2.5 → 0` |
| A1 (shortlist 3) | The two geometry springs retuned. | grow 0.38 / 0.82, collapse 0.30 / 0.92 |
| A3 + A5 (shortlist 4) | A page turn is its own kind, judged by identity before size, and content slides along the axis of the swipe inside the island's clip. | `pageChange` spring 0.34 / 0.86, slide ±14 pt |
| A7 + B13 (shortlist 5) | One bright marker travels the dot track and grows, instead of two opacities crossfading. | dot 3 pt, marker 4 pt, pitch 8 pt, spring 0.3 / 0.8 |
| B1 (shortlist 8) | The island pulses once when a card from *another feature* takes it over without moving it. | a pulse aiming at +8 / +3 pt, reversed after 90 ms, peaking around +4 pt, spring 0.32 / 0.62 |
| A13 | Reduce Motion is live: `MotionSettings` observes `NSWorkspaceAccessibilityDisplayOptionsDidChange` and the surface resolves its curves while drawing. | — |

Two deliberate departures from the proposals above, both in the conservative direction:

- **A1's "collapse the two `.animation` modifiers into one" was not done.** `layout` does *not*
  change when a card is replaced by one of identical size — which is exactly the A6 case — and
  the modifier keyed on `presenter.state` is what animates the content swap there. Merging them
  would have made the commonest arrival silent.
- **B1 fires only when the layout is otherwise unchanged**, i.e. the A6 case, not on every
  arrival. When the arrival resizes the island the geometry spring already owns the frame and is
  already reacting; a second animation on the same value would fight it for no gain. It is also
  skipped when the arriving card belongs to the **same feature** as the one leaving: the HUD
  presents a fresh id at the same 96 pt width when volume gives way to brightness, and a notch
  that twitches while the user holds a volume key is noise. A Code completion alert landing over
  Music still pulses. A real layout change inside the 90 ms cancels the pulse outright, without
  animating, so its deliberately loose spring can never wobble a move the user asked for.

Reduce Motion now has a real form rather than a partial one: the reduced content transition is
opacity alone (it used to still scale 0.94), the page slide and the arrival beat are skipped, and
the dot marker stays dot-sized. Still outstanding for A13's "standardise on one mechanism
repo-wide": `GlyphMotion.isReduced` and `MotionPreference.isReduced` in the feature modules read
`NSWorkspace` directly on every draw — correct, but a third spelling of the same idea.

Untouched here and still open: A6's widening variant, A8/A9/A10/A11/A12, every Part B item other
than B1 and B13. Nothing in this work goes near the mirror-window machinery, `IslandFrame`'s
clamp, or any feature-owned constant.
