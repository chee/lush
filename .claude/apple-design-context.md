# Apple Design Context

*Auto-generated from the codebase during a HIG audit (2026-08-21). Values marked (inferred) came from code, not from the author — correct anything wrong.*

## Product
- **Name**: Lush
- **Description**: A local-first notes app with CRDT sync (Automerge/Rust core), an agenda view (EventKit), AI chat over notes (local MLX + cloud via OpenRouter + Apple FoundationModels), a scriptable "Patchwork" surface, quick capture, and rich-text editing.
- **Category**: Productivity (inferred)
- **Stage**: Development (inferred)

## Platforms
| Platform | Supported | Min OS | Notes |
|----------|-----------|--------|-------|
| iOS      | Yes       | 26.5   | TARGETED_DEVICE_FAMILY 1,2 |
| iPadOS   | Yes       | 26.5   | |
| macOS    | Yes       | 26.5   | Menu bar extra, Services menu, dock tile plugin, Finder action extension |
| tvOS     | No        |        | |
| watchOS  | No        |        | |
| visionOS | No        |        | |

## Technology
- **UI Framework**: SwiftUI, with AppKit/UIKit interop (custom text editor on NSTextLayoutManager/TextKit 2; `Platform.swift` typealias shims)
- **Architecture**: Multi-window on macOS (main window, quick capture, menu-bar extra); single-scene on iOS. Not document-based — storage is an Automerge repo owned by a Rust `Core`.
- **Apple Technologies**: EventKit, EventKit reminders, CoreLocation, WeatherKit, MapKit, Contacts, AppIntents, CoreSpotlight, UserNotifications, BackgroundTasks, WidgetKit, PhotosUI, AVFoundation, Speech, Vision, FoundationModels, WebKit, Network (Bonjour local sync server)
- **Extensions**: Widget (LushWidget), Share extension, Finder action extension, Dock tile plugin

## Design System
- **Base**: System components with a custom identity layer
- **Brand Colors**: "Lush pink" `#FF69A5` (AccentColor asset, `Color.lushPink`)
- **Typography**: User-configurable interface/editor fonts; bundled Caroni, Fantasque Sans Mono, Jost, Merriweather (`InterfaceFont.swift`, `FontSettingsView.swift`)
- **Dark Mode**: Relies on system semantic colors (mostly); some hard-coded colors exist
- **Dynamic Type**: Partial — custom font sizing paths exist; needs audit

## Accessibility
- **Target Level**: Baseline (inferred — ~36 accessibility modifiers across ~53k lines of Swift)
- **Key Considerations**: Custom text editor and custom-drawn controls need VoiceOver attention

## Users
- **Primary Persona**: The author (personal tool, `party.chee.lush`) and similar power users who live in notes + calendar and script their tools (inferred)
- **Key Use Cases**: Daily notes and agenda at a desk (macOS), quick capture from menu bar/share sheet, reading and capture on the go (iOS), AI-assisted writing and querying
- **Known Challenges**: Universal app parity across macOS and iOS; heavy custom editor UI; many system integrations to keep idiomatic
