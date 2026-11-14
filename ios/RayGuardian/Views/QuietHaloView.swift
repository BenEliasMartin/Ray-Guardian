import SwiftUI
import UIKit
import GuardianCore

/// A small peripheral status capsule. Audio and native incident controls carry instructions.
struct QuietHaloView: View {
    let state: QuietHalo.State?
    let incidentID: String?
    let countdown: QuietHalo.Countdown?
    let updatedAt: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmationVisible = false

    private var identity: String { "\(incidentID ?? "capture"):\(state?.title ?? "idle")" }
    private var visible: Bool { state != nil && (state?.kind != .confirmation || confirmationVisible) }

    var body: some View {
        Group {
            if visible, let state {
                if state.kind == .checkIn, let countdown {
                    TimelineView(.periodic(from:.now,by:1)) { context in
                        QuietHaloBadge(state:state,reading:countdown.reading(at:context.date.timeIntervalSince1970*1000))
                    }
                } else {
                    QuietHaloBadge(state:state,reading:nil)
                }
            }
        }
        .transition(reduceMotion ? .opacity : .opacity.combined(with:.scale(scale:0.96,anchor:.trailing)))
        .animation(reduceMotion ? nil : .easeOut(duration:0.22),value:identity)
        .animation(reduceMotion ? nil : .easeOut(duration:0.18),value:visible)
        .allowsHitTesting(false)
        .task(id:identity) {
            confirmationVisible = false
            guard state?.kind == .confirmation, let updatedAt else { return }
            // Don't replay a confirmation when an old incident/history view reappears.
            let age = Date().timeIntervalSince1970-updatedAt/1000
            guard age >= -1, age < 2 else { return }
            confirmationVisible = true
            do { try await Task.sleep(for:.seconds(min(2,max(0,2-age)))) }
            catch { return }
            confirmationVisible = false
        }
    }
}

private struct QuietHaloBadge: View {
    let state: QuietHalo.State
    let reading: QuietHalo.Countdown.Reading?
    @Environment(\.colorScheme) private var colorScheme

    private var expired: Bool { state.kind == .checkIn && (reading?.seconds ?? 0) == 0 }
    private var title: String { expired ? "Checking status" : state.title }
    private var detail: String { expired ? "Awaiting confirmation" : state.detail }
    private var ink: Color { colorScheme == .dark ? Color(red:0.94,green:0.97,blue:0.93) : Color(red:0.10,green:0.18,blue:0.14) }
    private var fill: Color { colorScheme == .dark ? Color(red:0.08,green:0.13,blue:0.10) : Color(red:1,green:0.98,blue:0.94) }

    var body: some View {
        ViewThatFits(in:.horizontal) {
            HStack(spacing:10) {
                ring
                VStack(alignment:.leading,spacing:2) {
                    Text(title).font(.system(size:13,weight:.semibold)).lineLimit(1)
                    Text(detail).font(.system(size:11)).foregroundStyle(ink.opacity(0.72)).lineLimit(1)
                }
            }
            .padding(.leading,10).padding(.trailing,17).padding(.vertical,9)
            .background(fill,in:Capsule())
            ring.padding(9).background(fill,in:Circle())
        }
        .foregroundStyle(ink)
        .shadow(color:.black.opacity(0.10),radius:10,y:3)
        .accessibilityElement(children:.ignore)
        .accessibilityLabel(title)
        .accessibilityValue(reading.map { $0.seconds > 0 ? "\($0.seconds) seconds remaining" : detail } ?? detail)
        .accessibilityIdentifier("guardian.quietHalo")
    }
    private var ring: some View {
        QuietHaloRing(reading:expired ? nil : reading,tone:expired ? .neutral : state.tone,symbol:expired ? "clock" : state.symbol)
            .frame(width:44,height:44)
    }
}

struct QuietHaloRing: View {
    let reading: QuietHalo.Countdown.Reading?
    let tone: QuietHalo.Tone
    let symbol: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var tint: Color {
        if let reading, reading.seconds > 0 && reading.seconds <= 3 { return Color(red:0.90,green:0.36,blue:0.25) }
        switch tone {
        case .amber: return Color(red:0.91,green:0.65,blue:0.29)
        case .mint: return colorScheme == .dark ? Color(red:0.48,green:0.85,blue:0.65) : Color(red:0.14,green:0.48,blue:0.30)
        case .neutral: return colorScheme == .dark ? Color(red:0.58,green:0.74,blue:0.66) : Color(red:0.37,green:0.53,blue:0.45)
        case .warning: return Color(red:0.90,green:0.36,blue:0.25)
        }
    }
    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.20),lineWidth:3)
            Circle().trim(from:0,to:reading?.fraction ?? 1)
                .stroke(tint,style:StrokeStyle(lineWidth:3,lineCap:.round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .linear(duration:0.8),value:reading?.fraction)
            if let reading, reading.seconds > 0 {
                Text("\(reading.seconds)").font(.system(size:19,weight:.semibold,design:.rounded)).monospacedDigit()
            } else {
                Image(systemName:symbol).font(.system(size:17,weight:.medium)).foregroundStyle(tint)
            }
        }.padding(2)
    }
}

@MainActor enum QuietHaloDisplayImage {
    /// Native DAT display accepts a small icon image; refresh only during an active check-in.
    static func ring(_ reading: QuietHalo.Countdown.Reading?) -> UIImage {
        let renderer = ImageRenderer(content:QuietHaloRing(reading:reading,tone:.amber,symbol:"clock")
            .frame(width:44,height:44).foregroundStyle(.white).environment(\.colorScheme,.dark))
        renderer.scale = 2
        return renderer.uiImage ?? UIImage(systemName:"clock") ?? UIImage()
    }
}

#Preview("Quiet halo · state gallery") {
    VStack(alignment:.trailing,spacing:18) {
        QuietHaloBadge(state:QuietHalo.state(incidentState:nil,capturing:true)!,reading:nil)
        QuietHaloBadge(state:QuietHalo.state(incidentState:"check_in")!,reading:QuietHalo.Countdown(startedAt:0,deadline:15000)!.reading(at:3000))
        QuietHaloBadge(state:QuietHalo.state(incidentState:"cancelled")!,reading:nil)
        QuietHaloBadge(state:QuietHalo.state(incidentState:"call_queued")!,reading:nil)
        QuietHaloBadge(state:QuietHalo.state(incidentState:"demo_call_active",transport:"playback")!,reading:nil)
        QuietHaloBadge(state:QuietHalo.state(incidentState:"call_unknown")!,reading:nil)
    }.padding(24).background(Color(red:0.28,green:0.36,blue:0.29))
}
