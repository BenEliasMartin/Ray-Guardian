import CoreLocation
@MainActor final class IncidentLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation,Error>?, timeout: Task<Void,Never>?
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters }
    func requestPermission() { manager.requestWhenInUseAuthorization() }
    func current() async throws -> CLLocation {
        guard continuation == nil else { throw DeviceError.message("A location request is already active.") }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeout = Task { [weak self] in try? await Task.sleep(for:.seconds(10)); guard !Task.isCancelled else { return }; self?.finish(.failure(DeviceError.message("Location timed out."))) }
            if manager.authorizationStatus == .notDetermined { finish(.failure(DeviceError.message("Grant location in Setup before arming."))) }
            else { requestIfAllowed() }
        }
    }
    private func requestIfAllowed() {
        switch manager.authorizationStatus { case .authorizedAlways,.authorizedWhenInUse: manager.requestLocation(); case .denied,.restricted: finish(.failure(DeviceError.message("Location permission denied."))); default: break }
    }
    private func finish(_ result: Result<CLLocation,Error>) { timeout?.cancel(); timeout = nil; let pending = continuation; continuation = nil; manager.stopUpdatingLocation(); pending?.resume(with:result) }
    func cancel() { finish(.failure(CancellationError())) }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { Task { @MainActor in guard self.continuation != nil else { return }; self.requestIfAllowed() } }
    nonisolated func locationManager(_ manager: CLLocationManager,didUpdateLocations locations: [CLLocation]) { Task { @MainActor in
        guard let value = locations.last,value.horizontalAccuracy >= 0,abs(value.timestamp.timeIntervalSinceNow) <= 30 else { self.finish(.failure(DeviceError.message("No fresh incident location."))); return }; self.finish(.success(value))
    } }
    nonisolated func locationManager(_ manager: CLLocationManager,didFailWithError error: Error) { Task { @MainActor in self.finish(.failure(error)) } }
}
