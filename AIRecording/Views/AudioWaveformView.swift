import SwiftUI

struct AudioWaveformView: View {
    let levels: [Float]
    let isPlaying: Bool

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(0..<barCount(in: geometry), id: \.self) { index in
                    let level = index < levels.count ? levels[index] : 0
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor(level: level))
                        .frame(width: barWidth(in: geometry))
                        .frame(height: max(4, CGFloat(level) * geometry.size.height))
                        .animation(.easeInOut(duration: 0.1), value: level)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func barCount(in geometry: GeometryProxy) -> Int {
        let width = barWidth(in: geometry)
        return max(20, Int(geometry.size.width / (width + 2)))
    }

    private func barWidth(in geometry: GeometryProxy) -> CGFloat {
        return max(3, geometry.size.width / 80)
    }

    private func barColor(level: Float) -> Color {
        if level > 0.8 {
            return .red.opacity(0.8)
        } else if level > 0.5 {
            return .orange.opacity(0.8)
        } else {
            return .accentColor.opacity(0.6)
        }
    }
}
