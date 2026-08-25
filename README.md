# Spark

A private, local macOS menu-bar app for finding one-to-one Messages chats that may need a follow-up.

<p align="center">
  <img src="Spark/Spark/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" width="160" alt="Spark app icon">
</p>

## What it does

- **Follow Up:** chats where your latest non-reaction message may need a follow-up.
- **Respond:** chats where the other person's latest non-reaction message is awaiting you.
- **Suggested:** prioritizes questions and requests; **All** includes every eligible chat.
- Dismiss a message or ignore a conversation to keep the queue tidy.

Set a minimum follow-up age (one day by default) and a maximum age for stale conversations in Settings. Group chats and reactions are excluded from the latest-message calculation.

## Get started

1. Open [Spark.xcodeproj](Spark/Spark.xcodeproj) in Xcode and run the **Spark** scheme.
2. Grant the development app **Full Disk Access** in **System Settings → Privacy & Security**.
3. Open the menu-bar item and choose **Refresh**.

## Privacy

Spark reads Messages locally and in read-only mode. It has no backend, networking, telemetry, or analytics. After metadata eligibility checks, text from the final uninterrupted same-sender message run is used only transiently for optional local ranking and is never stored or sent.

[Read the privacy policy.](PRIVACY.md)

## Develop and test

Run the unit tests:

```sh
xcodebuild test \
  -project Spark/Spark.xcodeproj \
  -scheme Spark \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:SparkTests
```
