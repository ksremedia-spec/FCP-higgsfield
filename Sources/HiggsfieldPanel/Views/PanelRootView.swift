#if os(macOS)
import HiggsfieldKit
import SwiftUI

/// The Higgsfield panel: header with account and credits, the seven tools,
/// the active tool's form, the Generate bar and recent activity.
public struct PanelRootView: View {
    @ObservedObject var model: PanelModel

    public init(model: PanelModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            HeaderView(model: model)
            Divider().overlay(Theme.cardStroke)
            switch model.authState {
            case .checking:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut, .signingIn:
                SignInView(model: model)
            case .signedIn:
                signedInBody
            }
        }
        .background(Theme.panelBackground)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .overlay(alignment: .top) { BannerView(model: model).padding(.top, 52) }
        .frame(minWidth: 360, minHeight: 560)
    }

    private var signedInBody: some View {
        VStack(spacing: 0) {
            ToolStrip(selection: $model.operation)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            Divider().overlay(Theme.cardStroke)
            VSplitView {
                VStack(spacing: 0) {
                    ScrollView {
                        ToolFormView(model: model)
                            .padding(10)
                    }
                    SubmitBar(model: model)
                }
                .frame(minHeight: 300)
                ActivityView(model: model)
                    .frame(minHeight: 120, idealHeight: 220)
            }
        }
    }
}

struct HeaderView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        HStack(spacing: 8) {
            Logo()
            VStack(alignment: .leading, spacing: 0) {
                Text("Higgsfield").font(.system(size: 13, weight: .bold))
                Text(model.isExtension ? (model.timeline.sequenceName.map { "FCP · \($0)" } ?? "Final Cut Pro") : "for Final Cut Pro")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            if case .signedIn(let source) = model.authState {
                if let account = model.account {
                    Chip(text: "\(Self.credits(account.credits)) credits", systemImage: "bolt.fill", tint: Theme.accent.opacity(0.18))
                        .help("Higgsfield credits available\(account.subscriptionPlanType.map { " · \($0.capitalized) plan" } ?? "")")
                }
                AccountMenu(model: model, source: source)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    static func credits(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

struct Logo: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Theme.accent)
            Text("H").font(.system(size: 14, weight: .black)).foregroundStyle(Theme.accentForeground)
        }
        .frame(width: 24, height: 24)
        .accessibilityLabel("Higgsfield")
    }
}

struct AccountMenu: View {
    @ObservedObject var model: PanelModel
    var source: CredentialSource

    var body: some View {
        Menu {
            if let email = model.account?.email { Text(email) }
            if let plan = model.account?.subscriptionPlanType { Text("\(plan.capitalized) plan") }
            Text(sourceLabel)
            Divider()
            if model.workspaces.count > 1 {
                Picker("Workspace", selection: Binding(get: { model.workspaceID ?? "" }, set: { model.selectWorkspace($0) })) {
                    ForEach(model.workspaces) { ws in
                        Text(ws.name ?? ws.id).tag(ws.id)
                    }
                }
            }
            Button("Refresh Credits") { Task { await model.refreshBalance() } }
            Toggle("Add Results to Final Cut Pro Automatically", isOn: $model.autoImport)
            Divider()
            Button("Sign Out") { model.signOut() }
        } label: {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 16))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    var sourceLabel: String {
        switch source {
        case .oauth: return "Signed in with Higgsfield"
        case .higgsfieldCLI: return "Using Higgsfield CLI session"
        case .manual: return "Using a pasted access token"
        }
    }
}

struct ToolStrip: View {
    @Binding var selection: OperationKind

    var body: some View {
        HStack(spacing: 2) {
            ForEach(OperationKind.allCases) { op in
                Button {
                    selection = op
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: op.symbolName).font(.system(size: 15))
                        Text(op.shortTitle).font(.system(size: 9, weight: .medium)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .foregroundStyle(selection == op ? Theme.accentForeground : .white.opacity(0.85))
                    .background(RoundedRectangle(cornerRadius: 6).fill(selection == op ? Theme.accent : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(op.title)
                .accessibilityLabel(op.title)
            }
        }
    }
}

struct SubmitBar: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(spacing: 6) {
            if let message = model.validationMessage {
                Label(message, systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if model.insufficientCredits {
                Label("Not enough credits for this generation.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                costLabel
                Button(action: model.submit) {
                    Label(model.operation == .generateVideo || model.operation == .generateImage ? "Generate" : model.operation.title, systemImage: "sparkles")
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canSubmit)
            }
        }
        .padding(10)
        .background(Theme.panelBackground.opacity(0.95))
        .overlay(Divider().overlay(Theme.cardStroke), alignment: .top)
    }

    @ViewBuilder
    private var costLabel: some View {
        switch model.costState {
        case .idle:
            EmptyView()
        case .estimating:
            ProgressView().controlSize(.mini).frame(width: 60)
        case .estimate(let e):
            Label(HeaderView.credits(e.creditsExact ?? e.credits), systemImage: "bolt.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .help("Estimated Higgsfield credits for this generation")
                .frame(minWidth: 60)
        case .unavailable(let reason):
            Image(systemName: "bolt.slash")
                .foregroundStyle(Theme.secondaryText)
                .help("Cost estimate unavailable: \(reason)")
                .frame(width: 30)
        }
    }
}

struct BannerView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        if let banner = model.banner {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon(banner.kind)).foregroundStyle(color(banner.kind))
                Text(banner.text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { model.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: banner.id) {
                try? await Task.sleep(nanoseconds: banner.kind == .error ? 12_000_000_000 : 5_000_000_000)
                if model.banner?.id == banner.id { model.banner = nil }
            }
        }
    }

    func icon(_ kind: PanelModel.Banner.Kind) -> String {
        switch kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.octagon.fill"
        }
    }

    func color(_ kind: PanelModel.Banner.Kind) -> Color {
        switch kind {
        case .info: return .blue
        case .success: return .green
        case .error: return .red
        }
    }
}
#endif
