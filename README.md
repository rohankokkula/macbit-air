# Macbit Air

A minimal macOS notch app that shows your Fitbit data from the **Google Health API**.

| State | What you see |
|---|---|
| Idle | The notch, with a pulsing live dot on the left and your heart rate on the right |
| Hover | The notch grows to show **Sleep** (last night), **Steps** (today), **Heart rate** (latest bpm, resting HR) |
| Click | It grows again to add one small detail per metric: a sleep-stage bar, hourly step bars, and a 60-minute heart-rate line |
| Right-click | Refresh, Sign in/out, Launch at login, Quit |

Data is fetched every minute, just after the minute boundary.

> **How "real-time" this is:** Fitbit trackers upload to Google's cloud every ~15 min in
> the background, or right away when you open the Fitbit app. Macbit Air polls every minute,
> so new data shows up within ~1 minute of a sync. The footer of the expanded view shows
> how old the newest data point is (e.g. "Fitbit data: 4m ago").

## Requirements
- macOS 14 (Sonoma) or newer. A notched MacBook works best; other screens get a small pill in the menu bar.
- Xcode 16 or the Swift 5.9+ command-line tools.
- A Google account linked to your Fitbit (the Google Health API reads Fitbit data).

## 1. Create a Google OAuth client (one-time, ~5 min)
1. Go to <https://console.cloud.google.com/> and create a project, e.g. "Macbit Air".
2. **APIs & Services → Library**: search for **Google Health API** and click **Enable**.
3. **Google Auth Platform → Branding / Audience**: choose **External**, keep the app in **Testing**,
   and add your own Google account under **Test users**.
4. **Data Access → Add scopes**: add these three read-only scopes:
   - `.../auth/googlehealth.activity_and_fitness.readonly`
   - `.../auth/googlehealth.health_metrics_and_measurements.readonly`
   - `.../auth/googlehealth.sleep.readonly`
5. **Clients → Create client → Application type: Desktop app**. Copy the **Client ID** and **Client secret**.

## 2. Add your client to Macbit Air
The first launch creates `~/Library/Application Support/MacbitAir/config.json`. You can
also create it yourself:

```json
{
  "clientId": "1234-abc.apps.googleusercontent.com",
  "clientSecret": "GOCSPX-..."
}
```

Right-click the notch and choose **Open config folder** to find it.

## 3. Build and run
Quick run from the terminal:

```bash
swift run -c release
```

Or build a real `.app` (`build/Macbit Air.app`), which is needed for "Launch at login":

```bash
./scripts/build-app.sh
```

```bash
open "build/Macbit Air.app"
```

Hover over the notch and click **Sign in**. Your browser opens Google's consent screen
(you'll see "Google hasn't verified this app": click **Continue**, since it's your own
app). After you approve, the tab says "Macbit Air is connected" and the numbers appear.
Tokens are stored in your login Keychain.

You can also open `Package.swift` in Xcode and press ▶.

## How it works
```
Sources/MacbitAir/
  App.swift                    accessory app (no Dock icon)
  Config.swift                 config.json loader
  Auth/OAuth.swift             Google OAuth: PKCE + loopback redirect on 127.0.0.1:<random>
  Auth/Keychain.swift          token storage
  Data/GoogleHealthClient.swift  REST client + all API names in HealthDataType + parsers
  Data/HealthStore.swift       60 s polling loop, caching, backoff
  Data/JSON.swift              tolerant JSON reader
  Notch/…                      panel, geometry, notch shape, hover/expand state
  Views/…                      metric tiles and the three mini charts
```

**API calls per minute:** steps for the last 3 h and heart rate for the last 15 min,
merged into a local cache. Every 5 or 10 min the app re-fetches the whole day of steps
and the full hour of heart rate, to catch late syncs. Sleep is fetched every 15 min and
resting HR every hour. On HTTP 429 the app backs off, and it pauses while the display
sleeps.

Endpoints used (`GET https://health.googleapis.com/v4/users/me/dataTypes/{type}/dataPoints?filter=…`):

| Metric | type | filter |
|---|---|---|
| Steps | `steps` | `steps.interval.start_time >= "<RFC3339>"` |
| Heart rate | `heart-rate` | `heart_rate.sample_time.physical_time >= "<RFC3339>"` |
| Sleep | `sleep` | `sleep.interval.end_time >= "<RFC3339>"` |
| Resting HR (optional) | `daily-resting-heart-rate` | `daily_resting_heart_rate.date >= "YYYY-MM-DD"` |

## Troubleshooting
- **"API 400 … INVALID_DATA_POINT_FILTER"** or **"API 404"**: a data type or filter field
  name differs from what the app expects. All names are in `HealthDataType` in
  `Data/GoogleHealthClient.swift`; check them against
  <https://developers.google.com/health/filters>.
- **A metric stays "—" with no error**: the response parsed, but a field name differs.
  The parsers in `HealthParser` (same file) look for `count`, `beatsPerMinute`,
  `startTime`/`endTime`, `physicalTime` and `stages`. Compare them with a real response
  from the API Explorer.
- **"API 403 MISSING_OAUTH_SCOPE"**: add the scope in the Cloud console, then Sign out and Sign in again.
- **Sign-in tokens expire after 7 days**: Google does this to apps still in *Testing*. Publish
  the app to *In production* in the Audience page (you can stay unverified for personal use).
