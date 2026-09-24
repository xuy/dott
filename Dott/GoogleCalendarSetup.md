# Google Calendar setup

1. In Google Cloud, create an OAuth client with application type **Desktop app**.
2. Download the JSON file and copy it to:

   `Dott/google-oauth-client.json`

3. Keep the file private. It is ignored by Git and should remain mode `600`.
4. Enable the Google Calendar API for the project.
5. Rebuild and launch Dott.
6. Use **Connect Google Calendar** in the Dott menu when that option is available.
7. Approve read-only calendar access in the browser.

Dott stores refresh tokens in the macOS Keychain, not in the repository or recording folders. Calendar enrichment is opt-in and stores attendee display names only; attendee email addresses, event descriptions, and conference links are not persisted.
