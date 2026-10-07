# Agent Chats for macOS

Native SwiftUI Gemini Live voice agent with separate, persistent conversations for each bot. Clover, Droid, and Star are included; you can also create and delete bots.

## Run

Requires macOS 14 or later and Xcode Command Line Tools:

```sh
swift run
```

The app looks for `GEMINI_API_KEY` in this order: process environment, `.env` in the current directory, then Keychain. If none is found, enter a key in the app and choose **Save key**. For `swift run`, a `.env` file can contain:

```env
GEMINI_API_KEY=your_key_here
```

The app connects on launch. Use **Connect / Disconnect** in the header to manage the session; disconnect before changing the model. Use **Start talking / Stop talking** to send a push-to-talk voice message. **Call** starts a continuous hands-free conversation; Gemini detects pauses and responds automatically, and **End call** returns to voice-message mode. The first use requests microphone access. Spoken replies and their transcriptions appear in the selected bot's chat history.

Choose a bot from the sidebar (or the horizontal picker in a narrow window) to switch to its separate chat. Use the plus button to create a bot; delete bots from their customization panel. The model picker selects `gemini-3.8-live` or `gemini-3.8-live-extended-thinking`. With Extended Thinking selected, use the adjacent menu to choose Low, Medium, or High reasoning depth; changing it reconnects the session. Use the folder button to select the workspace the bots can access.

Use the sliders button in a bot's chat header to customize its avatar shape, color, face, and material, and edit its system prompt. Settings are saved separately for each bot; changing the active bot's prompt reconnects after its current turn.

Ask a bot to use the Mac to inspect the main display. Screen inspection returns OCR text and positions, not a saved screenshot. macOS may ask for Screen Recording permission. Clicks, typing, keypresses, and scrolling each show an approval sheet; macOS may also ask for Accessibility permission before the first action.

## Current prototype scope

- Native, resizable chat UI with persistent per-bot history and Libraries.dev BotAvatarsKit avatars.
- Per-bot avatar and system prompt customization, saved locally.
- Persistent, user-managed bot roster with create and delete actions.
- Push-to-talk voice messages and hands-free Gemini Live calls with automatic speech detection, with user and reply transcriptions shown in the conversation.
- Gemini tool calling for listing, searching, reading, and opening files in the selected working folder, plus launching Mac apps. File writes always wait for approval in the app.
- Terminal commands are shown with their exact text and working folder; they run only after you approve them in the app. Commands stop after 45 seconds and return at most 32 KB of output.
- Computer use can inspect the main display and propose clicks, text entry, keypresses, and scrolling. Each interaction requires its own approval. Screen text is treated as untrusted input.
- The file tools are limited to the selected folder and exclude hidden files and common secret files. Choose the folder from the button in the window header.
- Direct WebSocket connection for a quick local prototype. The `.env` file is ignored by Git; before distributing the app, add a small authenticated token service and use short-lived Gemini Live tokens.
