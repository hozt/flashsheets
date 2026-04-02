# Flash Sheets

A Flutter flashcard app that turns any Google Sheet into a study deck. Sign in with Google to load private sheets, or paste a public share link — no account required for public sheets.

Built by [Jeffrey Haug](https://hozt.com).

## How it works

1. Create a Google Sheet with two columns: the first column is the **front** of the card (question/term), the second is the **back** (answer/definition).
2. Either share the sheet publicly and paste the link into the app, or sign in with Google to access private sheets.
3. Study your deck — mark cards right or wrong, flip card orientation, and focus on missed cards only.

Your decks are saved locally so they persist between sessions.

## Features

- Load multiple decks from Google Sheets
- Google Sign-In for private sheets (optional)
- Public share link mode (no sign-in required)
- Shuffle cards on each session
- Reverse card orientation (swap front/back)
- Review missed cards only mode
- Multi-language UI support
- Works on Android, iOS, and web

## Google Sheet format

| Column A (front) | Column B (back) |
|------------------|-----------------|
| What is Flutter? | A UI toolkit by Google for cross-platform apps |
| Photosynthesis   | Process plants use to convert light to energy   |

The first row is treated as data (no header row skipping). Keep it simple — two columns, one card per row.

## Getting started

### Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (Dart SDK ^3.11.0)
- For Android builds: Android Studio with SDK tools installed

Run the Android prerequisite check script to verify your setup:

```bash
bash scripts/check-android-prereqs.sh
```

### Install and run

```bash
flutter pub get
flutter run
```

### Android — Google Sign-In

For Android builds, pass your Google OAuth server client ID at build time:

```bash
flutter run --dart-define=GOOGLE_SERVER_CLIENT_ID=your-client-id-here
```

Without a client ID, Android will still work in public share link mode.

## Configuration

Google Sign-In is configured via the platform-specific files:

- **Android:** `android/app/src/main/AndroidManifest.xml`
- **iOS:** `ios/Runner/Info.plist`
- **Web:** `web/index.html`

See the [google_sign_in package docs](https://pub.dev/packages/google_sign_in) for OAuth setup instructions.

## License

MIT
