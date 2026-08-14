import AppKit
import Darwin
import Foundation
import SwiftUI

enum KapsicumRuntimeLocalization {
    static let bundle: Bundle = {
        if let resourceURL = Bundle.main.resourceURL,
           let bundle = Bundle(
               url: resourceURL.appendingPathComponent(
                   "Kapp_Kapp.bundle",
                   isDirectory: true))
        {
            return bundle
        }

        // SwiftPM keeps the processed bundle beside an unwrapped executable
        // during local package builds. Installed Kapps take the standard
        // Contents/Resources path above.
        return .module
    }()
}

enum KapsicumRuntimeError: LocalizedError {
    case unavailable
    case accessNotGranted(String)
    case invalidResponse
    case timedOut
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(
                localized: "kapsicum.runtime.error.unavailable",
                defaultValue: "Kapsicum access is unavailable.",
                bundle: KapsicumRuntimeLocalization.bundle,
                comment: "Generated Kapp error when the Kapsicum runtime channel is unavailable")
        case let .accessNotGranted(message):
            message
        case .invalidResponse:
            String(
                localized: "kapsicum.runtime.error.invalid_response",
                defaultValue: "Kapsicum returned an invalid response.",
                bundle: KapsicumRuntimeLocalization.bundle,
                comment: "Generated Kapp error when Kapsicum returns malformed runtime data")
        case .timedOut:
            String(
                localized: "kapsicum.runtime.error.timed_out",
                defaultValue: "Kapsicum did not respond in time.",
                bundle: KapsicumRuntimeLocalization.bundle,
                comment: "Generated Kapp error when a Kapsicum runtime request times out")
        case let .requestFailed(message):
            message
        }
    }
}

enum KapsicumRuntime {
    /// Brings the Kapsicum host that launched this process to its dashboard.
    /// The host remains the only place where archive access can be changed.
    @MainActor
    @discardableResult
    static func openKapsicum() -> Bool {
        DistributedNotificationCenter.default().post(
            name: Notification.Name("dev.kapsicum.mac.OpenDashboard"),
            object: nil)
        return NSRunningApplication(processIdentifier: getppid())?
            .activate(options: [.activateAllWindows]) ?? false
    }

    static func invoke<Arguments, Response>(
        descriptorID: String,
        arguments: Arguments,
        as responseType: Response.Type = Response.self
    ) async throws -> Response
    where Arguments: Encodable & Sendable, Response: Decodable & Sendable {
        try await KapsicumRuntimeClient.shared.invoke(
            descriptorID: descriptorID,
            arguments: arguments,
            as: responseType)
    }
}

struct KappAITextTurn: Codable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    let role: Role
    let text: String
}

struct KappAISelection: Codable, Hashable, Sendable {
    let backendID: String
    let modelID: String?
    let reasoningID: String?
}

struct KappAIModelOption: Codable, Hashable, Sendable {
    let id: String
    let title: String
    let reasoningLevels: [String]
}

struct KappAIAgentOption: Codable, Hashable, Sendable {
    let id: String
    let displayName: String
    let isLocal: Bool
    let models: [KappAIModelOption]
}

struct KappAICatalog: Codable, Hashable, Sendable {
    let agents: [KappAIAgentOption]
    let isComplete: Bool
}

private struct KappAICatalogRequest: Codable, Sendable {}

struct KappAIRequest: Codable, Sendable {
    let clientRequestID: UUID
    let conversationID: UUID
    let prompt: String
    let priorTurns: [KappAITextTurn]

    init(
        clientRequestID: UUID = UUID(),
        conversationID: UUID,
        prompt: String,
        priorTurns: [KappAITextTurn] = []
    ) {
        self.clientRequestID = clientRequestID
        self.conversationID = conversationID
        self.prompt = prompt
        self.priorTurns = priorTurns
    }
}

private struct KappAIWireRequest: Codable, Sendable {
    let clientRequestID: UUID
    let conversationID: UUID
    let prompt: String
    let priorTurns: [KappAITextTurn]
    let selection: KappAISelection
}

enum KappAIRunState: String, Codable, Sendable {
    case running
    case succeeded
    case failed
    case cancelled
}

struct KappAIRunSnapshot: Codable, Sendable {
    let runID: UUID
    let state: KappAIRunState
    let answer: String?
    let errorCode: String?
}

private struct KappAIRunReference: Codable, Sendable {
    let runID: UUID
}

@MainActor
private enum KapsicumAISelectionStore {
    static let backendKey = "kapsicum.ai.selection.backend"
    static let modelKey = "kapsicum.ai.selection.model"
    static let reasoningKey = "kapsicum.ai.selection.reasoning"

    static func selection() -> KappAISelection? {
        let defaults = UserDefaults.standard
        guard let backendID = defaults.string(forKey: backendKey),
              !backendID.isEmpty else { return nil }
        return KappAISelection(
            backendID: backendID,
            modelID: defaults.string(forKey: modelKey),
            reasoningID: defaults.string(forKey: reasoningKey))
    }

    static func select(
        backendID: String,
        modelID: String?,
        reasoningID: String?
    ) {
        let defaults = UserDefaults.standard
        defaults.set(backendID, forKey: backendKey)
        defaults.set(modelID, forKey: modelKey)
        defaults.set(reasoningID, forKey: reasoningKey)
    }

    static func normalize(using catalog: KappAICatalog) {
        guard let selection = selection() else { return }
        guard let agent = catalog.agents.first(where: {
            $0.id == selection.backendID
        }) else {
            clear()
            return
        }
        guard let modelID = selection.modelID else { return }
        guard let model = agent.models.first(where: { $0.id == modelID }),
              selection.reasoningID.map(model.reasoningLevels.contains) ?? true
        else {
            clear()
            return
        }
    }

    private static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: backendKey)
        defaults.removeObject(forKey: modelKey)
        defaults.removeObject(forKey: reasoningKey)
    }
}

@MainActor
enum KapsicumAI {
    static func catalog() async throws -> KappAICatalog {
        try await KapsicumRuntime.invoke(
            descriptorID: "kapp.ai.catalog",
            arguments: KappAICatalogRequest())
    }

    static func start(_ request: KappAIRequest) async throws -> UUID {
        guard let selection = KapsicumAISelectionStore.selection() else {
            throw KapsicumRuntimeError.requestFailed(String(
                localized: "kapsicum.ai.choose",
                defaultValue: "Choose AI",
                bundle: KapsicumRuntimeLocalization.bundle,
                comment: "Generated Kapp prompt to choose an AI agent"))
        }
        let reference: KappAIRunReference = try await KapsicumRuntime.invoke(
            descriptorID: "kapp.ai.start",
            arguments: KappAIWireRequest(
                clientRequestID: request.clientRequestID,
                conversationID: request.conversationID,
                prompt: request.prompt,
                priorTurns: request.priorTurns,
                selection: selection))
        return reference.runID
    }

    static func status(runID: UUID) async throws -> KappAIRunSnapshot {
        try await KapsicumRuntime.invoke(
            descriptorID: "kapp.ai.status",
            arguments: KappAIRunReference(runID: runID))
    }

    static func cancel(runID: UUID) async throws {
        let _: KappAIRunReference = try await KapsicumRuntime.invoke(
            descriptorID: "kapp.ai.cancel",
            arguments: KappAIRunReference(runID: runID))
    }
}

struct KapsicumAISelector: View {
    @AppStorage(KapsicumAISelectionStore.backendKey)
    private var backendID = ""
    @AppStorage(KapsicumAISelectionStore.modelKey)
    private var modelID = ""
    @AppStorage(KapsicumAISelectionStore.reasoningKey)
    private var reasoningID = ""
    @State private var catalog = KappAICatalog(
        agents: [],
        isComplete: false)

    init() {}

    var body: some View {
        Menu {
            if catalog.agents.isEmpty {
                Text(String(
                    localized: "kapsicum.ai.unavailable",
                    defaultValue: "No AI agents available",
                    bundle: KapsicumRuntimeLocalization.bundle,
                    comment: "Generated Kapp AI selector empty state"))
            } else {
                ForEach(catalog.agents, id: \.id) { agent in
                    Menu(agent.displayName) {
                        selectionButton(
                            title: String(
                                localized: "kapsicum.ai.engine_default",
                                defaultValue: "Agent default",
                                bundle: KapsicumRuntimeLocalization.bundle,
                                comment: "Generated Kapp option using the agent default model"),
                            agent: agent,
                            model: nil,
                            reasoning: nil)
                        ForEach(agent.models, id: \.id) { model in
                            if model.reasoningLevels.isEmpty {
                                selectionButton(
                                    title: model.title,
                                    agent: agent,
                                    model: model,
                                    reasoning: nil)
                            } else {
                                Menu(model.title) {
                                    selectionButton(
                                        title: String(
                                            localized: "kapsicum.ai.engine_default",
                                            defaultValue: "Agent default",
                                            bundle: KapsicumRuntimeLocalization.bundle,
                                            comment: "Generated Kapp option using default reasoning"),
                                        agent: agent,
                                        model: model,
                                        reasoning: nil)
                                    ForEach(model.reasoningLevels, id: \.self) { level in
                                        selectionButton(
                                            title: level,
                                            agent: agent,
                                            model: model,
                                            reasoning: level)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Label(selectionTitle, systemImage: "sparkles")
        }
        .task {
            await loadCatalog()
        }
        .accessibilityIdentifier("kapsicum-ai-selector")
    }

    private func loadCatalog() async {
        var retryDelayNanoseconds: UInt64 = 2_000_000_000
        while !Task.isCancelled {
            if let loaded = try? await KapsicumAI.catalog() {
                catalog = loaded
                if loaded.isComplete {
                    KapsicumAISelectionStore.normalize(using: loaded)
                    retryDelayNanoseconds = 30_000_000_000
                }
            }
            do {
                try await Task.sleep(nanoseconds: retryDelayNanoseconds)
            } catch {
                return
            }
            if !catalog.isComplete {
                retryDelayNanoseconds = min(
                    retryDelayNanoseconds * 2,
                    30_000_000_000)
            }
        }
    }

    @ViewBuilder
    private func selectionButton(
        title: String,
        agent: KappAIAgentOption,
        model: KappAIModelOption?,
        reasoning: String?
    ) -> some View {
        Button {
            KapsicumAISelectionStore.select(
                backendID: agent.id,
                modelID: model?.id,
                reasoningID: reasoning)
        } label: {
            if backendID == agent.id,
               modelID.nilIfEmpty == model?.id,
               reasoningID.nilIfEmpty == reasoning {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var selectionTitle: String {
        guard let agent = catalog.agents.first(where: {
            $0.id == backendID
        }) else {
            return String(
                localized: "kapsicum.ai.choose",
                defaultValue: "Choose AI",
                bundle: KapsicumRuntimeLocalization.bundle,
                comment: "Generated Kapp AI selector label")
        }
        guard let model = agent.models.first(where: {
            $0.id == modelID
        }) else { return agent.displayName }
        return reasoningID.isEmpty
            ? "\(agent.displayName) · \(model.title)"
            : "\(agent.displayName) · \(model.title) [\(reasoningID)]"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct RuntimeWireRequest: Codable {
    let protocolVersion: Int
    let requestID: String
    let descriptorID: String
    let arguments: Data
}

private struct RuntimeWireResponse: Codable {
    let protocolVersion: Int
    let requestID: String
    let status: String
    let result: Data?
    let errorCode: String?
    let errorMessage: String?
}

private final class KapsicumRuntimeClient: @unchecked Sendable {
    static let shared = KapsicumRuntimeClient()

    // Safe under @unchecked Sendable: this queue is the sole owner of all descriptor I/O.
    private let queue = DispatchQueue(label: "dev.kapsicum.kapp.runtime-channel")
    private var descriptor: Int32?
    // The broker owns the shorter request deadline. Leave enough time to
    // receive its terminal response instead of abandoning a live frame.
    private static let responseTimeoutMilliseconds = 15000
    private static let maximumArgumentsBytes = 65536
    private static let maximumRequestFrameBytes = 614400
    private static let maximumResponseFrameBytes = 8388608

    private init() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--kapsicum-runtime-fd"),
              arguments.indices.contains(flag + 1),
              let descriptor = Int32(arguments[flag + 1]),
              descriptor > STDERR_FILENO,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            self.descriptor = nil
            return
        }
        self.descriptor = descriptor
    }

    func invoke<Arguments, Response>(
        descriptorID: String,
        arguments: Arguments,
        as responseType: Response.Type
    ) async throws -> Response
    where Arguments: Encodable & Sendable, Response: Decodable & Sendable {
        let argumentData = try JSONEncoder().encode(arguments)
        guard argumentData.count <= Self.maximumArgumentsBytes else {
            throw KapsicumRuntimeError.requestFailed(String(
                localized: "kapsicum.runtime.error.request_too_large",
                defaultValue: "The request is too large.",
                bundle: KapsicumRuntimeLocalization.bundle,
                comment: "Generated Kapp error when an encoded runtime request exceeds its bound"))
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard let descriptor else { throw KapsicumRuntimeError.unavailable }
                    let requestID = UUID().uuidString.lowercased()
                    let request = RuntimeWireRequest(
                        protocolVersion: 1,
                        requestID: requestID,
                        descriptorID: descriptorID,
                        arguments: argumentData)
                    try Self.writeFrame(
                        JSONEncoder().encode(request),
                        to: descriptor,
                        timeoutMilliseconds: 5_000)
                    let responseData = try Self.readFrame(
                        from: descriptor,
                        timeoutMilliseconds: Self.responseTimeoutMilliseconds)
                    let response = try JSONDecoder().decode(
                        RuntimeWireResponse.self,
                        from: responseData)
                    guard response.protocolVersion == 1,
                          response.requestID == requestID else {
                        throw KapsicumRuntimeError.invalidResponse
                    }
                    guard response.status == "succeeded", let result = response.result else {
                        let failureMessage = response.errorMessage
                            ?? response.errorCode
                            ?? String(
                                localized: "kapsicum.runtime.error.request_denied",
                                defaultValue: "Kapsicum denied the request.",
                                bundle: KapsicumRuntimeLocalization.bundle,
                                comment: "Generated Kapp error when Kapsicum denies a runtime request")
                        if response.errorCode == "capability_not_granted" {
                            throw KapsicumRuntimeError.accessNotGranted(
                                failureMessage)
                        }
                        throw KapsicumRuntimeError.requestFailed(failureMessage)
                    }
                    continuation.resume(returning: try JSONDecoder().decode(responseType, from: result))
                } catch let error as KapsicumRuntimeError {
                    switch error {
                    case .accessNotGranted, .requestFailed:
                        break
                    case .unavailable, .invalidResponse, .timedOut:
                        invalidateChannel()
                    }
                    continuation.resume(throwing: error)
                } catch {
                    invalidateChannel()
                    continuation.resume(throwing: KapsicumRuntimeError.requestFailed(error.localizedDescription))
                }
            }
        }
    }

    private func invalidateChannel() {
        guard let descriptor else { return }
        self.descriptor = nil
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        _ = Darwin.close(descriptor)
    }

    private static func readFrame(
        from descriptor: Int32,
        timeoutMilliseconds: Int
    ) throws -> Data {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeoutMilliseconds) * 1_000_000
        let header = try readExactly(4, from: descriptor, deadline: deadline)
        let length = header.withUnsafeBytes { bytes in
            bytes.loadUnaligned(as: UInt32.self).bigEndian
        }
        guard length > 0,
              length <= Self.maximumResponseFrameBytes
        else {
            throw KapsicumRuntimeError.invalidResponse
        }
        return try readExactly(Int(length), from: descriptor, deadline: deadline)
    }

    private static func writeFrame(
        _ data: Data,
        to descriptor: Int32,
        timeoutMilliseconds: Int
    ) throws {
        guard !data.isEmpty,
              data.count <= Self.maximumRequestFrameBytes
        else {
            throw KapsicumRuntimeError.requestFailed(String(
                localized: "kapsicum.runtime.error.request_too_large",
                defaultValue: "The request is too large.",
                bundle: KapsicumRuntimeLocalization.bundle,
                comment: "Generated Kapp error when a runtime request exceeds its bound"))
        }
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeoutMilliseconds) * 1_000_000
        var length = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &length) { bytes in
            try writeExactly(Data(bytes), to: descriptor, deadline: deadline)
        }
        try writeExactly(data, to: descriptor, deadline: deadline)
    }

    private static func readExactly(
        _ count: Int,
        from descriptor: Int32,
        deadline: UInt64
    ) throws -> Data {
        var result = Data(count: count)
        var offset = 0
        while offset < count {
            try wait(descriptor, events: Int16(POLLIN), deadline: deadline)
            let amount = result.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), count - offset)
            }
            guard amount > 0 else {
                if amount < 0, errno == EINTR || errno == EAGAIN { continue }
                throw KapsicumRuntimeError.unavailable
            }
            offset += amount
        }
        return result
    }

    private static func writeExactly(
        _ data: Data,
        to descriptor: Int32,
        deadline: UInt64
    ) throws {
        var offset = 0
        while offset < data.count {
            try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
            let amount = data.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
            }
            guard amount > 0 else {
                if amount < 0, errno == EINTR || errno == EAGAIN { continue }
                throw KapsicumRuntimeError.unavailable
            }
            offset += amount
        }
    }

    private static func wait(
        _ descriptor: Int32,
        events: Int16,
        deadline: UInt64
    ) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                throw KapsicumRuntimeError.timedOut
            }
            let remaining = min((deadline - now) / 1_000_000, UInt64(Int32.max))
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let status = Darwin.poll(&item, 1, Int32(max(1, remaining)))
            if status > 0 {
                guard item.revents & (Int16(POLLERR) | Int16(POLLHUP) | Int16(POLLNVAL)) == 0,
                      item.revents & events != 0 else {
                    throw KapsicumRuntimeError.unavailable
                }
                return
            }
            if status == 0 {
                throw KapsicumRuntimeError.timedOut
            }
            if errno != EINTR { throw KapsicumRuntimeError.unavailable }
        }
    }
}
