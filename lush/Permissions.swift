import SwiftUI
import AVFoundation
import CoreLocation
import Contacts
import EventKit
import Photos
import UserNotifications
#if os(macOS)
import CoreServices
#endif

enum PermissionState {
    case granted
    case partial
    case denied
    case notDetermined
    case unavailable
}

enum PermissionKind: String, CaseIterable, Identifiable {
    case location
    case filesAndFolders
    case calendar
    case reminders
    case contacts
    case microphone
    case camera
    case photos
    case appleNotes
    case notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .location: "Location"
        case .filesAndFolders: "Files and Folders"
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .contacts: "Contacts"
        case .microphone: "Microphone"
        case .camera: "Camera"
        case .photos: "Photos"
        case .appleNotes: "Apple Notes"
        case .notifications: "Notifications"
        }
    }

    var detail: String {
        switch self {
        case .location: "Names the place in a logline and lets you save places."
        case .filesAndFolders: "Reads and attaches files from your Desktop, Documents, and Downloads."
        case .calendar: "Adds what you were doing to a logline."
        case .reminders: "Adds reminders to a logline and lets notes create them."
        case .contacts: "Names the people you were with in a logline."
        case .microphone: "Records voice memos into a note."
        case .camera: "Takes photos to attach to a note."
        case .photos: "Attaches pictures from your library."
        case .appleNotes: "Imports your Apple Notes."
        case .notifications: "Tells you when a smart notebook's count changes."
        }
    }

    var symbolName: String {
        switch self {
        case .location: "location"
        case .filesAndFolders: "folder"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .contacts: "person.crop.circle"
        case .microphone: "mic"
        case .camera: "camera"
        case .photos: "photo.on.rectangle"
        case .appleNotes: "note.text"
        case .notifications: "bell"
        }
    }

    var isSupported: Bool {
        #if os(macOS)
        self != .camera
        #else
        self != .filesAndFolders && self != .appleNotes
        #endif
    }

    var privacyAnchor: String {
        switch self {
        case .location: "Privacy_LocationServices"
        case .filesAndFolders: "Privacy_FilesAndFolders"
        case .calendar: "Privacy_Calendars"
        case .reminders: "Privacy_Reminders"
        case .contacts: "Privacy_Contacts"
        case .microphone: "Privacy_Microphone"
        case .camera: "Privacy_Camera"
        case .photos: "Privacy_Photos"
        case .appleNotes: "Privacy_Automation"
        case .notifications: "Privacy_Notifications"
        }
    }
}

@MainActor
@Observable
final class PermissionsModel {
    private(set) var states: [PermissionKind: PermissionState] = [:]
    private let locationManager = CLLocationManager()
    private let eventStore = EKEventStore()
    private var notificationState: PermissionState = .notDetermined

    func refresh() {
        var next: [PermissionKind: PermissionState] = [:]
        for kind in PermissionKind.allCases where kind.isSupported {
            next[kind] = state(kind)
        }
        states = next
        Task {
            notificationState = await Self.notificationState()
            states[.notifications] = notificationState
        }
    }

    private static func notificationState() async -> PermissionState {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        default: .notDetermined
        }
    }

    func request(_ kind: PermissionKind) async {
        switch kind {
        case .location:
            locationManager.requestWhenInUseAuthorization()
        case .calendar:
            _ = try? await eventStore.requestFullAccessToEvents()
        case .reminders:
            _ = try? await eventStore.requestFullAccessToReminders()
        case .contacts:
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        case .microphone:
            _ = await AVAudioApplication.requestRecordPermission()
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .photos:
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        case .filesAndFolders:
            #if os(macOS)
            let result = await Task.detached { UserFolders.probe() }.value
            UserFolders.remember(result)
            #endif
        case .appleNotes:
            #if os(macOS)
            _ = await Task.detached { AppleEventPermission.state(for: "com.apple.notes", askUser: true) }.value
            #endif
        case .notifications:
            await SmartNotebookAlerts.requestAuthorization()
        }
        refresh()
    }

    func openSystemSettings(_ kind: PermissionKind) {
        #if os(macOS)
        let url = URL(
            string: kind == .notifications
                ? "x-apple.systempreferences:com.apple.preference.notifications"
                : "x-apple.systempreferences:com.apple.preference.security?\(kind.privacyAnchor)"
        )
        #else
        let url = URL(string: UIApplication.openSettingsURLString)
        #endif
        if let url { ExternalBrowser.open(url) }
    }

    private func state(_ kind: PermissionKind) -> PermissionState {
        switch kind {
        case .location:
            switch locationManager.authorizationStatus {
            case .authorizedAlways: .granted
            case .authorizedWhenInUse: .granted
            case .denied, .restricted: .denied
            default: .notDetermined
            }
        case .calendar:
            eventState(EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            eventState(EKEventStore.authorizationStatus(for: .reminder))
        case .contacts:
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized: .granted
            case .limited: .partial
            case .denied, .restricted: .denied
            default: .notDetermined
            }
        case .microphone:
            switch AVAudioApplication.shared.recordPermission {
            case .granted: .granted
            case .denied: .denied
            default: .notDetermined
            }
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: .granted
            case .denied, .restricted: .denied
            default: .notDetermined
            }
        case .photos:
            switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
            case .authorized: .granted
            case .limited: .partial
            case .denied, .restricted: .denied
            default: .notDetermined
            }
        case .filesAndFolders:
            #if os(macOS)
            UserFolders.lastResult
            #else
            .unavailable
            #endif
        case .appleNotes:
            #if os(macOS)
            AppleEventPermission.state(for: "com.apple.notes", askUser: false)
            #else
            .unavailable
            #endif
        case .notifications:
            notificationState
        }
    }

    private func eventState(_ status: EKAuthorizationStatus) -> PermissionState {
        switch status {
        case .fullAccess: .granted
        case .writeOnly: .partial
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }
}

#if os(macOS)
enum UserFolders {
    private static let key = "userFolderAccess"

    static var directories: [FileManager.SearchPathDirectory] {
        [.desktopDirectory, .documentDirectory, .downloadsDirectory]
    }

    static var lastResult: PermissionState {
        switch UserDefaults.standard.string(forKey: key) {
        case "granted": .granted
        case "partial": .partial
        case "denied": .denied
        default: .notDetermined
        }
    }

    static func remember(_ state: PermissionState) {
        switch state {
        case .granted: UserDefaults.standard.set("granted", forKey: key)
        case .partial: UserDefaults.standard.set("partial", forKey: key)
        default: UserDefaults.standard.set("denied", forKey: key)
        }
    }

    static func probe() -> PermissionState {
        var readable = 0
        var checked = 0
        for directory in directories {
            guard let url = FileManager.default.urls(for: directory, in: .userDomainMask).first else {
                continue
            }
            checked += 1
            if (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil {
                readable += 1
            }
        }
        if checked == 0 { return .unavailable }
        if readable == checked { return .granted }
        return readable == 0 ? .denied : .partial
    }
}

enum AppleEventPermission {
    static func state(for bundleIdentifier: String, askUser: Bool) -> PermissionState {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        guard let descriptor = target.aeDesc else { return .notDetermined }
        let status = withExtendedLifetime(target) {
            AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, askUser)
        }
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .notDetermined
        }
    }
}
#endif

struct PermissionsSettingsPane: View {
    @State private var permissions = PermissionsModel()
    @State private var pending: PermissionKind?

    var body: some View {
        Form {
            Section {
                ForEach(PermissionKind.allCases.filter(\.isSupported)) { kind in
                    row(kind)
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Lush asks for each of these only when you turn it on. Anything you have already refused has to be changed in System Settings.")
            }
            FocusSettingsSections()
        }
        .formStyle(.grouped)
        .navigationTitle("Permissions")
        .onAppear { permissions.refresh() }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
        #endif
    }

    private func row(_ kind: PermissionKind) -> some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbolName)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                Text(kind.detail)
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            control(kind)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func control(_ kind: PermissionKind) -> some View {
        switch permissions.states[kind] ?? .notDetermined {
        case .granted:
            Label("Access Granted", systemImage: "checkmark")
                .uiFont(.callout)
                .foregroundStyle(.secondary)
        case .partial:
            Button("Grant Full Access") { permissions.openSystemSettings(kind) }
        case .denied:
            Button("Open Settings") { permissions.openSystemSettings(kind) }
        case .unavailable:
            Text("Unavailable")
                .uiFont(.callout)
                .foregroundStyle(.tertiary)
        case .notDetermined:
            Button {
                pending = kind
                Task {
                    await permissions.request(kind)
                    pending = nil
                }
            } label: {
                if pending == kind {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Grant Access")
                }
            }
            .disabled(pending != nil)
        }
    }
}
