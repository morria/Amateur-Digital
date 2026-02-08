/*
 Fast complex math - ported from complex.hh
 Original Copyright 2018 Ahmet Inan <inan@aicodix.de>
 */

import Foundation

public struct Complex<T: FloatingPoint>: Equatable, AdditiveArithmetic {
    public static var zero: Complex { Complex() }

    public static func == (lhs: Complex, rhs: Complex) -> Bool {
        lhs.real == rhs.real && lhs.imag == rhs.imag
    }

    public var real: T
    public var imag: T

    @inlinable
    public init() {
        self.real = 0
        self.imag = 0
    }

    @inlinable
    public init(_ real: T) {
        self.real = real
        self.imag = 0
    }

    @inlinable
    public init(_ real: T, _ imag: T) {
        self.real = real
        self.imag = imag
    }
}

// MARK: - Arithmetic Operators

extension Complex {
    @inlinable
    public static func + (a: Complex, b: Complex) -> Complex {
        Complex(a.real + b.real, a.imag + b.imag)
    }

    @inlinable
    public static func - (a: Complex, b: Complex) -> Complex {
        Complex(a.real - b.real, a.imag - b.imag)
    }

    @inlinable
    public static prefix func - (a: Complex) -> Complex {
        Complex(-a.real, -a.imag)
    }

    @inlinable
    public static prefix func + (a: Complex) -> Complex {
        a
    }

    @inlinable
    public static func * (a: Complex, b: Complex) -> Complex {
        Complex(a.real * b.real - a.imag * b.imag,
                a.real * b.imag + a.imag * b.real)
    }

    @inlinable
    public static func * (a: T, b: Complex) -> Complex {
        Complex(a * b.real, a * b.imag)
    }

    @inlinable
    public static func * (a: Complex, b: T) -> Complex {
        Complex(a.real * b, a.imag * b)
    }

    @inlinable
    public static func / (a: Complex, b: T) -> Complex {
        Complex(a.real / b, a.imag / b)
    }

    @inlinable
    public static func / (a: Complex, b: Complex) -> Complex {
        let denom = b.real * b.real + b.imag * b.imag
        return Complex(
            (a.real * b.real + a.imag * b.imag) / denom,
            (a.imag * b.real - a.real * b.imag) / denom
        )
    }

    @inlinable
    public static func += (a: inout Complex, b: Complex) {
        a = a + b
    }

    @inlinable
    public static func -= (a: inout Complex, b: Complex) {
        a = a - b
    }

    @inlinable
    public static func *= (a: inout Complex, b: Complex) {
        a = a * b
    }

    @inlinable
    public static func *= (a: inout Complex, b: T) {
        a = a * b
    }

    @inlinable
    public static func /= (a: inout Complex, b: T) {
        a = a / b
    }

    @inlinable
    public static func /= (a: inout Complex, b: Complex) {
        a = a / b
    }
}

// MARK: - Free Functions

@inlinable
public func conj<T>(_ a: Complex<T>) -> Complex<T> {
    Complex(a.real, -a.imag)
}

@inlinable
public func norm<T>(_ a: Complex<T>) -> T {
    a.real * a.real + a.imag * a.imag
}

@inlinable
public func abs(_ a: Complex<Float>) -> Float {
    Foundation.sqrt(norm(a))
}

@inlinable
public func abs(_ a: Complex<Double>) -> Double {
    Foundation.sqrt(norm(a))
}

@inlinable
public func arg(_ a: Complex<Float>) -> Float {
    Foundation.atan2(a.imag, a.real)
}

@inlinable
public func arg(_ a: Complex<Double>) -> Double {
    Foundation.atan2(a.imag, a.real)
}

@inlinable
public func polar(_ r: Float, _ theta: Float) -> Complex<Float> {
    Complex(r * Foundation.cos(theta), r * Foundation.sin(theta))
}

@inlinable
public func polar(_ r: Double, _ theta: Double) -> Complex<Double> {
    Complex(r * Foundation.cos(theta), r * Foundation.sin(theta))
}

// MARK: - Type Alias

public typealias cmplx = Complex<Float>
