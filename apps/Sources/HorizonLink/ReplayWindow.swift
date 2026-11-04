import Foundation

public struct ReplayWindow: Sendable {
    public let size: Int
    private var blocks: [UInt64]
    private var highest: UInt64?

    public init(size: Int = 1024) {
        self.size = (max(size, 1) + 63) / 64 * 64
        blocks = Array(repeating: 0, count: self.size / 64 + 1)
    }

    public func canAccept(_ counter: UInt64) -> Bool {
        guard let highest else { return true }
        if counter > highest { return true }
        if highest - counter >= UInt64(size) { return false }
        let (index, bit) = location(of: counter)
        return blocks[index] & bit == 0
    }

    public mutating func accept(_ counter: UInt64) {
        if let highest {
            if counter > highest {
                let current = highest >> 6
                let cleared = min((counter >> 6) - current, UInt64(blocks.count))
                for step in 0..<cleared {
                    blocks[slot(current + step + 1)] = 0
                }
                self.highest = counter
            } else if highest - counter >= UInt64(size) {
                return
            }
        } else {
            highest = counter
        }
        let (index, bit) = location(of: counter)
        blocks[index] |= bit
    }

    private func slot(_ block: UInt64) -> Int {
        Int(block % UInt64(blocks.count))
    }

    private func location(of counter: UInt64) -> (index: Int, bit: UInt64) {
        (slot(counter >> 6), 1 << (counter & 63))
    }
}
