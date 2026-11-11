# SimpleTTS

A text-to-speech app for macOS, iPhone, and iPad. It uses system voices and supports sentence-by-sentence playback, moving between sentences, playback speeds from 0.5× to 2.0×, saved reading positions, and notes on individual sentences.

## Requirements

The current project targets macOS 27.0.1 or later and iOS / iPadOS 27.0 or later. Development uses Xcode 27.2. There are no third-party Swift package dependencies.

The app icon is `SimpleTTS/AppIcon.icon`. Open it in Icon Composer to edit the separate speech bubble and waveform SVG layers, Liquid Glass material, and appearance variants. The shared macOS and iOS target uses `AppIcon` as its app icon source; Xcode compiles the layered icon when building the app.

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

## Notes

Each sentence can have one note, and notes can span multiple lines. Use the note button in the top-right corner of the current sentence, or choose **Notes > Add Note…** (⇧⌘N), to add or edit the note for that sentence. The note appears below the sentence, and nearby sentences with notes show a note icon. Saving an empty note removes it.

Notes are stored per document and load automatically when you open the same file again or resume from a saved position. Notes are identified by the standardized file path, independently of the text cache. Separate paths have separate notes even when their contents match. After editing the same file, notes are reattached only to matching sentences. Notes whose sentence is missing or ambiguous are kept: they are not shown in the reader, but they appear at the end of the notes list without a sentence number, where you can copy, export, or delete them. Moving or renaming a file starts a separate set of notes. Saved positions retain their notes identifier. Saved positions created before notes were available do not record the file; notes added after resuming from one are moved to the file's notes the next time you open that file, and opening the file still resumes from that position.

**Notes** in the reader header (or **Notes > Show Notes**, ⇧⌘L) lists each sentence that has a note, the note, and when it was last modified. Double-click a row to go to that sentence. Use **Export** to save the list as a CSV or TSV file (UTF-8 with a byte order mark so spreadsheet apps detect the encoding). Cells that begin with `=`, `+`, `-`, `@`, a tab, or a carriage return are prefixed with `'` so spreadsheet apps treat them as text rather than formulas.

Notes can be added only while **Save Documents and History** is on.

## Privacy settings

Open **Settings** on macOS or **Privacy** in the iOS toolbar to control document storage and the document name shown on the Lock Screen.

- **Save Documents and History** is on by default. The app copies opened documents into its storage and retains reading positions, document names, text excerpts, save dates, and sentence notes. Turning it off stops new document and history saves and disables note editing. Previously saved data remains.
- **Show Document Name on Lock Screen** is off by default. iOS playback information shows the app name. Turn this setting on to show the file name instead.
- Use **Delete All Saved Data…** to remove saved documents, history, and notes. Deleting an individual saved position can leave document text and other history behind.

Speech synthesis creates temporary audio files even when document saving is off. See [PRIVACY.md](PRIVACY.md) for storage locations, deletion behavior, and backup details.

## Distribute the source

After committing the changes you want to publish, create a source ZIP with:

```sh
./scripts/export-source.sh
```

The default output is `build/SimpleTTS-source.zip`. The script uses `git archive HEAD`, so the archive contains no Git history, untracked files, local build products, or investigation audio. It stops if there are uncommitted changes or the output file already exists. To use a different destination, pass the ZIP path as the first argument.

Publishing the Git repository also publishes its commit history. Do not ZIP the entire working directory: it may contain local settings and audio files.

## Tests

Run the storage, file import, notes, and privacy regression tests on macOS:

```sh
./scripts/test-storage-import.sh
./scripts/test-reader-privacy.sh
```

The tests use synthetic data in temporary directories and an isolated preferences domain. They do not modify normal app data or play audio.

## License

[MIT License](LICENSE). This project does not bundle or redistribute system voices or Apple frameworks.
