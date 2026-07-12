# Backup & restore (operator notes)

General setup and the restore procedure live in the app: **/docs/backup-and-restore**.
Deployment-specific facts:

- rclone remote and bucket are both named `departures-backups`.
- Volume path on the host: `/var/lib/docker/volumes/departures_storage/_data/`.
- Cron: `15 3 * * *` as root; log at `/var/log/departures-backup.log`.
- Restore drill: run download + `PRAGMA integrity_check` against last night's snapshot at each phase
  close and after any change to `bin/backup`; record the output in the phase-close notes.
