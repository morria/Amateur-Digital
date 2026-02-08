import XCTest
@testable import RattlegramCore

final class FFTTests: XCTestCase {
    func testInverseRoundTrip() {
        let n = 64
        let fwd = FFT(size: n, sign: -1)
        let bwd = FFT(size: n, sign: 1)

        var input = [cmplx](repeating: cmplx(), count: n)
        for i in 0..<n {
            input[i] = cmplx(Float.random(in: -1...1), Float.random(in: -1...1))
        }

        var freq = [cmplx](repeating: cmplx(), count: n)
        var recovered = [cmplx](repeating: cmplx(), count: n)
        fwd.transform(&freq, input)
        bwd.transform(&recovered, freq)

        // IFFT should recover input (scaled by N)
        for i in 0..<n {
            XCTAssertEqual(recovered[i].real / Float(n), input[i].real, accuracy: 1e-4)
            XCTAssertEqual(recovered[i].imag / Float(n), input[i].imag, accuracy: 1e-4)
        }
    }

    func testParseval() {
        let n = 128
        let fwd = FFT(size: n, sign: -1)

        var input = [cmplx](repeating: cmplx(), count: n)
        for i in 0..<n {
            input[i] = cmplx(Float.random(in: -1...1), Float.random(in: -1...1))
        }

        var freq = [cmplx](repeating: cmplx(), count: n)
        fwd.transform(&freq, input)

        // Parseval's theorem: sum|x|² = (1/N) sum|X|²
        var timePower: Float = 0
        var freqPower: Float = 0
        for i in 0..<n {
            timePower += norm(input[i])
            freqPower += norm(freq[i])
        }
        XCTAssertEqual(timePower, freqPower / Float(n), accuracy: 1e-2)
    }

    func testKnownDCSignal() {
        let n = 16
        let fwd = FFT(size: n, sign: -1)

        // All ones -> DC bin = N, rest = 0
        let input = [cmplx](repeating: cmplx(1, 0), count: n)
        var freq = [cmplx](repeating: cmplx(), count: n)
        fwd.transform(&freq, input)

        XCTAssertEqual(freq[0].real, Float(n), accuracy: 1e-4)
        XCTAssertEqual(freq[0].imag, 0, accuracy: 1e-4)
        for i in 1..<n {
            XCTAssertEqual(abs(freq[i]), 0, accuracy: 1e-4)
        }
    }

    func testMixedRadixSize() {
        // 7680 = 2^9 × 3 × 5 (the actual symbol length at 48kHz)
        let n = 7680
        let fwd = FFT(size: n, sign: -1)
        let bwd = FFT(size: n, sign: 1)

        var input = [cmplx](repeating: cmplx(), count: n)
        input[0] = cmplx(1, 0)
        input[1] = cmplx(0, 1)

        var freq = [cmplx](repeating: cmplx(), count: n)
        var recovered = [cmplx](repeating: cmplx(), count: n)
        fwd.transform(&freq, input)
        bwd.transform(&recovered, freq)

        XCTAssertEqual(recovered[0].real / Float(n), 1, accuracy: 1e-3)
        XCTAssertEqual(recovered[1].imag / Float(n), 1, accuracy: 1e-3)
    }

    func testSingleFrequency() {
        let n = 64
        let fwd = FFT(size: n, sign: -1)
        let k = 5 // frequency bin

        var input = [cmplx](repeating: cmplx(), count: n)
        for i in 0..<n {
            let angle = 2.0 * Float.pi * Float(k) * Float(i) / Float(n)
            input[i] = cmplx(cos(angle), sin(angle))
        }

        var freq = [cmplx](repeating: cmplx(), count: n)
        fwd.transform(&freq, input)

        // Energy should be concentrated at bin k
        XCTAssertEqual(abs(freq[k]), Float(n), accuracy: 1e-2)
        for i in 0..<n where i != k {
            XCTAssertEqual(abs(freq[i]), 0, accuracy: 1e-2)
        }
    }
}
