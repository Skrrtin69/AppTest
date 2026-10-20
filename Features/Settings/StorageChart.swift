import SwiftUI
#if canImport(Charts)
import Charts
#endif

/// Horizontal bars, one per storage slice: Swift Charts on iOS 16+, simple bars on iOS 15.
struct StorageChart: View {
    let slices: [StorageView.Slice]

    var body: some View {
        #if canImport(Charts)
        if #available(iOS 16.0, *) {
            Chart(slices) { s in
                BarMark(x: .value("Size (MB)", Double(s.bytes) / 1_048_576), y: .value("Item", s.label))
                    .foregroundStyle(by: .value("Kind", s.kind))
                    .annotation(position: .trailing) {
                        Text(StorageView.size(s.bytes)).font(.caption2).foregroundColor(.secondary)
                    }
            }
            .chartForegroundStyleScale(["Cache": Color.orange, "Downloads": Color.accentColor, "Data": Color.purple])
            .chartXAxisLabel("MB")
            .accessibilityIdentifier("storageChart")
        } else {
            bars
        }
        #else
        bars
        #endif
    }

    var bars: some View {
        let biggest = max(slices.map(\.bytes).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(slices) { s in
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.label).font(.caption)
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 3).fill(StorageView.color(s.kind))
                            .frame(width: max(2, g.size.width * CGFloat(s.bytes) / CGFloat(biggest)))
                    }
                    .frame(height: 10)
                }
            }
        }
    }
}
