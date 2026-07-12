<!-- SEED: re-run /impeccable document once the new visual system is implemented, to capture the actual tokens and components. -->

---
name: Departures
description: Self-hosted transactional email, designed like a first-class product
---

# Design System: Departures

## 1. Overview

**Creative North Star: "The Sunlit Terminal"**

Departures borrows its calm from a well-run airport terminal at dawn: mostly quiet, highly legible surfaces where one warm signal — the coral of a sunrise departure board — tells you exactly where to look. The system is restrained by doctrine: tinted neutrals carry almost everything, and the single warm coral/sunset-orange accent appears only where attention is earned (primary actions, live signals, the anomaly in a sea of healthy rows). The craft bar is Linear and Cursor — dense, fast, precisely finished — but delivered with a warmer, friendlier voice, because this dashboard must welcome the whole team, not just the engineer who deployed it.

The system explicitly rejects the AWS console it exists to replace: no cramped gray config walls, no jargon-dense tables. It equally rejects the generic admin-template look — no sidebar-of-icons, no interchangeable card grids.

**Key Characteristics:**
- Restrained neutral surfaces with one warm coral accent at ≤10% of any screen
- Linear/Cursor-grade density and finish, warmed by a humanist voice
- Calm at rest; sharp, information-dense when investigating
- Responsive motion: feedback and smooth transitions, never choreography

## 2. Colors

Restrained tinted neutrals anchored by one warm coral / sunset-orange accent.

### Primary
- **Sunset Coral** (warm coral / sunset-orange family; exact value `[to be resolved during implementation]`): primary actions, live-activity signals, focused states. Its rarity is the point.

### Neutral
- **Tinted neutral ramp** (`[to be resolved during implementation]`): canvas, surfaces, borders, and ink, tinted subtly toward the brand's own hue — never the default warm-cream band, never flat gray. Light and dark themes both required.

### Named Rules
**The One Signal Rule.** Sunset Coral covers no more than 10% of any screen. If two things compete for it, neither gets it.
**The Status Is Not Decoration Rule.** Delivery statuses (delivered, bounced, complained…) carry semantic colors plus an icon or label — never color alone (WCAG AA, colorblind-safe).

## 3. Typography

**Body/UI Font:** single humanist, warm sans `[font to be chosen at implementation]`, multiple weights — no second display family.

**Character:** friendly and highly readable at dense table sizes; precision through weight and spacing, not through a cold geometric skeleton.

### Named Rules
**The One Family Rule.** One sans, many weights. Monospace appears only where content is literally code: message IDs, API keys, headers, payloads.

## 4. Elevation

Flat by default. Depth comes from tonal layering (canvas → surface → raised surface) and hairline borders; shadows, if any, respond to state (open menus, dialogs) rather than decorating resting surfaces.

## 5. Components

`[No components yet — this is a seed. The next scan-mode run documents real primitives.]`

## 6. Do's and Don'ts

### Do:
- **Do** keep healthy states quiet and let density surface on demand — "calm by default, sharp on demand."
- **Do** hold every screen to WCAG 2.1 AA: ≥4.5:1 body contrast, visible focus, reduced-motion alternatives, in both themes.
- **Do** hold finish quality to the Linear/Cursor bar: aligned baselines, deliberate spacing, no default-styled anything.

### Don't:
- **Don't** look like the AWS console — no wall-of-config, no jargon-dense tables (PRODUCT.md anti-reference, verbatim).
- **Don't** look like a generic Bootstrap/Tailwind admin template — no sidebar-of-icons, no card-grid sameness (PRODUCT.md anti-reference).
- **Don't** exceed the One Signal Rule: coral on more than 10% of a screen means something lost its priority.
- **Don't** encode any delivery status by color alone.
