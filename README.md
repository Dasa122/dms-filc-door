# dms-filc-door

A bar widget for Dux Shell (DMS 2.0) that opens a door at a filc-equipped school.

## Requirements

- Dux Shell 2.0 (`dux-shell` >= 2.0.0, formerly DankMaterialShell)
- `curl`
- a filc account that owns a door card

This plugin does NOT work on DMS 1.6: it uses a different plugin path and widget classes.

## Install

Clone into the DMS plugin dir and enable it:

```bash
git clone https://github.com/Dasa122/dms-filc-door.git ~/.config/dms/plugins/filcDoor
dms ipc call plugin-scan scan
dms ipc call plugins enable filcDoor
```

Then add it to the bar, either via Settings → Dank Bar → Widgets, or by adding `{ "id": "filcDoor", "enabled": true }` to `barConfigs[].rightWidgets` in `~/.config/dms/settings.json`.

## Configure

Settings → Plugins → filc Door. Paste an API key (filc → Settings → API keys → Create; max 32 chars; shown once), set the base URL (`https://filc.petrik.hu`), press **Fetch doors**, and pick a door. Optional: show a text label next to the icon.

## Behaviour

Clicking the door icon sends the unlock request for the configured door. While the request is in flight the icon pulses, there is a 3 s cooldown between clicks, and a toast reports success or failure.

Settings keys the plugin stores: `baseUrl`, `apiKey`, `target`, `label`, `showLabel`.

## How it talks to filc

- `GET {base}/api/doorlock/self/cards` with `Authorization: Bearer <key>` returns `{ items: [{ id, name, enabled, frozen, authorizedDevices: [{ id, name }] }], total }`.
- `POST {base}/api/doorlock/self/cards/{cardId}/activate` with `{"deviceId": "<id>"}` (or `{}` when the card has exactly one authorised reader) returns 200 with an audit row. Errors are `{code, message, status}`.

## Security

The API key is a bearer token for your filc account. It is stored in plaintext in `~/.config/dms/plugin_settings.json` (DMS has no secret store); `chmod 600` on that file is worth doing.

The key is passed to curl through the process environment, never as a command-line argument, so it does not appear in `ps` or shell logs.

## Limitations

- A 2xx means the unlock message was published to the reader, not that the door physically opened. The server does not wait for an ack; an offline reader still returns 200.
- `activate` is ownership-scoped: the key must belong to a user who owns the card, otherwise the request returns 404.
- The API is rate-limited server-side; `429 RATE_LIMITED` is possible.
- Only tested against the author's own deployment (`filc.petrik.hu`); the base URL is configurable for other Chronos instances.

## Troubleshooting

- `dms ipc call plugins status filcDoor` — expect `loaded`.
- `dms ipc call plugins reload filcDoor` — reload after editing the plugin.
- `journalctl --user -f | grep -i filcDoor` — QML errors.

Error codes:

| code | meaning |
| --- | --- |
| `UNAUTHORIZED` | bad or expired API key |
| `NOT_FOUND` | not your card |
| `CONFLICT` | frozen or disabled card |
| `FORBIDDEN` | reader not authorised for that card |
| `BAD_REQUEST` | multi-reader card with no deviceId |

## License

MIT
