import Foundation

public struct CalibrationObservation: Codable, Sendable, Equatable {
    public let features: [Double]
    public let target: GazePoint
    public init(features: [Double], target: GazePoint) { self.features = features; self.target = target }
}

/// Persist with the provider type, camera, orientation and viewport used to collect it.
public struct CalibrationSnapshot: Codable, Sendable, Equatable {
    public let version: Int
    public let observations: [CalibrationObservation]
    public init(observations: [CalibrationObservation]) { version = 1; self.observations = observations }
    public func fittedModel() throws -> CalibrationModel {
        guard version == 1 else { throw EyeTrackingError.invalidCalibration }
        return try CalibrationModel.fit(observations)
    }
}

public struct CalibrationModel: Codable, Sendable, Equatable {
    public let xCoefficients: [Double]
    public let yCoefficients: [Double]
    public init(xCoefficients: [Double], yCoefficients: [Double]) throws {
        guard xCoefficients.count >= 2, xCoefficients.count == yCoefficients.count,
              (xCoefficients + yCoefficients).allSatisfy(\.isFinite) else { throw EyeTrackingError.invalidCalibration }
        self.xCoefficients = xCoefficients; self.yCoefficients = yCoefficients
    }
    public func predict(_ features: [Double]) -> GazePoint? {
        guard features.count + 1 == xCoefficients.count, xCoefficients.count == yCoefficients.count,
              features.allSatisfy(\.isFinite) else { return nil }
        let row = [1.0] + features
        let point = GazePoint(x: zip(row, xCoefficients).reduce(0) { $0 + $1.0 * $1.1 },
                              y: zip(row, yCoefficients).reduce(0) { $0 + $1.0 * $1.1 })
        return point.isFinite ? point : nil
    }
    public static func fit(_ observations: [CalibrationObservation]) throws -> CalibrationModel {
        guard let first = observations.first, !first.features.isEmpty else { throw EyeTrackingError.insufficientCalibration }
        let n = first.features.count + 1
        guard observations.count >= n else { throw EyeTrackingError.insufficientCalibration }
        guard observations.allSatisfy({ $0.features.count == n - 1 && $0.features.allSatisfy(\.isFinite) &&
            $0.target.isFinite && (0...1).contains($0.target.x) && (0...1).contains($0.target.y) }) else {
            throw EyeTrackingError.invalidCalibration
        }
        // Standardize to avoid units dominating the rank test, then solve least squares.
        let means = (0..<n-1).map { j in observations.map { $0.features[j] }.reduce(0, +) / Double(observations.count) }
        let scales = (0..<n-1).map { j in
            sqrt(observations.reduce(0) { $0 + pow($1.features[j] - means[j], 2) } / Double(observations.count))
        }
        guard scales.allSatisfy({ $0.isFinite && $0 > 1e-10 }) else { throw EyeTrackingError.invalidCalibration }
        var matrix = Array(repeating: Array(repeating: 0.0, count: n + 2), count: n)
        for observation in observations {
            let row = [1.0] + (0..<n-1).map { (observation.features[$0] - means[$0]) / scales[$0] }
            for i in 0..<n {
                for j in 0..<n { matrix[i][j] += row[i] * row[j] }
                matrix[i][n] += row[i] * observation.target.x
                matrix[i][n+1] += row[i] * observation.target.y
            }
        }
        for column in 0..<n {
            let pivot = (column..<n).max { abs(matrix[$0][column]) < abs(matrix[$1][column]) }!
            guard abs(matrix[pivot][column]) > Double(observations.count) * 1e-9 else { throw EyeTrackingError.invalidCalibration }
            matrix.swapAt(column, pivot)
            let divisor = matrix[column][column]
            for j in column..<n+2 { matrix[column][j] /= divisor }
            for i in 0..<n where i != column {
                let factor = matrix[i][column]
                for j in column..<n+2 { matrix[i][j] -= factor * matrix[column][j] }
            }
        }
        func coefficients(_ output: Int) -> [Double] {
            let slopes = (1..<n).map { matrix[$0][output] / scales[$0-1] }
            return [matrix[0][output] - zip(slopes, means).reduce(0) { $0 + $1.0 * $1.1 }] + slopes
        }
        return try .init(xCoefficients: coefficients(n), yCoefficients: coefficients(n+1))
    }
}

public struct GazeSmoother: Sendable {
    public var timeConstant: Double
    private var last: (UInt64, GazePoint)?
    public init(timeConstant: Double = 0.08) { self.timeConstant = timeConstant }
    public mutating func reset() { last = nil }
    public mutating func filter(_ point: GazePoint, timestampNanos: UInt64) -> GazePoint? {
        guard point.isFinite else { return nil }
        guard let previous = last else { last = (timestampNanos, point); return point }
        guard timestampNanos > previous.0 else { return nil }
        let dt = Double(timestampNanos - previous.0) / 1e9
        let alpha = timeConstant > 0 && timeConstant.isFinite && dt < 1 ? 1 - exp(-dt / timeConstant) : 1
        let result = GazePoint(x: previous.1.x + alpha * (point.x - previous.1.x),
                               y: previous.1.y + alpha * (point.y - previous.1.y))
        last = (timestampNanos, result)
        return result
    }
}
