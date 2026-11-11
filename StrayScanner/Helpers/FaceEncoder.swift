//
//  FaceEncoder.swift
//  StrayScanner
//
//  Copyright © 2026 Stray Robots. All rights reserved.
//

import Foundation
import ARKit

// Writes face.csv: the wearer's face pose as seen by the front camera, one row
// per ARFrame, on the same clock as poses.csv. The pipeline uses the face pose
// just before the phone is lifted into the head mount, and the camera pose just
// after, to work out where the eyes are relative to the mounted phone.
//
// The face pose is ARKit's face anchor, unmodified: face-to-world, in ARKit's
// world frame; face axes are x toward the face's own left, y up, z out of the
// face. Note that poses.csv flips the camera axes and this file does not.
// Eye poses are eye-to-face. Columns after is_tracked are empty on frames with
// no face anchor. No image, mesh or expression data is written.
class FaceEncoder {
    let path: URL
    let fileHandle: FileHandle
    private static let emptyFields = String(repeating: ", ", count: 21)

    init(url: URL) {
        self.path = url
        do {
            try "".write(to: self.path, atomically: true, encoding: .utf8)
            self.fileHandle = try FileHandle(forWritingTo: self.path)
            let header = "timestamp, is_tracked, x, y, z, qx, qy, qz, qw, "
                + "left_eye_x, left_eye_y, left_eye_z, left_eye_qx, left_eye_qy, left_eye_qz, left_eye_qw, "
                + "right_eye_x, right_eye_y, right_eye_z, right_eye_qx, right_eye_qy, right_eye_qz, right_eye_qw\n"
            self.fileHandle.write(header.data(using: .utf8)!)
        } catch let error {
            print("Can't create file \(self.path.absoluteString). \(error.localizedDescription)")
            preconditionFailure("Can't open face file for writing.")
        }
    }

    static func faceAnchor(in frame: ARFrame) -> ARFaceAnchor? {
        for anchor in frame.anchors {
            if let face = anchor as? ARFaceAnchor {
                return face
            }
        }
        return nil
    }

    func add(frame: ARFrame, face: ARFaceAnchor?) {
        let line: String
        if let face = face {
            let fields = [face.transform, face.leftEyeTransform, face.rightEyeTransform].map(FaceEncoder.describe)
            line = "\(frame.timestamp), \(face.isTracked ? 1 : 0), \(fields.joined(separator: ", "))\n"
        } else {
            line = "\(frame.timestamp), 0\(FaceEncoder.emptyFields)\n"
        }
        self.fileHandle.write(line.data(using: .utf8)!)
    }

    func done() {
        do {
            try self.fileHandle.close()
        } catch let error {
            print("Can't close face file \(self.path.absoluteString). \(error.localizedDescription)")
        }
    }

    // Position, then quaternion (x, y, z, w).
    private static func describe(_ transform: simd_float4x4) -> String {
        let t = transform[3]
        let q = simd_quatf(transform).vector
        return "\(t.x), \(t.y), \(t.z), \(q.x), \(q.y), \(q.z), \(q.w)"
    }
}
