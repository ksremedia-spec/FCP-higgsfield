import Foundation
import HiggsfieldKit

// hfcp — command-line harness for HiggsfieldKit. It exercises the same client,
// schema parser and request builder as the Final Cut Pro panel, so the
// integration can be checked against the live Higgsfield API from a terminal
// or CI without Final Cut Pro.
//
// Credentials, in order: --token, $HIGGSFIELD_ACCESS_TOKEN, or --cli to reuse
// the official Higgsfield CLI session (`hf auth token`).

let usage = """
usage: hfcp [--token T | --cli] [--workspace ID] <command> [options]

read-only commands (no credits are spent):
  balance                         account email, plan and credits
  workspaces                      workspaces available to the account
  catalog [--type video|image] [--chain]
                                  job types from the live catalog
  schema <job_type>               live JSON Schema, as parsed by the panel
  cost <operation> [--model JOB_TYPE] [--duration S] [--width W --height H]
       [--prompt TEXT] [--set key=value]...
                                  credit estimate for a tool configuration

  upload <file>                   upload a file as the panel does (free; creates no job)
  preview <operation> [--file PATH] [same options as run]
                                  the exact request the panel would submit (placeholder media ids)

commands that spend credits (require --yes):
  run <operation> --file PATH [--model JOB_TYPE] [--prompt TEXT] [--set key=value]...
      [--sketch PNG] [--mask PNG] [--out DIR] --yes

utilities:
  fcpxml <media file> --duration S [--fps F] [--width W --height H] [--image]
         [--library URL] [--event NAME]
                                  print the FCPXML the panel would send to Final Cut Pro

operations: \(OperationKind.allCases.map(\.rawValue).joined(separator: ", "))
"""

struct Arguments {
    var positional: [String] = []
    var options: [String: [String]] = [:]
    var flags: Set<String> = []

    init(_ argv: [String]) {
        let flagNames: Set<String> = ["cli", "yes", "chain", "image", "json"]
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if flagNames.contains(name) {
                    flags.insert(name)
                } else if i + 1 < argv.count {
                    options[name, default: []].append(argv[i + 1])
                    i += 1
                } else {
                    flags.insert(name)
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func value(_ name: String) -> String? { options[name]?.last }
    func double(_ name: String) -> Double? { value(name).flatMap(Double.init) }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("hfcp: \(message)\n".utf8))
    exit(1)
}

func parseValue(_ raw: String) -> JSONValue {
    if raw == "true" { return true }
    if raw == "false" { return false }
    if let d = Double(raw) { return .number(d) }
    return .string(raw)
}

func makeClient(_ args: Arguments) async throws -> HiggsfieldClient {
    let provider: AccessTokenProvider
    if let token = args.value("token") ?? ProcessInfo.processInfo.environment["HIGGSFIELD_ACCESS_TOKEN"], !token.isEmpty {
        provider = StaticTokenProvider(token: token)
    } else if args.flags.contains("cli") {
        provider = CLITokenProvider(bridge: HiggsfieldCLIBridge())
    } else {
        fail("no credentials: pass --token, set HIGGSFIELD_ACCESS_TOKEN, or use --cli")
    }
    let client = HiggsfieldClient(configuration: HiggsfieldConfiguration(userAgent: "hfcp/0.1"), tokenProvider: provider)
    if let ws = args.value("workspace") ?? ProcessInfo.processInfo.environment["HIGGSFIELD_WORKSPACE_ID"] {
        await client.setWorkspace(ws)
    } else {
        let spaces = try await client.workspaces()
        guard let first = spaces.first else { fail("the account has no workspaces") }
        await client.setWorkspace(first.id)
    }
    return client
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(value) { print(String(decoding: data, as: UTF8.self)) }
}

/// Loads the live schema for `jobType` into the catalog (falls back to the snapshot).
func catalog(with client: HiggsfieldClient, jobType: String) async -> ModelCatalog {
    var catalog = ModelCatalog.snapshot
    do {
        catalog.merge(live: try await client.jobType(jobType))
    } catch {
        FileHandle.standardError.write(Data("hfcp: live schema for \(jobType) unavailable (\(error.localizedDescription)); using snapshot \(ModelCatalog.snapshotDate)\n".utf8))
    }
    return catalog
}

func draft(from args: Arguments, operation: OperationKind, sourceFile: URL?) -> OperationDraft {
    var source: SourceClip?
    if let file = sourceFile ?? (args.double("duration") != nil || args.flags.contains("image") ? URL(fileURLWithPath: "/dev/null/source") : nil) {
        let kind: MediaKind = args.flags.contains("image") ? .image : (MediaKind(fileExtension: file.pathExtension) ?? .video)
        source = SourceClip(name: file.deletingPathExtension().lastPathComponent, fileURL: file, kind: kind, origin: .file,
                            info: MediaInfo(kind: kind, duration: args.double("duration"), frameRate: args.double("fps"),
                                            width: args.value("width").flatMap { Int($0) }, height: args.value("height").flatMap { Int($0) }))
    }
    var values: [String: JSONValue] = [:]
    for pair in args.options["set"] ?? [] {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { fail("--set expects key=value, got \(pair)") }
        values[parts[0]] = parseValue(parts[1])
    }
    return OperationDraft(
        operation: operation, jobType: args.value("model") ?? operation.candidateJobTypes(sourceKind: source?.kind).first,
        prompt: args.value("prompt") ?? "", values: values, source: source,
        sketchFile: args.value("sketch").map { URL(fileURLWithPath: $0) },
        maskFile: args.value("mask").map { URL(fileURLWithPath: $0) }
    )
}

func run() async {
    let args = Arguments(Array(CommandLine.arguments.dropFirst()))
    guard let command = args.positional.first else { print(usage); return }
    do {
        switch command {
        case "balance":
            let client = try await makeClient(args)
            printJSON(try await client.balance())

        case "workspaces":
            let client = try await makeClient(args)
            printJSON(try await client.workspaces())

        case "catalog":
            let client = try await makeClient(args)
            let type = args.value("type").flatMap(MediaKind.init(rawValue:))
            let items = try await client.jobTypes(outputType: args.flags.contains("chain") ? nil : type,
                                                  labels: args.flags.contains("chain") ? ["chain"] : ["model", "app"])
            for item in items {
                print("\(item.jobType)\t\(item.outputType?.rawValue ?? "?")\t\(item.name ?? "")")
            }

        case "schema":
            guard args.positional.count > 1 else { fail("schema needs a job type") }
            let client = try await makeClient(args)
            let info = try await client.jobType(args.positional[1])
            if args.flags.contains("json") { printJSON(info.jsonSchema); return }
            guard let raw = info.jsonSchema else { fail("no json_schema in response") }
            let schema = ParameterSchema(jsonSchema: raw)
            print("job_type: \(info.jobType)  output: \(info.outputType?.rawValue ?? "?")  prompt: \(schema.acceptsPrompt)")
            let roles = schema.mediaRoles.map { role in schema.mediaField(named: role)?.isArray == true ? role + "[]" : role }
            print("media roles: \(roles.joined(separator: ", "))\(schema.mediaFields.isEmpty && schema.acceptsMedias ? "  (in params.medias)" : "")")
            for p in schema.parameters {
                print("  \(p.name)\t\(p.kind)\tdefault=\(p.defaultValue?.displayString ?? "—")\(p.isRequired ? "\trequired" : "")")
            }
            let hidden = schema.propertyNames.subtracting(schema.parameters.map(\.name)).sorted()
            print("other properties: \(hidden.joined(separator: ", "))")

        case "cost":
            guard args.positional.count > 1, let op = OperationKind(rawValue: args.positional[1]) else { fail("cost needs an operation") }
            let client = try await makeClient(args)
            var d = draft(from: args, operation: op, sourceFile: nil)
            let cat = await catalog(with: client, jobType: d.jobType)
            if op == .drawToEdit { d.sketchFile = d.sketchFile ?? URL(fileURLWithPath: "/dev/null/sketch.png"); d.maskFile = d.maskFile ?? URL(fileURLWithPath: "/dev/null/mask.png") }
            let request = try RequestBuilder.prepare(d, catalog: cat)
            let cost = try await client.estimateCost(jobType: request.jobType, params: request.costParams)
            print("\(request.jobType): \(cost.creditsExact ?? cost.credits) credits  params=\(String(decoding: try JSONValue.object(request.costParams).encodedData(), as: UTF8.self))")

        case "upload":
            // Free: uploads one file the way the panel does (slot → PUT → confirm)
            // and prints the media reference. No job is created.
            guard args.positional.count > 1 else { fail("upload needs a file") }
            let client = try await makeClient(args)
            let file = URL(fileURLWithPath: args.positional[1])
            let kind = args.flags.contains("image") ? MediaKind.image : (MediaKind(fileExtension: file.pathExtension) ?? .video)
            let ref = try await client.uploadMedia(fileURL: file, kind: kind)
            print("uploaded \(file.lastPathComponent): id=\(ref.id) type=\(ref.source.rawValue)")

        case "preview":
            // Free: prints the submission the panel would send, with placeholder
            // media ids in place of uploads. Nothing is uploaded or submitted.
            guard args.positional.count > 1, let op = OperationKind(rawValue: args.positional[1]) else { fail("preview needs an operation") }
            let client = try await makeClient(args)
            let file = args.value("file").map { URL(fileURLWithPath: $0) }
            let d = draft(from: args, operation: op, sourceFile: file)
            let cat = await catalog(with: client, jobType: d.jobType)
            let request = try RequestBuilder.prepare(d, catalog: cat)
            let references = request.media.enumerated().map { i, item in
                MediaReference.uploaded(id: String(format: "00000000-0000-4000-8000-%012d", i + 1), kind: item.kind)
            }
            print("POST /\(request.output.generationSegment)/\(request.jobType)/generations")
            print(String(decoding: try JSONValue.object(["params": .object(request.submissionParams(references: references))]).encodedData(), as: UTF8.self))

        case "run":
            guard args.positional.count > 1, let op = OperationKind(rawValue: args.positional[1]) else { fail("run needs an operation") }
            guard args.flags.contains("yes") else { fail("run spends Higgsfield credits; add --yes to confirm") }
            let client = try await makeClient(args)
            let file = args.value("file").map { URL(fileURLWithPath: $0) }
            if op.requiresSource && file == nil { fail("\(op.rawValue) needs --file") }
            let d = draft(from: args, operation: op, sourceFile: file)
            let cat = await catalog(with: client, jobType: d.jobType)
            let request = try RequestBuilder.prepare(d, catalog: cat)
            let cost = try? await client.estimateCost(jobType: request.jobType, params: request.costParams)
            print("estimated cost: \(cost.map { String($0.credits) } ?? "unavailable") credits")
            let outDir = URL(fileURLWithPath: args.value("out") ?? FileManager.default.currentDirectoryPath, isDirectory: true)
            let store = JobStore(url: outDir.appendingPathComponent(".hfcp-jobs.json"))
            let runner = JobRunner(client: client, store: store, output: OutputLocation(root: outDir))
            await runner.setUpdateHandler { record in
                print("[\(record.phase.label)] \(record.remoteID ?? "-") \(record.message ?? "")")
            }
            let started = await runner.start(request, prompt: d.prompt.isEmpty ? nil : d.prompt, sourceName: d.source?.name, estimatedCredits: cost?.credits)
            while true {
                guard let r = await store.record(id: started.id) else { break }
                if !r.phase.isActive {
                    if let file = r.localFile { print("saved: \(file.path)") }
                    if r.phase != .completed { exit(2) }
                    break
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }

        case "fcpxml":
            guard args.positional.count > 1 else { fail("fcpxml needs a media file") }
            let url = URL(fileURLWithPath: args.positional[1]).standardizedFileURL
            let kind: MediaKind = args.flags.contains("image") ? .image : (MediaKind(fileExtension: url.pathExtension) ?? .video)
            let info = MediaInfo(kind: kind, duration: args.double("duration"), frameRate: args.double("fps"),
                                 width: args.value("width").flatMap { Int($0) }, height: args.value("height").flatMap { Int($0) })
            let item = FCPXMLImportItem(name: url.deletingPathExtension().lastPathComponent, fileURL: url, info: info, keywords: ["Higgsfield"])
            let destination: FCPXMLBuilder.Destination = args.value("event") != nil || args.value("library") != nil
                ? .event(name: args.value("event") ?? "Higgsfield AI", libraryURL: args.value("library").flatMap(URL.init(string:)))
                : .dragAndDrop
            print(FCPXMLBuilder().document(items: [item], destination: destination), terminator: "")

        default:
            print(usage)
            exit(64)
        }
    } catch let error as HiggsfieldError {
        fail(error.userMessage)
    } catch {
        fail(error.localizedDescription)
    }
}

let done = DispatchSemaphore(value: 0)
Task {
    await run()
    done.signal()
}
done.wait()
