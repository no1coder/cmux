import Foundation

protocol TerminalRemoteDaemonTransport: Sendable {
    func writeLine(_ line: String) async throws
    func readLine() async throws -> String
}

struct TerminalRemoteDaemonHello: Decodable, Equatable, Sendable {
    let name: String
    let version: String
    let capabilities: [String]
}

struct TerminalRemoteDaemonAttachmentStatus: Decodable, Equatable, Sendable {
    let attachmentID: String
    let cols: Int
    let rows: Int
    let mode: String?
    let updatedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case attachmentID = "attachment_id"
        case cols
        case rows
        case mode
        case updatedAt = "updated_at"
    }
}

struct TerminalRemoteDaemonSessionStatus: Decodable, Equatable, Sendable {
    let sessionID: String
    let attachments: [TerminalRemoteDaemonAttachmentStatus]
    let effectiveCols: Int
    let effectiveRows: Int
    let lastKnownCols: Int
    let lastKnownRows: Int

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case attachments
        case effectiveCols = "effective_cols"
        case effectiveRows = "effective_rows"
        case lastKnownCols = "last_known_cols"
        case lastKnownRows = "last_known_rows"
    }
}

struct TerminalRemoteDaemonTerminalOpenResult: Decodable, Equatable, Sendable {
    let sessionID: String
    let attachmentID: String
    let attachments: [TerminalRemoteDaemonAttachmentStatus]
    let effectiveCols: Int
    let effectiveRows: Int
    let lastKnownCols: Int
    let lastKnownRows: Int
    let offset: UInt64

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case attachmentID = "attachment_id"
        case attachments
        case effectiveCols = "effective_cols"
        case effectiveRows = "effective_rows"
        case lastKnownCols = "last_known_cols"
        case lastKnownRows = "last_known_rows"
        case offset
    }
}

struct TerminalRemoteDaemonTerminalReadResult: Decodable, Equatable, Sendable {
    let sessionID: String
    let offset: UInt64
    let baseOffset: UInt64
    let truncated: Bool
    let eof: Bool
    let data: Data

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case offset
        case baseOffset = "base_offset"
        case truncated
        case eof
        case data
    }

    init(
        sessionID: String,
        offset: UInt64,
        baseOffset: UInt64,
        truncated: Bool,
        eof: Bool,
        data: Data
    ) {
        self.sessionID = sessionID
        self.offset = offset
        self.baseOffset = baseOffset
        self.truncated = truncated
        self.eof = eof
        self.data = data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        offset = try container.decode(UInt64.self, forKey: .offset)
        baseOffset = try container.decode(UInt64.self, forKey: .baseOffset)
        truncated = try container.decode(Bool.self, forKey: .truncated)
        eof = try container.decode(Bool.self, forKey: .eof)

        let encodedData = try container.decode(String.self, forKey: .data)
        guard let decodedData = Data(base64Encoded: encodedData) else {
            throw DecodingError.dataCorruptedError(
                forKey: .data,
                in: container,
                debugDescription: "terminal.read data was not valid base64"
            )
        }
        data = decodedData
    }
}

enum TerminalRemoteDaemonClientError: LocalizedError, Equatable {
    case invalidJSON(String)
    case missingResult
    case rpc(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let line):
            return "Invalid daemon response: \(line)"
        case .missingResult:
            return "Daemon response was missing a result payload."
        case .rpc(let code, let message):
            return "Daemon RPC failed (\(code)): \(message)"
        }
    }
}

actor TerminalRemoteDaemonClient {
    private let transport: any TerminalRemoteDaemonTransport
    private let decoder: JSONDecoder
    private var nextRequestID = 1

    init(transport: any TerminalRemoteDaemonTransport) {
        self.transport = transport
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    static func decodeHello(from line: String) throws -> TerminalRemoteDaemonHello {
        let decoder = JSONDecoder()
        return try decodeResponse(from: line, decoder: decoder, as: TerminalRemoteDaemonHello.self)
    }

    func sendHello() async throws -> TerminalRemoteDaemonHello {
        try await sendRequest(method: "hello", params: [:], as: TerminalRemoteDaemonHello.self)
    }

    func ensureSession(sessionID: String?) async throws -> TerminalRemoteDaemonSessionStatus {
        var params: [String: Any] = [:]
        if let sessionID, !sessionID.isEmpty {
            params["session_id"] = sessionID
        }
        return try await sendRequest(method: "session.open", params: params, as: TerminalRemoteDaemonSessionStatus.self)
    }

    func sessionAttach(
        sessionID: String,
        attachmentID: String,
        cols: Int,
        rows: Int
    ) async throws -> TerminalRemoteDaemonSessionStatus {
        try await sendRequest(
            method: "session.attach",
            params: [
                "session_id": sessionID,
                "attachment_id": attachmentID,
                "cols": cols,
                "rows": rows,
            ],
            as: TerminalRemoteDaemonSessionStatus.self
        )
    }

    func sessionResize(
        sessionID: String,
        attachmentID: String,
        cols: Int,
        rows: Int
    ) async throws -> TerminalRemoteDaemonSessionStatus {
        try await sendRequest(
            method: "session.resize",
            params: [
                "session_id": sessionID,
                "attachment_id": attachmentID,
                "cols": cols,
                "rows": rows,
            ],
            as: TerminalRemoteDaemonSessionStatus.self
        )
    }

    func sessionDetach(
        sessionID: String,
        attachmentID: String
    ) async throws -> TerminalRemoteDaemonSessionStatus {
        try await sendRequest(
            method: "session.detach",
            params: [
                "session_id": sessionID,
                "attachment_id": attachmentID,
            ],
            as: TerminalRemoteDaemonSessionStatus.self
        )
    }

    func sessionClose(sessionID: String) async throws {
        _ = try await sendRequest(
            method: "session.close",
            params: ["session_id": sessionID],
            as: TerminalRemoteDaemonCloseResult.self
        )
    }

    func terminalOpen(
        command: String,
        cols: Int,
        rows: Int
    ) async throws -> TerminalRemoteDaemonTerminalOpenResult {
        try await sendRequest(
            method: "terminal.open",
            params: [
                "command": command,
                "cols": cols,
                "rows": rows,
            ],
            as: TerminalRemoteDaemonTerminalOpenResult.self
        )
    }

    func terminalWrite(sessionID: String, data: Data) async throws {
        _ = try await sendRequest(
            method: "terminal.write",
            params: [
                "session_id": sessionID,
                "data": data.base64EncodedString(),
            ],
            as: TerminalRemoteDaemonTerminalWriteResult.self
        )
    }

    func terminalRead(
        sessionID: String,
        offset: UInt64,
        maxBytes: Int,
        timeoutMilliseconds: Int
    ) async throws -> TerminalRemoteDaemonTerminalReadResult {
        try await sendRequest(
            method: "terminal.read",
            params: [
                "session_id": sessionID,
                "offset": offset,
                "max_bytes": maxBytes,
                "timeout_ms": timeoutMilliseconds,
            ],
            as: TerminalRemoteDaemonTerminalReadResult.self
        )
    }

    private func sendRequest<ResponsePayload: Decodable>(
        method: String,
        params: [String: Any],
        as responseType: ResponsePayload.Type
    ) async throws -> ResponsePayload {
        let requestID = nextRequestID
        nextRequestID += 1

        try await transport.writeLine(try encodeRequestLine(id: requestID, method: method, params: params))
        let responseLine = try await transport.readLine()
        return try Self.decodeResponse(from: responseLine, decoder: decoder, as: responseType)
    }

    private func encodeRequestLine(id: Int, method: String, params: [String: Any]) throws -> String {
        let payload: [String: Any] = [
            "id": id,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeResponse<ResponsePayload: Decodable>(
        from line: String,
        decoder: JSONDecoder,
        as responseType: ResponsePayload.Type
    ) throws -> ResponsePayload {
        guard let data = line.data(using: .utf8) else {
            throw TerminalRemoteDaemonClientError.invalidJSON(line)
        }

        let envelope: TerminalRemoteDaemonResponseEnvelope<ResponsePayload>
        do {
            envelope = try decoder.decode(TerminalRemoteDaemonResponseEnvelope<ResponsePayload>.self, from: data)
        } catch {
            NSLog("📱 RPC decode error: %@ for type %@ line: %@", String(describing: error), String(describing: responseType), String(line.prefix(200)))
            throw TerminalRemoteDaemonClientError.invalidJSON(line)
        }

        if envelope.ok {
            guard let result = envelope.result else {
                throw TerminalRemoteDaemonClientError.missingResult
            }
            return result
        }

        if let error = envelope.error {
            throw TerminalRemoteDaemonClientError.rpc(code: error.code, message: error.message)
        }

        throw TerminalRemoteDaemonClientError.missingResult
    }
}

extension TerminalRemoteDaemonClient: TerminalRemoteDaemonSessionClient {}

private struct TerminalRemoteDaemonResponseEnvelope<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result?
    let error: TerminalRemoteDaemonRPCErrorPayload?
}

private struct TerminalRemoteDaemonRPCErrorPayload: Decodable {
    let code: String
    let message: String
}

private struct TerminalRemoteDaemonCloseResult: Decodable {
    let sessionID: String
    let closed: Bool

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case closed
    }
}

private struct TerminalRemoteDaemonTerminalWriteResult: Decodable {
    let sessionID: String
    let written: Int

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case written
    }
}
