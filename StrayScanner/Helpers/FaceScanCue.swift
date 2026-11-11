//
//  FaceScanCue.swift
//  StrayScanner
//
//  Copyright © 2026 Stray Robots. All rights reserved.
//

import Foundation
import simd

// Decides when to cue the wearer during a face scan. The wearer looks at the
// phone, waits for the first cue, lifts the phone into the head mount and gets a
// second cue once it has settled there. The same first cue fires again when the
// phone is taken off and held in front of the face at the end.
//
// This only drives the prompts. The pipeline finds the same moments again from
// face.csv and poses.csv, with its own thresholds.
struct FaceScanCue {
    enum Phase {
        case lookingForFace
        case awaitingSeat
    }
    enum Cue {
        case faceSteady // head has been still in front of the phone: lift now
        case seated     // phone has come to rest away from the face
    }

    // The head counts as steady, and the phone as settled, while its pose stays
    // within these limits of where it was when the window started.
    static let faceSteadySeconds: TimeInterval = 1.0
    static let faceSteadyMaxShift: Float = 0.02 // m
    static let faceSteadyMaxAngle: Float = 3.0 // degrees
    static let settleSeconds: TimeInterval = 0.5
    static let settleMaxShift: Float = 0.02 // m
    static let settleMaxAngle: Float = 4.0 // degrees
    // The phone has to travel this far from where it was at the first cue before
    // coming to rest counts as seated.
    static let seatMinTravel: Float = 0.10 // m

    static let thresholds: [String: Any] = [
        "face_steady_seconds": faceSteadySeconds,
        "face_steady_max_shift_m": Double(faceSteadyMaxShift),
        "face_steady_max_angle_deg": Double(faceSteadyMaxAngle),
        "settle_seconds": settleSeconds,
        "settle_max_shift_m": Double(settleMaxShift),
        "settle_max_angle_deg": Double(settleMaxAngle),
        "seat_min_travel_m": Double(seatMinTravel),
    ]

    private(set) var phase: Phase = .lookingForFace
    private(set) var seatedCount: Int = 0
    private var window: Window?
    private var cameraAtCue: simd_float3 = simd_float3()
    private var faceLostSinceCue: Bool = false

    // A stretch of time over which a pose has stayed near its starting value.
    private struct Window {
        let start: TimeInterval
        let position: simd_float3
        let orientation: simd_quatf

        func holds(_ transform: simd_float4x4, maxShift: Float, maxAngle: Float) -> Bool {
            let t = transform[3]
            let shift = simd_distance(simd_float3(t.x, t.y, t.z), position)
            let delta = orientation.inverse * simd_quatf(transform)
            let angle = 2 * acos(min(1, abs(delta.real))) * 180 / Float.pi
            return shift <= maxShift && angle <= maxAngle
        }
    }

    private static func startWindow(_ transform: simd_float4x4, at time: TimeInterval) -> Window {
        let t = transform[3]
        return Window(start: time, position: simd_float3(t.x, t.y, t.z), orientation: simd_quatf(transform))
    }

    mutating func reset() {
        self = FaceScanCue()
    }

    // camera: camera-to-world. face: face-to-world, nil unless the face is tracked
    // in this frame. Returns a cue on the frame it becomes due.
    mutating func update(time: TimeInterval, camera: simd_float4x4, face: simd_float4x4?) -> Cue? {
        switch phase {
            case .lookingForFace:
                guard let face = face else {
                    window = nil
                    return nil
                }
                guard let current = window, current.holds(face, maxShift: FaceScanCue.faceSteadyMaxShift, maxAngle: FaceScanCue.faceSteadyMaxAngle) else {
                    window = FaceScanCue.startWindow(face, at: time)
                    return nil
                }
                if time - current.start < FaceScanCue.faceSteadySeconds {
                    return nil
                }
                let t = camera[3]
                cameraAtCue = simd_float3(t.x, t.y, t.z)
                faceLostSinceCue = false
                window = nil
                phase = .awaitingSeat
                return .faceSteady
            case .awaitingSeat:
                if face != nil {
                    // Back in front of the face after leaving it: the lift was
                    // abandoned, so scan again.
                    if faceLostSinceCue {
                        phase = .lookingForFace
                    }
                    window = nil
                    return nil
                }
                faceLostSinceCue = true
                let t = camera[3]
                if simd_distance(simd_float3(t.x, t.y, t.z), cameraAtCue) < FaceScanCue.seatMinTravel {
                    window = nil
                    return nil
                }
                guard let current = window, current.holds(camera, maxShift: FaceScanCue.settleMaxShift, maxAngle: FaceScanCue.settleMaxAngle) else {
                    window = FaceScanCue.startWindow(camera, at: time)
                    return nil
                }
                if time - current.start < FaceScanCue.settleSeconds {
                    return nil
                }
                window = nil
                seatedCount += 1
                phase = .lookingForFace
                return .seated
        }
    }
}
