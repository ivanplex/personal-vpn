# hosts/hong-kong/dashboards

Provisioned into Grafana by `../dashboard.nix`. The provider is declared with
`allowUiUpdates = false`, so **these files are the dashboards** — an edit made
in the browser cannot be saved and will vanish on the next reload. That is the
same trade `services.immich.settings` makes for Immich's System Settings page,
and it is deliberate: this repo is the machine.

| File | uid | What it answers |
|---|---|---|
| `fleet.json` | `fleet-overview` | Is every host reachable, how hard is it working, how much room is left |
| `services.json` | `fleet-services` | Which systemd units are running, failed or flapping |
| `deploys.json` | `fleet-deploys` | Which node is on which commit, and did the last deploy work |

## Editing one

Grafana is still the best editor; it just is not the store.

1. Open the dashboard, change what you want.
2. **Dashboard settings → JSON Model**, and copy the whole document.
3. Paste it over the file here, then set `"id"` back to `null` and check that
   `"uid"` still matches the table above — Grafana rewrites both on export,
   and a changed `uid` provisions a *second* dashboard rather than replacing
   this one.
4. Commit. The provider re-reads every 60 s, so the change lands with the
   deploy and needs no restart.

## The datasource

Every panel references `"uid": "fleet-prometheus"`, which is pinned in
`../dashboard.nix`. Do not let Grafana rewrite it to a generated uid: the pin
is the only reason these dashboards keep working across rebuilds.

## What is deliberately not here

No imported community dashboards (the Node Exporter Full board is 200-odd
panels aimed at a fleet of hundreds, and most of it is noise on a two-core
box), and no panel that needs a plugin. Everything renders with what ships in
`pkgs.grafana`.

The alert rules that watch these same series are **not** here either — they
are Prometheus-side, in `../metrics.nix`, so they keep evaluating when Grafana
is down.
