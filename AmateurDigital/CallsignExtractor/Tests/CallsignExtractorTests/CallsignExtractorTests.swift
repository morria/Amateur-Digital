import Testing
@testable import CallsignExtractor

@Suite("CallsignExtractor Tests")
struct CallsignExtractorTests {

    let extractor: CallsignExtractor

    init() throws {
        extractor = try CallsignExtractor()
    }

    // MARK: - CQ Calls

    @Test func cqBasic() {
        let result = extractor.extractCallsign("CQ CQ CQ DE W1AW W1AW K")
        #expect(result == "W1AW")
    }

    @Test func cqNoDe() {
        let result = extractor.extractCallsign("CQ CQ W1AW W1AW K")
        #expect(result == "W1AW")
    }

    @Test func cqPOTA() {
        let result = extractor.extractCallsign("CQ POTA CQ POTA DE K4SWL K4SWL K")
        #expect(result == "K4SWL")
    }

    @Test func cqSOTA() {
        let result = extractor.extractCallsign("CQ SOTA CQ SOTA DE VK3ABC VK3ABC K")
        #expect(result == "VK3ABC")
    }

    @Test func cqDX() {
        let result = extractor.extractCallsign("CQ DX CQ DX DE JA1XYZ K")
        #expect(result == "JA1XYZ")
    }

    @Test func cqContest() {
        let result = extractor.extractCallsign("CQ TEST N5KO N5KO")
        #expect(result == "N5KO")
    }

    // MARK: - Reply to CQ (target is the CQ caller, listed first)

    @Test func replyToCQ() {
        let result = extractor.extractCallsign("W1AW W1AW DE VK3ABC VK3ABC K")
        #expect(result == "W1AW")
    }

    // MARK: - Exchange (target is the DE station)

    @Test func exchange() {
        let result = extractor.extractCallsign("VK3ABC DE W1AW UR RST 599 599 NAME JOHN QTH CT BK")
        #expect(result == "W1AW")
    }

    // MARK: - Multi-QSO buffer (target is the new CQ caller)

    @Test func multiQSOBuffer() {
        let result = extractor.extractCallsign("73 W1AW DE VK3ABC SK  CQ CQ DE JA1XYZ JA1XYZ K")
        #expect(result == "JA1XYZ")
    }

    // MARK: - Single callsign

    @Test func singleCallsign() {
        let result = extractor.extractCallsign("CQ CQ DE DL1ABC K")
        #expect(result == "DL1ABC")
    }

    // MARK: - No callsign

    @Test func noCallsign() {
        let result = extractor.extractCallsign("CQ CQ CQ NO CALLSIGN HERE")
        #expect(result == nil)
    }

    // MARK: - Confidence API

    @Test func confidenceAPI() throws {
        let result = extractor.extractCallsignWithConfidence("CQ CQ CQ DE W1AW W1AW K")
        #expect(result != nil)
        #expect(result?.callsign == "W1AW")
        #expect((result?.confidence ?? 0) > 0.5)
    }

    // MARK: - POTA with park reference

    @Test func potaWithPark() {
        let result = extractor.extractCallsign("CQ POTA K4SWL K-1234 K")
        #expect(result == "K4SWL")
    }

    // MARK: - Tail end / 73

    @Test func tailEnd73() {
        let result = extractor.extractCallsign("73 AB1CD DE EF2GH SK")
        #expect(result == "EF2GH")
    }

    // MARK: - Various international callsigns

    @Test func japaneseCallsign() {
        let result = extractor.extractCallsign("CQ CQ DE JA1XYZ JA1XYZ K")
        #expect(result == "JA1XYZ")
    }

    @Test func germanCallsign() {
        let result = extractor.extractCallsign("CQ CQ DE DL3ABC K")
        #expect(result == "DL3ABC")
    }

    @Test func australianCallsign() {
        let result = extractor.extractCallsign("CQ CQ DE VK2XYZ K")
        #expect(result == "VK2XYZ")
    }
}
