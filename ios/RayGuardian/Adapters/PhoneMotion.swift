import Combine
import CoreMotion
import GuardianCore

/// Explicit Mock-mode test source, independent from replay/glasses sensor samples.
@MainActor final class PhoneMotion: ObservableObject {
    @Published private(set) var status = "Off"
    var onMotion: ((MotionPoint) -> Void)?
    var onFailure: ((String) -> Void)?
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "Guardian phone motion"; queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var generation = UUID()
    func start() throws {
        stop()
        guard manager.isAccelerometerAvailable else { throw DeviceError.message("Phone accelerometer unavailable. Use the Mock glasses motion replay instead.") }
        let token = generation
        manager.accelerometerUpdateInterval = 1.0/60
        manager.startAccelerometerUpdates(to: queue) { [weak self] data,error in
            let point = data.map { MotionPoint.phoneAcceleration(time:$0.timestamp,x:$0.acceleration.x,y:$0.acceleration.y,z:$0.acceleration.z) }
            let failure = error?.localizedDescription
            Task { @MainActor in
                guard let self,self.generation == token else { return }
                if let failure { self.stop(); self.status = "Unavailable: \(failure)"; self.onFailure?(self.status); return }
                if let point { self.onMotion?(point) }
            }
        }
        status = "iPhone accelerometer · Mock test source · 60 Hz"
    }
    func stop() { generation = UUID(); manager.stopAccelerometerUpdates(); status = "Off" }
}
