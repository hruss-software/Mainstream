import SwiftUI
import Contacts
import ContactsUI
import CoreLocation
import MainstreamCore

/// System contact picker (no Contacts permission needed); returns the contact as a vCard.
struct ContactPicker: UIViewControllerRepresentable {
    let onPick: (Payload) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick) }
    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let c = CNContactPickerViewController()
        c.delegate = context.coordinator
        return c
    }
    func updateUIViewController(_ c: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPick: (Payload) -> Void
        init(_ onPick: @escaping (Payload) -> Void) { self.onPick = onPick }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            guard let data = try? CNContactVCardSerialization.data(with: [contact]) else { return }
            let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            onPick(Payload(kind: .file, name: "\(name.isEmpty ? "contact" : name).vcf", data: data))
        }
    }
}

/// Network name and password, sent in the standard `WIFI:` form that the receiver can join.
struct WiFiComposer: View {
    let onSend: (Payload) -> Void
    @State private var ssid = ""
    @State private var password = ""
    @State private var reveal = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                HStack(spacing: 12) {
                    Image(systemName: "wifi").foregroundStyle(.secondary).frame(width: 24)
                    TextField("", text: $ssid).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                HStack(spacing: 12) {
                    Image(systemName: "key").foregroundStyle(.secondary).frame(width: 24)
                    Group {
                        if reveal { TextField("", text: $password) } else { SecureField("", text: $password) }
                    }
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let text = WiFi(ssid: ssid, password: password).encoded
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            onSend(Payload(kind: .text, name: "wifi.txt", data: Data(text.utf8)))
                        }
                    } label: { Image(systemName: "paperplane.fill") }
                    .disabled(ssid.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// `WIFI:T:WPA;S:name;P:password;;` (the format camera apps read from QR codes).
struct WiFi: Equatable {
    var ssid: String
    var password: String
    var hidden = false

    private static func escape(_ s: String) -> String {
        var o = ""
        for c in s { if c == "\\" || c == ";" || c == "," || c == ":" || c == "\"" { o.append("\\") }; o.append(c) }
        return o
    }

    var encoded: String {
        "WIFI:T:\(password.isEmpty ? "nopass" : "WPA");S:\(WiFi.escape(ssid));" + (password.isEmpty ? "" : "P:\(WiFi.escape(password));") + (hidden ? "H:true;" : "") + ";"
    }

    init(ssid: String, password: String, hidden: Bool = false) {
        self.ssid = ssid
        self.password = password
        self.hidden = hidden
    }

    init?(parsing text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.uppercased().hasPrefix("WIFI:") else { return nil }
        var fields: [String: String] = [:]
        var key = "", value = "", inValue = false, escaped = false
        for c in t.dropFirst(5) {
            if escaped { value.append(c); escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if !inValue {
                if c == ":" { inValue = true } else if c != ";" { key.append(c) }
            } else if c == ";" {
                fields[key.uppercased()] = value
                key = ""; value = ""; inValue = false
            } else {
                value.append(c)
            }
        }
        guard let s = fields["S"], !s.isEmpty else { return nil }
        ssid = s
        password = fields["P"] ?? ""
        hidden = fields["H"]?.lowercased() == "true"
    }
}

/// One-shot current location, sent as a `geo:` URI plus an Apple Maps link for other apps.
final class LocationFetcher: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var busy = false
    private let manager = CLLocationManager()
    private var done: ((Payload) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func fetch(_ done: @escaping (Payload) -> Void) {
        self.done = done
        busy = true
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: busy = false
        default: manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        guard busy else { return }
        switch m.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: m.requestLocation()
        case .denied, .restricted: busy = false
        default: break
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard busy, let l = locs.last else { return }
        busy = false
        let lat = String(format: "%.6f", l.coordinate.latitude), lon = String(format: "%.6f", l.coordinate.longitude)
        let text = "geo:\(lat),\(lon)\nhttps://maps.apple.com/?ll=\(lat),\(lon)&q=\(lat),\(lon)"
        done?(Payload(kind: .text, name: "location.txt", data: Data(text.utf8)))
        done = nil
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) { busy = false }
}
