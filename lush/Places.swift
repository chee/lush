import SwiftUI
import Contacts
import CoreLocation
import MapKit

struct ContactAddress: Identifiable, Hashable, @unchecked Sendable {
    let id: String
    let personName: String
    let placeName: String
    let label: String
    let formatted: String
    let postal: CNPostalAddress
}

enum ContactPlaces {
    static let keys = [
        CNContactGivenNameKey,
        CNContactFamilyNameKey,
        CNContactNicknameKey,
        CNContactOrganizationNameKey,
        CNContactPostalAddressesKey,
    ] as [CNKeyDescriptor]

    static func requestAccess() async -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: return true
        case .denied, .restricted: return false
        default: return (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
        }
    }

    static func everyone() throws -> [ContactAddress] {
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .givenName
        var found: [ContactAddress] = []
        try CNContactStore().enumerateContacts(with: request) { contact, _ in
            found.append(contentsOf: addresses(of: contact, isMe: false))
        }
        return found
    }

    #if os(macOS)
    static func mine() throws -> [ContactAddress] {
        let me = try CNContactStore().unifiedMeContactWithKeys(toFetch: keys)
        return addresses(of: me, isMe: true)
            .filter { $0.placeName == "Home" || $0.placeName == "Work" }
    }
    #endif

    static func addresses(of contact: CNContact, isMe: Bool) -> [ContactAddress] {
        contact.postalAddresses.enumerated().compactMap { index, entry in
            let formatted = CNPostalAddressFormatter
                .string(from: entry.value, style: .mailingAddress)
                .split(separator: "\n")
                .joined(separator: ", ")
            guard !formatted.isEmpty else { return nil }
            let label = entry.label ?? CNLabelOther
            return ContactAddress(
                id: "\(contact.identifier)-\(index)",
                personName: personName(contact),
                placeName: placeName(contact, label: label, isMe: isMe),
                label: CNLabeledValue<NSString>.localizedString(forLabel: label),
                formatted: formatted,
                postal: entry.value
            )
        }
    }

    static func personName(_ contact: CNContact) -> String {
        if !contact.nickname.isEmpty { return contact.nickname }
        if !contact.givenName.isEmpty { return contact.givenName }
        if !contact.familyName.isEmpty { return contact.familyName }
        return contact.organizationName
    }

    static func placeName(_ contact: CNContact, label: String, isMe: Bool) -> String {
        let localized = CNLabeledValue<NSString>.localizedString(forLabel: label)
        if isMe {
            switch label {
            case CNLabelHome: return "Home"
            case CNLabelWork: return "Work"
            default: return localized
            }
        }
        if label == CNLabelWork, !contact.organizationName.isEmpty {
            return contact.organizationName
        }
        let person = personName(contact)
        guard !person.isEmpty else { return localized }
        if label == CNLabelHome { return "\(person)'s" }
        return "\(person)'s \(localized.lowercased())"
    }

    static func geocode(_ address: ContactAddress) async -> SavedPlace? {
        let addressString = CNPostalAddressFormatter.string(from: address.postal, style: .mailingAddress)
        guard let request = MKGeocodingRequest(addressString: addressString),
              let item = try? await request.mapItems.first
        else { return nil }
        let coord = item.location.coordinate
        return SavedPlace(
            name: address.placeName,
            latitude: coord.latitude,
            longitude: coord.longitude
        )
    }

    static func geocode(_ addresses: [ContactAddress]) async -> [SavedPlace] {
        var places: [SavedPlace] = []
        for (index, address) in addresses.enumerated() {
            if index > 0 { try? await Task.sleep(for: .milliseconds(1200)) }
            if let place = await geocode(address) { places.append(place) }
        }
        return places
    }
}

struct ContactPlacePicker: View {
    let onAdd: ([SavedPlace]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var addresses: [ContactAddress] = []
    @State private var selection: Set<String> = []
    @State private var filter = ""
    @State private var loading = true
    @State private var adding = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter contacts", text: $filter)
                    .textFieldStyle(.plain)
            }
            .padding(12)

            Divider()

            if loading {
                ProgressView("Reading contacts…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message {
                ContentUnavailableView(
                    "No addresses",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text(message)
                )
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else {
                List(filtered) { address in
                    Button {
                        if selection.contains(address.id) {
                            selection.remove(address.id)
                        } else {
                            selection.insert(address.id)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selection.contains(address.id)
                                ? "checkmark.circle.fill"
                                : "circle")
                                .foregroundStyle(selection.contains(address.id) ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(address.placeName)
                                Text("\(address.label) · \(address.formatted)")
                                    .uiFont(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }

            Divider()

            HStack {
                if adding {
                    ProgressView()
                        .controlSize(.small)
                    Text("Looking up addresses…")
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(selection.count == 1 ? "Add Place" : "Add \(selection.count) Places") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.isEmpty || adding)
            }
            .padding(12)
        }
        .frame(width: 460, height: 460)
        .task { await load() }
    }

    private var filtered: [ContactAddress] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return addresses }
        return addresses.filter {
            $0.placeName.localizedCaseInsensitiveContains(query)
                || $0.personName.localizedCaseInsensitiveContains(query)
                || $0.formatted.localizedCaseInsensitiveContains(query)
        }
    }

    private func load() async {
        guard await ContactPlaces.requestAccess() else {
            loading = false
            message = "Lush has no access to your contacts. Turn it on in Permissions."
            return
        }
        let found = await Task.detached { try? ContactPlaces.everyone() }.value ?? []
        addresses = found
        loading = false
        if found.isEmpty { message = "None of your contacts have a postal address." }
    }

    private func add() {
        let chosen = addresses.filter { selection.contains($0.id) }
        adding = true
        Task {
            let places = await ContactPlaces.geocode(chosen)
            adding = false
            onAdd(places)
            dismiss()
        }
    }
}

struct MapPlacePicker: View {
    let start: CLLocationCoordinate2D?
    let onAdd: (SavedPlace) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var camera: MapCameraPosition
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var name = ""
    @State private var radius: Double = 150
    @State private var query = ""
    @State private var searching = false

    init(start: CLLocationCoordinate2D?, onAdd: @escaping (SavedPlace) -> Void) {
        self.start = start
        self.onAdd = onAdd
        let center = start ?? CLLocationCoordinate2D(latitude: 51.5072, longitude: -0.1276)
        _camera = State(initialValue: .region(MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )))
        _coordinate = State(initialValue: start)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search for a place or address", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { search() }
                if searching {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(12)

            Divider()

            MapReader { proxy in
                Map(position: $camera) {
                    if let coordinate {
                        Marker(name.isEmpty ? "New place" : name, coordinate: coordinate)
                        MapCircle(center: coordinate, radius: radius)
                            .foregroundStyle(Color.accentColor.opacity(0.2))
                            .stroke(Color.accentColor, lineWidth: 1)
                    }
                }
                .onTapGesture { point in
                    guard let tapped = proxy.convert(point, from: .local) else { return }
                    coordinate = tapped
                    Task { await suggestName(at: tapped) }
                }
            }

            Divider()

            Form {
                TextField("Name", text: $name)
                LabeledContent("Radius") {
                    HStack(spacing: 12) {
                        Slider(value: $radius, in: 25...1000, step: 25)
                        Text("\(Int(radius))m")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Tap the map to move the pin.")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .frame(height: 150)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add Place") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(coordinate == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 520, height: 620)
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searching = true
        Task {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = text
            if let coordinate {
                request.region = MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
                )
            }
            let response = try? await MKLocalSearch(request: request).start()
            searching = false
            guard let item = response?.mapItems.first else { return }
            let found = item.location.coordinate
            coordinate = found
            if name.trimmingCharacters(in: .whitespaces).isEmpty, let itemName = item.name {
                name = itemName
            }
            camera = .region(MKCoordinateRegion(
                center: found,
                span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
            ))
        }
    }

    private func suggestName(at coordinate: CLLocationCoordinate2D) async {
        guard name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first,
              let found = item.name
        else { return }
        name = found
    }

    private func add() {
        guard let coordinate else { return }
        onAdd(SavedPlace(
            name: name.trimmingCharacters(in: .whitespaces),
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radius: radius
        ))
        dismiss()
    }
}
