# **Product Brief: Blue Bubble Vault (macOS)**

## **1\. Executive Summary & Concept**

**Blue Bubble Vault** is a local, privacy-first macOS application designed to extract, filter, and permanently archive Apple iMessage, SMS, and RCS threads. Unlike existing data recovery tools, this app focuses heavily on user experience by providing exact date range filters, granular choices over media attachments, pre-flight file size estimations, and device storage safety checks before performing any disk execution.

### **The Problem**

Apple's native Messages app offers no way to cleanly export or print long chronological conversation histories. The few third-party solutions that exist are bloated, expensive, or transfer data across third-party cloud servers.

### **The Value Proposition**

* **100% Local Processing:** Zero external server pings. Complete privacy.  
* **Granular Extraction:** Users only download what they need (e.g., *just* text from June 1st to June 10th).  
* **Storage Guardrails:** It prevents system-crashing out-of-storage bugs by validating disk sizes beforehand.

## **2\. Technical Requirements & Environment**

To run properly, the compiled application has specific structural requirements:

### **Target Operating System**

* macOS 13.0 (Ventura) or newer.

### **System Permissions (Crucial)**

* **Full Disk Access (TCC Exception):** The app must request/instruct the user to grant Full Disk Access inside macOS System Settings. Without this, reading the system's underlying message databases will result in an "Operation not permitted" terminal error.  
* **App Sandbox:** Disabled inside Xcode capabilities to allow raw filesystem URL reads.

### **Data Sourcing (Dual Compatibility)**

The app must be capable of pulling messaging records via two paths depending on user configurations:

1. **Primary Path (iCloud Sync):** Reads the live database directly from \~/Library/Messages/chat.db if the user has "Messages in iCloud" turned on.  
2. **Fallback Path (USB Device Backup):** If messages aren't synced to the Mac, the user connects their iPhone via **USB Cable**, triggers a standard local unencrypted backup via Finder, and the app reads from \~/Library/Application Support/MobileSync/Backup/.

## **3\. Core Feature Specifications**

### **Feature 1: Contact Selection & Discovery**

* **Description:** Scan the active message database handles and present a searchable, scrollable list of matching chat threads.  
* **UI Element:** A sidebar or structured SwiftUI Picker displaying contact names, phone numbers, or email aliases.  
* **Logic:** Run a distinct SQL query to match handle.id with historical records inside the chat table.

### **Feature 1.5: Interactive Preview & Filtering**

* **Description:** Provide a scrollable interface for users to review selected threads and apply real-time filters prior to export.  
* **UI Element:** A dynamic message feed with a top-level search bar and filter chips (e.g., \[ Images \], \[ Links \], \[ Documents \]).  
* **Logic:** Implementation of a client-side search predicate to filter messages by keyword, sender, or content type within the current selection buffer.

### **Feature 2: Time Period & Date Filtering**

* **Description:** Give users control over how much history they want to dump.  
* **UI Elements:**  
  * A segmented picker with two choices: \[ All Messages \] or \[ Select Date Range \].  
  * Two responsive SwiftUI DatePicker elements (Start Date and End Date) which unlock when "Select Date Range" is checked.  
* **Logic:** Convert Swift standard Date instances into Mac Core Data Nanosecond Epoch times (seconds elapsed since January 1, 2001, multiplied by $1,000,000,000$) to filter out SQL queries using the WHERE date BETWEEN... condition.

### **Feature 3: Granular Media Attachment Toggles**

* **Description:** Ask the user what kind of heavy files they want to package with their log.  
* **UI Elements:** A toggle or series of checkboxes labeled:  
  * "Include Media (Photos, Videos, Documents, and Voice Notes)"  
* **Logic:** When disabled, the file compilation pipeline entirely skips joining queries to the attachment and message\_attachment\_join SQL tables, ignoring physical file assets.

### **Feature 4: Pre-Flight Size & Storage Calculation**

* **Description:** Calculate the potential size weight of the export file *before* writing it to disk.  
* **UI Elements:** A live dynamic string stating: Estimated Export Size: \[X.XX MB/GB\].  
* **Logic & Guardrails:**  
  1. The app queries the specific size metadata rows from the database matching the criteria.  
  2. Text strings are estimated at roughly 200 bytes per entry. Media attachments calculate total file payload via their literal database size entries (attachment.total\_bytes).  
  3. The app fetches system properties using volumeAvailableCapacityForImportantUsageKey.  
  4. **The Safe Check:** If Available Mac Space \< Estimated Size \+ 500MB Safety Buffer, disable the Export Button and display an error warning: *"Not enough disk space available to complete export safely."*

### **Feature 5: Local Export Compiling Engine**

**Description:** Build the target export asset pack safely inside a clean local folder.

#### **Export Configuration Options**

1. **File Format:** PDF/A (Archival/Legal), HTML (Personal/Interactive), and CSV/JSON (Research/Data Analysis).  
2. **Data Fidelity:** Include toggles for "Redact PII" (masking phone numbers/names) and "Media Handling" (Embed, Link-only, or Exclude).  
3. **Output Structure:** Choose between "Threaded Chat View" (visual look of the app) or "Tabular/Grid View" (raw data for analysis).

These configurations ensure that **legal professionals** can generate forensically sound PDF/A discovery files, **personal archivists** can maintain beautiful interactive HTML histories, and **researchers** can export raw tabular data for large-scale analysis.

### **Feature 6: Legal Discovery & Integrity**

1. **Forensic Metadata:** Include Case/Export ID, device information, and export timestamp in headers/footers.  
2. **Message Attribution:** Include sender/recipient identity, exact timestamp (ISO 8601), and a unique message hash (SHA-256) for every message.  
3. **Discovery Index:** Generate a searchable sidecar CSV/JSON index for all exported messages.  
4. **Audit Manifest:** Include a mandatory summary log file containing the total message count, date range, and export hash.

## **4\. UI Layout Hierarchy (SwiftUI Blueprint)**

```
+-------------------------------------------------------------+
|  Blue Bubble Vault                                          |
+-------------------------------------------------------------+
|                                                             |
|  1. Select Chat Thread:                                     |
|     [ Search Name or Number...                         v ]  |
|                                                             |
|  2. Define Time Period:                                     |
|     ( ) All Messages                                        |
|     (*) Custom Date Range                                   |
|         Start Date: [ Jan 01, 2026 ]                        |
|         End Date:   [ Jun 05, 2026 ]                        |
|                                                             |
|  3. Review & Filter Preview:                                |
|     [ Filter by Keyword or Content Type...               ]  |
|                                                             |
|  4. Package Customization:                                  |
|     [X] Include Media Attachments (Photos/Videos)           |
|                                                             |
|  ---------------------------------------------------------  |
|                                                             |
|  Estimated Export Size: 1.42 GB                             |
|  Available Mac Space:   42.10 GB  (Status: Safe)            |
|                                                             |
|                                      [ Cancel ]  [ EXPORT ] |
+-------------------------------------------------------------+
```

## **5\. Help & Feature Guide**

* **Contact Selection & Discovery:** Allows you to easily scan and find specific chat threads from your message history.  
* **Interactive Preview & Filtering:** Provides a way to review your messages and apply real-time filters like keywords or content types before exporting.  
* **Time Period & Date Filtering:** Gives you precise control to select only the specific dates of conversation history you wish to archive.  
* **Granular Media Attachment Toggles:** Lets you choose whether to include heavy files like photos, videos, and voice notes in your export.  
* **Pre-Flight Size & Storage Calculation:** Automatically checks if your Mac has enough space for the export to prevent system errors.  
* **Local Export Compiling Engine:** Securely builds your archive in various formats like HTML, PDF, or TXT directly on your device.  
* **Legal Discovery & Integrity:** Ensures exports are forensically sound with message hashes, metadata, and audit manifests for professional use.

