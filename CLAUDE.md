# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

```bash
# Build
swift build

# Run tests
swift test

# Build for release
swift build -c release
```

This is a Swift Package Manager project (no .xcodeproj). Targets defined in `Package.swift`:
- `AIRecording` — macOS executable (min macOS 13)
- `AIRecordingTests` — XCTest suite

To open in Xcode: `open Package.swift` or `xed .`

## Architecture

Four-layer architecture: **Presentation** (SwiftUI views + AppKit bridge) → **ViewModels** (@MainActor, ObservableObject) → **Services** (singletons, Combine publishers) → **Data** (Core Data + file system).

### App entry point

`AIRecordingApp.swift` — `@main` SwiftUI App with `NSApplicationDelegateAdaptor`. The `AppDelegate` creates a `MenuBarController` and sets `NSApp.setActivationPolicy(.regular)`, so the app shows in both the Dock and the menu bar. Main window uses `.windowStyle(.hiddenTitleBar)`.

### Menu bar (AppKit bridge)

`MenuBarController` — `NSStatusBar` controller with left-click to toggle recording, right-click for context menu (recent recordings, open window, settings, quit). Observes `AudioRecordingService.shared.$state` via Combine. Posts `Notification.Name.openRecordingDetail` and `.openSettings` to coordinate with SwiftUI views.

### Core Data

`PersistenceController` — shared singleton wrapping `NSPersistentContainer`. WAL journal mode, `NSMergeByPropertyObjectTrumpMergePolicy`. Three entities defined in `.xcdatamodeld`:
- `Recording` — audio file metadata, status, file path
- `Transcription` — engine, status, language, confidence; one-to-one with Recording
- `TranscriptionSegment` — startTime, endTime, text, confidence, speakerId, sequence; many-to-one with Transcription

Models use `@NSManaged` properties and `fetchRequest()` class methods. `Recording.isDeletedValue` implements soft delete.

### Recording flow

1. `AudioRecordingService.shared.startRecording()` — requests mic permission via `AVAudioDevice.requestAccess(for:)`, sets up `AVAudioEngine` with input node tap, writes PCM to CAF file, creates Core Data `Recording` entity, publishes `RecordingState` via `@Published`. Publishes `audioLevel: Float` for waveform visualization.
2. `stopRecording()` — removes tap, stops engine, updates file size and status, saves context, then **automatically triggers** `TranscriptionService.shared.transcribe()`.
3. `TranscriptionService.shared.transcribe()` — requests speech recognition permission, creates `Transcription` entity, uses `SFSpeechURLRecognitionRequest` with `requiresOnDeviceRecognition = true`, converts CAF to WAV if needed, extracts `TranscriptionSegmentDTO` with timestamps, saves segments to Core Data.
4. Auto-conversion CAF→WAV uses `AVAssetExportSession` — this is lossy passthrough; SFSpeechRecognizer requires WAV/MP3 input.

### Services (singletons)

All services use `static let shared` pattern, no dependency injection container:
- `AudioRecordingService` — `@Published var state: RecordingState` and `audioLevel: Float`, manages AVAudioEngine lifecycle
- `TranscriptionService` — wraps SFSpeechRecognizer, handles permission flow, creates/populates Transcription+Segments in Core Data
- `AudioPlayerService` — wraps AVAudioPlayer with `@Published` state/time/duration/rate, seek and rate control, 0.1s polling timer
- `PersistenceController` — Core Data stack, `saveContext()` (catches and logs errors silently), `newBackgroundContext()`

### ViewModels (@MainActor)

All ViewModels conform to `@MainActor` and `ObservableObject`:
- `RecordingViewModel` — observes `AudioRecordingService.$state` + `$audioLevel`, maintains rolling 60-point `audioLevels: [Float]`
- `RecordingListViewModel` — Core Data fetch with `isDeleted == false` predicate, listens to `NSManagedObjectContextObjectsDidChange` for auto-refresh, `search(query:)` with `CONTAINS[cd]` predicate on title fields, soft-delete (`isDeletedValue = true`)
- `RecordingDetailViewModel` — loads recording by `NSManagedObjectID`, delegates to `AudioPlayerService`, manual `startTranscription()`, waveform uses random Float levels during playback
- `NewRecordingViewModel` — manages recording lifecycle in the new recording sheet, audio source selection
- `SettingsViewModel` — UserDefaults-backed (format, sampleRate, channels, language, storagePath), `NSOpenPanel` for path chooser

### Views (SwiftUI)

`MainWindowView` — `NavigationSplitView` with sidebar (录音列表, 设置) and detail area. Uses `SidebarItem` enum for navigation. Listens to custom `Notification.Name` for cross-module navigation (menu bar → open recording/settings).

`RecordingListView` — two-pane: list with search + detail drill-down. `selectedRecordingObjectID: Binding<NSManagedObjectID?>` toggles between list and detail. `contextMenu` for delete.

`RecordingDetailView` — audio player (waveform, slider, play/pause, skip, rate picker) + transcription panel (segments with timestamps, loading state, error state with retry, empty state with "开始转录" button).

`AudioWaveformView` — custom `Canvas`-free bar visualization using `GeometryReader` + `RoundedRectangle`, color-coded by level (green→orange→red).

`NewRecordingView` — sheet with source picker, live waveform, record/stop button.

`SettingsView` — `Form` with `.grouped` style, three sections: recording, transcription, storage.

### Infra

- `Info.plist` — `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription` (no `LSUIElement`: regular app, icon in Dock and menu bar)
- `Package.swift` — targets `macOS(.v13)`, `StrictConcurrency` experimental feature enabled
- No third-party dependencies (zero SPM packages), everything uses system frameworks
- No Xcode project — this is SPM-only, open with `open Package.swift` or `xed .`

## Key patterns

- **Combine for reactivity**: `AudioRecordingService.$state` → ViewModels via `.sink` → Views via `@Published`. ViewModels store `cancellables` set.
- **Async/await with MainActor**: All public service async methods, ViewModels marked `@MainActor`, `await MainActor.run` for UI updates from service callbacks.
- **Core Data on main context**: No background context usage in ViewModels; heavy work (transcription) runs on SFSpeechRecognizer's internal queue.
- **Soft delete**: `Recording.isDeletedValue` flag, `deletedAt` timestamp — no hard deletes.
- **Custom Notification.Name** for cross-module communication (menu bar → SwiftUI views).
- **Status enums stored as Int16** in Core Data (RecordingStatus, TranscriptionStatus, TranscriptionEngine), backed by Swift enums with `rawValue: Int`.

## Design docs

Design and planning documentation lives in `docs/`:
- `PRD-v1.0.md`, `TechSpec-v1.0.md`, `DatabaseDesign-v1.0.md`, `APIDesign-v1.0.md`
- `UserStoriesUseCases-v1.0.md`, `NonFunctionalRequirements-v1.0.md`
- `QATestingPlan-v1.0.md`, `RiskAssessment-v1.0.md`

**Current scope**: local-only MVP — recording + Apple Speech transcription + history + settings. Cloud AI summaries, speaker diarization, chart generation, and full-text search (FTS5) are deferred to future iterations.
