---
target: the top menu (app/views/layouts/_nav.html.erb)
total_score: 25
p0_count: 2
p1_count: 2
timestamp: 2026-07-17T06-56-48Z
slug: app-views-layouts-nav-html-erb
---
**Method: dual-agent (A: aa2e52f0bf6909c7b · B: acfaf2ef3806e5ec0)**

# Design Critique: Departures Top Menu (`app/views/layouts/_nav.html.erb`)

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | Good coral active indicator, but overflow-scroll can push the current item off-screen; `current_page?` exact-match means sub-pages don't light up their section |
| 2 | Match System / Real World | 3 | "Security" vague for session management; "Send test" is a verb among nouns |
| 3 | User Control and Freedom | 3 | Persistent nav, no traps |
| 4 | Consistency and Standards | 2 | Mixes tenancy scopes (personal "Security" beside project data) and verbs with nouns |
| 5 | Error Prevention | 3 | Low-risk surface |
| 6 | Recognition Rather Than Recall | 2 | Flat 15-item wall forces linear scanning; hidden overflow breaks recognition |
| 7 | Flexibility and Efficiency | 2 | No keyboard shortcuts, no grouping; hidden horizontal scroll unreachable for mouse-wheel users |
| 8 | Aesthetic and Minimalist Design | 1 | 15 equal-weight items — the antithesis of "calm by default" |
| 9 | Error Recovery | 3 | n/a to nav; Docs link present |
| 10 | Help and Documentation | 3 | Docs link in identity row |
| **Total** | | **25/40** | **Acceptable — significant improvements needed** |

## Anti-Patterns Verdict

Crafted skin over generic-admin bones. Styling is on-brand (coral active state, aria-current, focus-visible, restrained neutrals) but the IA is one-tab-per-database-table — the AWS-console anti-reference PRODUCT.md forbids. Tell: `overflow-x: auto; scrollbar-width: none` on `.nav`.

Deterministic scan: clean — detect.mjs exit 0, zero findings on `_nav.html.erb` and `application.html.erb`. No false positives. Browser overlay unavailable (Chrome extension not connected; Playwright blocked at login, no credentials entered).

## Priority Issues

- **[P0] No hierarchy — 15 flat peers.** Blows working memory, fails 7/8 cognitive-load checks, reads as generic admin. Fix: collapse to 4–5 top-level entries with grouped disclosure. (/impeccable shape, /impeccable distill)
- **[P0] Hidden-scrollbar overflow as the entire responsive strategy.** At ~900px items vanish past the right edge with no scrollbar; Security/Send test unreachable for mouse-wheel-only users. Same bug on `.workspace-switcher`. Fix: grouping + real collapse pattern. (/impeccable adapt)
- **[P1] Scope mixing.** User-scoped "Security" and workspace-scoped "Workspace"/"Audit log" inside project-scoped nav; "Send test" is an action, not a place. Fix: Security → user menu; Workspace/Audit log → workspace menu; Send test → button.
- **[P1] No skip-to-content link.** `<main id="main">` exists but 15 tab-stops precede content. Fix: visually-hidden skip link. (/impeccable audit)
- **[P2] Dashboard / Activity / Reports conceptual overlap.** Three "show me what's happening" destinations. Fix: consolidate or nest.

## Recommended IA (mirrors routes' tenancy tiers)

- Top-level nav (~4): Overview (Dashboard ± Reports) · Activity · Emails · Deliverability ▾ (Bounces, Suppressions)
- Configure ▾: Domains, Sources, Templates, Webhooks, API keys
- Workspace menu (identity row, capability-gated): Workspace settings, Audit log
- User/avatar menu (identity row): Security, Sign out
- Send test → action button

## Persona Red Flags

- **Alex (power user):** eye-scans 15 words to hit "Emails"; no shortcuts; no spatial anchors for muscle memory; targets can live in invisible overflow.
- **Sam (a11y):** 15 tab-stops before content every page (no skip link); nav is one undifferentiated 15-link group. Positives: aria-current, aria-label="Primary", :focus-visible all correct.
- **Non-technical teammate ("why didn't the customer get the email?"):** 8 equally-plausible entry points, zero guidance — fails "approachable to the whole team."

## Minor Observations

- Workspace switcher renders one form-button per workspace; should be a dropdown.
- `current_page?` exact-match: detail pages don't highlight their section — use path-prefix matching when grouping.
- No tooltips for ambiguous labels ("Security", "Sources").

## Questions to Consider

1. Do Dashboard, Activity, and Reports need to be three destinations?
2. Why is "why didn't this email arrive" scattered across three ungrouped tabs?
3. Why aren't Workspace, Audit log, and Security in the identity tier where their scope belongs?
