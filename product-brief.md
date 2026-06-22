# Blue Bubble Vault Product Brief

Last updated: June 22, 2026

## 1. Executive Summary

Blue Bubble Vault is a local-first native macOS app for reviewing, filtering, and exporting Apple Messages / iMessage / SMS / RCS threads. Its core promise is privacy: message processing, previewing, filtering, and export generation happen on the user's Mac, with no cloud upload and no network dependency.

The current MVP focuses on a practical archive workflow:

- Discover available message sources, including the local Messages database, iPhone backup databases, and a safe simulated demo source.
- Let the user select a thread, preview matching messages, and narrow the export with date and keyword filters.
- Show export guardrails before export, including estimated size, available disk space, and the number of messages that will be exported when filters are active.
- Generate a local export package from the filtered message set: A4-paginated PDF, CSV, manifest JSON, diagnostic HTML, and available attachment copies when media export is enabled.

Blue Bubble Vault is intended for privacy-conscious users, legal/archive workflows, personal records, and anyone who needs clean offline exports from Apple Messages without sending private conversations to a third party.

## 2. Current Product Status

### Implemented

- Native macOS SwiftUI application shell with a split-view workflow.
- Full Disk Access onboarding for live Messages database access.
- Safe simulated demo mode for development, demos, and testing without private user data.
- Source discovery model for:
  - Local iCloud Messages database.
  - Local iPhone backup message databases.
  - Simulated demo data.
- Thread list with source selection and search.
- Message preview for the selected thread.
- Date filtering with "all messages" and "date range" modes.
- Keyword filtering.
- Include/exclude media toggle.
- Estimated export size calculation.
- Available disk space display and storage safety messaging.
- Filtered message count display when a keyword or date range is active.
- Optional contact name resolution toggle.
- PDF export through a local rendering pipeline.
- A4-sized PDF page normalization.
- HTML pagination logic that keeps message rows together before PDF generation.
- Diagnostic HTML output beside the PDF for export verification.
- CSV output using the same filtered message set as the PDF.
- Manifest JSON sidecar with stable metadata and SHA-256 hashes for generated output files.
- Optional attachment folder that copies available local attachment files and records missing/unavailable files as metadata.
- Synthetic SQLite fixture tests for database discovery and message filtering.
- Unit tests for export HTML escaping, CSV escaping, manifest stability, hashing, missing attachment metadata, pagination scaffolding, and A4 page normalization.

### Partially Implemented

- **Live Messages database support:** The app can discover and read expected Messages database locations, but real-world schema variation, permissions, and large-library behavior still need broader validation.
- **iPhone backup support:** Backup discovery targets the known MobileSync backup path and hashed SMS database location, but backup variants and encrypted backup handling are not complete.
- **Contact resolution:** Contacts are opt-in and demo-safe, but production behavior needs careful permission handling and privacy review.
- **Media handling:** Available attachment files can be copied into an export package when media export is enabled, and missing files are recorded in CSV/manifest metadata. Attachments are not embedded into the PDF.
- **HTML export:** HTML is currently produced as a diagnostic sidecar for PDF verification, not as a polished standalone user export.
- **Integrity output:** The manifest records package metadata and SHA-256 hashes for generated output files. It is not a PDF/A validation report, legal certification, or formal chain-of-custody workflow.

### Missing

- Standalone user-facing HTML export.
- Standalone JSON message export beyond the manifest sidecar.
- Message-level hashes.
- PDF/A generation or validation.
- Redaction tools.
- Attachment embedding in the PDF.
- Rich content-type filters beyond the current media toggle.
- Export templates or user-configurable report styles.
- Robust handling for encrypted iPhone backups.
- Automated UI tests.
- A formal release/privacy review pass for entitlements, sandboxing, Full Disk Access, and Contacts behavior.

### Implemented but Risky or Fragile

- Keyword filtering now runs against resolved message text, but real-world attributed-body variants still need broad validation.
- Date picker end dates are expanded to include the selected calendar day, but very large real libraries still need performance validation.
- Full Disk Access detection probes protected user locations and should remain security-reviewed.
- The app currently expects known local filesystem paths for Messages and backups.
- Diagnostic HTML contains message content and should be treated as sensitive export output.
- Real database access depends on Full Disk Access and may behave differently across macOS versions.

## 3. Technical Requirements and Environment

Blue Bubble Vault is a native macOS app built with Swift, SwiftUI, AppKit, WebKit, and SQLite.

Current implementation areas:

- **UI:** SwiftUI for the primary app experience.
- **System integration:** AppKit panels for export destination selection.
- **Database access:** SQLite read-only access for Messages-style databases.
- **PDF rendering:** WebKit-based HTML rendering to PDF, followed by A4 normalization.
- **Testing:** XCTest unit tests using synthetic fixtures and generated in-memory documents.

Product target:

- macOS 13+ is the intended product baseline.
- Local-only processing is a core product requirement.
- No cloud processing or network calls should be introduced without explicit product approval.

Release-sensitive settings:

- App Sandbox, signing, bundle identifier, entitlements, and Info.plist privacy strings are security-sensitive and should not be changed casually.
- Full Disk Access and Contacts permission behavior require explicit review before release.

## 4. Privacy and Security Position

Blue Bubble Vault must preserve a strict privacy boundary:

- No automated development task should access a developer's real `~/Library/Messages/chat.db`.
- No automated development task should access real Contacts, Messages, MobileSync backups, Desktop, Downloads, or personal files.
- Development and tests should use only repo-local fixtures, mocked data, or synthetic demo data.
- The app should read message databases in read-only mode.
- Export files are sensitive because they can contain private message content.
- Diagnostic HTML exports are also sensitive and should be treated the same as final PDFs.
- Logs should avoid message bodies, participant identifiers, private file paths, and attachment paths wherever possible.

Privacy-sensitive areas that require continued review:

- Full Disk Access onboarding and detection.
- Live Messages database access.
- iPhone backup scanning.
- Contacts permission and contact name resolution.
- Export destination handling.
- Any future audit logs, manifests, hashes, or diagnostics.

## 5. Core User Workflow

1. The user launches Blue Bubble Vault.
2. The app either guides the user through Full Disk Access for live data or offers the simulated demo source.
3. The user selects a message source.
4. The user selects a thread from the sidebar.
5. The app loads a preview of the thread.
6. The user optionally applies a date range, keyword filter, and media inclusion setting.
7. The bottom context area shows export readiness, estimated export size, available disk space, and the number of messages to export when filters are active.
8. The user starts export.
9. The app writes an export package beside the chosen PDF filename: PDF, CSV, manifest JSON, diagnostic HTML, and an attachments folder when available files are copied.

## 6. UI Layout Hierarchy

### Onboarding

- App logo and product identity.
- Full Disk Access explanation.
- Button to open macOS privacy settings.
- Simulated demo mode entry point.

### Main Dashboard

- Sidebar:
  - Source picker.
  - Search field.
  - Thread list.
  - Contact sync toggle.
- Main preview:
  - Thread title and participant summary.
  - Message count and date range summary.
  - Message preview rows.
  - Empty and loading states.
- Context/export area:
  - Date filter controls.
  - Keyword filter.
  - Include media toggle.
  - Estimated export size.
  - Available disk space.
  - Filtered message count when applicable.
  - Export action.
  - Storage safety status.

### Export Progress

- Export phase and progress indicator.
- Completion state with exported destination.
- Error state with user-facing recovery language.

The export progress screen should describe the generated package accurately: PDF, CSV, manifest JSON, diagnostic HTML, and attachment copies only when files are enabled and available.

## 7. Export Pipeline

### Current Export Package

The current export path generates a local package:

1. The selected thread and filtered messages are copied into an export render context.
2. The app builds an HTML representation of the export.
3. The app writes a diagnostic HTML file next to the final PDF.
4. A hidden WebKit view loads the HTML.
5. JavaScript paginates message rows into A4-sized page containers before PDF rendering.
6. WebKit creates PDF data.
7. The PDF is normalized to A4 pages.
8. The final PDF is written to disk.
9. Available attachment files are copied into an attachments folder when media export is enabled.
10. A CSV is written with one row per exported message.
11. A manifest JSON is written with package metadata, generated output file hashes, and attachment copy/missing status.

Current strengths:

- Shared HTML formatting is used for the diagnostic HTML and PDF render source.
- Message rows are intended to stay together across page breaks.
- Unit tests cover escaping, pagination scaffolding, and page-size normalization.
- The export path can be tested with synthetic message data.
- CSV escaping, manifest stability, hashing, and missing attachment metadata are covered by unit tests.

Current limitations:

- The diagnostic HTML is not yet a polished standalone export format.
- Attachments are copied only when source files are available; missing files are represented as metadata.
- The manifest is an integrity sidecar for generated package files, not a legal certification.
- There is no PDF/A guarantee.
- Very large exports still need broader stress testing.

### Planned Export Formats

- **PDF:** A4 paginated report suitable for sharing and archiving.
- **CSV:** Structured rows for spreadsheet workflows.
- **Manifest JSON:** Package metadata, filter snapshot, generated file hashes, and attachment copy/missing status.
- **Diagnostic HTML:** Render source for PDF verification, treated as sensitive sidecar output.

Planned later:

- **HTML:** Standalone, user-facing archive with local assets and printable styling.
- **JSON:** Structured message export for downstream tools, separate from the manifest.

## 8. Data Model Overview

Primary app concepts:

- **Message source:** A local database source such as live Messages, iPhone backup, or simulated demo.
- **Chat thread:** A conversation with participants, message count, date range, and source metadata.
- **Message item:** A single message with sender, timestamp, body text, service, direction, and optional attachments.
- **Attachment item:** Local metadata for message attachments, including filename, type, path, and size where available.
- **App state:** Current source, selected thread, active filters, preview messages, export estimates, progress, and permission state.
- **Export render context:** A frozen snapshot of thread, message, filter, and source metadata used by the export renderer.

## 9. MVP Acceptance Criteria

A usable MVP should allow a user to:

- Start in demo mode without granting private permissions.
- Select a realistic demo thread.
- Apply a keyword or date range.
- See the number of messages that will be exported.
- See estimated export size and storage safety status.
- Export a PDF with A4-sized pages.
- Export CSV rows and a manifest JSON sidecar using the same filtered message set as the PDF.
- Copy available attachments when media export is enabled, without failing when synthetic/demo attachment paths are missing.
- Open the resulting PDF and see content paginated without cutting through message rows.
- Run unit tests without touching private local data.

Before release, the MVP should also:

- Align UI copy with actual export outputs.
- Avoid logging private content or sensitive paths.
- Make export sidecar behavior clear to users.
- Validate live database behavior on supported macOS versions.
- Review all privacy-sensitive settings and permissions.

## 10. Near-Term Product Priorities

1. Tighten the PDF export experience.
   - Keep A4 pagination reliable.
   - Ensure progress and completion copy matches generated files.
   - Add stress tests for longer synthetic threads.

2. Make export outputs honest and explicit.
   - Clarify when HTML is diagnostic versus user-facing.
   - Avoid claiming PDF/A, legal certification, deleted message recovery, encrypted backup support, cloud sync, or full forensic chain-of-custody.

3. Harden filtering.
   - Fix keyword behavior for attributed-body messages.
   - Confirm inclusive end-date behavior.
   - Add tests for keyword plus date range combinations.

4. Add deterministic integrity output.
   - Add message-level hashes if needed for future workflows.
   - Keep generated file hashing covered by tests.

5. Expand export formats.
   - Add standalone JSON exports using the same filtered message set.
   - Keep all export formats testable with synthetic data.

## 11. Development Guardrails

- Keep changes small, reversible, and reviewable.
- Use repo-local synthetic fixtures for tests.
- Do not read real private Messages, Contacts, backups, Desktop, Downloads, or personal files during automated development.
- Do not change signing, bundle identifiers, entitlements, sandbox settings, release configuration, or privacy strings without explicit review.
- Do not add network calls or cloud processing.
- Treat every generated export as sensitive user data.
