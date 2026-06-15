# AGENTS.md

This is a native macOS Swift/SwiftUI app built with Xcode.

Rules:
- Prefer small, reversible changes.
- One task should produce one clean Git diff.
- Do not change signing, bundle IDs, entitlements, App Sandbox settings, Info.plist privacy strings, or release configuration without calling it out clearly.
- After changing Swift code, run the project build action or an appropriate xcodebuild command.
- Keep UI work native to SwiftUI/AppKit conventions.
- Do not add network calls unless explicitly required.
- Do not introduce cloud processing; this app’s value proposition is local-first privacy.

Blue Bubble Vault safety rules:
- Never access real ~/Library/Messages/chat.db during automated development.
- Never access the developer’s real Contacts, Messages, backups, Desktop, Downloads, or personal files.
- Use only repo-local synthetic fixtures for message database tests.
- Treat Full Disk Access, Contacts permission, App Sandbox, and Info.plist privacy strings as security-sensitive.
- Any export integrity logic must be deterministic and covered by tests where possible.