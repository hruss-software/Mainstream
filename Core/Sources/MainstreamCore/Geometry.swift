import Foundation

public struct Pt: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

public struct Homography {
    public var h: [Double]  // row-major 3×3, h[8] == 1

    public init(_ h: [Double]) { self.h = h }

    @inline(__always) public func apply(_ x: Double, _ y: Double) -> Pt {
        let w = h[6] * x + h[7] * y + h[8]
        return Pt((h[0] * x + h[1] * y + h[2]) / w, (h[3] * x + h[4] * y + h[5]) / w)
    }

    /// Maps src[i] -> dst[i] for four correspondences.
    public static func from(_ src: [Pt], _ dst: [Pt]) -> Homography? {
        var A = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let (x, y, u, v) = (src[i].x, src[i].y, dst[i].x, dst[i].y)
            A[2 * i] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            A[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }
        guard let s = solve(&A, 8) else { return nil }
        return Homography(s + [1])
    }

    /// Composes: (self ∘ other)(p) = self(other(p))
    public func after(_ o: Homography) -> Homography {
        var r = [Double](repeating: 0, count: 9)
        for i in 0..<3 { for j in 0..<3 {
            var s = 0.0
            for k in 0..<3 { s += h[i * 3 + k] * o.h[k * 3 + j] }
            r[i * 3 + j] = s
        } }
        let n = r[8]
        return Homography(r.map { $0 / n })
    }

    public static func scaleTranslate(sx: Double, sy: Double, tx: Double, ty: Double) -> Homography {
        Homography([sx, 0, tx, 0, sy, ty, 0, 0, 1])
    }

    /// Jacobian at a point: columns d/dx, d/dy.
    @inline(__always) func jacobian(_ x: Double, _ y: Double) -> (Double, Double, Double, Double) {
        let w = h[6] * x + h[7] * y + h[8]
        let u = (h[0] * x + h[1] * y + h[2]) / w
        let v = (h[3] * x + h[4] * y + h[5]) / w
        return ((h[0] - u * h[6]) / w, (h[1] - u * h[7]) / w, (h[3] - v * h[6]) / w, (h[4] - v * h[7]) / w)
    }
}

/// Gaussian elimination on an n×(n+1) augmented matrix.
func solve(_ A: inout [[Double]], _ n: Int) -> [Double]? {
    for c in 0..<n {
        var p = c
        for r in (c + 1)..<n where abs(A[r][c]) > abs(A[p][c]) { p = r }
        if abs(A[p][c]) < 1e-12 { return nil }
        A.swapAt(c, p)
        for r in 0..<n where r != c {
            let f = A[r][c] / A[c][c]
            if f != 0 { for k in c...n { A[r][k] -= f * A[c][k] } }
        }
    }
    return (0..<n).map { A[$0][n] / A[$0][$0] }
}

func invert3(_ m: [Double]) -> [Double]? {
    let a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8]
    let A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g
    let det = a * A + b * B + c * C
    if abs(det) < 1e-9 { return nil }
    let inv = [A, -(b * i - c * h), b * f - c * e,
               B, a * i - c * g, -(a * f - c * d),
               C, -(a * h - b * g), a * e - b * d]
    return inv.map { $0 / det }
}
