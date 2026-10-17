import SwiftUI
import AVKit
import MapKit
import Photos
import QuickLook
import Contacts
import ContactsUI
import NetworkExtension
import UniformTypeIdentifiers
import MainstreamCore

/// What a received payload turns out to be, so the result screen can offer the right action.
enum Smart {
    case text(String)
    case link(URL)
    case wifi(WiFi)
    case location(CLLocationCoordinate2D)
    case contact(CNContact)
    case image(UIImage)
    case video
    case audio
    case file

    static func detect(_ p: Payload) -> Smart {
        let type = PayloadPrep.type(of: p)
        if type?.conforms(to: .vCard) == true || (p.kind == .text && String(decoding: p.data.prefix(11), as: UTF8.self).uppercased() == "BEGIN:VCARD"),
           let c = (try? CNContactVCardSerialization.contacts(with: p.data))?.first {
            return .contact(c)
        }
        if p.kind == .image, let img = UIImage(data: p.data) { return .image(img) }
        if type?.conforms(to: .movie) == true { return .video }
        if p.kind == .audio || type?.conforms(to: .audio) == true { return .audio }
        guard p.kind == .text || type?.conforms(to: .plainText) == true else { return .file }
        let text = String(decoding: p.data, as: UTF8.self)
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let w = WiFi(parsing: t) { return .wifi(w) }
        if let c = geo(t) { return .location(c) }
        if !t.contains(where: \.isWhitespace), let u = URL(string: t), let scheme = u.scheme?.lowercased(),
           ["http", "https", "mailto", "tel", "sms", "facetime", "maps"].contains(scheme) {
            return .link(u)
        }
        return .text(text)
    }

    /// `geo:lat,lon` (first line), as sent by the location payload or other apps.
    private static func geo(_ t: String) -> CLLocationCoordinate2D? {
        guard let line = t.split(separator: "\n").first, line.lowercased().hasPrefix("geo:") else { return nil }
        let parts = line.dropFirst(4).split(separator: "?")[0].split(separator: ",")
        guard parts.count >= 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
              abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

/// The received payload saved once to a temporary file, for previews, sharing and saving.
final class ReceivedFile: ObservableObject {
    let url: URL
    init(_ p: Payload) {
        let name = p.name.isEmpty ? "file" : (p.name as NSString).lastPathComponent
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(name)
        try? p.data.write(to: url)
    }
    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

struct ResultView: View {
    let payload: Payload
    private let smart: Smart
    @StateObject private var file: ReceivedFile
    @State private var done: Bool?            // outcome of the last action (✓ / ✗)
    @State private var addingContact = false
    @State private var revealPassword = false
    @State private var videoPlayer: AVPlayer?

    init(payload: Payload) {
        self.payload = payload
        smart = Smart.detect(payload)
        _file = StateObject(wrappedValue: ReceivedFile(payload))
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 40) {
                actions
                if let text = plainText {
                    Button { UIPasteboard.general.string = text; done = true } label: { icon("doc.on.doc") }
                    ShareLink(item: text) { icon("square.and.arrow.up") }
                } else {
                    ShareLink(item: file.url) { icon("square.and.arrow.up") }
                }
            }
            .padding(.vertical, 20)
            .overlay(alignment: .trailing) {
                if let done {
                    Image(systemName: done ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(done ? .green : .red)
                        .padding(.trailing, 24)
                        .transition(.opacity)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $addingContact) {
            if case .contact(let c) = smart { ContactAdd(contact: c) }
        }
        .animation(.default, value: done)
    }

    private var plainText: String? {
        switch smart {
        case .text(let t): return t
        case .link(let u): return u.absoluteString
        default: return nil
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.title3).frame(minWidth: 32, minHeight: 32)
    }

    // MARK: content

    @ViewBuilder private var content: some View {
        switch smart {
        case .text(let t):
            ScrollView {
                Text(t)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
        case .link(let u):
            VStack(spacing: 18) {
                Image(systemName: "link").font(.system(size: 44)).foregroundStyle(.secondary)
                Text(u.absoluteString).font(.callout).multilineTextAlignment(.center).textSelection(.enabled).padding(.horizontal, 24)
            }
        case .wifi(let w):
            VStack(spacing: 16) {
                Image(systemName: "wifi").font(.system(size: 48)).foregroundStyle(.secondary)
                Text(w.ssid).font(.title3.weight(.semibold))
                if !w.password.isEmpty {
                    Button { revealPassword.toggle() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "key")
                            Text(revealPassword ? w.password : String(repeating: "•", count: min(12, w.password.count)))
                                .font(.body.monospaced())
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        case .location(let c):
            Map(initialPosition: .region(MKCoordinateRegion(center: c, latitudinalMeters: 800, longitudinalMeters: 800))) {
                Marker("", coordinate: c)
            }
        case .contact(let c):
            VStack(spacing: 12) {
                Image(systemName: "person.crop.circle").font(.system(size: 64)).foregroundStyle(.secondary)
                Text(CNContactFormatter.string(from: c, style: .fullName) ?? c.organizationName).font(.title3.weight(.semibold))
                ForEach(Array(c.phoneNumbers.prefix(3).enumerated()), id: \.offset) { _, n in
                    Label(n.value.stringValue, systemImage: "phone").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(c.emailAddresses.prefix(2).enumerated()), id: \.offset) { _, e in
                    Label(e.value as String, systemImage: "envelope").font(.callout).foregroundStyle(.secondary)
                }
            }
        case .image(let img):
            Image(uiImage: img).resizable().scaledToFit().padding(12)
        case .video:
            VideoPlayer(player: videoPlayer)
                .onAppear { if videoPlayer == nil { videoPlayer = AVPlayer(url: file.url) } }
                .onDisappear { videoPlayer?.pause() }
        case .audio:
            AudioResult(player: Player(data: payload.data))
        case .file:
            QuickLookPreview(url: file.url)
        }
    }

    // MARK: actions

    @ViewBuilder private var actions: some View {
        switch smart {
        case .link(let u):
            Link(destination: u) { icon(u.scheme == "tel" ? "phone" : u.scheme == "mailto" ? "envelope" : "safari") }
        case .text(let t):
            ForEach(Array(detected(t).enumerated()), id: \.offset) { _, d in
                Link(destination: d.1) { icon(d.0) }
            }
        case .wifi(let w):
            Button { join(w) } label: { icon("wifi") }
            if !w.password.isEmpty {
                Button { UIPasteboard.general.string = w.password; done = true } label: { icon("key") }
            }
        case .location(let c):
            Button {
                MKMapItem(placemark: MKPlacemark(coordinate: c)).openInMaps()
            } label: { icon("map") }
        case .contact:
            Button { addingContact = true } label: { icon("person.badge.plus") }
        case .image:
            Button { save(.photo) } label: { icon("square.and.arrow.down") }
        case .video:
            Button { save(.video) } label: { icon("square.and.arrow.down") }
        case .audio, .file:
            EmptyView()
        }
    }

    /// Phone numbers, links and addresses in plain text (up to three), each with its action.
    private func detected(_ t: String) -> [(String, URL)] {
        let types: NSTextCheckingResult.CheckingType = [.link, .phoneNumber, .address]
        guard let det = try? NSDataDetector(types: types.rawValue) else { return [] }
        var out: [(String, URL)] = []
        for m in det.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
            if let u = m.url { out.append((u.scheme == "mailto" ? "envelope" : "safari", u)) }
            if let n = m.phoneNumber, let u = URL(string: "tel:" + n.filter { "+0123456789".contains($0) }) { out.append(("phone", u)) }
            if m.resultType == .address, let r = Range(m.range, in: t),
               let q = String(t[r]).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let u = URL(string: "https://maps.apple.com/?q=" + q) {
                out.append(("map", u))
            }
            if out.count >= 3 { break }
        }
        return out
    }

    private func join(_ w: WiFi) {
        let cfg = w.password.isEmpty ? NEHotspotConfiguration(ssid: w.ssid) : NEHotspotConfiguration(ssid: w.ssid, passphrase: w.password, isWEP: false)
        cfg.hidden = w.hidden
        NEHotspotConfigurationManager.shared.apply(cfg) { error in
            let e = error as NSError?
            let ok = e == nil || e?.code == NEHotspotConfigurationError.alreadyAssociated.rawValue
            DispatchQueue.main.async { done = ok }
        }
    }

    private func save(_ type: PHAssetResourceType) {
        let url = file.url, data = payload.data
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { DispatchQueue.main.async { done = false }; return }
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                if type == .photo { req.addResource(with: .photo, data: data, options: nil) } else { req.addResource(with: .video, fileURL: url, options: nil) }
            }) { ok, _ in DispatchQueue.main.async { done = ok } }
        }
    }
}

/// Quick Look for any other file (PDF, documents, archives…).
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let q = QLPreviewController()
        q.dataSource = context.coordinator
        return q
    }
    func updateUIViewController(_ q: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(_ url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

/// The system "new contact" card for a received vCard.
struct ContactAdd: UIViewControllerRepresentable {
    let contact: CNContact
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator { dismiss() } }
    func makeUIViewController(context: Context) -> UINavigationController {
        let vc = CNContactViewController(forUnknownContact: contact)
        vc.contactStore = CNContactStore()
        vc.allowsActions = false
        vc.delegate = context.coordinator
        vc.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { _ in context.coordinator.close() })
        return UINavigationController(rootViewController: vc)
    }
    func updateUIViewController(_ c: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        let close: () -> Void
        init(_ close: @escaping () -> Void) { self.close = close }
        func contactViewController(_ vc: CNContactViewController, didCompleteWith contact: CNContact?) { close() }
    }
}

struct AudioResult: View {
    @StateObject var player: Player

    var body: some View {
        VStack(spacing: 26) {
            Button { player.toggle() } label: {
                Image(systemName: player.playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 84))
            }
            ProgressView(value: player.position).frame(width: 200)
        }
        .onDisappear { player.stop() }
    }
}
