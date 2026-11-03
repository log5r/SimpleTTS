# SimpleTTS

A text-to-speech app for macOS, iPhone, and iPad. It uses system voices and supports sentence-by-sentence playback, moving between sentences, playback speeds from 0.5× to 2.0×, and saved reading positions.

## Requirements

The current project targets macOS 27.0.1 or later and iOS / iPadOS 27.0 or later. Development uses Xcode 27.2. There are no third-party Swift package dependencies.

## Run on macOS

Open `SimpleTTS.xcodeproj` in Xcode, select the `SimpleTTS` scheme and `My Mac`, then run the app. You can also launch it from Terminal:

```sh
./start.sh
```

The script launches an existing build if one is available. Rebuild after changing the source or signing settings:

```sh
./start.sh rebuild
```

To try the app locally without code signing, use `NO_SIGN=1 ./start.sh rebuild`. This is a development option; signing and notarization for distribution are separate steps.

## Run on iOS / iPadOS

In Xcode, select the `SimpleTTS` scheme and an iPhone or iPad simulator, then run the app. To build for the simulator from the command line:

```sh
xcodebuild -project SimpleTTS.xcodeproj -scheme SimpleTTS \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData-iOS \
  CODE_SIGNING_ALLOWED=NO build
```

To install on a physical device, specify your own Apple development team and bundle ID. The public project does not contain a personal team ID.

```sh
cp Config/Signing.example.xcconfig Config/Signing.local.xcconfig
```

Replace `YOUR_TEAM_ID` and `com.example.SimpleTTS` in the copied file with your own values. `Signing.local.xcconfig` is ignored by Git and loaded automatically by `start.sh`. When using `xcodebuild` directly, pass `-xcconfig Config/Signing.local.xcconfig`. When running from Xcode, select your development team locally and keep personal signing changes out of commits.

## Read a file

Choose a text file with **Open…**, or drop it into the app. Only regular files up to 10 MiB are accepted. HTTP and HTTPS URLs are not loaded. Supported encodings include UTF-8, UTF-16, Shift JIS, and EUC-JP.

You can move between sentences during playback. While paused, use **Save Position** to save your place or **Copy Sentence** to copy the displayed sentence. On iOS, playback can continue in the background.

## Privacy settings

Open **Settings** on macOS or **Privacy** in the iOS toolbar to control document storage and the document name shown on the Lock Screen.

- **Save Documents and History** is on by default. The app copies opened documents into its storage and retains reading positions, document names, text excerpts, and save dates. Turning it off stops new document and history saves. Previously saved data remains.
- **Show Document Name on Lock Screen** is off by default. iOS playback information shows the app name. Turn this setting on to show the file name instead.
- Use **Delete All Saved Data…** to remove saved documents and history. Deleting an individual saved position can leave document text and other history behind.

Speech synthesis creates temporary audio files even when document saving is off. See [PRIVACY.md](PRIVACY.md) for storage locations, deletion behavior, and backup details.

## Distribute the source

After committing the changes you want to publish, create a source ZIP with:

```sh
./scripts/export-source.sh
```

The default output is `build/SimpleTTS-source.zip`. The script uses `git archive HEAD`, so the archive contains no Git history, untracked files, local build products, or investigation audio. It stops if there are uncommitted changes or the output file already exists. To use a different destination, pass the ZIP path as the first argument.

Publishing the Git repository also publishes its commit history. Do not ZIP the entire working directory: it may contain local settings and audio files.

## Tests

Run the storage, file import, and privacy regression tests on macOS:

```sh
./scripts/test-storage-import.sh
./scripts/test-reader-privacy.sh
```

The tests use synthetic data in temporary directories and an isolated preferences domain. They do not modify normal app data or play audio.

## License

[MIT License](LICENSE). This project does not bundle or redistribute system voices or Apple frameworks.
