/*
 Trigger functions - ported from trigger.hh
 Original Copyright 2019 Ahmet Inan <inan@aicodix.de>
 */

public struct SchmittTrigger {
    private let low: Float
    private let high: Float
    private var previous: Bool

    public init(low: Float, high: Float, previous: Bool = false) {
        self.low = low
        self.high = high
        self.previous = previous
    }

    public mutating func process(_ input: Float) -> Bool {
        if previous {
            if input < low { previous = false }
        } else {
            if input > high { previous = true }
        }
        return previous
    }
}

public struct FallingEdgeTrigger {
    private var previous: Bool

    public init(previous: Bool = false) {
        self.previous = previous
    }

    public mutating func process(_ input: Bool) -> Bool {
        let tmp = previous
        previous = input
        return tmp && !input
    }
}

public struct RisingEdgeTrigger {
    private var previous: Bool

    public init(previous: Bool = false) {
        self.previous = previous
    }

    public mutating func process(_ input: Bool) -> Bool {
        let tmp = previous
        previous = input
        return !tmp && input
    }
}
