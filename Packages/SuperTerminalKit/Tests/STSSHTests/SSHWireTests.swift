import Testing
@testable import STSSH

@Suite("SSH wire codec")
struct SSHWireTests {
    @Test("Reads a length-prefixed string")
    func readsString() {
        var reader = SSHWireReader(Data([0, 0, 0, 3, 0x61, 0x62, 0x63]))
        #expect(reader.readStringUTF8() == "abc")
        #expect(reader.isAtEnd)
    }
}
import Foundation
