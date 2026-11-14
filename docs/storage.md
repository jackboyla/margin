# Library storage

## This Mac

The default library needs no server. Notes remain available offline; answering questions still requires the chosen model backend.

`~/Library/Application Support/Margin/library.json` holds document records, highlights, conversations, captured text, model settings saved with threads, and Codex session identifiers. `Attachments/` holds window images. Back up the whole `Margin/` folder to retain notes and images. Codex keeps its runtime sessions separately in its own home directory; API keys and database passwords stay in macOS Keychain.

Local writes replace the library atomically. After a restart, unfinished local replies become interrupted and do not restart themselves. A corrupt or unsupported library produces an error without replacing its saved contents.

## PostgreSQL

Use **Settings → Library → PostgreSQL** to open a library in your own database:

1. Create a PostgreSQL database and login. The login needs permission to create the `margin_libraries` table on first use and to read, insert, and update its rows.
2. Enter the host, port, database, username, password, and **Library name**. Use the same database and library name on another Mac to open the same records.
3. Keep **Verify encrypted connection (TLS)** enabled for a server with a trusted certificate. Disable it only for a trusted local connection.
4. Choose **Connect to PostgreSQL**. Margin opens the named library or creates it if absent. Connecting preserves the existing local library.

The database holds document records, captured text, highlights, conversations, and their saved provider settings and identifiers. Images and Codex session files remain on the Mac that created them. A shared transcript does not make a Codex runtime session portable. Set up credentials separately on each Mac.

Use **Reload remote library** to see changes from another client. Margin does not poll or merge edits. A stale write refuses to overwrite a newer revision, and an uncertain write blocks further writes until reload. Reload before retrying a failed change. If an answer could not save, copy its displayed text before switching libraries or quitting.

**Copy local notes into this empty library** copies the local records and preserves their original. It refuses a destination containing any documents, highlights, or threads; choose a new library name to keep both libraries. It does not transfer attachment files.

Remote unfinished replies may belong to another active Mac. Use **Mark unfinished replies interrupted** only after confirming that no other client still produces them. A failed remote connection does not switch silently to local storage; choose **This Mac → Use this Mac** to return to local notes.

Back up PostgreSQL through your database's normal backup tools, and back up each Mac's attachments and Codex sessions separately. Library names select records within the same table; database permissions control access.
