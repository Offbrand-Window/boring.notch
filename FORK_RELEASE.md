# Offbrand-Window fork: 2.8.2 “Vibing Deer”

Repository: https://github.com/Offbrand-Window/boring.notch
Upstream: https://github.com/TheBoredTeam/boring.notch

This GPL-3.0 fork adds Bluetooth connection and native AirPods handoff activities, Default / Inline / Low Profile HUD layouts, a removable headphone-notification profile with an approval flow, and the face/artwork lock-screen layout with a brief unlock transition. Bluetooth controls are under Settings → HUDs. Low Profile temporarily replaces media artwork with the device icon on the left and connection/return status on the right.

## Known limitations

- The native AirPods stem-volume HUD is not suppressed on the tested macOS 27.2 system. It bypasses keyboard interception.
- The return-to-Mac button uses a private BluetoothServices UIRoute request and awaits native ownership confirmation. The latest request path has not been physically verified with the AirPods.
- Native handoff monitoring uses a narrowly filtered local macOS log stream because CoreAudio misses some ownership changes. No system logs are saved or transmitted. This depends on macOS's current native event format.
- The headphone-banner profile is system-wide while installed, even when the app is closed. It contains only notification settings for com.apple.BTUserNotifications. macOS approval is required. Remove it in Device Management to restore Apple banners.
- The published binary is Apple Silicon only and ad-hoc signed, not Developer ID notarized. macOS may require Open Anyway after downloading.

## Build and release

Build with Xcode 26 or newer. The GitHub build workflow compiles the fork without signing; upstream publishing workflows are retained as inactive references under .github/upstream-workflows.

Run `scripts/build-fork-release.sh VERSION BUILD_NUMBER` on the release Mac. The script builds, ad-hoc signs, packages and EdDSA-signs the archive, verifies its signature, and writes updater/appcast.xml. It requires the fork's existing private Sparkle signing key in the login Keychain under account `Offbrand-Window.boring-notch`. The private key is never committed. Do not generate a different key for an existing release line.

The app embeds the matching public EdDSA key and checks only this fork's HTTPS appcast. Manual Check for Updates is available in the menu and Settings toolbar. Automatic checks follow the user's updater preferences; automatic installation is off by default.

After reviewing a release, commit the source and appcast, push main, and create the matching GitHub release with the signed ZIP asset. Keep the appcast enclosure URL and release asset name unchanged after signing. Future releases must increment CFBundleVersion.

The internal bundle identifier is retained from the earlier local build so existing preferences and the embedded helper continue to work. The installed application name is Boring Notch.
