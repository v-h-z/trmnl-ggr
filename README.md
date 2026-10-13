# Golden Globe Race tracker for TRMNL

A full-screen TRMNL plugin for the Golden Globe Race 2026: fleet positions on an
Atlantic/world chart (black land, white sea) on the left, the leaderboard on the
right. Data comes straight from the official YB Tracking feed for the race.

## How it works

- `src/transform.rb` runs on TRMNL **Serverless** (Ruby, standard library only) after each poll. It
  fetches three things from `yb.tl` for race `ggr2026`: `RaceSetup` (skippers,
  boats, course), `leaderboard` (ranks, distance to finish, last 24 h) and the
  binary `AllPositions3` feed, which it decodes with a port of YB's own
  `PositionParser`. It returns a compact JSON (`race`, `boats`, `course`) that
  the Liquid templates render.
- `src/full.liquid` draws the map with the TRMNL framework's Map component
  (MapLibre, `outline` preset restyled to black land / white sea), the course
  line, one dot per boat (bigger for the leader, hollow for retired), rank
  numerals for the top three, and the leaderboard table.
- The polling URL in `settings.yml` is only there because the plugin uses the
  polling strategy. The transform ignores it and fetches everything itself.
- Positions on the YB tracker update every four hours, so `refresh_interval`
  is 120 minutes.

## Local preview

```sh
trmnlp serve          # http://localhost:4567, live reload
trmnlp build --png    # PNGs in _build/ through the same Firefox pipeline TRMNL uses
trmnlp lint
bin/run-transform      # run the transform alone and print its output
```

## Deploy to TRMNL

```sh
trmnlp login   # once; stores the API key in ~/.config/trmnlp/config.yml
trmnlp push    # creates the private plugin and uploads markup + transform
```

The first push writes the plugin `id` into `src/settings.yml`; keep it so later
pushes update the same plugin.

Pushing does **not** fetch any data. TRMNL only refreshes a plugin that is on a
device's playlist, so add it to a playlist and press Force Refresh on the plugin
settings page. Until then "Your variables" shows only the `trmnl` namespace and
the preview renders the "No fleet data yet" notice. That is normal, not a
failure.

Manual alternative: Plugins → Private Plugins → New, strategy Polling with the
URL from `settings.yml`, paste `src/full.liquid` into the Full markup tab and
`src/transform.rb` into the Serverless tab with Ruby selected.

## Notes

- Serverless gives 5 seconds and 128 MB. The transform currently runs in well
  under a second. `AllPositions3` holds the whole race so far (about 150 KB
  five weeks in) and will grow to roughly 1 MB by the finish, which is fine.
- `TRMNLMaps.fit` frames the racing boats on an integer zoom, so the view
  widens by itself as the fleet spreads into the Southern Ocean.
- Chichester Class entries (one stop allowed) are marked "(C)" in the table.
