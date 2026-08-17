import Foundation

struct SSEEventDecoder: Sendable {
    private let maximumLineBytes: Int
    private let maximumEventBytes: Int
    private var lineBuffer = Data()
    private var dataLines: [Data] = []
    private var dataByteCount = 0
    private var pendingCarriageReturn = false

    init(
        maximumLineBytes: Int = 1_048_576,
        maximumEventBytes: Int = 1_048_576
    ) {
        self.maximumLineBytes = maximumLineBytes
        self.maximumEventBytes = maximumEventBytes
    }

    mutating func consume(byte: UInt8) throws -> String? {
        if pendingCarriageReturn {
            pendingCarriageReturn = false
            let payload = try processCompletedLine()
            if byte == 0x0A {
                return payload
            }
            if let payload {
                if byte == 0x0D {
                    pendingCarriageReturn = true
                } else {
                    try appendNonTerminator(byte)
                }
                return payload
            }
        }

        switch byte {
        case 0x0D:
            pendingCarriageReturn = true
            return nil
        case 0x0A:
            return try processCompletedLine()
        default:
            try appendNonTerminator(byte)
            return nil
        }
    }

    mutating func consume(line: String) throws -> String? {
        for byte in line.utf8 {
            if let payload = try consume(byte: byte) {
                return payload
            }
        }
        return try consume(byte: 0x0A)
    }

    mutating func finish() throws -> String? {
        if pendingCarriageReturn {
            pendingCarriageReturn = false
            if let payload = try processCompletedLine() {
                return payload
            }
        } else if !lineBuffer.isEmpty {
            if let payload = try processCompletedLine() {
                return payload
            }
        }
        return try flushEvent()
    }

    private mutating func appendNonTerminator(_ byte: UInt8) throws {
        guard lineBuffer.count < maximumLineBytes else {
            throw SSEEventDecoderError.lineTooLarge(maximumLineBytes)
        }
        lineBuffer.append(byte)
    }

    private mutating func processCompletedLine() throws -> String? {
        defer { lineBuffer.removeAll(keepingCapacity: true) }
        guard !lineBuffer.isEmpty else {
            return try flushEvent()
        }
        if lineBuffer.first == 0x3A {
            return nil
        }

        let fieldData: Data
        var value = Data()
        if let colon = lineBuffer.firstIndex(of: 0x3A) {
            fieldData = lineBuffer[..<colon]
            let valueStart = lineBuffer.index(after: colon)
            value = Data(lineBuffer[valueStart...])
            if value.first == 0x20 {
                value.removeFirst()
            }
        } else {
            fieldData = lineBuffer
        }

        guard fieldData == Data("data".utf8) else {
            return nil
        }
        let separatorBytes = dataLines.isEmpty ? 0 : 1
        let newByteCount = dataByteCount + separatorBytes + value.count
        guard newByteCount <= maximumEventBytes else {
            throw SSEEventDecoderError.eventTooLarge(maximumEventBytes)
        }
        dataByteCount = newByteCount
        dataLines.append(value)
        return nil
    }

    private mutating func flushEvent() throws -> String? {
        guard !dataLines.isEmpty else {
            return nil
        }
        var payload = Data()
        payload.reserveCapacity(dataByteCount)
        for (index, line) in dataLines.enumerated() {
            if index > 0 {
                payload.append(0x0A)
            }
            payload.append(line)
        }
        dataLines.removeAll(keepingCapacity: true)
        dataByteCount = 0
        guard let text = String(data: payload, encoding: .utf8) else {
            throw SSEEventDecoderError.invalidUTF8
        }
        return text
    }
}

enum SSEEventDecoderError: LocalizedError, Sendable, Equatable {
    case lineTooLarge(Int)
    case eventTooLarge(Int)
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case let .lineTooLarge(limit):
            return "模型流式数据行超过 \(limit) 字节上限。"
        case let .eventTooLarge(limit):
            return "模型流式事件超过 \(limit) 字节上限。"
        case .invalidUTF8:
            return "模型流式事件不是有效的 UTF-8。"
        }
    }
}
