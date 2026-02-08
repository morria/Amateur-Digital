import XCTest
@testable import RattlegramCore

final class ComplexTests: XCTestCase {
    func testAddition() {
        let a = cmplx(1, 2)
        let b = cmplx(3, 4)
        let c = a + b
        XCTAssertEqual(c.real, 4)
        XCTAssertEqual(c.imag, 6)
    }

    func testSubtraction() {
        let a = cmplx(5, 7)
        let b = cmplx(2, 3)
        let c = a - b
        XCTAssertEqual(c.real, 3)
        XCTAssertEqual(c.imag, 4)
    }

    func testMultiplication() {
        let a = cmplx(1, 2)
        let b = cmplx(3, 4)
        // (1+2i)(3+4i) = 3+4i+6i+8i² = 3+10i-8 = -5+10i
        let c = a * b
        XCTAssertEqual(c.real, -5)
        XCTAssertEqual(c.imag, 10)
    }

    func testDivision() {
        let a = cmplx(-5, 10)
        let b = cmplx(1, 2)
        // (-5+10i)/(1+2i) = (-5+10i)(1-2i)/|1+2i|² = (-5+10+10i+20i²)/5 = (-5+10-20+10i)/5 = nope
        // Actually: (-5+10i)(1-2i) = -5+10i+10i-20i² = -5+20+20i = 15+20i, /5 = 3+4i
        let c = a / b
        XCTAssertEqual(c.real, 3, accuracy: 1e-6)
        XCTAssertEqual(c.imag, 4, accuracy: 1e-6)
    }

    func testScalarMultiply() {
        let a = cmplx(2, 3)
        let b = a * 2
        XCTAssertEqual(b.real, 4)
        XCTAssertEqual(b.imag, 6)
    }

    func testNorm() {
        let a = cmplx(3, 4)
        XCTAssertEqual(norm(a), 25) // |z|² = 9+16 = 25
    }

    func testAbs() {
        let a = cmplx(3, 4)
        XCTAssertEqual(abs(a), 5, accuracy: 1e-6)
    }

    func testConj() {
        let a = cmplx(3, 4)
        let c = conj(a)
        XCTAssertEqual(c.real, 3)
        XCTAssertEqual(c.imag, -4)
    }

    func testArg() {
        let a = cmplx(1, 0)
        XCTAssertEqual(arg(a), 0, accuracy: 1e-6)

        let b = cmplx(0, 1)
        XCTAssertEqual(arg(b), Float.pi / 2, accuracy: 1e-6)

        let c = cmplx(-1, 0)
        XCTAssertEqual(Swift.abs(arg(c)), Float.pi, accuracy: 1e-6)
    }

    func testPolar() {
        let z = polar(2 as Float, Float.pi / 4)
        let expected = cmplx(Float(2) * Float(cos(Float.pi / 4)),
                             Float(2) * Float(sin(Float.pi / 4)))
        XCTAssertEqual(z.real, expected.real, accuracy: 1e-6)
        XCTAssertEqual(z.imag, expected.imag, accuracy: 1e-6)
    }

    func testZero() {
        let z = cmplx()
        XCTAssertEqual(z.real, 0)
        XCTAssertEqual(z.imag, 0)
    }

    func testMultiplicativeIdentity() {
        let a = cmplx(3, 4)
        let one = cmplx(1, 0)
        let b = a * one
        XCTAssertEqual(b.real, a.real)
        XCTAssertEqual(b.imag, a.imag)
    }
}
