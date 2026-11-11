# How SimpleTTS Handles Data

SimpleTTS reads selected text using system voices. It has no document upload code, advertising SDKs, or analytics SDKs. It cannot open network URLs directly.

Downloading additional voices and retrieving files selected from iCloud Drive or other file providers are functions of the operating system or file provider. Their network and storage behavior follows the settings of those services.

## Documents and history

When **Save Documents and History** is on, opening a file copies its entire text into the app's storage. Saving a reading position also records the document name, position, up to 80 characters of text, and the date and time. This allows reading to resume even if the original file is moved or deleted.

Data is stored in the `SimpleTTS` folder inside the app's Application Support directory. Document text is stored as `Documents/<SHA-256 of the text>.txt`, history is stored in `saves.json`, and sentence notes are stored as `Notes/<SHA-256 of the standardized file path>.json`. Saved positions also retain the notes identifier. The original file path is not stored. Notes added to a document resumed from a saved position created before notes were available are stored as `Notes/<SHA-256 of the text>.json` until that file is opened again, when they are moved to the file's notes. The SHA-256 hash identifies the document or notes set; it does not encrypt the text. The app does not add its own text encryption and relies on the device's file and account protections.

Turning saving off stops new document and history saves for the current document and any documents opened afterward. Previously saved documents and history are not automatically deleted. To read without saving, turn this setting off before opening the document.

A document opened without saving remains unsaved even if you turn saving on while reading it. To start saving that document, turn the setting on and reopen the file. While saving is off, the app does not restore the previous document at launch.

Voice, playback speed, and privacy preferences are stored in the app's `UserDefaults`.

## Notes

Notes can be added only while **Save Documents and History** is on and the document was opened with saving enabled. Each note file records the document name and, for every note, the sentence number, the full text of that sentence, the note, and the date and time it was last modified. Notes are not deleted when you delete a saved position or turn saving off; they load again when you reopen the same document. If the file's text changes and a note's sentence can no longer be found, the note is kept and listed without a sentence number until you delete it.

**Export** in the notes list writes the sentence number, the sentence, the note, and the last modified date to a CSV or TSV file at a location you choose, including notes whose sentence can no longer be found. Cells that begin with `=`, `+`, `-`, `@`, a tab, or a carriage return are prefixed with `'` so spreadsheet apps do not run them as formulas. The app does not track or delete exported files. On macOS, the app requests read-write access only to files you choose in the open and save panels so that it can write the exported file.

Unreadable note files are moved to `Notes/<SHA-256>.corrupted-*.json` for recovery. If a file cannot be moved, notes for that document cannot be edited for the rest of the session so the original file is not overwritten.

## Deleting data

**Delete** in the saved positions list removes the selected position record. The document text remains if another saved position or the currently open document still refers to it. If you delete the automatic save for the open document while saving is enabled, a later pause or app exit can create it again.

To remove all document information retained by the app, use **Delete All Saved Data…** in Privacy settings. This closes the current document and deletes stored text, all saved positions, all notes, recovery copies of corrupted history and notes, and generated temporary audio. The closed document is not saved again when the app exits. Original text files and voice, speed, and privacy preferences remain.

Unreadable history is moved to `saves.corrupted-*.json` for recovery. While such a file exists, deleting individual saved positions does not automatically prune stored document text. **Delete All Saved Data…** also removes these recovery files.

Deletion removes files from the app's storage. It does not remove existing backups, original files, exported notes, sentences or notes copied to the clipboard, or information saved by other apps.

## Temporary audio

Before playback, the app converts the current sentence and the next sentence into WAV files. These temporary audio files are created even when document and history saving is off.

Audio is stored in the app's temporary directory. Unneeded synthesized files and files from failed or canceled synthesis are deleted. Files may be retained while paused so playback can resume. Cleanup also runs during normal app termination and at the next launch. After a forced termination, files may remain until the next launch.

## Lock Screen and clipboard

By default, the iOS Lock Screen and Control Center display `SimpleTTS` and the reading position. The actual file name is displayed only when **Show Document Name on Lock Screen** is on. Playback information never includes a text excerpt.

The app asks the operating system to exclude playback information from suggestions such as Siri and Journal. Playback information may also appear on AirPlay destinations and supported accessories through [Apple's Now Playing feature](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter).

**Copy Sentence** writes the displayed sentence to the system clipboard. It can then be pasted into other apps or shared through Universal Clipboard, depending on your settings.

## Backups

The folder containing document text, history, notes, and recovery files is marked as excluded from operating system backups. At launch, the same exclusion is applied to storage created by earlier versions. Temporary audio is stored in the operating system's temporary directory.

This setting does not remove information from existing iCloud or device backups. It also does not delete copies made manually or by other backup software. See [Apple's backup exclusion documentation](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup) for details.

## Privacy Manifest

`PrivacyInfo.xcprivacy` declares that the app does not track users or collect data for the developer. For APIs that require a reason declaration, it uses `CA92.1` to read and write the app's own preferences and `3B52.1` to inspect the type and size of files selected by the user. See [Apple's approved API reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
