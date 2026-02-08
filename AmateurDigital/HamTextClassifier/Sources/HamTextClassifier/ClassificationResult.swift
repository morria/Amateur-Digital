/// The result of classifying a text string as legitimate ham radio communication or garbage.
public struct ClassificationResult: Sendable, Equatable {
    /// Whether the text is classified as legitimate ham radio communication.
    public let isLegitimate: Bool

    /// The model's confidence in its prediction (0.0 to 1.0).
    public let confidence: Double

    /// The raw label from the model (1 = legitimate, 0 = garbage).
    public let label: Int
}
