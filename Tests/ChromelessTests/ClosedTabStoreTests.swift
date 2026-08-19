import Foundation
import Testing
@testable import ChromelessCore

@Suite("ClosedTabStore — recently-closed tab stack", .serialized)
struct ClosedTabStoreTests {

    @Test("push/pop is LIFO and http(s)-only")
    func lifoAndSchemeFilter() {
        ClosedTabStore.stack.removeAll()
        ClosedTabStore.push(URL(string: "https://one.example"))
        ClosedTabStore.push(URL(string: "http://two.example"))
        ClosedTabStore.push(URL(string: "chromeless://settings")) // rejected
        ClosedTabStore.push(nil)                                   // rejected

        #expect(ClosedTabStore.stack.count == 2)
        #expect(ClosedTabStore.pop()?.absoluteString == "http://two.example")
        #expect(ClosedTabStore.pop()?.absoluteString == "https://one.example")
        #expect(ClosedTabStore.pop() == nil)
    }

    @Test("The stack is capped at 50 entries, evicting the oldest")
    func cap() {
        ClosedTabStore.stack.removeAll()
        for i in 0..<55 {
            ClosedTabStore.push(URL(string: "https://example.com/\(i)"))
        }
        #expect(ClosedTabStore.stack.count == 50)
        #expect(ClosedTabStore.stack.first?.absoluteString == "https://example.com/5")
        #expect(ClosedTabStore.stack.last?.absoluteString == "https://example.com/54")
    }
}
