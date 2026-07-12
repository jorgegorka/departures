# Monitoring (operator notes)

General guidance lives in the app: **/docs/monitoring**. Deployment-specific facts:

- Uptime: UptimeRobot free tier, HTTP monitor on `https://<APP_DOMAIN>/up`, alerts to Jorge's email.
- `ops:` credentials block — an IAM user restricted to `ses:SendRawEmail`, `to:` Jorge's address.
- Backup log on the host: `/var/log/departures-backup.log`.
