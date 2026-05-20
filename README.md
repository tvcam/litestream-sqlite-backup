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

```bash
# dry-run restore to a scratch path (safe; doesn't touch live DB)
sudo ./restore.sh /tmp/restore_test.sqlite3

# point-in-time restore
sudo ./restore.sh /tmp/restore_test.sqlite3 2026-05-20T10:00:00Z
```

To restore over the live database, stop the app and litestream first, move the live file aside, then restore. See `restore.sh` comments.

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
