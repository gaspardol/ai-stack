# AI Stack

A personal, always-on macOS menu-bar app that replaces paid AI tools, using your **Claude subscription**
(through the `claude` CLI login) as the only AI backend. No API keys, no extra subscriptions.

| Tool | Replaces | What it does |
|------|----------|--------------|
| **Writing assistant** | Grammarly | In any app, underlines errors in **red** and awkward phrasing in **blue**. Hover (or click) an underline to see the fix and accept it. A small badge in the text field's corner lists every suggestion and has **Fix all errors**. |
| **Meeting notes** | Granola | Detects calls (Google Meet / Teams / Zoom in the browser, or the Zoom, Teams, FaceTime, Slack, WhatsApp… apps), transcribes **you** (mic) and **them** (system audio) on-device, then Claude writes structured notes with action items when the call ends. You can type your own notes during the call and ask questions afterwards ("draft a follow-up email"). |

## Install / update

```bash
./scripts/build.sh      # compile, sign, install to /Applications, (re)launch
```

The first launch opens **Setup & Permissions**. Grant:

1. **Accessibility** (writing assistant)
2. **Microphone** and **Call audio** (meeting notes; macOS asks for "System Audio Recording")
3. Optional: **Calendar** (names meetings after events), **Notifications**
4. When asked, allow access to **Documents** (Markdown notes are saved in `~/Documents/Meeting Notes`) and
   **Automation → Google Chrome** (used to tell a Meet/Teams tab apart from other mic use)

AI Stack registers itself as a launch agent: it starts at login and relaunches by itself if it ever crashes.
"Quit AI Stack" in the menu really quits.

## Everyday use

- **Writing**: just type. Checks run about 1 second after you pause; only paragraphs you changed are re-checked.
  Turn it off for one app from the menu bar (✦ → *Turn Off in …*). Terminals, code editors and password
  managers are off by default.
- **Calls**: notes start automatically (red dot in the menu bar) and stop about 20 seconds after the call app
  releases the microphone. A notification tells you when the notes are ready. Change the behaviour (auto / ask /
  manual) and the call language in Settings or straight from the menu.
- **Notes window**: ✦ → *Open Meeting Notes…* — sidebar of meetings, Notes / Transcript / My notes tabs, an
  "Ask anything" bar, editable Markdown, clickable checkboxes.

## How it works

```
Sources/AIStack/
  Core/ClaudeCLI.swift          claude -p --input-format stream-json, one fresh process per request,
                                with a pre-started process kept warm (≈1s latency instead of ≈3.5s)
  Writing/WritingAssistant.swift  focused-field tracking (AX API), debounce, geometry, hover, apply
  Writing/GrammarEngine.swift   paragraph cache, prompt, JSON parsing, span location
  Writing/OverlayPanels.swift   click-through underline overlay, suggestion card, badge, list
  Notes/MeetingDetector.swift   Core Audio "who is using the mic", browser tab check, calendar lookup
  Notes/AudioCapture.swift      AVAudioEngine mic + Core Audio process tap for system audio
  Notes/LiveTranscriber.swift   macOS 26 SpeechAnalyzer / SpeechTranscriber (on-device)
  Notes/MeetingRecorder.swift   meeting lifecycle + Claude notes / Q&A prompts
  UI/                           SwiftUI notes window, settings, setup
```

- Models: Haiku for writing checks (fast), Opus for meeting notes, Sonnet for Q&A. All configurable.
- Audio never leaves the Mac; only the transcript text is sent to Claude. Meetings are stored as JSON in
  `~/Library/Application Support/AIStack/Meetings` and exported as Markdown.
- Logs: `~/Library/Logs/AIStack/aistack.log`.
- Self-tests (no UI): `"/Applications/AI Stack.app/Contents/MacOS/AIStack" --selftest grammar|notes|transcribe <file>`

## Known limits

- Google Docs draws its text on a canvas, so the writing assistant can't see it (works in Gmail, Slack, Notion,
  Mail, Notes, Messages, most web text boxes, Electron apps…).
- One language per call (pick it in the menu). Speakers are "Me" and "Them"; Claude infers names from context.
- If you use loudspeakers instead of headphones, your mic also hears the other side; the notes prompt handles
  the duplicates.
- Recording calls may require the other participants' consent where you live.
