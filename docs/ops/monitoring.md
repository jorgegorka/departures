# Monitoring

## Uptime

External monitor pinging `https://<APP_DOMAIN>/up` every 5 minutes
(UptimeRobot free tier or equivalent; HTTP monitor, keyword optional, alert
to Jorge's email). `/up` is excluded from the force_ssl redirect and from
request logs, and reports 200 only when the app boots and connects to its
databases.

## Error alerts

`Ops::ErrorNotifier` (subscribed to `Rails.error` in production) emails
unhandled request/job exceptions through dedicated ops SES credentials —
at most one email per error class per 10 minutes. Configuration lives in
Rails credentials under `ops:`; if the key is absent the notifier is silent.

    ops:
      aws_access_key_id: <IAM key with ses:SendRawEmail only>
      aws_secret_access_key: <secret>
      region: <SES region>
      from: <verified sender, e.g. alerts@APP_DOMAIN>
      to: <Jorge's address>

Accepted trade-off (Phase 9 spec): a total SES outage also silences alerts;
the uptime monitor is the independent backstop.

## Where to look when something is wrong

- `bin/kamal logs` / `bin/kamal logs -r job` — app and worker logs.
- `bin/kamal console` — production Rails console.
- `/var/log/departures-backup.log` on the host — backup runs.
