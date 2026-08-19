import AppKit
import Foundation
import Testing
@testable import ChromelessCore

@Suite("String & NSColor extensions")
struct StringExtensionTests {

    @Test("nilIfEmpty maps empty strings to nil")
    func nilIfEmpty() {
        #expect("".nilIfEmpty == nil)
        #expect("x".nilIfEmpty == "x")
        #expect(" ".nilIfEmpty == " ") // whitespace is not empty
    }

    @Test("NSColor(hex:) parses 6-digit hex")
    func sixDigit() throws {
        let color = try #require(NSColor(hex: "#3B82F6"))
        let rgb = color.usingColorSpace(.sRGB)
        #expect(rgb != nil)
        #expect(abs(rgb!.redComponent - 0x3B / 255.0) < 0.001)
        #expect(abs(rgb!.greenComponent - 0x82 / 255.0) < 0.001)
        #expect(abs(rgb!.blueComponent - 0xF6 / 255.0) < 0.001)
        #expect(abs(rgb!.alphaComponent - 1.0) < 0.001)
    }

    @Test("NSColor(hex:) expands 3-digit shorthand")
    func threeDigit() throws {
        let color = try #require(NSColor(hex: "#F00"))
        let rgb = color.usingColorSpace(.sRGB)
        #expect(abs(rgb!.redComponent - 1.0) < 0.001)
        #expect(abs(rgb!.greenComponent - 0.0) < 0.001)
        #expect(abs(rgb!.blueComponent - 0.0) < 0.001)
    }

    @Test("NSColor(hex:) parses 8-digit hex with alpha")
    func eightDigit() throws {
        let color = try #require(NSColor(hex: "#FF000080"))
        let rgb = color.usingColorSpace(.sRGB)
        #expect(abs(rgb!.redComponent - 1.0) < 0.001)
        #expect(abs(rgb!.alphaComponent - 0x80 / 255.0) < 0.001)
    }

    @Test("NSColor(hex:) tolerates a missing # and surrounding whitespace")
    func lenientInput() {
        #expect(NSColor(hex: "3B82F6") != nil)
        #expect(NSColor(hex: "  #3B82F6  ") != nil)
    }

    @Test("NSColor(hex:) rejects malformed input")
    func malformed() {
        #expect(NSColor(hex: "") == nil)
        #expect(NSColor(hex: "#GGGGGG") == nil)
        #expect(NSColor(hex: "#12345") == nil)   // 5 digits
        #expect(NSColor(hex: "#1234567890") == nil)
    }
}
