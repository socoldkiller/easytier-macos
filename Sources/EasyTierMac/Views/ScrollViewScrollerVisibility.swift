import SwiftUI

extension View {
    func hideScrollViewScrollers(vertical: Bool = true, horizontal: Bool = true) -> some View {
        scrollIndicators(.hidden, axes: hiddenScrollIndicatorAxes(vertical: vertical, horizontal: horizontal))
    }
}

private func hiddenScrollIndicatorAxes(vertical: Bool, horizontal: Bool) -> Axis.Set {
    var axes: Axis.Set = []
    if vertical { axes.insert(.vertical) }
    if horizontal { axes.insert(.horizontal) }
    return axes
}
