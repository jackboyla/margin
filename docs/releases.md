# Release packaging

## Build a DMG

On macOS 26 or later with Xcode 26.3 or later and Swift 6.2 or later, build both architectures and package the app:

```sh
export MARGIN_VERSION=0.1.0
MARGIN_UNIVERSAL=1 bash scripts/build-app.sh
bash scripts/package-dmg.sh
```

This produces `dist/Margin-0.1.0-macOS.dmg` and its `.sha256` file. The DMG contains `Margin.app` and an Applications link. Version values accept `x.y.z` and suffixes such as `0.1.0-beta.1`; the app's numeric bundle version uses `x.y.z`. Without `MARGIN_VERSION`, scripts use the version in `Resources/Info.plist`. Keep the same version when building and packaging.

Local builds target the current architecture unless `MARGIN_UNIVERSAL=1` requests Apple silicon and Intel. Both require macOS 26 or later. Packaging verifies the app signature and disk image, and writes the checksum after any notarization and stapling.

## GitHub Releases

Pushing a `v*` tag, such as `v0.1.0`, runs the release workflow. It runs tests, builds the universal app, packages the DMG and checksum, and publishes both assets through the repository's `GITHUB_TOKEN` with `contents: write`. Versions with a suffix become prereleases. Regular checks also upload DMG artifacts; those workflow artifacts require GitHub access and are separate from public release downloads.

Releases work without Apple credentials: they use ad-hoc signatures and say that they are not notarized. Gatekeeper can block these downloads. Check the signing notice in each release before distributing it.

## Developer ID and notarization

For a distribution signature, add these GitHub Actions repository secrets:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_BASE64` | Base64-encoded export of the Developer ID Application certificate and private key as a `.p12` file |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password for the `.p12` export; may be empty for an unprotected export |
| `DEVELOPER_ID_IDENTITY` | Developer ID Application identity name or fingerprint accepted by `codesign` |

Follow [GitHub's certificate guidance](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications) to export and encode the certificate. The workflow imports it into a temporary keychain and removes that material afterward. A partial certificate configuration fails the release instead of falling back to ad-hoc signing.

For notarization, also set all three secrets:

| Secret | Value |
| --- | --- |
| `NOTARY_APPLE_ID` | Apple account used for notarization |
| `NOTARY_TEAM_ID` | Apple Developer team identifier |
| `NOTARY_PASSWORD` | App-specific password for that account |

Notarization requires the Developer ID configuration above. The packaging script submits the signed DMG with `notarytool`, waits for processing, staples and validates its ticket, then computes the checksum. A failed submission or ticket check prevents publication. See [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

For a local distribution build, set `CODE_SIGN_IDENTITY`, optional `CODE_SIGN_KEYCHAIN`, and `MARGIN_DISTRIBUTION_SIGNING=1` for both scripts. This enables hardened runtime, timestamping, and the Apple Events entitlement used for browser Automation. Provide the same `NOTARY_*` environment variables when packaging to request notarization. Keep private keys and passwords outside the repository and command history. For ordinary repeated development builds, see [development signing](development.md#signing-repeated-builds).
