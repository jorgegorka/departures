# Backup & Restore

Nightly host-cron snapshots of the SQLite databases and the `.eml` archive to
S3-compatible object storage via rclone. RPO: 24 h (accepted in the Phase 9 spec).

## One-time host setup

1. `apt-get install -y sqlite3 rclone`
2. `rclone config` — create a remote named `departures-backups` pointing at the
   S3-compatible provider (type `s3`, provider/endpoint/keys per account), and
   create the `departures-backups` bucket.
3. Copy the script: `scp bin/backup root@<VPS_IP>:/usr/local/bin/departures-backup`
   (re-copy whenever `bin/backup` changes — it is versioned in the repo, executed on the host).
4. Crontab (`crontab -e` as root):

       15 3 * * * /usr/local/bin/departures-backup >> /var/log/departures-backup.log 2>&1

5. Verify the first run manually: `/usr/local/bin/departures-backup` then
   `rclone ls departures-backups:departures-backups`.

**Warning:** `DEPARTURES_BACKUP_REMOTE` MUST point at a dedicated bucket/prefix
used only for these snapshots. The prune step (`rclone delete --min-age`)
recursively deletes everything older than the retention window under that path,
so anything else stored there will be destroyed.

Cron mails/logs handle script failures (`set -euo pipefail` — any failing step
exits non-zero). This is deliberately independent of the app's error notifier.

## Snapshot layout

    <bucket>/<YYYY-MM-DD>/production.sqlite3
    <bucket>/<YYYY-MM-DD>/production_queue.sqlite3
    <bucket>/<YYYY-MM-DD>/emails.tar.gz

Retention: 30 days (pruned by the script).

## Restore procedure

1. Download: `rclone copy departures-backups:departures-backups/<DATE> /root/restore/<DATE>`
2. Integrity check BEFORE touching production:
   `sqlite3 /root/restore/<DATE>/production.sqlite3 "PRAGMA integrity_check;"` → must print `ok`.
   Spot-check: `sqlite3 /root/restore/<DATE>/production.sqlite3 "SELECT count(*) FROM emails;"`
3. Stop the app: `bin/kamal app stop` (from the dev machine).
4. On the host, swap the files in
   `/var/lib/docker/volumes/departures_storage/_data/`:
   move the live `production.sqlite3` (and `-wal`/`-shm` siblings, if present) aside,
   copy the restored file in; same for `production_queue.sqlite3`;
   `tar -xzf /root/restore/<DATE>/emails.tar.gz -C /var/lib/docker/volumes/departures_storage/_data/` to restore the archive.
5. Start the app: `bin/kamal app boot`. Verify `/up`, sign in, open the activity page.

## Restore drill (run at phase close and after any script change)

Steps 1–2 only, against last night's snapshot, in a scratch directory. Record
the date and `PRAGMA integrity_check` output in the phase-close notes.
