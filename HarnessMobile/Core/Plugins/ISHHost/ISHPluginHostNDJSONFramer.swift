import Foundation

struct ISHPluginHostNDJSONFramer: Sendable {
    private(set) var bufferedByteCount = 0

    private let maximumLineBytes: Int
    private var buffer = Data()

    init(maximumLineBytes: Int = 4 * 1_024 * 1_024) {
        self.maximumLineBytes = max(maximumLineBytes, 1)
    }

    mutating func append(_ chunk: Data) throws -> [Data] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)
        var lines: [Data] = []

        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.last == 0x0D {
                line.removeLast()
            }
            guard line.count <= maximumLineBytes else {
                throw ISHPluginHostError.frameTooLarge(maximumBytes: maximumLineBytes)
            }
            if !line.isEmpty {
                lines.append(line)
            }
        }

        bufferedByteCount = buffer.count
        guard buffer.count <= maximumLineBytes else {
            throw ISHPluginHostError.frameTooLarge(maximumBytes: maximumLineBytes)
        }
        return lines
    }

    mutating func finish() throws -> [Data] {
        defer {
            buffer.removeAll(keepingCapacity: false)
            bufferedByteCount = 0
        }
        guard !buffer.isEmpty else { return [] }
        guard buffer.count <= maximumLineBytes else {
            throw ISHPluginHostError.frameTooLarge(maximumBytes: maximumLineBytes)
        }
        if buffer.last == 0x0D {
            buffer.removeLast()
        }
        return buffer.isEmpty ? [] : [buffer]
    }
}

