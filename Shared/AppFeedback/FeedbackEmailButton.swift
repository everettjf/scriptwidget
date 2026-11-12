import SwiftUI
#if os(iOS)
import MessageUI
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Opens a draft for the user to review and send. No feedback is transmitted automatically.
@MainActor
struct AtomSproutFeedbackEmailButton: View {
    let appName: String
    @Environment(\.openURL) private var openURL
    @State private var composing = false
    @State private var compositionFailed = false
    @State private var showingFallback = false

    private var email: AtomSproutFeedbackEmail {
        .current(appName: appName, prompt: String(localized: "Please describe your feedback here."))
    }

    var body: some View {
        Button(action: compose) {
            Label("Email Feedback", systemImage: "envelope")
        }
        .accessibilityIdentifier("atomsprout.email-feedback")
        #if os(iOS)
        .sheet(isPresented: $composing, onDismiss: {
            if compositionFailed { compositionFailed = false; showingFallback = true }
        }) {
            AtomSproutMailComposer(email: email) { failed in
                compositionFailed = failed
                composing = false
            }
            .ignoresSafeArea()
        }
        .alert("Mail Unavailable", isPresented: $showingFallback) {
            Button("Copy Email Details") { UIPasteboard.general.string = email.copyableText }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(email.copyableText)
        }
        #endif
    }

    private func compose() {
        #if os(iOS)
        if MFMailComposeViewController.canSendMail() {
            composing = true
        } else if let url = email.mailtoURL {
            openURL(url) { opened in if !opened { showingFallback = true } }
        } else { showingFallback = true }
        #elseif os(macOS)
        if let url = email.mailtoURL, NSWorkspace.shared.open(url) { return }
        // A native alert also works when this button is used in a menu without an active window.
        let alert = NSAlert()
        alert.messageText = String(localized: "Mail Unavailable")
        alert.informativeText = email.copyableText
        alert.addButton(withTitle: String(localized: "Copy Email Details"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(email.copyableText, forType: .string)
        }
        #endif
    }
}

#if os(iOS)
private struct AtomSproutMailComposer: UIViewControllerRepresentable {
    let email: AtomSproutFeedbackEmail
    let finished: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }
    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([AtomSproutFeedbackEmail.recipient])
        controller.setSubject(email.subject)
        controller.setMessageBody(email.body, isHTML: false)
        return controller
    }
    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}
    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let finished: (Bool) -> Void
        init(finished: @escaping (Bool) -> Void) { self.finished = finished }
        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult, error: Error?) {
            finished(result == .failed || error != nil)
        }
    }
}
#endif
