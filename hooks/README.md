# Webhook ingest (reserved)

WatchCI's primary mode is **local polling**. Webhooks are optional and share the same event queue.

## Event format

Same as poller-produced events in `$DATA_DIR/events/pending/*.json`:

```json
{
  "project": "my-app",
  "kind": "branch|pr",
  "ref": "main",
  "pr_id": null,
  "sha": "abc123...",
  "source": "webhook",
  "ts": 1730000000
}
```

## Helper

[`webhook_ingest.sh`](webhook_ingest.sh) maps raw provider payloads to that JSON:

```bash
export WATCHCI_PROJECT=my-app
cat github-push.json | ./hooks/webhook_ingest.sh github push \
  > data/events/pending/wh-$(date +%s).json
```

Currently implemented mappings:

- `github` / `push`
- `github` / `pull_request` (`opened|synchronize|reopened`)

Stubs (exit 0, no output): gitee / gitlab / gitcode — extend the `case` in the script.

## HTTP listener

Not included. Put any reverse proxy / serverless / `nc` front-end in front of this script. Do **not** publish the config admin UI with the static results site.
