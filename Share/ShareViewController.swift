import UIKit
import SwiftUI
import UniformTypeIdentifiers
import MainstreamCore

/// "Mainstream" in the share sheet: shows the shared item as the animated code, right there,
/// for another phone's camera to read.
final class ShareViewController: UIViewController {
    private var savedBrightness: CGFloat?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        spinner.startAnimating()
        Task {
            let payload = await loadPayload()
            spinner.removeFromSuperview()
            guard let payload else { close(); return }
            show(payload)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let screen = view.window?.windowScene?.screen {
            savedBrightness = screen.brightness
            screen.brightness = 1
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let b = savedBrightness { view.window?.windowScene?.screen.brightness = b }
    }

    private func show(_ payload: Payload) {
        let host = UIHostingController(rootView: VisibleSender(payload: payload) { [weak self] in self?.close() })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    private func close() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    // MARK: loading the shared item

    private func loadPayload() async -> Payload? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        // prefer the richest representation: media and files, then links, then text
        for p in providers {
            for type in [UTType.image, .movie, .audio, .pdf, .data] where type != .data || !p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if p.hasItemConformingToTypeIdentifier(type.identifier), let payload = await file(p, type) { return payload }
            }
        }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                if url.isFileURL, let d = try? Data(contentsOf: url) {
                    return Payload(kind: PayloadPrep.kind(forName: url.lastPathComponent), name: url.lastPathComponent, data: d)
                }
                return Payload(kind: .text, name: "link.txt", data: Data(url.absoluteString.utf8))
            }
        }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let s = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                return Payload(kind: .text, name: "text.txt", data: Data(s.utf8))
            }
        }
        return nil
    }

    private func file(_ p: NSItemProvider, _ type: UTType) async -> Payload? {
        await withCheckedContinuation { c in
            _ = p.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                // the file is deleted when this handler returns, so read it now
                guard let url, let d = try? Data(contentsOf: url) else { c.resume(returning: nil); return }
                var name = p.suggestedName ?? url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "") : url.pathExtension
                if !ext.isEmpty && (name as NSString).pathExtension.isEmpty { name += "." + ext }
                c.resume(returning: Payload(kind: PayloadPrep.kind(forName: name), name: name, data: d))
            }
        }
    }
}
