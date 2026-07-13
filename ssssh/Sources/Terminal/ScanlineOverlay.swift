import SwiftUI

/// Subtle repeating horizontal lines plus a soft vignette to sell the CRT
/// look, without hurting text legibility.
struct ScanlineOverlay: View {
    var body: some View {
        Canvas { context, size in
            let lineSpacing: CGFloat = 3
            var y: CGFloat = 0
            while y < size.height {
                let rect = CGRect(x: 0, y: y, width: size.width, height: 1)
                context.fill(Path(rect), with: .color(.black.opacity(0.06)))
                y += lineSpacing
            }
        }
        .overlay(
            RadialGradient(
                colors: [.clear, .black.opacity(0.12)],
                center: .center,
                startRadius: 0,
                endRadius: 500
            )
        )
    }
}

#Preview {
    ZStack {
        Color.black
        ScanlineOverlay()
    }
    .ignoresSafeArea()
}
