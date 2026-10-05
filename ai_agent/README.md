# Voice Agent for macOS

Native SwiftUI prototype for a voice-first Gemini Live assistant.

## Run

Requires macOS 14 or later and Xcode Command Line Tools:

```sh
swift run
```

Put your Gemini API key in the `.env` file in this folder:

```env
GEMINI_API_KEY=your_key_here
```

Restart with `swift run`. The app connects on launch. macOS will prompt for microphone permission on first use; if not, enable it under **System Settings → Privacy & Security → Microphone**.

The model picker selects `gemini-3.8-live` or `gemini-3.8-live-extended-thinking` before connecting. Disconnect to change models. Push and hold **Hold to talk** to send a voice turn.

## Current prototype scope

- Native macOS UI, push-to-talk audio capture, streamed audio playback, and live transcription.
- Direct WebSocket connection for a quick local prototype. The `.env` file is ignored by Git; before distributing the app, add a small authenticated token service and use short-lived Gemini Live tokens.
- No tool execution yet. Add a tool router only after the audio loop works, with confirmation for actions that change or transmit user data.
