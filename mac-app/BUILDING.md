# Building Dungeons II Fixer

## How it works

- **CrossOver:** lists every copy in the Applications folder, with its version. Copies anywhere else are ignored. **Other…** lets you pick one yourself.
- **Bottles:** looks in `~/Library/Application Support/CrossOver/Bottles` and in any bottle folder named in CrossOver's preferences. **Other…** adds a folder yourself.
- **Game:** reads the bottle's Steam `libraryfolders.vdf` and `appmanifest_1912410.acf`, so the game is found even on a second drive. **Choose…** lets you point to it by hand.
- **DLL overrides:** written with the selected CrossOver's own Wine (`regedit`), the same way Wine Configuration does it, and then read back to check. If that doesn't work, the app edits the bottle's `user.reg` directly. It only does this while the bottle isn't running, and it keeps a one-time backup called `user.reg.dungeons-fixer-backup`.
- **Undo:** every change is recorded in `~/Library/Application Support/Dungeons II Fixer`. Any file the app overwrites is backed up there first.
- The DLL is checked against the SHA-256 recorded at build time before it's installed.

## Building

On a Mac with Xcode 15 or later, from the `mac-app` folder:

```sh
swift test            # unit tests
scripts/build.sh      # dist/Dungeons II Fixer.app and dist/DungeonsIIFixer-<version>.dmg
```

CI (`.github/workflows/mac-app.yml`) runs the tests and uploads the DMG on every push. You can also start it by hand from the Actions tab and give it a version number.

### Signing and notarization

The quickest way: download a build from the Actions tab into `~/Downloads`, then run `scripts/notarize.sh` on a Mac with your Developer ID certificate. It signs the app, notarizes it and puts the DMG on the Desktop.

To have CI do it on every build instead, add these repository secrets. Without them, CI builds are only ad-hoc signed and need **System Settings → Privacy & Security → Open Anyway** on first launch.

| Secret | Value |
| --- | --- |
| `MACOS_CERT_P12` | Your *Developer ID Application* certificate exported as .p12, base64-encoded |
| `MACOS_CERT_PASSWORD` | The .p12 password |
| `MACOS_SIGN_IDENTITY` | e.g. `Developer ID Application: Your Name (TEAMID)` |
| `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` | Apple ID, team ID and an app-specific password |

### The DLL

The app doesn't keep its own copy of `xgameruntime.dll`. `scripts/build.sh` takes the one in `../src/` and records its SHA-256 in the app, which checks it before installing. Rebuild the app after updating the DLL and that's all.
