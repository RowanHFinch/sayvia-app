# Sayvia

[中文](README.zh-CN.md)

Sayvia is a native macOS dictation app. In any app's text field, press **fn** to start talking and press it again to stop. Sayvia transcribes what you said, cleans it up (removes filler words and fixes slips like "three, no wait, four"), and types the result at the caret.

You bring your own API key. Sayvia talks directly to the speech and language model provider you choose. There is no Sayvia server in between.

> **Status: alpha.** This build works day to day, but it isn't notarized by Apple yet and hasn't been tested widely. Expect rough edges.

## Features

- Works in any app's text field, triggered by **fn** or **⌥⌘Space**.
- Cleanup keeps your meaning, numbers and language, and removes fillers and false starts.
- Realtime recognition on Alibaba Cloud Bailian: text is recognized while you speak, so the result appears soon after you stop. Other providers use file recognition.
- A personal dictionary for names and terms. Optional auto-learning adds a word when you correct a misrecognized term after dictation.
- Local history with audio, so you can copy, re-run cleanup or export any dictation.
- Chinese and English interface, following your system language.

## Requirements

- macOS 14 or later.
- An API key from a supported provider:
  - **Alibaba Cloud Model Studio (Bailian)**, Beijing or Singapore region. This is the recommended provider and the only one with realtime recognition. You also need your **Workspace ID**, found in the Model Studio console.
  - **OpenAI** (Whisper for recognition, a chat model for cleanup).
  - **Any OpenAI-compatible service**, by entering the full `…/audio/transcriptions` and `…/chat/completions` endpoints.

Usage is billed by your provider to your account.

## Install

### From a release

1. Download `Sayvia-<version>.dmg` from [Releases](../../releases) and drag **Sayvia** into **Applications**.
2. Open Sayvia. Because the app isn't notarized yet, macOS blocks it the first time:
   - Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to the Sayvia message, then confirm with your password.
   - Or run this in Terminal once:

     ```bash
     xattr -dr com.apple.quarantine /Applications/Sayvia.app
     ```

Release builds are signed with one fixed self-signed certificate. Your permissions should therefore carry over to later updates; this hasn't been tested on many Macs yet.

### From source

You need Xcode 16 or later; the Command Line Tools alone lack the SwiftUI macros.

```bash
git clone https://github.com/RowanHFinch/sayvia-app.git
cd sayvia-app
scripts/build-app.sh
open dist/Sayvia.app
```

`build-app.sh` signs the app with a local self-signed certificate named "Sayvia Release Signing", creating one in your login keychain if it's missing. Set `SAYVIA_SIGNING_IDENTITY=-` to use ad-hoc signing instead. With ad-hoc signing, macOS asks for permissions again after every rebuild.

To run the offline self-test (temporary data only, no network calls):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run Sayvia --self-test
```

## Setup

The first launch walks you through four steps:

1. **Privacy.** Confirm what gets sent, and choose how long history is kept.
2. **Service.** Pick a provider and paste your API key. For Bailian, also enter your Workspace ID; you can paste the dedicated domain instead. You can change recognition and cleanup separately later in **Settings → Service**, and **Check connection** there sends one tiny cleanup request to confirm the key works.
3. **Permissions.**
   - **Microphone**, to record.
   - **Accessibility**, to find the focused text field and type into it.
   - **Input Monitoring**, so fn works in every app.
4. **Try it.** Dictate one sentence.

## Privacy

- Recordings, transcripts, history and your dictionary stay on your Mac, in `~/Library/Application Support/io.github.rowanhfinch.sayvia`.
- API keys are stored in the macOS Keychain, one per provider host.
- Data leaves your Mac only when you dictate, retry or check the connection. Each time, the following goes **directly to the provider you chose**:
  - the audio;
  - your dictionary terms;
  - a little text around the caret and the window title;
  - visible text in the current window, which helps with names and terms. Turn this off under **Settings → Data & privacy → Use on-screen text**. Password fields are never read.
- With auto-learning on, only the corrected span and a few surrounding words are sent for review.
- There is no analytics, telemetry or cloud sync. Deleting data in Sayvia doesn't delete anything your provider may have kept; see your provider's data policy.

## How writing works

When the text is ready, Sayvia writes it into whatever field has focus at that moment. It pastes once through a temporary clipboard and then restores your original clipboard. If the clipboard can't be borrowed safely (for example, it holds a password or an image), it types the text instead.

Sayvia never retries a write and never presses Send. If it can't confirm the text arrived, the result stays in History for you to copy.

## Known limitations

- The app isn't notarized; see [Install](#install).
- Realtime recognition is available on Bailian only. Other providers transcribe after you stop, which adds a little delay.
- Recognition and cleanup quality depend on the provider and model.

## License

[GPL-3.0](LICENSE). Contributions are accepted under the same license.
