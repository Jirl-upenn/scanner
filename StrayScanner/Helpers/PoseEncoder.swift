//
//  PoseEncoder.swift
//  StrayScanner
//
//  Copyright © 2026 Stray Robots. All rights reserved.
//

import Foundation
import ARKit

// Writes poses.csv: the camera pose of every ARFrame, with ARKit's tracking state.
// Unlike odometry.csv (one row per saved RGB-D frame) it is written as frames
// arrive, so frames dropped by the fps setting or by a backed up encoder still
// have a pose. Same pose convention as odometry.csv.
class PoseEncoder {
    let path: URL
    let q_AC = simd_quatf(ix: 1.0, iy: 0.0, iz: 0.0, r: 0.0)
    let fileHandle: FileHandle

    init(url: URL) {
        self.path = url
        do {
            try "".write(to: self.path, atomically: true, encoding: .utf8)
            self.fileHandle = try FileHandle(forWritingTo: self.path)
            self.fileHandle.write("timestamp, x, y, z, qx, qy, qz, qw, tracking_state, tracking_reason, world_mapping_status\n".data(using: .utf8)!)
        } catch let error {
            print("Can't create file \(self.path.absoluteString). \(error.localizedDescription)")
            preconditionFailure("Can't open pose file for writing.")
        }
    }

    func add(frame: ARFrame) {
        let transform = frame.camera.transform
        let t = transform[3]
        let q: vector_float4 = (simd_quatf(transform) * q_AC).vector
        let (state, reason) = PoseEncoder.describe(frame.camera.trackingState)
        let mapping = PoseEncoder.describe(frame.worldMappingStatus)
        let line = "\(frame.timestamp), \(t.x), \(t.y), \(t.z), \(q.x), \(q.y), \(q.z), \(q.w), \(state), \(reason), \(mapping)\n"
        self.fileHandle.write(line.data(using: .utf8)!)
    }

    func done() {
        do {
            try self.fileHandle.close()
        } catch let error {
            print("Can't close pose file \(self.path.absoluteString). \(error.localizedDescription)")
        }
    }

    static func describe(_ trackingState: ARCamera.TrackingState) -> (String, String) {
        switch trackingState {
            case .normal:
                return ("normal", "")
            case .notAvailable:
                return ("not_available", "")
            case .limited(let reason):
                switch reason {
                    case .initializing:
                        return ("limited", "initializing")
                    case .relocalizing:
                        return ("limited", "relocalizing")
                    case .excessiveMotion:
                        return ("limited", "excessive_motion")
                    case .insufficientFeatures:
                        return ("limited", "insufficient_features")
                    @unknown default:
                        return ("limited", "unknown")
                }
        }
    }

    static func describe(_ status: ARFrame.WorldMappingStatus) -> String {
        switch status {
            case .notAvailable:
                return "not_available"
            case .limited:
                return "limited"
            case .extending:
                return "extending"
            case .mapped:
                return "mapped"
            @unknown default:
                return "unknown"
        }
    }
}
