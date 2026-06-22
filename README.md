# Blue Bubble Vault

Blue Bubble Vault is a local-first native macOS app for reviewing, filtering, and exporting Apple Messages / iMessage / SMS / RCS conversations.

The app is in active development. The current MVP focuses on safe demo data, local message source discovery, thread preview, filtering, export guardrails, and a local export package.

## Privacy Promise

Blue Bubble Vault is designed around local processing:

- No cloud processing.
- No accounts.
- No subscription service requirement.
- No network calls in the current app.
- Demo mode can be used without granting private system permissions.

Exports may contain private message content. Treat generated PDFs, CSV files, manifests, diagnostic HTML files, and copied attachments as sensitive user data.

## Current Features

- Native SwiftUI macOS interface.
- Full Disk Access onboarding for live Messages database access.
- Simulated demo mode for safe development and demos.
- Source picker for available message sources.
- Thread list with search.
- Optional Contacts sync toggle for name resolution.
- Message preview for the selected thread.
- Date range filtering.
- Keyword filtering.
- Include/exclude media toggle for preview, size estimates, and available attachment copies.
- Message count display when a keyword or date range is active.
- Estimated export size and available disk space display.
- A4-paginated PDF export.
- CSV export using the same filtered messages as the PDF.
- Deterministic manifest JSON sidecar with generated file hashes.
- Diagnostic HTML sidecar used to verify export rendering.
- Optional attachment folder for available local attachment files.
- Synthetic fixture tests for database behavior.
- Unit tests for export HTML escaping, pagination scaffolding, and A4 page normalization.

## Not Yet Implemented

These are planned or aspirational features, but they are not complete in the current app:

- Standalone user-facing HTML export.
- JSON export.
- PDF/A generation or validation.
- Message-level hashes and formal audit workflows.
- Attachment embedding in the PDF.
- PII redaction.
- Encrypted iPhone backup handling.
- Formal chain-of-custody workflow.
- Automated UI tests.

## Current Export Behavior

The current export action creates:

- A new export folder named after the selected export name.
- An A4-sized PDF file inside that folder for the selected thread and active filters.
- A CSV file inside that folder with one row per exported message.
- A manifest JSON sidecar inside that folder with stable metadata and SHA-256 hashes for generated output files.
- A diagnostic HTML sidecar inside that folder for PDF render verification.
- A nested `attachments/` folder when media export is enabled and source attachment files are available.

The diagnostic HTML is used to inspect the render source for the PDF. It is not yet a polished standalone archive format.

When media export is enabled, available attachment files are copied into the export package. Missing or unavailable attachment files are recorded in the CSV and manifest without failing the export.

## Data Sources

Blue Bubble Vault currently models three source types:

| Source | Current Status | Notes |
|---|---|---|
| Simulated demo data | Implemented | Safe for development, testing, and demos. |
| Local Messages database | Partially implemented | Requires Full Disk Access when used against real local data. |
| Local iPhone backups | Partially implemented | Discovers expected MobileSync backup locations, but backup variants and encrypted backups are not complete. |

Development and automated testing must use only repo-local fixtures, mock data, or simulated demo data.

## Full Disk Access

macOS protects the local Messages database with system privacy controls. Live local database access requires Full Disk Access.

Demo mode does not require Full Disk Access.

For live local testing, the user must manually grant access in:

`System Settings > Privacy & Security > Full Disk Access`

Do not request or use Full Disk Access during automated development. Do not access a developer's real Messages database, Contacts, backups, Desktop, Downloads, or personal files while developing or testing.

## Project Structure

```text
Blue Bubble Vault/
├── Blue Bubble Vault/
│   ├── AppState.swift
│   ├── Blue_Bubble_VaultApp.swift
│   ├── ContactsManager.swift
│   ├── ContentView.swift
│   ├── DatabaseConnectionManager.swift
│   ├── DatabaseService.swift
│   ├── ExportPDFService.swift
│   ├── ExportProgressView.swift
│   ├── FDAPermissionManager.swift
│   └── Assets.xcassets/
├── Blue Bubble VaultTests/
│   ├── DatabaseServiceFixtureTests.swift
│   └── ExportPDFServiceHTMLTests.swift
├── Blue Bubble Vault.xcodeproj/
├── docs/
├── AGENTS.md
├── product-brief.md
├── README.md
└── LICENSE
```

## Development

Open the Xcode project:

```bash
open "Blue Bubble Vault.xcodeproj"
```

After Swift changes, run the project build action or an appropriate `xcodebuild` command. Tests should use synthetic fixtures only and must not touch private local data.

## Safety Rules for Contributors

- Do not access real `~/Library/Messages/chat.db` during automated development.
- Do not access real Contacts, Messages, MobileSync backups, Desktop, Downloads, or personal files.
- Use only repo-local synthetic fixtures, mocked data, or simulated demo data for tests.
- Do not change signing, bundle identifiers, entitlements, App Sandbox settings, release configuration, or Info.plist privacy strings without explicit review.
- Do not add network calls or cloud processing.
- Keep export integrity logic deterministic and covered by tests where possible.

## Roadmap

Near-term work is focused on making the v1 export package useful and honest:

- Continue hardening keyword and date range filtering.
- Add stress tests for longer synthetic exports.
- Improve attachment status presentation.
- Add optional standalone HTML only when it can be reviewed as a user-facing format.
- Keep user-facing copy aligned with generated files.

## License

MIT License. See [LICENSE](LICENSE).

## Disclaimer

Blue Bubble Vault is intended for lawful personal archiving and review of message history the user is authorized to access. Users are responsible for ensuring their use complies with applicable privacy, consent, and recordkeeping laws.
