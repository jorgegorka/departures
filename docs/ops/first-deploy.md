# First deploy (operator notes)

The general runbook now lives in the app: **/docs/self-hosting-quickstart** and **/docs/deployment**.
This file keeps only what is specific to this deployment.

- Image: `ghcr.io/jorgegorka/departures` — registry PAT needs `write:packages`.
- Placeholders still to fill before first deploy: `<VPS_IP>`, `<APP_DOMAIN>` in `config/deploy.yml`
  and the mailer host in `config/environments/production.rb`.
- Phase 9 first-deploy verification: the 8-point checklist results should be recorded in the
  phase-close notes (see `docs/plans/departures-execution-plan.md` Phase 9 status).
