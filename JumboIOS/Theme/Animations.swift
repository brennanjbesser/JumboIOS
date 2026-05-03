import SwiftUI

// MARK: - Animation Constants
struct AnimationConfig {
    static let snappy = Animation.spring(response: 0.25, dampingFraction: 0.7)
    static let bouncy = Animation.spring(response: 0.3, dampingFraction: 0.5)
    static let smooth = Animation.easeInOut(duration: 0.2)
    static let quick = Animation.easeOut(duration: 0.15)

    static let voteBounce = Animation.spring(response: 0.2, dampingFraction: 0.4)
    static let cardAppear = Animation.spring(response: 0.4, dampingFraction: 0.7)
    static let pulse = Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true)
}

// MARK: - Pulse Animation Modifier
struct PulseAnimationModifier: ViewModifier {
    @State private var isPulsing = false
    let color: Color
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .overlay(
                Circle()
                    .stroke(color, lineWidth: 2)
                    .scaleEffect(isPulsing ? 1.5 : 1.0)
                    .opacity(isPulsing ? 0 : 0.8)
                    .animation(
                        isActive ? .easeOut(duration: 1.0).repeatForever(autoreverses: false) : .default,
                        value: isPulsing
                    )
            )
            .onAppear {
                if isActive {
                    isPulsing = true
                }
            }
            .onChange(of: isActive) { _, newValue in
                isPulsing = newValue
            }
    }
}

extension View {
    func pulseAnimation(color: Color, isActive: Bool = true) -> some View {
        modifier(PulseAnimationModifier(color: color, isActive: isActive))
    }
}

// MARK: - Bounce Scale Animation
struct BounceScaleModifier: ViewModifier {
    @Binding var isAnimating: Bool
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(isAnimating ? scale : 1.0)
            .animation(AnimationConfig.voteBounce, value: isAnimating)
            .onChange(of: isAnimating) { _, newValue in
                if newValue {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        isAnimating = false
                    }
                }
            }
    }
}

// MARK: - Particle Burst Effect
struct ParticleBurstView: View {
    let color: Color
    let particleCount: Int
    @Binding var isActive: Bool

    @State private var particles: [Particle] = []

    struct Particle: Identifiable {
        let id = UUID()
        var x: CGFloat
        var y: CGFloat
        var scale: CGFloat
        var opacity: Double
        var rotation: Double
    }

    var body: some View {
        ZStack {
            ForEach(particles) { particle in
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .scaleEffect(particle.scale)
                    .opacity(particle.opacity)
                    .offset(x: particle.x, y: particle.y)
                    .rotationEffect(.degrees(particle.rotation))
            }
        }
        .onChange(of: isActive) { _, newValue in
            if newValue {
                triggerBurst()
            }
        }
    }

    private func triggerBurst() {
        // Create particles
        particles = (0..<particleCount).map { _ in
            Particle(
                x: 0,
                y: 0,
                scale: CGFloat.random(in: 0.5...1.5),
                opacity: 1.0,
                rotation: Double.random(in: 0...360)
            )
        }

        // Animate particles outward
        withAnimation(.easeOut(duration: 0.5)) {
            particles = particles.map { particle in
                var p = particle
                let angle = Double.random(in: 0...(2 * .pi))
                let distance = CGFloat.random(in: 20...50)
                p.x = cos(angle) * distance
                p.y = sin(angle) * distance
                p.scale = 0
                p.opacity = 0
                return p
            }
        }

        // Clear particles
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            particles = []
            isActive = false
        }
    }
}

// MARK: - Confetti Burst Effect
struct ConfettiBurstView: View {
    let colors: [Color]
    @Binding var isActive: Bool

    @State private var confetti: [ConfettiPiece] = []

    struct ConfettiPiece: Identifiable {
        let id = UUID()
        let color: Color
        var x: CGFloat
        var y: CGFloat
        var rotation: Double
        var scale: CGFloat
        var opacity: Double
    }

    var body: some View {
        ZStack {
            ForEach(confetti) { piece in
                RoundedRectangle(cornerRadius: 1)
                    .fill(piece.color)
                    .frame(width: 8, height: 4)
                    .scaleEffect(piece.scale)
                    .opacity(piece.opacity)
                    .offset(x: piece.x, y: piece.y)
                    .rotationEffect(.degrees(piece.rotation))
            }
        }
        .onChange(of: isActive) { _, newValue in
            if newValue {
                triggerConfetti()
            }
        }
    }

    private func triggerConfetti() {
        // Create confetti pieces
        confetti = (0..<20).map { _ in
            ConfettiPiece(
                color: colors.randomElement() ?? .white,
                x: 0,
                y: 0,
                rotation: Double.random(in: 0...360),
                scale: CGFloat.random(in: 0.8...1.2),
                opacity: 1.0
            )
        }

        // Animate confetti
        withAnimation(.easeOut(duration: 0.8)) {
            confetti = confetti.map { piece in
                var p = piece
                let angle = Double.random(in: 0...(2 * .pi))
                let distance = CGFloat.random(in: 30...80)
                p.x = cos(angle) * distance
                p.y = sin(angle) * distance - 20 // Slight upward bias
                p.rotation = Double.random(in: 0...720)
                p.opacity = 0
                return p
            }
        }

        // Clear confetti
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            confetti = []
            isActive = false
        }
    }
}

// MARK: - Number Flip Animation
struct FlipNumberView: View {
    let number: Int
    let color: Color
    let font: Font

    @State private var displayedNumber: Int
    @State private var isFlipping = false

    init(number: Int, color: Color, font: Font = .system(size: 16, weight: .bold)) {
        self.number = number
        self.color = color
        self.font = font
        self._displayedNumber = State(initialValue: number)
    }

    var body: some View {
        Text("\(displayedNumber)")
            .font(font)
            .foregroundColor(color)
            .scaleEffect(y: isFlipping ? 0.1 : 1.0)
            .opacity(isFlipping ? 0.5 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isFlipping)
            .onChange(of: number) { oldValue, newValue in
                if oldValue != newValue {
                    flipTo(newValue)
                }
            }
    }

    private func flipTo(_ newNumber: Int) {
        isFlipping = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            displayedNumber = newNumber
            isFlipping = false
        }
    }
}

// MARK: - Slide In Animation
struct SlideInModifier: ViewModifier {
    let delay: Double
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .offset(y: isVisible ? 0 : 30)
            .opacity(isVisible ? 1 : 0)
            .onAppear {
                withAnimation(AnimationConfig.cardAppear.delay(delay)) {
                    isVisible = true
                }
            }
    }
}

extension View {
    func slideIn(delay: Double = 0) -> some View {
        modifier(SlideInModifier(delay: delay))
    }
}

// MARK: - Color Cycling Animation
struct ColorCyclingView: View {
    let colors: [Color]
    @State private var currentIndex = 0

    var body: some View {
        colors[currentIndex]
            .onAppear {
                startCycling()
            }
    }

    private func startCycling() {
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                currentIndex = (currentIndex + 1) % colors.count
            }
        }
    }
}

// MARK: - Shimmer Effect
struct ShimmerEffect: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    LinearGradient(
                        colors: [
                            .clear,
                            .white.opacity(0.2),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 2)
                    .offset(x: -geometry.size.width + (phase * geometry.size.width * 2))
                }
                .mask(content)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerEffect())
    }
}

// MARK: - Live Pulse Indicator
//
// Two styles:
//   • .standard — original behavior. Inner solid 8pt dot + outer ring
//     that scales 1→2 and fades 0.5→0 over 1.0s ease-in-out, repeat-
//     forever (no autoreverse). Used for prominent LIVE indicators.
//   • .soft — ambient opacity-only pulse for secondary surfaces (e.g.,
//     repeated game-card chat-count dots). Single inner dot whose
//     opacity oscillates 0.45 ↔ 1.0 over 1.4s ease-in-out auto-
//     reversing. No scale, no outer ring. Reads as breathing rather
//     than pinging.
struct LivePulseIndicator: View {
    enum Style { case standard, soft }

    var color: Color = FanChatTheme.liveIndicator
    var animated: Bool = true
    var style: Style = .standard
    @State private var isPulsing = false
    @State private var softOpacity: Double = 1.0

    var body: some View {
        ZStack {
            switch style {
            case .standard:
                // Outer pulse (only when animated)
                if animated {
                    Circle()
                        .fill(color)
                        .frame(width: 12, height: 12)
                        .scaleEffect(isPulsing ? 2 : 1)
                        .opacity(isPulsing ? 0 : 0.5)
                }

                // Inner solid
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)

            case .soft:
                // Inner dot only — opacity-only ambient pulse.
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .opacity(animated ? softOpacity : 1.0)
            }
        }
        .onAppear {
            guard animated else { return }
            switch style {
            case .standard:
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false)) {
                    isPulsing = true
                }
            case .soft:
                // 1.4s breathe, autoreverses, lower opacity floor.
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    softOpacity = 0.45
                }
            }
        }
    }
}

// MARK: - Spinning Loader with Color Cycling
struct CasinoSpinner: View {
    @State private var rotation: Double = 0
    @State private var colorIndex = 0

    let colors: [Color] = [
        FanChatTheme.neonGreen,
        FanChatTheme.neonBlue,
        FanChatTheme.neonPurple,
        FanChatTheme.neonPink,
        FanChatTheme.neonOrange
    ]

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(
                colors[colorIndex],
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
            .frame(width: 30, height: 30)
            .rotationEffect(.degrees(rotation))
            .glow(colors[colorIndex], radius: 6)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    rotation = 360
                }

                Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        colorIndex = (colorIndex + 1) % colors.count
                    }
                }
            }
    }
}
