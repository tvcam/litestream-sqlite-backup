# litestream-sqlite-backup

Continuous SQLite backup to S3-compatible object storage using [Litestream](https://litestream.io).
Streams the WAL to a bucket in near-real-time. Restore to any point in time within the retention window with one command.

Tested on Ubuntu hosts running Rails apps deployed via Kamal, with SQLite databases on a host-mounted volume.

## Layout

- `litestream.yml.example` — replication config template
- `litestream.env.example` — bucket credentials template (kept out of `litestream.yml` so the yaml can be checked in)
- `install.sh` — installs litestream + writes config + enables the systemd unit
- `restore.sh` — restores the database from S3 to a target path
- `lifecycle.json` — optional Hetzner/S3 bucket lifecycle policy (e.g. expire old backups after N days)

## Quickstart

```bash
git clone git@github.com:tvcam/litestream-sqlite-backup.git
cd litestream-sqlite-backup

# 1. fill in your values
cp litestream.yml.example litestream.yml
cp litestream.env.example litestream.env
$EDITOR litestream.yml   # set db path, bucket, prefix, endpoint, region
$EDITOR litestream.env   # set access key + secret

# 2. install on the server (run as a user with sudo)
sudo ./install.sh
```

Watch it run:

```bash
sudo systemctl status litestream
sudo journalctl -u litestream -f
```

## Restore

Litestream restores from the latest known state by default, or from any timestamp
within the retention window for point-in-time recovery.

### Dry-run restore (safe — doesn't touch the live DB)

Always do this first to confirm the backup is intact:

```bash
sudo ./restore.sh /tmp/restore_test.sqlite3
sqlite3 /tmp/restore_test.sqlite3 "PRAGMA integrity_check; SELECT COUNT(*) FROM sqlite_master;"
rm /tmp/restore_test.sqlite3
```

Integrity check should return `ok` and the schema count should be non-zero.

### Point-in-time restore

Restore to a specific UTC timestamp (ISO 8601):

```bash
sudo ./restore.sh /tmp/recovered.sqlite3 2026-05-20T10:00:00Z
```

Common case: "undo the bad migration that ran at 09:47." Pick a timestamp
*before* the bad event. The restore goes to a scratch path; inspect it, then
swap in if it looks right.

### Live restore (over the running database)

Only do this when the live DB is broken or you've confirmed via dry-run that
the recovered state is what you want.

```bash
DB=/path/to/your/production.sqlite3

# 1. stop the app so it doesn't write during restore
kamal app stop                    # or: docker stop <container>

# 2. stop litestream so it doesn't fight the restore
sudo systemctl stop litestream

# 3. move the live DB aside — litestream refuses to overwrite an existing file
sudo mv "$DB" "${DB}.broken"
sudo mv "${DB}-wal" "${DB}-wal.broken" 2>/dev/null || true
sudo mv "${DB}-shm" "${DB}-shm.broken" 2>/dev/null || true

# 4. restore (optionally with -timestamp)
sudo ./restore.sh "$DB"
# or for PITR:
# sudo ./restore.sh "$DB" 2026-05-20T10:00:00Z

# 5. fix ownership to match what the app expects (check before restore!)
sudo chown <app-user>:<group> "$DB"

# 6. start app, then litestream
kamal app start
sudo systemctl start litestream
```

### Gotchas

- **"file already exists" error** — litestream refuses to overwrite. Move the
  target aside first (step 3 above).
- **Ownership** — after restore the file is owned by whoever ran the restore
  (typically root). The app may not be able to write to it. `chown` to the
  app's runtime user before starting the app.
- **WAL/SHM sidecar files** — SQLite creates `-wal` and `-shm` files next to
  the DB during normal operation. Move those aside too on a live restore; a
  stale WAL next to a fresh DB will confuse SQLite.
- **Timestamp must be UTC** — `2026-05-20T10:00:00Z`, not local time. Convert
  first if needed.
- **Outside the retention window** — if you ask for a timestamp older than
  what's retained, litestream restores from the oldest available snapshot
  instead of erroring loudly. Check the journal output of the restore.

### Verify after restore

```bash
sqlite3 "$DB" "PRAGMA integrity_check;"     # expect: ok
sqlite3 "$DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table';"
# spot-check a recent row from a known table
sqlite3 "$DB" "SELECT * FROM your_table ORDER BY id DESC LIMIT 1;"
```

## Retention

**Do not set `retention:` in `litestream.yml`.** On litestream 0.5.x the key is
silently accepted but ignored — the journal shows only built-in compaction monitors
firing, never a retention sweep. Use a **bucket lifecycle policy** instead:
object storage deletes old data, litestream stays untouched.

`lifecycle.json` in this repo expires every object in the bucket after 7 days.
To use a different window, edit the `Days` field. To scope to one app instead of
the whole bucket, change `"Prefix": ""` to `"Prefix": "your-app/"`.

Apply via AWS CLI (works against Hetzner since it's S3-compatible):

```bash
AWS_ACCESS_KEY_ID=$LITESTREAM_ACCESS_KEY_ID \
AWS_SECRET_ACCESS_KEY=$LITESTREAM_SECRET_ACCESS_KEY \
aws --endpoint-url https://hel1.your-objectstorage.com \
    s3api put-bucket-lifecycle-configuration \
    --bucket YOUR_BUCKET \
    --lifecycle-configuration file://lifecycle.json
```

Verify it stuck:

```bash
AWS_ACCESS_KEY_ID=$LITESTREAM_ACCESS_KEY_ID \
AWS_SECRET_ACCESS_KEY=$LITESTREAM_SECRET_ACCESS_KEY \
aws --endpoint-url https://hel1.your-objectstorage.com \
    s3api get-bucket-lifecycle-configuration --bucket YOUR_BUCKET
```

Lifecycle rules apply to all objects under the prefix, so existing snapshots/WAL
older than the window will be cleaned up on the bucket's next sweep (typically
within 24h).

## Notes

- Credentials live in `/etc/litestream.env` (mode 600, root-owned) and are referenced from `litestream.yml` via `${LITESTREAM_ACCESS_KEY_ID}` / `${LITESTREAM_SECRET_ACCESS_KEY}`.
- The systemd unit shipped by the .deb does not source env files; `install.sh` adds a drop-in at `/etc/systemd/system/litestream.service.d/override.conf` for that.
- Only the primary SQLite DB is replicated by default. Solid Queue / cache / cable DBs are intentionally excluded — rebuildable from the app on restore.
