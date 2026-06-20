import CoreMotion
import simd

/// Reads device orientation from the IMU via CMMotionManager and exposes it as a quaternion
/// in the ALVR coordinate system (right-hand, Y-up, looking into -Z).
final class HeadTracker {
    private let motionManager = CMMotionManager()
    // Dedicated queue so 200 Hz IMU callbacks never run on (and starve) the main thread.
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.phonevr.motion"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()

    // Protected by the lock below; read from any thread.
    private let lock = NSLock()
    private var _quaternion: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var _fov = FOV(left: -45, right: 45, up: 45, down: -45)

    struct FOV {
        var left, right, up, down: Float
    }

    var currentQuaternion: simd_quatf {
        lock.lock(); defer { lock.unlock() }
        return _quaternion
    }

    func start() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 200.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical,
                                               to: motionQueue) { [weak self] motion, _ in
            guard let self, let m = motion else { return }
            self.update(motion: m)
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }

    private func update(motion: CMDeviceMotion) {
        let att = motion.attitude
        // CMAttitude quaternion is in a right-hand coordinate system where:
        //   +X = right, +Y = up, +Z = out of screen (landscape-left).
        // Map to ALVR/OpenVR:
        //   +X = right, +Y = up, -Z = forward (into screen).
        // The device held landscape-left:
        //   CMQuaternion (w,x,y,z) where the device faces the user = looking along +Z.
        // Rotate 180° around Y to flip Z: multiply by quaternion (0, 0, 1, 0) [x,y,z,w].
        let q = att.quaternion
        let deviceQ = simd_quatf(ix: Float(q.x), iy: Float(q.y), iz: Float(q.z), r: Float(q.w))
        let flip = simd_quatf(ix: 0, iy: 1, iz: 0, r: 0) // 180° around Y
        let vrQ = flip * deviceQ

        lock.lock()
        _quaternion = vrQ
        lock.unlock()
    }
}
