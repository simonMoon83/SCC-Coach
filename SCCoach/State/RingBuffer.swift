// 고정 용량 링버퍼 — supplyHistory(180)·alertLog(64) 등 (§4.3)
public struct RingBuffer<Element> {
    private var storage: [Element] = []
    private var head = 0                 // 다음 쓰기 위치
    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
        }
        head = (head + 1) % capacity
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }

    /// 오래된 것 → 최신 순
    public var elements: [Element] {
        if storage.count < capacity { return storage }
        return Array(storage[head...] + storage[..<head])
    }

    public var last: Element? {
        guard !storage.isEmpty else { return nil }
        if storage.count < capacity { return storage.last }
        return storage[(head + capacity - 1) % capacity]
    }
}
