# Privacy

Spark has no backend, network requests, telemetry, analytics, or cloud synchronization.

## Messages data

It opens `~/Library/Messages/chat.db` using SQLite read-only mode and `PRAGMA query_only = ON`. It retrieves chat identifiers/display names, message IDs, timestamps, outgoing status, reaction metadata, participant-count metadata, and the text or rich-text body of the latest uninterrupted run of eligible messages from the same sender per conversation. That content is processed transiently on-device by deterministic rules to identify questions and requests; it is never saved, logged, or transmitted. Reaction metadata is used only to determine whether a newer reaction from the other participant acknowledges the latest conversation message. The app does not query attachments or contact handles, and never modifies Apple's database.

## Contacts data

If you grant Contacts permission, Spark reads local contact names, phone numbers, and email addresses to replace a listed phone number/email with a saved name. The matching index and resolved names are kept only in memory for the active app session. Contacts information is never transmitted.

## Local preferences

Its local `UserDefaults` state contains the follow-up threshold, maximum conversation age, notification preference, group-chat preference, reaction-as-reply preference, launch-at-login preference, ignored chat IDs, dismissed message IDs, and already-notified message IDs.
