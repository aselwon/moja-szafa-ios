import Foundation
import CryptoKit
import MetricKit

/// Parses Apple's legacy iOS 14+ call-stack JSON. Only UUIDs and text-segment
/// offsets for our binaries survive; file names, symbols, addresses and payload
/// strings are never persisted or uploaded.
enum CrashSanitizer {
    private struct Tree: Decodable { let callStacks: [Stack] }
    private struct Wrapper: Decodable { let callStackTree: Tree }
    private struct Stack: Decodable { let callStackRootFrames: [Frame] }
    private struct Frame: Decodable {
        let binaryName: String?
        let binaryUUID: String?
        let offsetIntoBinaryTextSegment: UInt64?
        let subFrames: [Frame]?
    }
    static func event(data: Data, build: String, architecture: String, begin: Date, end: Date) -> TelemetryEvent? {
        guard data.count <= 1_048_576, begin <= end,
              build.range(of: "^[0-9]{1,12}(\\.[0-9]{1,12}){0,2}$", options: .regularExpression) != nil,
              ["arm64", "arm64e", "x86_64"].contains(architecture) else { return nil }
        let decoder = JSONDecoder()
        guard let tree = (try? decoder.decode(Wrapper.self, from: data).callStackTree)
            ?? (try? decoder.decode(Tree.self, from: data)) else { return nil }
        let allowed: Set<String> = ["MojaSzafa", "MojaSzafa.debug.dylib", "MojaSzafaWidget", "MojaSzafaWidget.debug.dylib"]
        var frames: [TelemetryFrame] = []
        var pending = tree.callStacks.flatMap(\.callStackRootFrames).map { ($0, 0) }
        var visited = 0
        while let (frame, depth) = pending.popLast(), visited < 4096, frames.count < 64 {
            visited += 1
            if let name = frame.binaryName, allowed.contains(name), let rawUUID = frame.binaryUUID,
               let uuid = UUID(uuidString: rawUUID), let offset = frame.offsetIntoBinaryTextSegment,
               offset <= 9_007_199_254_740_991 {
                frames.append(TelemetryFrame(binaryUUID: uuid, offset: offset))
            }
            if depth < 64 { pending.append(contentsOf: (frame.subFrames ?? []).map { ($0, depth + 1) }) }
        }
        guard !frames.isEmpty else { return nil }
        struct Identity: Encodable {
            let build: String; let architecture: String; let begin: Date; let end: Date; let frames: [TelemetryFrame]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let identity = try? encoder.encode(Identity(build: build, architecture: architecture, begin: begin, end: end, frames: frames)) else { return nil }
        var bytes = Array(SHA256.hash(data: identity).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80; bytes[8] = (bytes[8] & 0x3f) | 0x80
        let id = UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
        return TelemetryEvent(id: id, kind: "crash", build: build, architecture: architecture, frames: frames)
    }
}

@MainActor
final class CrashDiagnostics: NSObject, MXMetricManagerSubscriber {
    private var recorder: TelemetryRecorder?
    private var subscribed = false

    func attach(_ recorder: TelemetryRecorder) {
        self.recorder = recorder
        if !subscribed { MXMetricManager.shared.add(self); subscribed = true }
    }
    func detach() {
        recorder = nil
        if subscribed { MXMetricManager.shared.remove(self); subscribed = false }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        // Extract typed values on the callback thread. Raw MetricKit objects are
        // not captured by a cross-actor task or written to disk.
        let reports: [(Date, TelemetryEvent)] = payloads.flatMap { payload in
            (payload.crashDiagnostics ?? []).compactMap { crash in
                guard let event = CrashSanitizer.event(data: crash.callStackTree.jsonRepresentation(),
                    build: crash.metaData.applicationBuildVersion,
                    architecture: crash.metaData.platformArchitecture,
                    begin: payload.timeStampBegin, end: payload.timeStampEnd) else { return nil }
                return (payload.timeStampBegin, event)
            }
        }
        Task { @MainActor [weak self] in
            guard let recorder = self?.recorder, let began = await recorder.diagnosticWindow() else { return }
            for (begin, event) in reports where begin >= began { await recorder.record(event) }
        }
    }
}
