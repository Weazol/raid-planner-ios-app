# Raid-Planner iOS app

A native iOS app around the Raid-Planner web frontend, built with [Capacitor 8](https://capacitorjs.com)
(Swift Package Manager, no CocoaPods). The web app, its API and the Keycloak realm need no change.

## How it works

The app is a native shell whose `WKWebView` loads the hosted web app. Its address is entered in
the app, so no host is built in (see [Addresses](#addresses)):

- **Same origin as in the browser**: API calls, Keycloak login and silent SSO behave exactly like in
  Safari. Every web deploy reaches the app at once; a new app build is only needed for native changes.
- The login server (Keycloak host) is allowed for navigation, so the login page opens inside the app.
  Other external links (e.g. PayPal) and everything opened in a new tab go to Safari.
- Native touches (`ios/App/App/AppViewController.swift`):
  - the web view stays inside the safe area (notch / Dynamic Island / home indicator), the strips
    around it have the web app's header color; status bar light
  - **new design by default**, also on the iPad (the web app would start the iPad in the old one);
    a choice made in the profile menu still wins
  - swipe from the edge = back / forward
  - **pull to refresh**; with unsaved input (e.g. planning notes) it asks first, because WKWebView
    ignores the browser's `beforeunload` prompt
  - own **offline page** (`www/error.html`) with "Erneut versuchen" and automatic retry when the
    connection is back; cancelled navigations (links handed to Safari) do not trigger it
  - app icon and launch screen from the Raid-Imperator logo (`npm run icons`)
- The web app can recognize the app by the user agent suffix `RaidPlannerApp/1.0`.

Why not bundle the Angular build into the app: the bundle would run on `capacitor://localhost`,
i.e. cross-origin to the API and to Keycloak. That would need CORS in the backend, extra Keycloak
redirect URIs/web origins and a different login flow (silent SSO iframes do not work cross-site in
WKWebView). The shell avoids all of it.

## Addresses

On the first start the app shows a setup page (`www/index.html`) with two fields:

| Field                      | Example                              |
|----------------------------|--------------------------------------|
| Adresse des Raid-Planners  | `https://raid-planner.example.org` (`https://` may be left out) |
| Login-Server               | `keycloak.example.org`; suggested from the first field (`keycloak.` + its parent domain) |

The values are stored in the app (`UserDefaults`, keys `appUrl` / `authHost`) and can be changed
later in the **iOS Settings app → Raid-Planner** (`Settings.bundle`; applied when the app comes back
to the foreground) or via "Adresse ändern" on the offline page. Only the bundled setup page can
save them, never the loaded web app. Validation and normalization: `ios/App/App/AppSettings.swift`.

Capacitor reads the server address once per bridge, so after a change `RootViewController` creates
a new bridge (`AppBridgeViewController.instanceDescriptor()` sets `serverURL` and adds the login
server to the allowed navigation hosts).

## Build and run (needs a Mac with a current Xcode)

```bash
npm ci
npm run sync            # copies www/ + capacitor.config.json into the Xcode project
npm run open            # opens ios/App/App.xcodeproj in Xcode
```

In Xcode: target **App** → *Signing & Capabilities* → choose your **Team** (an Apple ID is enough
to start; Xcode adds it under *Settings → Accounts*). If the bundle id `de.weazol.raidplanner` is
taken, change it there. Connect the iPhone, enable developer mode on it
(*Settings → Privacy & Security → Developer Mode*), select it as run destination, ▶.
Do not commit the team id; for CI-signed builds it would go into GitHub secrets.

| Account                      | What works                                                                 |
|------------------------------|----------------------------------------------------------------------------|
| free Apple ID                | own devices, the app must be re-installed from Xcode every 7 days          |
| Apple Developer Program (99 $/year) | TestFlight for the raid group (internal testers without review), 90-day builds |

App Store: a pure web shell is likely rejected (guideline 4.2 "minimum functionality"); for a
guild tool, TestFlight is the practical way anyway.

Version: *General → Identity* (`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`), raise the build
number for every TestFlight upload (*Product → Archive → Distribute App*).

## CI

[`.github/workflows/ios.yml`](.github/workflows/ios.yml) compiles the app unsigned for the iOS
simulator on every push.

## Changing things

| What                         | Where                                                                   |
|------------------------------|-------------------------------------------------------------------------|
| app id, name, colors         | `capacitor.config.json` (app id also in Xcode)                          |
| test against a local stack   | enter `http://<pc-ip>:4200` and the local Keycloak host in the app (`NSAllowsLocalNetworking` in `Info.plist` permits plain http in the local network); the local realm's redirect URIs must allow that host |
| setup page / settings        | `www/index.html`, `ios/App/App/Settings.bundle/Root.plist`, `ios/App/App/AppSettings.swift` |
| native behavior              | `ios/App/App/AppViewController.swift`                                    |
| icon / launch screen         | `scripts/generate-icons.mjs`, `npm run icons`                            |
| offline page                 | `www/error.html`, then `npm run sync`                                    |
