# 💬 Blue Bubble Vault

> A local, privacy-first macOS app to extract, filter, and permanently archive your iMessage, SMS, and RCS conversation history.

![macOS](https://img.shields.io/badge/macOS-13.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)
![License](https://img.shields.io/badge/license-MIT-green)
![Status](https://img.shields.io/badge/status-active%20development-yellow)

---

## The Problem

Apple's native Messages app offers no way to cleanly export or archive long conversation histories. The few third-party tools that exist are bloated, expensive, or route your private data through external cloud servers.

## The Solution

Blue Bubble Vault runs **100% locally** on your Mac. No external server pings. No accounts. No subscriptions. Your messages never leave your device.

---

## Features

- **Contact Discovery** — Scans your message database and presents a searchable list of all chat threads
- **Interactive Preview & Filtering** — Review threads with real-time keyword and content-type filters before exporting
- **Contact Name Resolution** — Resolves phone numbers and emails to full names via macOS Contacts
- **Date Range Filtering** — Export all messages, or surgically select a custom start/end date range
- **Media Attachment Control** — Choose whether to include photos, videos, documents, and voice notes
- **Pre-Flight Size & Storage Check** — Calculates estimated export size and validates available disk space before writing anything
- **Multiple Export Formats** — PDF/A (legal/archival), HTML (interactive), CSV/JSON (research/analysis)
- **Legal Discovery Support** — SHA-256 message hashing, ISO 8601 timestamps, audit manifests, and forensic metadata

---

## System Requirements

| Requirement | Detail |
|---|---|
| macOS | 13.0 (Ventura) or newer |
| Xcode | 15.0 or newer |
| Swift | 5.9 or newer |
| Permissions | Full Disk Access (see setup below) |

---

## ⚠️ Required Setup: Full Disk Access

Blue Bubble Vault reads from `~/Library/Messages/chat.db`, which is protected by macOS's TCC (Transparency, Consent, and Control) framework.

**You must grant Full Disk Access before the app will function:**

1. Open **System Settings → Privacy & Security → Full Disk Access**
2. Click the **+** button and add **Blue Bubble Vault**
3. Restart the app

Without this permission, the app will return an `Operation not permitted` error when attempting to read the message database.

> **Note:** App Sandbox is disabled to allow direct filesystem access. This app is intended for local personal use only.

---

## Data Sources

Blue Bubble Vault supports two data paths depending on your setup:

| Mode | When to Use | Source Path |
|---|---|---|
| **iCloud Sync** (Primary) | "Messages in iCloud" is enabled on your Mac | `~/Library/Messages/chat.db` |
| **USB Device Backup** (Fallback) | Messages are not synced to Mac | `~/Library/Application Support/MobileSync/Backup/` |

For the USB fallback, connect your iPhone, open Finder, and trigger an **unencrypted local backup** before launching the app.

---

## Export Formats

| Format | Best For |
|---|---|
| **PDF/A** | Legal discovery, archival, printing |
| **HTML** | Personal archives, interactive browsing |
| **CSV / JSON** | Research, data analysis, scripting |

All exports include optional PII redaction, forensic metadata headers, SHA-256 message hashes, and a sidecar audit manifest.

---

## Project Structure

```
BlueBubbleVault/
├── Sources/
│   └── BlueBubbleVault/
│       ├── Models/          # Data models (Message, Thread, Attachment, ExportConfig)
│       ├── Views/           # SwiftUI views
│       ├── ViewModels/      # AppState, business logic
│       ├── Helpers/         # ContactsManager, DatabaseManager, StorageChecker
│       ├── Export/          # PDF, HTML, CSV/JSON export engines
│       └── Resources/       # Info.plist, Assets
├── Tests/
│   └── BlueBubbleVaultTests/
├── .github/
│   ├── ISSUE_TEMPLATE/
│   └── workflows/
├── LICENSE
├── README.md
├── CONTRIBUTING.md
└── SECURITY.md
```

---

## Getting Started

```bash
git clone https://github.com/mangla-co/blue-bubble-vault.git
cd blue-bubble-vault
open BlueBubbleVault.xcodeproj
```

Build and run in Xcode. Ensure Full Disk Access is granted before testing against a live database.

---

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a pull request.

---

## Security

This app handles sensitive personal communication data. Please review [SECURITY.md](SECURITY.md) for our responsible disclosure policy before reporting vulnerabilities.

---

## License

MIT License © 2026 [Mangla & Co LLC](https://mangla.co)

---

## Disclaimer

This tool is intended for lawful personal archiving of your own message history. Users are solely responsible for ensuring their use complies with applicable laws, including wiretapping and privacy statutes. The authors assume no liability for misuse.
