# Product

## Register

product

## Platform

web

## Users

Small development teams sharing a workspace. Several engineers run Departures for the apps they build, so multi-user concerns — roles, invitations, the workspace switcher — matter day to day. They live in the dashboard while wiring up sending domains, managing API keys, and watching mail flow for the products they operate.

## Product Purpose

Departures is a self-hosted transactional email platform: a Rails control plane for Amazon SES. Apps send through `POST /api/emails`; Departures delivers via SES, tracks the full delivery lifecycle, manages suppressions, relays events to customer webhooks, and renders a live activity dashboard. Success is twofold and equal: calm monitoring by default — the team confirms in seconds that mail is flowing healthily — and sharp investigation when something goes wrong, finding the exact email, event, or suppression and diagnosing it fast.

## Positioning

Own your email pipeline. A Postmark/Resend-class experience you run yourself: your infra, your data, SES rates. Every screen reinforces that self-hosting doesn't mean settling for less polish or less visibility.

## Brand Personality

Friendly, clear, approachable. The dashboard softens SES's complexity and stays welcoming even to less technical teammates — plain language over jargon, guidance over raw configuration. Reference: Linear, specifically its density, keyboard speed, and restrained visual polish; Departures aims for that level of craft delivered with a warmer, more approachable voice.

## Anti-references

- The AWS console — the thing Departures exists to replace. No wall-of-config, no jargon-dense tables, no making the user feel they need certification to send an email.
- Generic admin templates — no Bootstrap/Tailwind-admin look, no sidebar-of-icons with card-grid sameness. The dashboard should feel designed for email operations specifically.

## Design Principles

- **Calm by default, sharp on demand.** Healthy state reads quietly in seconds; investigation tools surface density and detail only when the user goes looking.
- **Translate, don't transcribe.** Never pass SES/SNS jargon straight through — every status, error, and setting speaks the user's language and says what to do next.
- **Ownership feels first-class.** Self-hosted must never look self-hosted: the polish bar is commercial products like Linear, so running your own pipeline feels like an upgrade, not a compromise.
- **Approachable to the whole team.** A less technical teammate can read activity, understand a bounce, and act on a suppression without an engineer translating.

## Accessibility & Inclusion

WCAG 2.1 AA: ≥4.5:1 body-text contrast, full keyboard navigability, visible focus states, and reduced-motion alternatives (a `prefers-reduced-motion` guard already exists in `base.css`). Light and dark themes both meet the bar.
