# Pavarotti fork: build notes

Pavarotti is a private fork of Biscotti. It installs next to an official Biscotti
without sharing settings, permissions or meeting data:

| | Biscotti | Pavarotti |
|---|---|---|
| App | `Biscotti.app` | `Pavarotti.app` |
| Bundle ID | `net.scosman.biscotti` | `de.foxagon.pavarotti` |
| Data (store, recordings) | `~/Library/Application Support/Biscotti` | `~/Library/Application Support/Pavarotti` |
| Model caches (WhisperKit, LLMs) | `~/Library/Application Support/Biscotti` | shared with Biscotti |

The XPC services keep their upstream bundle IDs. They are embedded in the app and
looked up only inside it, so they never clash with Biscotti's copies.

Automatic update checks are off. The manual check in Settings still reports new
upstream Biscotti releases, which is the hint to merge upstream.

## Build and install

`build-and-install.sh` generates the Xcode project, builds the app (Release), signs it
and installs it to `/Applications`. Pass `--no-install` to only build. It needs Xcode
and XcodeGen (`make bootstrap`).

## Stable signing identity

macOS stores privacy permissions (microphone, system audio, calendar, and later
accessibility) per code signature. Ad-hoc signatures change with every build, so the
permissions would have to be granted again after each rebuild. The script therefore
signs with the identity `Pavarotti Signing` when it exists (override with
`PAVAROTTI_SIGN_IDENTITY`). Create it once:

1. Open Keychain Access and choose Keychain Access > Certificate Assistant > Create a Certificate.
2. Name: `Pavarotti Signing`, Identity Type: Self-Signed Root, Certificate Type: Code Signing.
3. In the login keychain, open the new certificate, expand Trust and set Code Signing to Always Trust.
4. Check with `security find-identity -p codesigning`.

After the first build signed with it, grant the permissions one last time.

The build is signed without the hardened runtime. That is fine for a local install and
avoids library-validation trouble with a self-signed certificate.
