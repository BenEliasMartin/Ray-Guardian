import SwiftUI
import UIKit
import GuardianCore

/// Selected concepts C1 (Night patrol) and M2 (Heartbeat ribbon), drawn natively.
/// One six-second entrance per incident/category; no assets, WebView or idle loop.
struct IncidentAnimationView: View {
    let presentation: IncidentAnimation.Presentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var animating = true

    private var taskID: String { "\(presentation.incidentID):\(presentation.kind.rawValue):\(reduceMotion)" }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(presentation.kind == .patrol ? "SAFETY CHECK-IN" : "FALL / MEDICAL CHECK-IN")
                    .font(.system(.caption2,design:.monospaced).weight(.medium)).tracking(1.1)
                    .fixedSize(horizontal:false,vertical:true)
                Spacer(minLength:0)
            }.foregroundStyle(presentation.kind == .patrol ? IncidentArtwork.cyan : IncidentArtwork.lime)
                .padding(.horizontal,16).padding(.top,15)
            Group {
                if animating,!reduceMotion,scenePhase == .active {
                    TimelineView(.animation(minimumInterval:1.0/30)) { tick in
                        IncidentArtwork(kind:presentation.kind,elapsed:presentation.elapsed(at:tick.date.timeIntervalSince1970))
                    }
                } else {
                    IncidentArtwork(kind:presentation.kind,elapsed:IncidentAnimation.duration)
                }
            }.aspectRatio(2,contentMode:.fit)
            if presentation.kind == .pulse {
                Text("Illustrative pulse · not a heart-rate reading")
                    .font(.caption2).foregroundStyle(IncidentArtwork.lime.opacity(0.7))
                    .fixedSize(horizontal:false,vertical:true)
                    .padding(.horizontal,16)
                    .padding(.bottom,12)
            }
        }
        .background(presentation.kind == .patrol ? Color(red:0.06,green:0.11,blue:0.13) : Color(red:0.08,green:0.13,blue:0.10),in:RoundedRectangle(cornerRadius:22))
        .clipShape(RoundedRectangle(cornerRadius:22))
        .accessibilityElement(children:.ignore)
        .accessibilityLabel(presentation.kind == .patrol ? "Safety check-in. Patrol car illustration." : "Fall or medical check-in. Illustrated pulse, not a measured heart rate.")
        .accessibilityIdentifier("guardian.animation.\(presentation.kind.rawValue)")
        .allowsHitTesting(false)
        .task(id:taskID) {
            let remaining = IncidentAnimation.duration-presentation.elapsed(at:Date().timeIntervalSince1970)
            animating = !reduceMotion && remaining > 0
            guard animating else { return }
            do { try await Task.sleep(for:.seconds(remaining)) } catch { return }
            animating = false
        }
    }
}

/// A fixed composition; only its entrance time changes. Used by the app and previews.
struct IncidentArtwork: View {
    let kind: IncidentAnimation.Kind
    let elapsed: TimeInterval
    static let cyan = Color(red:0.62,green:0.86,blue:0.87)
    static let lime = Color(red:0.82,green:0.94,blue:0.53)
    private static let cream = Color(red:0.86,green:0.91,blue:0.87)
    private static let teal = Color(red:0.14,green:0.26,blue:0.29)
    private static let amber = Color(red:1,green:0.76,blue:0.47)
    private var time: Double { min(6,max(0,elapsed.isFinite ? elapsed : 6)) }

    var body: some View {
        Canvas { context,size in
            var drawing = context
            drawing.scaleBy(x:size.width/600,y:size.height/300)
            if kind == .patrol { patrol(in:drawing) } else { pulse(in:drawing) }
        }.accessibilityHidden(true)
    }
    private func path(_ points: [(Double,Double)],closed: Bool = false) -> Path {
        Path { p in
            guard let first = points.first else { return }
            p.move(to:CGPoint(x:first.0,y:first.1))
            for point in points.dropFirst() { p.addLine(to:CGPoint(x:point.0,y:point.1)) }
            if closed { p.closeSubpath() }
        }
    }
    private func polygon(_ points: [(Double,Double)],_ color: Color,in context: GraphicsContext) {
        context.fill(path(points,closed:true),with:.color(color))
    }
    private func line(_ points: [(Double,Double)],_ color: Color,width: CGFloat = 1,in context: GraphicsContext) {
        context.stroke(path(points),with:.color(color),style:StrokeStyle(lineWidth:width,lineCap:.round,lineJoin:.round))
    }
    private func circle(x: Double,y: Double,radius: Double,color: Color,in context: GraphicsContext) {
        context.fill(Path(ellipseIn:CGRect(x:x-radius,y:y-radius,width:radius*2,height:radius*2)),with:.color(color))
    }
    private func rect(_ x: Double,_ y: Double,_ w: Double,_ h: Double,_ color: Color,in context: GraphicsContext) {
        context.fill(Path(CGRect(x:x,y:y,width:w,height:h)),with:.color(color))
    }
    private func patrol(in context: GraphicsContext) {
        let cyan = Self.cyan,cream = Self.cream,teal = Self.teal,amber = Self.amber
        // The restrained city and road are static, so the vehicle remains the focus.
        line([(54,191),(54,99),(109,99),(109,191)],cyan.opacity(0.14),in:context)
        line([(481,191),(481,73),(535,73),(535,191)],cyan.opacity(0.14),in:context)
        line([(117,191),(117,128),(170,128)],cyan.opacity(0.14),in:context)
        for y in [112.0,128] { line([(64,y),(95,y)],cyan.opacity(0.16),in:context) }
        for y in [91.0,108] { line([(493,y),(522,y)],cyan.opacity(0.16),in:context) }
        line([(60,255),(540,255)],cyan.opacity(0.3),width:2,in:context)
        for (a,b) in [(120.0,195.0),(310,389),(450,505)] { line([(a,268),(b,268)],cyan.opacity(0.3),width:2,in:context) }
        context.fill(Path(ellipseIn:CGRect(x:123,y:228,width:360,height:28)),with:.color(cyan.opacity(0.08)))
        let progress = min(1,time/2.4),ease = 1-pow(1-progress,3)
        var car = context
        car.translateBy(x:-340*(1-ease),y:0)
        car.opacity = min(1,progress*4)
        let glow = time >= 6 ? 0.75 : 0.35+0.65*(0.5-0.5*cos(time/1.8*2*Double.pi))
        // Slow local light changes, rather than flashing the whole screen.
        var beams = car
        beams.translateBy(x:263,y:109)
        beams.rotate(by:.degrees(time >= 6 ? 0 : sin(time/3*2*Double.pi)*12))
        beams.translateBy(x:-263,y:-109)
        polygon([(260,109),(155,6),(338,6)],cyan.opacity(0.09*glow),in:beams)
        polygon([(265,109),(383,4),(243,4)],amber.opacity(0.09*glow),in:beams)
        polygon([(437,190),(578,140),(578,247),(437,212)],cyan.opacity(0.09),in:car)
        polygon([(125,163),(179,146),(211,111),(328,111),(376,148),(429,160),(444,185),(431,211),(123,211),(110,190)],cream,in:car)
        polygon([(210,120),(264,120),(264,149),(183,149)],teal,in:car)
        polygon([(274,120),(322,120),(357,149),(274,149)],teal,in:car)
        rect(116,174,320,29,teal,in:car)
        rect(224,157,104,54,cream,in:car)
        polygon([(272,162),(288,170),(285,191),(272,202),(259,191),(256,170)],Color(red:0.39,green:0.53,blue:0.54),in:car)
        car.draw(Text("GUARDIAN").font(.system(size:9,weight:.medium,design:.monospaced)).tracking(2).foregroundStyle(cyan),at:CGPoint(x:137,y:187),anchor:.leading)
        rect(232,103,58,10,teal,in:car)
        rect(232,103,28,7,cyan.opacity(glow),in:car)
        rect(263,103,27,7,amber.opacity(glow),in:car)
        rect(427,166,17,15,Color(red:0.97,green:0.88,blue:0.67),in:car)
        rect(111,169,14,12,amber,in:car)
        for x in [176.0,381] {
            var wheel = car
            wheel.translateBy(x:x,y:215)
            wheel.rotate(by:.degrees(-350*(1-ease)))
            circle(x:0,y:0,radius:27,color:Color(red:0.06,green:0.1,blue:0.1),in:wheel)
            circle(x:0,y:0,radius:16,color:Color(red:0.36,green:0.46,blue:0.42),in:wheel)
            line([(0,-14),(0,14)],cream.opacity(0.5),width:3,in:wheel)
            line([(-14,0),(14,0)],cream.opacity(0.5),width:3,in:wheel)
            circle(x:0,y:0,radius:6,color:cream,in:wheel)
        }
        line([(138,229),(148,229)],cream.opacity(0.65),width:3,in:car)
        line([(407,226),(430,226)],cream.opacity(0.65),width:3,in:car)
    }
    private func pulse(in context: GraphicsContext) {
        let lime = Self.lime
        for y in stride(from:70.0,through:230,by:40) { line([(60,y),(540,y)],lime.opacity(0.08),in:context) }
        for x in stride(from:100.0,through:500,by:80) { line([(x,50),(x,250)],lime.opacity(0.08),in:context) }
        let ribbon = path([(55,163),(180,163),(207,133),(230,181),(266,68),(303,229),(336,133),(359,163),(545,163)])
        let progress = min(1,time/2.8)
        let drawn = ribbon.trimmedPath(from:0,to:progress)
        context.stroke(drawn,with:.color(lime.opacity(0.04)),style:StrokeStyle(lineWidth:20,lineCap:.round,lineJoin:.round))
        context.stroke(drawn,with:.color(lime),style:StrokeStyle(lineWidth:4,lineCap:.round,lineJoin:.round))
        if let tip = drawn.currentPoint,progress > 0 {
            let radius = time >= 6 ? 6.0 : 6+sin(time*Double.pi)*1.5
            circle(x:Double(tip.x),y:Double(tip.y),radius:radius,color:Self.cream,in:context)
        }
    }
}

@MainActor enum IncidentDisplayArtwork {
    static func image(kind: IncidentAnimation.Kind, elapsed: TimeInterval) -> UIImage? {
        let renderer = ImageRenderer(content: IncidentArtwork(kind: kind, elapsed: elapsed)
            .frame(width: 256, height: 128)
            .background(Color(red: 0.06, green: 0.11, blue: 0.13)))
        return renderer.uiImage
    }
}

@MainActor enum GlassesRecordingOverlay {
    static func frame(_ image: UIImage, dispatch: DemoDispatch?, animation: IncidentAnimation.Presentation?,
                      checkingIn: Bool, time: Double) -> IncidentFrame? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, 640 / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let rect = CGRect(origin: .zero, size: target)
        let title = dispatch?.title ?? (checkingIn ? "Are you okay?" : "Monitoring is on")
        let detail = dispatch.map { $0.coordinates?.displayText ?? $0.destination } ?? "Ray Guardian"
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let composed = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: rect)
            let width = target.width * 0.56
            let textScale = width / 180
            let titleFont = UIFont.systemFont(ofSize: 14 * textScale, weight: .semibold)
            let detailFont = UIFont.monospacedSystemFont(ofSize: 10 * textScale, weight: .regular)
            let artHeight = animation == nil ? 0 : width * 0.44
            let panel = CGRect(x: target.width - width - 12, y: target.height * 0.12,
                               width: width, height: 50 * textScale + artHeight)
            UIColor(red: 0.03, green: 0.07, blue: 0.09, alpha: 0.88).setFill()
            UIBezierPath(roundedRect: panel, cornerRadius: 8).fill()
            let titleRect = panel.insetBy(dx: 8 * textScale, dy: 7 * textScale)
            (title as NSString).draw(in: titleRect, withAttributes: [.font: titleFont, .foregroundColor: UIColor.white])
            let detailRect = titleRect.offsetBy(dx: 0, dy: 23 * textScale)
            (detail as NSString).draw(in: detailRect, withAttributes: [.font: detailFont, .foregroundColor: UIColor.white])
            if let animation, let art = IncidentDisplayArtwork.image(
                kind: animation.kind, elapsed: animation.elapsed(at: Date().timeIntervalSince1970)
            ) {
                art.draw(in: CGRect(x: panel.minX + width * 0.06, y: panel.maxY - artHeight - 3,
                                    width: width * 0.88, height: artHeight))
            }
        }
        guard let jpeg = composed.jpegData(compressionQuality: 0.72) else { return nil }
        return IncidentFrame(time: time, jpeg: jpeg, sharpness: 0)
    }
}

#if DEBUG && canImport(UIKit)
#Preview("Selected alert animations") {
    VStack(spacing:20) {
        IncidentAnimationView(presentation:.init(incidentID:"patrol-preview",kind:.patrol,startedAt:Date().timeIntervalSince1970))
        IncidentAnimationView(presentation:.init(incidentID:"pulse-preview",kind:.pulse,startedAt:Date().timeIntervalSince1970))
    }.padding(24)
}
#endif
