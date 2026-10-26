#if os(macOS)
import SwiftUI

/// Account connection. Mirrors the Premiere plugin's "sign in to your
/// Higgsfield account from the panel"; generations use the account's plan
/// credits.
struct SignInView: View {
    @ObservedObject var model: PanelModel
    @State private var token = ""
    @State private var showTokenField = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect your Higgsfield account").font(.system(size: 16, weight: .semibold))
                    Text("Generations and edits use the credits of your Higgsfield plan.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }

                if case .signingIn(let message) = model.authState {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(message).font(.system(size: 12))
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.corner))
                }

                if model.isOAuthAvailable {
                    Button {
                        Task { await model.signInWithHiggsfield() }
                    } label: {
                        Label("Sign in with Higgsfield", systemImage: "person.badge.key")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isBusy)
                }

                Card("Higgsfield CLI session") {
                    Text("Uses the official Higgsfield CLI’s sign-in. Install it once with `npm install -g @higgsfield/cli`; signing in opens Higgsfield in your browser.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await model.signInWithCLI() }
                    } label: {
                        Label("Use Higgsfield CLI Session", systemImage: "terminal")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .disabled(isBusy || (!model.isExtension && !model.isCLIInstalled))
                    if !model.isExtension && !model.isCLIInstalled {
                        Label("The Higgsfield CLI wasn’t found on this Mac.", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }

                DisclosureGroup("Use an access token", isExpanded: $showTokenField) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Paste the output of `hf auth token`. Tokens expire; a CLI session refreshes automatically.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryText)
                        SecureField("Access token", text: $token)
                            .textFieldStyle(.roundedBorder)
                        Button("Connect") { Task { await model.signIn(withAccessToken: token); token = "" } }
                            .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
                    }
                    .padding(.top, 6)
                }
                .font(.system(size: 12))

                if !model.isOAuthAvailable {
                    Text("Built-in “Sign in with Higgsfield” is enabled when this build includes an OAuth client ID issued by Higgsfield (HiggsfieldOAuthClientID).")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
    }

    private var isBusy: Bool {
        if case .signingIn = model.authState { return true }
        return false
    }
}
#endif
