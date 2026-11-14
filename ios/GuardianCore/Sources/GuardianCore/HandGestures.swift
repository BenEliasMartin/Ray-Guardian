import Foundation
#if canImport(Vision)
import Vision
#endif

public enum HandGesture: Equatable, Sendable { case fist, shaka }

/// Require a sustained pose; a stalled camera or a completed hold cannot fire again.
public struct HandGestureHold {
    private var first: Double?, last: Double?
    private var fired = false
    private var matchesInHold = 0
    private var missedSample = false
    public var isHolding: Bool { first != nil && !fired }
    public init() {}

    public mutating func consume(matches: Bool, at time: Double, allowingOneMiss: Bool = false) -> Bool {
        let maximumGap = allowingOneMiss ? 0.82 : 0.65
        if let last, time - last > maximumGap || time <= last { self = Self() }
        guard matches else {
            if allowingOneMiss && first != nil && !missedSample {
                missedSample = true
            } else {
                self = Self()
            }
            return false
        }
        missedSample = false
        last = time
        if first == nil { first = time }
        guard !fired else { return false }
        matchesInHold += 1
        guard matchesInHold >= 3, let first, time - first >= 0.85 else { return false }
        fired = true
        return true
    }
}

#if canImport(Vision)
public enum CameraHandPose {
    typealias Joint = VNHumanHandPoseObservation.JointName

    public enum Result: Equatable, Sendable { case noHand, handVisible, matches, unavailable }

    public static func recognize(_ gesture: HandGesture, in image: CGImage,
                                 orientation: CGImagePropertyOrientation) -> Result {
        let fullFrame = scan(gesture, in: image, orientation: orientation)
        guard gesture == .shaka, fullFrame.result == .handVisible,
              orientation == .up, let wrist = fullFrame.wrist,
              wrist.y < 0.45 else { return fullFrame.result }

        // In the glasses' wide view, a nearby hand can overlap other hands or objects.
        // Recheck the lower field on the side where Vision found the foreground wrist.
        let left = image.width / 5
        let top = image.height * 9 / 20
        let region = CGRect(x: wrist.x >= 0.5 ? left : 0, y: top,
                            width: image.width * 4 / 5, height: image.height * 11 / 20)
        guard let closeup = image.cropping(to: region) else { return fullFrame.result }
        return scan(gesture, in: closeup, orientation: .up).result == .matches ? .matches : fullFrame.result
    }

    private static func scan(_ gesture: HandGesture, in image: CGImage,
                             orientation: CGImagePropertyOrientation) -> (result: Result, wrist: CGPoint?) {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        do { try handler.perform([request]) }
        catch { return (.unavailable, nil) }
        guard let hands = request.results, !hands.isEmpty else { return (.noHand, nil) }
        if gesture == .fist && hands.count != 1 { return (.handVisible, nil) }

        let aspect = Double(image.width) / Double(image.height)
        let rotated = [.left, .leftMirrored, .right, .rightMirrored].contains(orientation)
        let poses = hands.compactMap { try? $0.recognizedPoints(.all) }
        let matchingHands = poses.filter { points in
            return matches(gesture) { joint, cutoff in
                guard let value = points[joint], value.confidence >= cutoff else { return nil }
                return CGPoint(x: value.location.x * (rotated ? 1 : aspect),
                               y: value.location.y * (rotated ? aspect : 1))
            }
        }
        let wrist = poses.compactMap { $0[.wrist] }
            .filter { $0.confidence >= 0.40 }
            .max { $0.confidence < $1.confidence }
        return (matchingHands.count == 1 ? .matches : .handVisible, wrist?.location)
    }

    static func matches(_ gesture: HandGesture, points: (Joint, Float) -> CGPoint?) -> Bool {
        func point(_ joint: Joint, cutoff: Float = 0.45) -> CGPoint? { points(joint, cutoff) }
        func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
        let knuckleConfidence: Float = gesture == .fist ? 0.30 : 0.45
        guard let wrist = point(.wrist), let palm = point(.middleMCP, cutoff: knuckleConfidence) else { return false }
        var scale = distance(wrist, palm)
        if let index = point(.indexMCP, cutoff: knuckleConfidence), let pinky = point(.littleMCP, cutoff: knuckleConfidence) {
            // The wrist-to-knuckle distance shrinks when the hand tilts toward the lens.
            scale = max(scale, distance(index, pinky))
        }
        guard scale >= 0.040 else { return false }

        enum Finger { case extended, curled, unclear, hidden }
        func finger(_ mcp: Joint, _ pip: Joint, _ dip: Joint, _ tip: Joint) -> Finger {
            // Folded fingertips can be partly hidden. Require the base joint to be clear.
            guard let base = point(mcp, cutoff: knuckleConfidence), let end = point(tip, cutoff: 0.30) else { return .hidden }
            let reach = distance(base, end) / scale, radius = distance(wrist, end) / scale
            if reach <= 0.58 && radius <= 1.47 { return .curled }
            if let bend = point(pip, cutoff: 0.35), radius <= 1.55,
               distance(wrist, end) + 0.10 * scale < distance(wrist, bend) {
                return .curled
            }
            if gesture == .shaka && reach >= 0.65 && radius >= 1.40 { return .extended }
            guard reach >= 0.48, radius >= 1.35 else { return .unclear }
            guard let middle = point(pip), let distal = point(dip) else { return .unclear }
            let length = distance(base, middle) + distance(middle, distal) + distance(distal, end)
            return distance(base, end) >= 0.87 * length ? .extended : .unclear
        }
        let index = finger(.indexMCP, .indexPIP, .indexDIP, .indexTip)
        let middle = finger(.middleMCP, .middlePIP, .middleDIP, .middleTip)
        let ring = finger(.ringMCP, .ringPIP, .ringDIP, .ringTip)
        switch gesture {
        case .fist:
            let little = finger(.littleMCP, .littlePIP, .littleDIP, .littleTip)
            let fingers = [index, middle, ring, little]
            let curled = fingers.filter { $0 == .curled }.count
            guard fingers.allSatisfy({ $0 == .curled || $0 == .hidden }), curled >= 3 else { return false }
            guard let thumb = point(.thumbTip, cutoff: 0.30) else { return curled == 4 }
            return distance(thumb, palm) <= 0.85 * scale
        case .shaka:
            let folded = [index, middle, ring]
            guard folded.filter({ $0 == .curled }).count >= 2, !folded.contains(.extended),
                  let thumbTip = point(.thumbTip, cutoff: 0.40), let thumbMP = point(.thumbMP, cutoff: 0.35),
                  let pinkyBase = point(.littleMCP), let pinkyTip = point(.littleTip, cutoff: 0.40),
                  let indexBase = point(.indexMCP) else { return false }

            // The outer fingers must spread to opposite sides of the palm. A slightly bent or
            // foreshortened pinky can still match if it reaches away from its knuckle.
            let palmWidth = distance(indexBase, pinkyBase)
            guard palmWidth >= 0.25 * scale else { return false }
            let axis = CGPoint(x: (pinkyBase.x - indexBase.x) / palmWidth, y: (pinkyBase.y - indexBase.y) / palmWidth)
            func side(_ point: CGPoint) -> Double {
                (point.x - palm.x) * axis.x + (point.y - palm.y) * axis.y
            }
            let thumbReach = distance(thumbMP, thumbTip)
            let pinkyReach = distance(pinkyBase, pinkyTip)
            let pinkySpreadsSideways = side(pinkyTip) - side(pinkyBase) >= 0.18 * scale
            guard thumbReach >= 0.37 * scale, distance(thumbTip, palm) >= 0.70 * scale,
                  side(thumbTip) <= -0.38 * scale, side(pinkyTip) >= 0.35 * scale,
                  distance(thumbTip, pinkyTip) >= 1.10 * scale,
                  pinkyReach >= 0.40 * scale || (pinkySpreadsSideways && pinkyReach >= 0.27 * scale),
                  distance(palm, pinkyTip) >= 0.64 * scale else { return false }
            if let pinkyMiddle = point(.littlePIP, cutoff: 0.35) {
                let length = distance(pinkyBase, pinkyMiddle) + distance(pinkyMiddle, pinkyTip)
                guard pinkyReach >= 0.70 * length else { return false }
            }
            return true
        }
    }
}
#endif
