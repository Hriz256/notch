public struct FeatureID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ raw: String) { rawValue = raw }
    public var description: String { rawValue }
}
