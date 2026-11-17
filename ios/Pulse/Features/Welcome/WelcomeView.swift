import SwiftUI

/// First-launch screens: what Pulse is, the privacy promise, and the honesty notes.
/// Mono design (ios/design/DESIGN.md): one thin icon, one big heavy headline, one black button.
struct WelcomeView: View {
    let onFinish: () -> Void
    @State private var page = 0
    /// 44 pt at the default text size, grows with Dynamic Type.
    @ScaledMetric(relativeTo: .largeTitle) private var headlineSize: CGFloat = 44

    private let pages: [(symbol: String, title: String, text: String)] = [
        ("waveform.path.ecg", "Welcome\nto Pulse",
         "Pulse turns your band's heart-rate data into three simple answers: how recovered you are, how hard you've pushed, and how well you slept."),
        ("lock.shield", "Your data\nstays yours",
         "Everything is calculated on this iPhone. Pulse talks to your band directly over Bluetooth, never to anyone's servers unless you turn on a connection yourself."),
        ("flask", "Honest\nnumbers",
         "Pulse only shows what your band actually recorded: no made-up numbers. Every formula is documented, and Pulse is for general wellness, not medical advice."),
    ]

    private var isLastPage: Bool { page >= pages.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    pageView(pages[index])
                        .tag(index)
                }
            }
            // The system page dots are white, so they would vanish on a white screen. We draw our own.
            .tabViewStyle(.page(indexDisplayMode: .never))

            dots
                .padding(.horizontal, DS.Space.side)

            Button {
                if isLastPage {
                    onFinish()
                } else {
                    withAnimation(DS.Motion.spring) { page += 1 }
                }
            } label: {
                Text(isLastPage ? "Get started" : "Next")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.primaryPill)
            .padding(.horizontal, DS.Space.side)
            .padding(.bottom, DS.Space.l)
        }
        .monoBackground()
        .sensoryFeedback(.selection, trigger: page)
    }

    private func pageView(_ content: (symbol: String, title: String, text: String)) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Spacer()
            Image(systemName: content.symbol)
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(DS.Colors.accent)
                .glow(DS.Colors.accent, radius: 14)
                .accessibilityHidden(true)
            Text(content.title)
                .font(.system(size: min(headlineSize, 56), weight: .bold))
                .tracking(-1.5)
                .foregroundStyle(DS.Colors.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(content.text)
                .textStyle(.body)
                .foregroundStyle(DS.Colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, DS.Space.side)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Page indicator: the current page is a longer black capsule.
    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(pages.indices, id: \.self) { index in
                Capsule()
                    .fill(index == page ? DS.Colors.accent : DS.Colors.muted)
                    .frame(width: index == page ? 24 : 8, height: 8)
            }
        }
        .animation(DS.Motion.spring, value: page)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(page + 1) of \(pages.count)")
    }
}

#Preview("Light") {
    WelcomeView {}
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    WelcomeView {}
        .preferredColorScheme(.dark)
}
