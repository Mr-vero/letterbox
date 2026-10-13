# Contributing to Letterbox

Thanks for helping out! Letterbox is a small, dependency-free Swift package, so getting started is quick.

## Setup

- macOS 15 or later, Xcode 16 or later (or a Swift 6 toolchain)
- Optional: the [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) for the AI features

```bash
git clone https://github.com/Mr-vero/letterbox.git
cd letterbox
make run        # builds build/Letterbox.app and opens it
```

Open `Package.swift` in Xcode if you prefer an IDE.

## Useful commands

| Command | What it does |
| --- | --- |
| `make test` | Offline unit tests (parsers, threading, alias detection) |
| `make test-live` | Also probes real IMAP/SMTP servers (no login) and your Claude CLI |
| `make screenshots` | Regenerates `docs/screenshots` from built-in demo data — no real mail involved |
| `make icon` | Re-renders the app icon from `scripts/make-icon.swift` |
| `make dist` | Universal, zipped release build |

## Code map

```
Sources/Letterbox
├── Core/      sockets (TLS + STARTTLS), keychain, dates
├── IMAP/      IMAP client and response parser
├── SMTP/      SMTP submission client
├── MIME/      MIME parsing and message building
├── Store/     SQLite cache, models, conversation threading, provider presets
├── Sync/      background sync engine, alias detection
├── AI/        Claude CLI bridge, prompts, the assistant
├── App/       app entry point, the MailStore view model
└── UI/        SwiftUI views and the design system (Theme.swift)
```

## Guidelines

- Keep it dependency-free and fast. The UI should read from the local cache, never wait on the network.
- Follow the quiet visual language in `UI/Theme.swift`: neutral surfaces, color only for meaning.
- Anything Claude proposes that changes mail must be confirmed by the user before it runs.
- Never commit real email content, addresses or credentials — use the demo data in `App/Snapshot.swift`.
- Run `make test` before opening a pull request.
