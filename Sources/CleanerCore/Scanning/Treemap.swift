import CoreGraphics

/// Squarified treemap layout (Bruls, Huizing, van Wijk): rectangles with areas
/// proportional to the values and aspect ratios close to 1.
public enum Treemap {
    /// Returns one rectangle per value, in the same order. Values should be
    /// sorted from largest to smallest for the best layout.
    public static func squarify(_ values: [Double], in bounds: CGRect) -> [CGRect] {
        var result = Array(repeating: CGRect.zero, count: values.count)
        let total = values.reduce(0) { $0 + max($1, 0) }
        guard total > 0, bounds.width > 0, bounds.height > 0 else { return result }

        let scale = Double(bounds.width * bounds.height) / total
        let areas = values.map { max($0, 0) * scale }
        var remaining = bounds
        var start = 0

        while start < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            var end = start + 1
            var worst = worstRatio(areas[start ..< end], side: side)
            while end < areas.count {
                let candidate = worstRatio(areas[start ... end], side: side)
                if candidate > worst {
                    break
                }
                worst = candidate
                end += 1
            }

            let rowArea = areas[start ..< end].reduce(0, +)
            if remaining.width >= remaining.height {
                // Lay the row out as a column along the left edge.
                let width = remaining.height > 0 ? rowArea / Double(remaining.height) : 0
                var y = Double(remaining.minY)
                for index in start ..< end {
                    let height = width > 0 ? areas[index] / width : 0
                    result[index] = CGRect(x: Double(remaining.minX), y: y, width: width, height: height)
                    y += height
                }
                remaining = CGRect(
                    x: remaining.minX + width, y: remaining.minY,
                    width: max(remaining.width - width, 0), height: remaining.height
                )
            } else {
                // Lay the row out along the top edge.
                let height = remaining.width > 0 ? rowArea / Double(remaining.width) : 0
                var x = Double(remaining.minX)
                for index in start ..< end {
                    let width = height > 0 ? areas[index] / height : 0
                    result[index] = CGRect(x: x, y: Double(remaining.minY), width: width, height: height)
                    x += width
                }
                remaining = CGRect(
                    x: remaining.minX, y: remaining.minY + height,
                    width: remaining.width, height: max(remaining.height - height, 0)
                )
            }
            start = end
        }
        return result
    }

    /// The worst aspect ratio in a row laid out along a side of length `side`.
    private static func worstRatio(_ row: ArraySlice<Double>, side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard sum > 0, side > 0, let largest = row.max(), let smallest = row.min(), smallest > 0 else {
            return .infinity
        }
        let sideSquared = side * side
        let sumSquared = sum * sum
        return max(sideSquared * largest / sumSquared, sumSquared / (sideSquared * smallest))
    }
}
