# Library storage

Margin saves locally in `~/Library/Application Support/Margin/`. Notes remain available offline; answering questions still requires the chosen model backend. No database server setup is needed.

`library.sqlite` holds document records, highlights, conversations, captured context, each thread's model settings, and Codex session identifiers. `Attachments/` holds window images. Codex keeps its runtime sessions separately in its own home directory. API keys stay in macOS Keychain.

SQLite commits library changes in transactions. After a restart, unfinished replies become interrupted and do not restart themselves. A corrupt or unsupported library produces an error without replacing its saved contents.

## Existing JSON libraries

When opening a library for the first time, Margin imports `library.json` into SQLite in one transaction and verifies the imported records before committing. It then renames the source to `library.json.migrated`. A failed import preserves the original file and reports an error. Once the SQLite library has been initialized, Margin does not import the JSON again.

## Backups

Quit Margin, then copy the whole `~/Library/Application Support/Margin/` folder to back up the database and attachments together. SQLite may keep `library.sqlite-wal` and `library.sqlite-shm` files beside the main database; copying the database alone while the app runs can miss recent writes or produce an inconsistent backup. Keep Codex's separate session files if you need to resume its agent sessions after a restore.
