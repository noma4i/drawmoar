import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        guard let group = Bundle.main.object(forInfoDictionaryKey: "DrawMoarAppGroup") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else {
            showMessage("Cannot access the shared container.")
            return
        }
        let attachments = (extensionContext?.inputItems as? [NSExtensionItem])?.flatMap { $0.attachments ?? [] } ?? []
        guard let attachment = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) else {
            showMessage("No image was provided.")
            return
        }
        let directory = container.appendingPathComponent("Inbox", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            showMessage(error.localizedDescription)
            return
        }
        attachment.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] url, _ in
            if let url {
                do {
                    let ext = url.pathExtension.isEmpty ? "image" : url.pathExtension
                    try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext))
                    DispatchQueue.main.async { self?.openApp() }
                    return
                } catch {
                    DispatchQueue.main.async { self?.showMessage(error.localizedDescription) }
                    return
                }
            }
            attachment.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                do {
                    guard let data else { throw error ?? CocoaError(.fileReadUnknown) }
                    try data.write(to: directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("image"), options: .atomic)
                    DispatchQueue.main.async { self?.openApp() }
                } catch {
                    DispatchQueue.main.async { self?.showMessage(error.localizedDescription) }
                }
            }
        }
    }

    private func openApp() {
        var responder: UIResponder? = self
        while let current = responder {
            if let app = current as? UIApplication {
                app.open(URL(string: "drawmoar://import")!, options: [:]) { [weak self] opened in
                    if opened {
                        self?.extensionContext?.completeRequest(returningItems: nil)
                    } else {
                        self?.showMessage("Saved. Open DrawMoar to edit.")
                    }
                }
                return
            }
            responder = current.next
        }
        showMessage("Saved. Open DrawMoar to edit.")
    }

    private func showMessage(_ message: String) {
        view.backgroundColor = .systemBackground
        let label = UILabel()
        label.text = message
        label.numberOfLines = 0
        label.textAlignment = .center
        let button = UIButton(type: .system)
        button.setTitle("Done", for: .normal)
        button.addTarget(self, action: #selector(done), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }

    @objc private func done() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
