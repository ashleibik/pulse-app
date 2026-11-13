import SwiftUI

/// First-launch screens: what Pulse is, the privacy promise, and the honesty notes.
struct WelcomeView: View {
    let onFinish: () -> Void
    @State private var page = 0

    private let pages: [(symbol: String, color: Color, title: String, text: String)] = [
        ("waveform.path.ecg.rectangle.fill", Theme.recoveryGreen, "Welcome to Pulse",
         "Pulse turns your band's heart-rate data into three simple answers: how recovered you are, how hard you've pushed, and how well you slept."),
        ("lock.shield.fill", Theme.accent, "Your data stays yours",
         "Everything is calculated on this iPhone. Pulse talks to your band directly over Bluetooth, never to anyone's servers unless you turn on a connection yourself."),
        ("flask.fill", Theme.recoveryYellow, "Honest numbers",
         "Until your band is paired, Pulse shows a simulated month so you can explore. Every formula is documented, and Pulse is for general wellness, not medical advice."),
    ]

    var body: some View {
        VStack(spacing: 24) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { i in
                    VStack(spacing: 20) {
                        Image(systemName: pages[i].symbol)
                            .font(.system(size: 72))
                            .foregroundStyle(pages[i].color.gradient)
                            .accessibilityHidden(true)
                        Text(pages[i].title)
                            .font(.largeTitle.weight(.bold))
                            .multilineTextAlignment(.center)
                        Text(pages[i].text)
                            .font(.body)
                            .foregroundStyle(Theme.secondaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 32)
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            Button {
                if page < pages.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    onFinish()
                }
            } label: {
                Text(page < pages.count - 1 ? "Next" : "Get started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .sensoryFeedback(.selection, trigger: page)
        }
        .background(Theme.background.ignoresSafeArea())
    }
}

#Preview {
    WelcomeView {}
        .preferredColorScheme(.dark)
}
