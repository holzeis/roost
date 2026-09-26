# Release pipeline setup (TestFlight / Play Store)

One-time setup for `.github/workflows/release.yml`, which builds and ships
the app via GitHub Actions instead of a local Xcode/Android Studio export.
Kept separate from `docs/ios-dev-setup.md`, which is about running the app
on your own machine/simulator, not shipping it.

## iOS — TestFlight

The workflow needs six repo secrets (Settings → Secrets and variables →
Actions → New repository secret). None of these are ever pasted into a
conversation with Claude — generate/export them yourself and paste directly
into GitHub's secret form.

1. **App Store Connect app record.** In
   [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → My Apps
   → **+** → New App, bundle ID `me.holzeis.roost.roost` (must already exist
   as an Identifier under Certificates, Identifiers & Profiles — see
   `docs/ios-dev-setup.md`'s push notifications section for that). Name:
   **Roost Family Chat** — plain "Roost" is already taken on the App Store
   (names must be globally unique across every developer's account). This
   is only the App Store Connect/TestFlight listing name; it's unrelated to
   `CFBundleDisplayName` in `Info.plist` (still plain "Roost"), which is
   what actually shows under the icon on a device's home screen.

2. **Distribution certificate** (`IOS_DIST_CERTIFICATE_BASE64`,
   `IOS_DIST_CERTIFICATE_PASSWORD`). In Xcode: Settings → Accounts → your
   team → Manage Certificates → **+** → Apple Distribution. Then export it
   as a `.p12`: Keychain Access → find the new certificate under "My
   Certificates" → right-click → Export → set any password (this becomes
   `IOS_DIST_CERTIFICATE_PASSWORD`). Base64-encode the file and put the
   result in `IOS_DIST_CERTIFICATE_BASE64`:
   ```sh
   base64 -i DistributionCertificate.p12 | pbcopy
   ```

3. **Provisioning profile** (`IOS_PROVISIONING_PROFILE_BASE64`). In
   developer.apple.com → Certificates, Identifiers & Profiles → Profiles →
   **+** → App Store distribution, select the `me.holzeis.roost.roost`
   Identifier and the distribution certificate from step 2. **Name it
   exactly `Roost App Store`** — `app/ios/ExportOptions.plist` references
   that name, not the downloaded filename. Download the `.mobileprovision`
   and base64-encode it the same way:
   ```sh
   base64 -i "Roost App Store.mobileprovision" | pbcopy
   ```

4. **App Store Connect API key** (`APP_STORE_CONNECT_KEY_ID`,
   `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_KEY`). In App Store
   Connect → Users and Access → Integrations → App Store Connect API →
   Generate API Key, App Manager role (or higher) is enough. Note the **Key
   ID** and **Issuer ID** (both shown on that page, non-secret identifiers)
   and download the `.p8` **once** — Apple doesn't let you re-download it.
   `APP_STORE_CONNECT_KEY` is that file's raw contents.

5. Once all six secrets exist, trigger a run manually: Actions →
   Release → Run workflow → pick the `ios` job (or let it run both). The
   first run is the one likely to need debugging — this pipeline can't be
   verified without real Apple credentials, so treat failures as expected
   until proven otherwise, not a sign the setup is wrong.

6. A successful run lands the build in App Store Connect → TestFlight
   (processing takes a few minutes). Add yourself as an internal tester
   there to install it without a cable — this is what unblocks testing when
   a device's port/cable is broken, since TestFlight installs entirely
   over the air.

### If `xcodebuild` rejects `app-store-connect` as the export method

`app-store-connect` replaced the older `app-store` value in `ExportOptions.plist`
somewhere around Xcode 15. If the GitHub-hosted `macos-latest` runner ever
ships an older Xcode than that, switch `app/ios/ExportOptions.plist`'s
`method` key back to `app-store`.

## Android — Play Store internal testing track

Not wired up yet — `release.yml`'s `android` job still has its signing and
upload steps as TODOs. Needs a release keystore
(`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`,
`ANDROID_KEY_PASSWORD`) and a Play Console service account
(`GOOGLE_PLAY_SERVICE_ACCOUNT`) before it can run. Ask for this to be
finished when it's actually needed.
