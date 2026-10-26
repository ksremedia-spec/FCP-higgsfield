#if os(macOS)
import HiggsfieldKit
import SwiftUI
import UniformTypeIdentifiers

/// The active tool: source, prompt, tool-specific controls, model and settings.
struct ToolFormView: View {
    @ObservedObject var model: PanelModel

    private var op: OperationKind { model.operation }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(op.title).font(.system(size: 15, weight: .semibold))
                Text(op.tagline).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }

            SourceWellView(model: model)

            if op == .drawToEdit, model.draft.source != nil {
                DrawToEditCard(model: model)
            }

            if op.usesPrompt {
                PromptCard(model: model)
            }

            switch op {
            case .reframe:
                AspectRatioCard(model: model)
            case .upscale:
                UpscaleTargetCard(model: model)
            default:
                EmptyView()
            }

            if [OperationKind.generateVideo, .generateImage, .editVideo, .reframe].contains(op) {
                ReferencesCard(model: model)
            }

            SettingsCard(model: model)
        }
    }
}

struct PromptCard: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        Card("Prompt") {
            ZStack(alignment: .topLeading) {
                if model.draft.prompt.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText.opacity(0.7))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: Binding(get: { model.draft.prompt }, set: { v in var d = model.draft; d.prompt = v; model.draft = d }))
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 64, maxHeight: 140)
            }
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var placeholder: String {
        switch model.operation {
        case .generateVideo: return "Describe the shot: subject, action, camera move, light…"
        case .generateImage: return "Describe the image…"
        case .editVideo: return "What should change? e.g. “turn day into a snowy night”"
        case .drawToEdit: return "Describe what your drawing means, e.g. “make the jacket red”"
        default: return ""
        }
    }
}

/// Reframe: choose the target canvas like the plugin's one-click formats.
struct AspectRatioCard: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        let options = choices
        Card("Target format") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(options, id: \.self) { value in
                    let selected = model.draft.values["aspect_ratio"] == value
                    Button {
                        model.setValue(value, for: "aspect_ratio")
                    } label: {
                        VStack(spacing: 4) {
                            AspectGlyph(ratio: value.stringValue ?? "1:1").frame(height: 24)
                            Text(value.displayString).font(.system(size: 11, weight: .medium))
                            Text(Self.platformHint(value.stringValue ?? "")).font(.system(size: 9)).foregroundStyle(Theme.secondaryText)
                        }
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.accent.opacity(0.22) : Color.black.opacity(0.2)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Theme.accent : Color.clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Higgsfield reframes generatively, extending the scene where needed and keeping the subject in frame.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var choices: [JSONValue] {
        if case .choice(let values)? = model.currentModel?.schema.parameter(named: "aspect_ratio")?.kind { return values }
        return ["9:16", "16:9", "1:1", "4:3", "3:4", "21:9"]
    }

    static func platformHint(_ ratio: String) -> String {
        switch ratio {
        case "9:16": return "Reels · Shorts · TikTok"
        case "16:9": return "YouTube · TV"
        case "1:1": return "Feed"
        case "4:5": return "Portrait feed"
        case "4:3", "3:4": return "Classic"
        case "21:9": return "Cinema"
        default: return ""
        }
    }
}

struct AspectGlyph: View {
    var ratio: String

    var body: some View {
        let parts = ratio.split(separator: ":").compactMap { Double($0) }
        let r = parts.count == 2 && parts[1] > 0 ? parts[0] / parts[1] : 1
        GeometryReader { geo in
            let h = geo.size.height
            let w = min(geo.size.width, h * r)
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                .frame(width: w, height: w / r)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Upscale: provider and target resolution up front.
struct UpscaleTargetCard: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        if let spec = model.currentModel?.schema.parameter(named: "resolution"), case .choice(let options) = spec.kind {
            Card("Target resolution") {
                Picker("", selection: Binding(get: { model.draft.values["resolution"] ?? spec.defaultValue ?? options[0] },
                                              set: { model.setValue($0, for: "resolution") })) {
                    ForEach(options, id: \.self) { Text(Self.label($0.displayString)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if let w = model.draft.source?.info?.width, let h = model.draft.source?.info?.height {
                    Text("Source is \(w)×\(h).").font(.system(size: 10)).foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }

    static func label(_ value: String) -> String {
        switch value.lowercased() {
        case "2160p", "4k": return "4K"
        case "2k": return "2K"
        default: return value
        }
    }
}

struct ReferencesCard: View {
    @ObservedObject var model: PanelModel
    @State private var isTargeted = false

    var body: some View {
        Card("Reference images", trailing: AnyView(addButton)) {
            if model.draft.referenceImages.isEmpty {
                Text("Optional. Drop images to guide style, characters or products.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.draft.referenceImages) { ref in
                            ZStack(alignment: .topTrailing) {
                                AsyncImage(url: ref.fileURL) { image in image.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.black }
                                    .frame(width: 52, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                Button { model.removeReference(ref.id) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain)
                                    .padding(2)
                            }
                        }
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { model.addReference(url) } }
                }
            }
            return true
        }
    }

    private var addButton: some View {
        Button {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = true
            if panel.runModal() == .OK { panel.urls.forEach(model.addReference) }
        } label: { Image(systemName: "plus") }
        .buttonStyle(.plain)
    }
}

/// Model picker plus the model's other parameters, generated from its schema.
struct SettingsCard: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        Card("Model & settings", trailing: AnyView(schemaBadge)) {
            if model.modelOptions.count > 1 {
                Picker("Model", selection: Binding(get: { model.draft.jobType }, set: { model.selectModel($0) })) {
                    ForEach(model.modelOptions) { option in
                        Text(option.provider.isEmpty ? option.name : "\(option.name) · \(option.provider)").tag(option.jobType)
                    }
                }
            } else if let current = model.currentModel {
                LabeledContent("Model", value: current.name)
            }
            if let schema = model.currentModel?.schema {
                ForEach(visibleParameters(schema)) { spec in
                    ParameterControl(spec: spec, value: Binding(get: { model.draft.values[spec.name] ?? spec.defaultValue },
                                                                set: { model.setValue($0, for: spec.name) }))
                }
                if model.operation.durationFollowsSource, schema.parameter(named: "duration") != nil || model.operation == .reframe {
                    Label("Duration follows the selected clip length.", systemImage: "link")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText)
                }
                if model.operation == .generateVideo, model.timeline.rangeDuration != nil, schema.parameter(named: "duration") != nil {
                    Button("Match Timeline Range (\(formatDuration(model.timeline.rangeDuration ?? 0)))", action: model.fitDurationToTimelineRange)
                        .controlSize(.small)
                }
            }
        }
    }

    private var schemaBadge: some View {
        Group {
            if let current = model.currentModel, !current.isLive {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(Theme.secondaryText)
                    .help("Settings from the bundled catalog (\(ModelCatalog.snapshotDate)); the live catalog loads after sign-in.")
            }
        }
    }

    private func visibleParameters(_ schema: ParameterSchema) -> [ParameterSpec] {
        var hidden: Set<String> = []
        switch model.operation {
        case .reframe: hidden = ["aspect_ratio", "duration"]
        case .upscale: hidden = ["resolution"]
        case .editVideo, .drawToEdit: hidden = ["duration", "mode", "is_inpaint"]
        default: break
        }
        return schema.parameters.filter { !hidden.contains($0.name) }
    }
}

struct ParameterControl: View {
    var spec: ParameterSpec
    @Binding var value: JSONValue?

    var body: some View {
        Group {
            switch spec.kind {
            case .choice(let options):
                let picker = Picker(spec.label, selection: Binding(get: { value ?? options.first ?? .null }, set: { value = $0 })) {
                    ForEach(options, id: \.self) { Text(UpscaleTargetCard.label($0.displayString)).tag($0) }
                }
                if options.count <= 4 && options.allSatisfy({ $0.displayString.count <= 7 }) {
                    picker.pickerStyle(.segmented)
                } else {
                    picker.pickerStyle(.menu)
                }
            case .toggle:
                Toggle(spec.label, isOn: Binding(get: { value?.boolValue ?? false }, set: { value = .bool($0) }))
            case .number(let lo, let hi, let integer):
                if let lo, let hi, hi > lo, hi - lo <= 120 {
                    LabeledContent(spec.label) {
                        HStack {
                            Slider(value: Binding(get: { value?.doubleValue ?? lo }, set: { value = .number(integer ? $0.rounded() : ($0 * 10).rounded() / 10) }),
                                   in: lo...hi, step: integer ? 1 : 0.5)
                            Text(value?.displayString ?? JSONValue.number(lo).displayString)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                } else {
                    LabeledContent(spec.label) {
                        TextField("", value: Binding(get: { value?.doubleValue ?? lo ?? 0 }, set: { value = .number(integer ? $0.rounded() : $0) }), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                }
            case .text:
                TextField(spec.label, text: Binding(get: { value?.stringValue ?? "" }, set: { value = $0.isEmpty ? nil : .string($0) }))
                    .textFieldStyle(.roundedBorder)
            }
        }
        .font(.system(size: 12))
        .help(spec.summary ?? spec.label)
    }
}
#endif
