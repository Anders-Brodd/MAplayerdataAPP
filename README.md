# Telemetry Analytics Web App

This project replaces the old Google Apps Script with a proper backend + website pipeline:

- Pulls Roblox DataStore entries via Open Cloud API.
- Retries with exponential backoff on 429 rate limits.
- Deep-flattens nested JSON into table-friendly fields.
- Converts timestamps/IDs/enums into human-readable columns.
- Stores normalized records in SQLite.
- Exposes API endpoints for trend analysis and dashboard charts.

## 1. Setup

1. Install Node.js 20+.
2. In this folder, run:

```bash
npm install
```

3. Copy `.env.example` to `.env` and fill values:

```env
PORT=3000
DB_PATH=data/telemetry.db
ROBLOX_API_KEY=your-roblox-open-cloud-key
ROBLOX_UNIVERSE_ID=your-roblox-universe-id
ROBLOX_DATASTORE_NAME=your-roblox-datastore-name
```

## 2. Run

Start the server and dashboard:

```bash
npm run dev
```

Open `http://localhost:3000`.

You can sync from UI or command line:

```bash
npm run sync
```

## 3. Deploy to DigitalOcean

This repo is ready for DigitalOcean App Platform with the included `Dockerfile` and `digitalocean.app.yaml` template.

1. Push the repo to GitHub.
2. In `digitalocean.app.yaml`, the GitHub repo is already set to `Anders-Brodd/MA-Player-Data`.
3. In DigitalOcean App Platform, create an app from the GitHub repo or import the app spec.
4. Set the required values in DigitalOcean to match your `.env`, especially `ROBLOX_API_KEY`, `ROBLOX_UNIVERSE_ID`, and `ROBLOX_DATASTORE_NAME`.
5. If you need SQLite persistence across deploys, mount a volume at `/app/data` and keep `DB_PATH=/app/data/telemetry.db`.

## 4. Important files

- `src/robloxApi.js`: Open Cloud pagination + retry logic
- `src/normalize.js`: flattening + human-readable transformations
- `src/mappings.js`: your ID/enum translation dictionaries
- `src/trends.js`: grouping and trend series calculations
- `src/db.js`: SQLite schema and queries
- `src/server.js`: API endpoints + static dashboard

## 5. Make random IDs human-readable

Update `src/mappings.js` with your game-specific values. Example:

```js
export const idDictionaries = {
  LiftId: {
    "101": "Base Quad",
    "102": "Summit Express"
  },
  EventType: {
    Purchase: "Purchase",
    SessionStart: "Session Start"
  }
};
```

When fields contain IDs/types, the pipeline adds `*_Label` columns.

## 6. Trend analysis endpoints

- `GET /api/overview`
- `GET /api/fields`
- `GET /api/players?limit=100`
- `GET /api/trends?metric=Stats_MoneyIn&bucket=day`
- `GET /api/top?field=LiftId_Label`
- `POST /api/sync`

Use these endpoints for BI tools (Metabase, Grafana, Power BI) if you later move beyond the built-in dashboard.

## 6. Security note

Do not expose your Roblox API key in frontend code or source control.
If your key was shared publicly, rotate it in Roblox Open Cloud immediately.
