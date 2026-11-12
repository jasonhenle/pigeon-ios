import MessageUI
import SwiftUI
import UIKit

/// Where developer feedback goes, and what the draft starts with.
enum Feedback {
    static let address = "hello@thepigeonlabs.com"
    static let subject = "Pigeon Remote feedback"

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (build \(b))"
    }

    /// Versions only: no name, address, network or account details. The person can edit all of it.
    static func body(product: String, pigeonVersion: String?, system: String, model: String) -> String {
        """


        ———
        Pigeon Remote \(appVersion)
        \(model), iOS \(system)
        \(product == "marquee" ? "Pigeon Marquee" : "Pigeon Clock"), PigeonOS \(pigeonVersion ?? "unknown")
        """
    }

    static func mailto(body: String) -> URL? {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = address
        c.queryItems = [.init(name: "subject", value: subject), .init(name: "body", value: body)]
        return c.url
    }
}

/// System › Send Developer Feedback: a Mail draft to the developers, or the address to copy.
struct FeedbackButton: View {
    let device: KnownDevice
    let pigeonVersion: String?
    @Environment(\.openURL) private var openURL
    @State private var composing = false
    @State private var showAddress = false

    private var body_: String {
        Feedback.body(product: device.product, pigeonVersion: pigeonVersion,
                      system: UIDevice.current.systemVersion, model: UIDevice.current.model)
    }

    var body: some View {
        Button(action: send) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Send Developer Feedback").font(Theme.uiBold(16)).foregroundStyle(.white)
                    Text("Ideas, problems, anything. It goes to the people who make Pigeon.")
                        .font(Theme.ui(12)).foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "envelope").foregroundStyle(Theme.inactive)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $composing) {
            MailComposer(to: Feedback.address, subject: Feedback.subject, body: body_) { composing = false }
                .ignoresSafeArea()
        }
        .alert("Send feedback", isPresented: $showAddress) {
            Button("Copy Address") { UIPasteboard.general.string = Feedback.address }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Email \(Feedback.address) from any mail app.")
        }
    }

    private func send() {
        if MFMailComposeViewController.canSendMail() {
            composing = true
        } else if let url = Feedback.mailto(body: body_) {
            // Another mail app, if one handles mailto:; otherwise the address to copy.
            openURL(url) { accepted in if !accepted { showAddress = true } }
        } else {
            showAddress = true
        }
    }
}

/// Apple Mail's compose sheet.
private struct MailComposer: UIViewControllerRepresentable {
    let to: String
    let subject: String
    let body: String
    var onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients([to])
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)
        return vc
    }

    func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult, error: Error?) {
            onFinish()
        }
    }
}
