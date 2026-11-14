<div align="center">

<img src="lib/images/sticko-app.png" width="88" alt="Sticko Logo" />

<h1>Sticko</h1>

<p>Custom WhatsApp sticker maker for Android, built with Flutter and a native Kotlin bridge.</p>

<p>
  <a href="https://github.com/vikri546/sticko/releases/latest"><img src="https://img.shields.io/github/v/release/vikri546/sticko?include_prereleases&style=flat-square&label=Release&color=128C7E" alt="Latest Release" /></a>
  <a href="https://github.com/vikri546/sticko/releases"><img src="https://img.shields.io/github/downloads/vikri546/sticko/total?style=flat-square&label=Downloads&color=F09A06" alt="Total Downloads" /></a>
  <a href="https://www.android.com"><img src="https://img.shields.io/badge/Platform-Android-3DDC84?style=flat-square&logo=android&logoColor=white" alt="Platform Android" /></a>
  <a href="https://flutter.dev"><img src="https://img.shields.io/badge/Flutter-Framework-02569B?style=flat-square&logo=flutter&logoColor=white" alt="Flutter" /></a>
  <a href="https://dart.dev"><img src="https://img.shields.io/badge/Dart-%3E%3D3.11.0-0175C2?style=flat-square&logo=dart&logoColor=white" alt="Dart >= 3.11.0" /></a>
  <a href="https://kotlinlang.org"><img src="https://img.shields.io/badge/Kotlin-Native%20Bridge-7F52FF?style=flat-square&logo=kotlin&logoColor=white" alt="Kotlin" /></a>
</p>

<p>
  <a href="#download">Download</a> &middot;
  <a href="#features">Features</a> &middot;
  <a href="#preview">Preview</a> &middot;
  <a href="#tech-stack">Tech Stack</a> &middot;
  <a href="#getting-started">Getting Started</a> &middot;
  <a href="#project-structure">Structure</a> &middot;
  <a href="https://github.com/vikri546/sticko/issues">Issues</a>
</p>

</div>

---

## Download

Download the latest APK directly from [GitHub Releases](https://github.com/vikri546/sticko/releases/latest) or inspect release metadata in [`version.json`](version.json).

## Features

- **Static & Animated Stickers:** Converts images, GIFs, and videos (up to 10s) into compliant 512x512 WebP assets following the [WhatsApp Stickers Protocol](https://github.com/WhatsApp/stickers).
- **Sticker Studio & Ordering:** Canvas controls for framing, rotation, mirroring, zoom, meme text, and drag-and-drop pack sorting.
- **Multi-Client WhatsApp Export:** Native Android chooser via [`StickerContentProvider`](android/app/src/main/kotlin/com/pkri/sticko/StickerContentProvider.kt) supporting WhatsApp, WhatsApp Business, Dual Apps, and cloned clients.
- **Backup & Maintenance:** Cross-pack duplicate detection, local ZIP archive backup/restore, and cache cleanup.
- **OTA App Updates:** Automated version checks, changelog previews, and status-bar APK downloads powered by [GitHub Releases](https://github.com/vikri546/sticko/releases).

## Preview

### Sticker Creation & Pack Studio

| Explore | Pack Workspace | Batch WebP Import (30x) | Pack Ready (30/30) |
| :---: | :---: | :---: | :---: |
| <img src="lib/images/assets/Screenshot_2026-11-14-06-56-48-801_com.pkri.sticko-edit.jpg" width="185" alt="Explore Screen" /> | <img src="lib/images/assets/Screenshot_2026-11-14-06-57-47-721_com.pkri.sticko-edit.jpg" width="185" alt="Pack Workspace" /> | <img src="lib/images/assets/Screenshot_2026-11-14-07-01-40-909_com.pkri.sticko-edit.jpg" width="185" alt="Batch WebP Import" /> | <img src="lib/images/assets/Screenshot_2026-11-14-07-02-51-475_com.pkri.sticko-edit.jpg" width="185" alt="Pack Ready" /> |

| Create Pack Dialog | Media Source Picker | Export Confirmation |
| :---: | :---: | :---: |
| <img src="lib/images/assets/Screenshot_2026-11-14-06-57-27-478_com.pkri.sticko-edit.jpg" width="210" alt="Create Pack Dialog" /> | <img src="lib/images/assets/Screenshot_2026-11-14-06-57-59-561_com.pkri.sticko-edit.jpg" width="210" alt="Media Source Picker" /> | <img src="lib/images/assets/Screenshot_2026-11-14-07-03-47-744_com.pkri.sticko-edit.jpg" width="210" alt="Export Confirmation" /> |

### Multi-Client Export & WhatsApp Integration

| WhatsApp & Business Chooser | Original & Dual App Chooser | Shared Pack Card |
| :---: | :---: | :---: |
| <img src="lib/images/assets/Screenshot_2026-11-14-07-03-06-385_com.android.intentresolver-edit.jpg" width="210" alt="WhatsApp Business Chooser" /> | <img src="lib/images/assets/Screenshot_2026-11-14-07-03-16-985_com.miui.securitycore-edit.jpg" width="210" alt="Dual App Chooser" /> | <img src="lib/images/assets/Screenshot_2026-11-14-07-05-17-358_com.whatsapp-edit.jpg" width="210" alt="Shared Pack Card" /> |

| WhatsApp Import Prompt | Sticker Keyboard Tray | Stickers in Chat |
| :---: | :---: | :---: |
| <img src="lib/images/assets/Screenshot_2026-11-14-07-03-36-440_com.whatsapp-edit.jpg" width="210" alt="WhatsApp Import Prompt" /> | <img src="lib/images/assets/Screenshot_2026-11-14-07-05-43-891_com.whatsapp-edit.jpg" width="210" alt="Sticker Keyboard Tray" /> | <img src="lib/images/assets/Screenshot_2026-11-14-07-07-01-747_com.whatsapp-edit.jpg" width="210" alt="Stickers in Chat" /> |

### Account, Releases & Utilities

| Creator Collection | Account Overview | Utilities & Social Links |
| :---: | :---: | :---: |
| <img src="lib/images/assets/Screenshot_2026-11-14-09-12-39-093_com.pkri.sticko-edit.jpg" width="210" alt="Creator Collection" /> | <img src="lib/images/assets/Screenshot_2026-11-14-09-12-49-531_com.pkri.sticko-edit.jpg" width="210" alt="Account Overview" /> | <img src="lib/images/assets/Screenshot_2026-11-14-09-13-08-088_com.pkri.sticko-edit.jpg" width="210" alt="Utilities and Links" /> |

| Edit Creator Profile | APK Update History | Cloud & ZIP Backup |
| :---: | :---: | :---: |
| <img src="lib/images/assets/Screenshot_2026-11-14-09-13-28-213_com.pkri.sticko-edit.jpg" width="210" alt="Edit Creator Profile" /> | <img src="lib/images/assets/Screenshot_2026-11-14-09-13-57-414_com.pkri.sticko-edit.jpg" width="210" alt="APK Update History" /> | <img src="lib/images/assets/Screenshot_2026-11-14-09-14-19-289_com.pkri.sticko-edit.jpg" width="210" alt="Cloud Backup and ZIP Restore" /> |

## Tech Stack

| Layer | Technology |
| --- | --- |
| Framework | [Flutter](https://flutter.dev) ([Dart](https://dart.dev) `>=3.11.0`) |
| Native Android | [Kotlin](https://kotlinlang.org) (`MethodChannel`, [`MainActivity`](android/app/src/main/kotlin/com/pkri/sticko/MainActivity.kt), [`StickerContentProvider`](android/app/src/main/kotlin/com/pkri/sticko/StickerContentProvider.kt)) |
| Media & Archives | [`image`](https://pub.dev/packages/image), [`image_picker`](https://pub.dev/packages/image_picker), [`file_picker`](https://pub.dev/packages/file_picker), [`archive`](https://pub.dev/packages/archive) |
| Utilities | [`permission_handler`](https://pub.dev/packages/permission_handler), [`open_filex`](https://pub.dev/packages/open_filex), [`url_launcher`](https://pub.dev/packages/url_launcher), [`crypto`](https://pub.dev/packages/crypto) |

## Getting Started

### Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (Dart `>=3.11.0`)
- [Android SDK](https://developer.android.com/studio) (`compileSdk 37`) and Java 17

### Setup

```bash
git clone https://github.com/vikri546/sticko.git
cd sticko

# Optional: configure creator social links (ignored by Git)
cp assets/config/social_links.json.example assets/config/social_links.json

flutter pub get
flutter run
```

### Verification & Build

```bash
flutter analyze
flutter test
flutter build apk --release
```

## Project Structure

```text
sticko/
├── android/app/src/main/kotlin/com/pkri/sticko/  # Native Kotlin bridge & ContentProvider
├── assets/config/                                 # Optional creator links template
├── lib/
│   ├── config/                                    # Runtime configuration loaders
│   ├── images/                                    # App icons, backgrounds & showcase assets
│   ├── services/                                  # Pack management, WebP processing, OTA updates
│   └── ui/                                        # Screens and reusable widgets
├── test/                                          # Unit and widget tests
└── version.json                                   # Remote release & changelog manifest
```
