import Combine
import CoreMotion
import GuardianCore

/// Uses iPhone sensors for Phone mode and optionally stands in for glasses sensors during Mock testing.
/// Like the glasses, it reports acceleration including gravity plus gyroscope rotation rate, so the same fall
/// detector paths (free fall, rapid tilt, slump) and motion summary apply.
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
        let token = generation
        if manager.isDeviceMotionAvailable {
            manager.deviceMotionUpdateInterval = 1.0/60
            manager.startDeviceMotionUpdates(to: queue) { [weak self] motion,error in
                // Gravity plus user acceleration is the same total acceleration a raw accelerometer (and DAT) reports.
                let point = motion.map {
                    MotionPoint.phoneAcceleration(time: $0.timestamp,
                                                  x: $0.gravity.x+$0.userAcceleration.x,
                                                  y: $0.gravity.y+$0.userAcceleration.y,
                                                  z: $0.gravity.z+$0.userAcceleration.z,
                                                  rotationX: $0.rotationRate.x,rotationY: $0.rotationRate.y,rotationZ: $0.rotationRate.z)
                }
                self?.deliver(point,error: error,token: token)
            }
            status = "iPhone accelerometer + gyroscope · 60 Hz"
        } else if manager.isAccelerometerAvailable {
            manager.accelerometerUpdateInterval = 1.0/60
            manager.startAccelerometerUpdates(to: queue) { [weak self] data,error in
                let point = data.map { MotionPoint.phoneAcceleration(time: $0.timestamp,x: $0.acceleration.x,y: $0.acceleration.y,z: $0.acceleration.z) }
                self?.deliver(point,error: error,token: token)
            }
            status = "iPhone accelerometer only (no gyroscope) · 60 Hz"
        } else {
            throw DeviceError.message("iPhone motion sensors are unavailable.")
        }
    }
    nonisolated private func deliver(_ point: MotionPoint?,error: Error?,token: UUID) {
        let failure = error?.localizedDescription
        Task { @MainActor [weak self] in
            guard let self,self.generation == token else { return }
            if let failure { self.stop(); self.status = "Unavailable: \(failure)"; self.onFailure?(self.status); return }
            if let point { self.onMotion?(point) }
        }
    }
    func stop() { generation = UUID(); manager.stopDeviceMotionUpdates(); manager.stopAccelerometerUpdates(); status = "Off" }
}
