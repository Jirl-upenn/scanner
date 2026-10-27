//
//  DatasetEncoder.swift
//  StrayScanner
//
//  Created by Kenneth Blomqvist on 1/2/21.
//  Copyright © 2021 Stray Robots. All rights reserved.
//

import Foundation
import UIKit
import ARKit
import CryptoKit
import CoreMotion

class DatasetEncoder {
    enum Status {
        case allGood
        case videoEncodingError
        case directoryCreationError
    }
    private let rgbEncoder: VideoEncoder
    private let depthEncoder: DepthEncoder
    private let confidenceEncoder: ConfidenceEncoder
    private let datasetDirectory: URL
    private let odometryEncoder: OdometryEncoder
    private let imuEncoder: IMUEncoder
    private let distortionEncoder: DistortionEncoder
    private let poseEncoder: PoseEncoder
    private let clockEncoder: ClockEncoder
    private let eventEncoder: EventEncoder
    private var lastFrame: ARFrame?
    private var dispatchGroup = DispatchGroup()
    private var currentFrame: Int = -1
    private var savedFrames: Int = 0
    private var droppedFrames: Int = 0
    private var finished: Bool = false
    private var lastTrackingState: String = ""
    private let videoWidth: CGFloat
    private let videoHeight: CGFloat
    private let startedUptime: TimeInterval
    private let startedUnix: TimeInterval
    private let wearerHeightCm: Double? // as set when recording started
    private let frameInterval: Int // Only save every frameInterval-th frame.
    private let encodingSemaphore = DispatchSemaphore(value: 3) // Limit queued frames to avoid ARFrame retention
    public let id: UUID
    public let rgbFilePath: URL // Relative to app document directory.
    public let depthFilePath: URL // Relative to app document directory.
    public let cameraMatrixPath: URL
    public let odometryPath: URL
    public let imuPath: URL
    public var status = Status.allGood
    private let queue: DispatchQueue
    
    private var latestAccelerometerData: (timestamp: Double, data: simd_double3)?
    private var latestGyroscopeData: (timestamp: Double, data: simd_double3)?


    init(arConfiguration: ARWorldTrackingConfiguration, fpsDivider: Int = 1) {
        self.frameInterval = fpsDivider
        self.wearerHeightCm = storedWearerHeightCm()
        self.queue = DispatchQueue(label: "encoderQueue")
        
        let width = arConfiguration.videoFormat.imageResolution.width
        let height = arConfiguration.videoFormat.imageResolution.height
        self.videoWidth = width
        self.videoHeight = height
        self.startedUptime = ProcessInfo.processInfo.systemUptime
        self.startedUnix = Date().timeIntervalSince1970
        var theId: UUID = UUID()
        datasetDirectory = DatasetEncoder.createDirectory(id: &theId)
        self.id = theId
        self.rgbFilePath = datasetDirectory.appendingPathComponent("rgb.mp4")
        self.rgbEncoder = VideoEncoder(file: self.rgbFilePath, width: width, height: height)
        self.depthFilePath = datasetDirectory.appendingPathComponent("depth", isDirectory: true)
        self.depthEncoder = DepthEncoder(outDirectory: self.depthFilePath)
        let confidenceFilePath = datasetDirectory.appendingPathComponent("confidence", isDirectory: true)
        self.confidenceEncoder = ConfidenceEncoder(outDirectory: confidenceFilePath)
        self.cameraMatrixPath = datasetDirectory.appendingPathComponent("camera_matrix.csv", isDirectory: false)
        self.odometryPath = datasetDirectory.appendingPathComponent("odometry.csv", isDirectory: false)
        self.odometryEncoder = OdometryEncoder(url: self.odometryPath)
        self.imuPath = datasetDirectory.appendingPathComponent("imu.csv", isDirectory: false)
        self.imuEncoder = IMUEncoder(url: self.imuPath)
        self.distortionEncoder = DistortionEncoder(datasetDirectory: datasetDirectory)
        self.poseEncoder = PoseEncoder(url: datasetDirectory.appendingPathComponent("poses.csv", isDirectory: false))
        self.clockEncoder = ClockEncoder(url: datasetDirectory.appendingPathComponent("clock.csv", isDirectory: false))
        self.eventEncoder = EventEncoder(url: datasetDirectory.appendingPathComponent("events.csv", isDirectory: false))
    }

    func add(frame: ARFrame) {
        // Every frame's pose is kept, whether or not its images are saved below.
        poseEncoder.add(frame: frame)
        let (state, reason) = PoseEncoder.describe(frame.camera.trackingState)
        let trackingState = reason.isEmpty ? state : "\(state)/\(reason)"
        if trackingState != lastTrackingState {
            eventEncoder.add(event: "tracking_state", detail: trackingState, timestamp: frame.timestamp)
            lastTrackingState = trackingState
        }
        let totalFrames: Int = currentFrame
        currentFrame = currentFrame + 1
        if (currentFrame % frameInterval != 0) {
            return
        }
        // Drop frame if encoding is backed up to avoid accumulating ARFrame references.
        guard encodingSemaphore.wait(timeout: .now()) == .success else {
            droppedFrames = droppedFrames + 1
            eventEncoder.add(event: "frame_dropped", detail: "encoder backed up", timestamp: frame.timestamp)
            return
        }
        let frameNumber: Int = savedFrames
        savedFrames = savedFrames + 1
        dispatchGroup.enter()
        queue.async {
            defer {
                self.encodingSemaphore.signal()
                self.dispatchGroup.leave()
            }
            if let sceneDepth = frame.sceneDepth {
                self.depthEncoder.encodeFrame(frame: sceneDepth.depthMap, frameNumber: frameNumber)
                if let confidence = sceneDepth.confidenceMap {
                    self.confidenceEncoder.encodeFrame(frame: confidence, frameNumber: frameNumber)
                } else {
                    print("warning: confidence map missing.")
                }
            } else {
                print("warning: scene depth missing.")
            }
            self.rgbEncoder.add(frame: VideoEncoderInput(buffer: frame.capturedImage, time: frame.timestamp), currentFrame: totalFrames)
            self.odometryEncoder.add(frame: frame, currentFrame: frameNumber)
            self.distortionEncoder.add(frame: frame, currentFrame: frameNumber)
            self.lastFrame = frame
        }
    }
    
   func addRawAccelerometer(data: CMAccelerometerData) {
        let acceleration = simd_double3(data.acceleration.x, data.acceleration.y, data.acceleration.z)
        latestAccelerometerData = (timestamp: data.timestamp, data: acceleration)
        tryWritingIMUData()
    }

    func addRawGyroscope(data: CMGyroData) {
        let rotationRate = simd_double3(data.rotationRate.x, data.rotationRate.y, data.rotationRate.z)
        latestGyroscopeData = (timestamp: data.timestamp, data: rotationRate)
        tryWritingIMUData()
    }

    private func tryWritingIMUData() {
        guard
            let accelerometer = latestAccelerometerData,
            let gyroscope = latestGyroscopeData
        else {
            return
        }

        // Write the row to the CSV with the most recent timestamp
        let timestamp = max(accelerometer.timestamp, gyroscope.timestamp)
        imuEncoder.add(
            timestamp: timestamp,
            linear: accelerometer.data,
            angular: gyroscope.data
        )

        // Clear the buffers after writing
        latestAccelerometerData = nil
        latestGyroscopeData = nil
    }

    func addEvent(_ event: String, detail: String = "") {
        // The AR session keeps running after recording stops; its files are closed by then.
        guard !finished else { return }
        eventEncoder.add(event: event, detail: detail)
    }

    // planes: the session's plane anchors when recording stops, written to planes.json.
    func wrapUp(planes: [ARPlaneAnchor] = []) {
        finished = true
        dispatchGroup.wait()
        self.rgbEncoder.finishEncoding()
        self.imuEncoder.done()
        self.odometryEncoder.done()
        self.distortionEncoder.done()
        self.poseEncoder.done()
        self.clockEncoder.done()
        self.eventEncoder.add(event: "thermal_state", detail: EventEncoder.describe(ProcessInfo.processInfo.thermalState))
        self.eventEncoder.done()
        writeIntrinsics()
        writePlanes(planes)
        writeMetadata()
        switch self.rgbEncoder.status {
            case .allGood:
                status = .allGood
            case .error:
                status = .videoEncodingError
        }
        // Only errors from here on: an earlier video error must not be reset.
        switch self.depthEncoder.status {
            case .allGood:
                break
            case .frameEncodingError:
                status = .videoEncodingError
                print("Something went wrong encoding depth.")
        }
        switch self.confidenceEncoder.status {
            case .allGood:
                break
            case .encodingError:
                status = .videoEncodingError
                print("Something went wrong encoding confidence values.")
        }
    }

    private func writeIntrinsics() {
        if let cameraMatrix = lastFrame?.camera.intrinsics {
            let rows = cameraMatrix.transpose.columns
            var csv: [String] = []
            for row in [rows.0, rows.1, rows.2] {
                let csvLine = "\(row.x), \(row.y), \(row.z)"
                csv.append(csvLine)
            }
            let contents = csv.joined(separator: "\n")
            do {
                try contents.write(to: self.cameraMatrixPath, atomically: true, encoding: String.Encoding.utf8)
            } catch let error {
                print("Could not write camera matrix. \(error.localizedDescription)")
            }
        }
    }

    private func writePlanes(_ planes: [ARPlaneAnchor]) {
        let entries: [[String: Any]] = planes.map { (plane: ARPlaneAnchor) -> [String: Any] in
            let m = plane.transform
            let extent: [Float]
            if #available(iOS 16.0, *) {
                extent = [plane.planeExtent.width, plane.planeExtent.height]
            } else {
                extent = [plane.extent.x, plane.extent.z]
            }
            let columns = [m.columns.0, m.columns.1, m.columns.2, m.columns.3]
            return [
                "identifier": plane.identifier.uuidString,
                "alignment": plane.alignment == .horizontal ? "horizontal" : "vertical",
                "classification": DatasetEncoder.describe(plane.classification),
                // Column-major 4x4 plane-to-world, in ARKit's world frame (y up).
                "transform": columns.flatMap { [$0.x, $0.y, $0.z, $0.w] },
                "center": [plane.center.x, plane.center.y, plane.center.z],
                // Along the plane's x and z axes, in meters.
                "extent": extent,
            ]
        }
        writeJSON(["planes": entries], to: "planes.json")
    }

    private func writeMetadata() {
        let info = Bundle.main.infoDictionary ?? [:]
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let metadata: [String: Any] = [
            "app_version": info["CFBundleShortVersionString"] as? String ?? "",
            "app_build": info["CFBundleVersion"] as? String ?? "",
            "device_model": machine,
            "system_version": UIDevice.current.systemVersion,
            "video_width": Int(videoWidth),
            "video_height": Int(videoHeight),
            "fps_divider": frameInterval,
            "ar_frames": currentFrame + 1,
            "saved_frames": savedFrames,
            "dropped_frames": droppedFrames,
            "started_uptime": startedUptime,
            "started_unix": startedUnix,
            "timestamps": "seconds of systemUptime; clock.csv pairs uptime with unix time",
            "pose_convention": "camera-to-world; camera x right, y down, z forward; world is ARKit's (y up, gravity aligned, origin where the AR session started)",
            "imu_units": "acceleration in g, rotation rate in rad/s, device axes",
            "wearer_height_m": wearerHeightCm.map { $0 / 100 } ?? NSNull(),
        ]
        writeJSON(metadata, to: "metadata.json")
    }

    private func writeJSON(_ object: [String: Any], to name: String) {
        let url = datasetDirectory.appendingPathComponent(name, isDirectory: false)
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
        } catch let error {
            print("Could not write \(name). \(error.localizedDescription)")
        }
    }

    static private func describe(_ classification: ARPlaneAnchor.Classification) -> String {
        switch classification {
            case .floor:
                return "floor"
            case .ceiling:
                return "ceiling"
            case .wall:
                return "wall"
            case .table:
                return "table"
            case .seat:
                return "seat"
            case .door:
                return "door"
            case .window:
                return "window"
            case .none(_):
                return "none"
            @unknown default:
                return "unknown"
        }
    }

    static private func createDirectory(id: inout UUID) -> URL {
        let directoryId = hashUUID(id: id)
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        var directory = URL(fileURLWithPath: directoryId, relativeTo: url)
        if FileManager.default.fileExists(atPath: directory.absoluteString) {
            // Just in case the first 5 characters clash, try again.
            id = UUID()
            directory = DatasetEncoder.createDirectory(id: &id)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        } catch let error as NSError {
            print("Error creating directory. \(error), \(error.userInfo)")
        }
        return directory
    }

    static private func hashUUID(id: UUID) -> String {
        var hasher: SHA256 = SHA256()
        hasher.update(data: id.uuidString.data(using: .ascii)!)
        let digest = hasher.finalize()
        var string = ""
        digest.makeIterator().prefix(5).forEach { (byte: UInt8) in
            string += String(format: "%02x", byte)
        }
        print("Hash: \(string)")
        return string
    }
}
