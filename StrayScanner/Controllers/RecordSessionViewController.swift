//
//  RecordSessionViewController.swift
//  Stray Scanner
//
//  Created by Kenneth Blomqvist on 11/28/20.
//  Copyright © 2020 Stray Robots. All rights reserved.
//

import Foundation
import UIKit
import Metal
import ARKit
import CoreData
import CoreMotion
import AudioToolbox

let FpsDividers: [Int] = [1, 2, 4, 12, 60]
let AvailableFpsSettings: [Int] = FpsDividers.map { Int(60 / $0) }
let FpsUserDefaultsKey: String = "FPS"

class MetalView : UIView {
    override class var layerClass: AnyClass {
        get {
            return CAMetalLayer.self
        }
    }
    override var layer: CAMetalLayer {
        return super.layer as! CAMetalLayer
    }
}

class RecordSessionViewController : UIViewController, ARSessionDelegate {
    private var unsupported: Bool = false
    private var arConfiguration: ARWorldTrackingConfiguration?
    private let session = ARSession()
    private let motionManager = CMMotionManager()
    private var renderer: CameraRenderer?
    private var updateLabelTimer: Timer?
    private var startedRecording: Date?
    private var dataContext: NSManagedObjectContext!
    private var datasetEncoder: DatasetEncoder?
    private let imuOperationQueue = OperationQueue()
    private var chosenFpsSetting: Int = 0
    private var hasSceneDepth: Bool = false
    private var faceTrackingEnabled: Bool = false
    private var faceCue = FaceScanCue()
    private let faceLabel = UILabel()
    private let faceLabelBackground = UIView()
    private let cueHaptics = UINotificationFeedbackGenerator()
    @IBOutlet private var rgbView: MetalView!
    @IBOutlet private var depthView: MetalView!
    @IBOutlet private var recordButton: RecordButton!
    @IBOutlet private var timeLabel: UILabel!
    @IBOutlet weak var fpsButton: UIButton!
    var dismissFunction: Optional<() -> Void> = Optional.none
    
    func setDismissFunction(_ fn: Optional<() -> Void>) {
        self.dismissFunction = fn
    }
    override func viewWillAppear(_ animated: Bool) {
        self.chosenFpsSetting = UserDefaults.standard.integer(forKey: FpsUserDefaultsKey)
        updateFpsSetting()
    }

    override func viewDidLoad() {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        self.dataContext = appDelegate.persistentContainer.newBackgroundContext()
        self.renderer = CameraRenderer(rgbLayer: rgbView.layer, depthLayer: depthView.layer)

        depthView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(viewTapped)))
        rgbView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(viewTapped)))
        
        setViewProperties()
        addFaceLabel()
        session.delegate = self

        recordButton.setCallback { (recording: Bool) in
            self.toggleRecording(recording)
        }
        fpsButton.layer.masksToBounds = true
        fpsButton.layer.cornerRadius = 12.0
        
        imuOperationQueue.qualityOfService = .userInitiated
        // Accelerometer and gyroscope handlers share DatasetEncoder's IMU state and
        // file; run them one at a time.
        imuOperationQueue.maxConcurrentOperationCount = 1
    }

    override func viewDidDisappear(_ animated: Bool) {
        session.pause();
    }

    override func viewWillDisappear(_ animated: Bool) {
        updateLabelTimer?.invalidate()
        datasetEncoder = nil
    }

    override func viewDidAppear(_ animated: Bool) {
        startSession()
    }

    private func startSession() {
        let config = ARWorldTrackingConfiguration()
        arConfiguration = config
        if !ARWorldTrackingConfiguration.isSupported {
            print("AR is not supported.")
            unsupported = true
            return
        }
        // Depth needs LiDAR. Without it the recording has no depth/ or confidence/ frames.
        hasSceneDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        if hasSceneDepth {
            config.frameSemantics.insert(.sceneDepth)
        } else {
            showRgbPreview()
        }
        // Plane anchors (with floor classification) are saved to planes.json.
        config.planeDetection = .horizontal
        // The front camera tracks the wearer's face while the rear camera tracks the
        // room, in the same world frame (face.csv).
        faceTrackingEnabled = ARWorldTrackingConfiguration.supportsUserFaceTracking
        config.userFaceTrackingEnabled = faceTrackingEnabled
        faceLabelBackground.isHidden = !faceTrackingEnabled
        session.run(config)
    }

    private func showRgbPreview() {
        renderer?.renderMode = RenderMode.rgb
        rgbView.isHidden = false
        depthView.isHidden = true
    }
    
    private func startRawIMU() {
        if self.motionManager.isAccelerometerAvailable {
            self.motionManager.accelerometerUpdateInterval = 1.0 / 1200.0 // Set update rate
            self.motionManager.startAccelerometerUpdates(to: imuOperationQueue) { (data, error) in
                guard let data = data else {
                    if let error = error {
                        print("Error retrieving accelerometer data: \(error.localizedDescription)")
                    }
                    return
                }
                self.datasetEncoder?.addRawAccelerometer(data: data)
            }
        } else {
            print("Accelerometer not available on this device.")
        }

        if self.motionManager.isGyroAvailable {
            self.motionManager.gyroUpdateInterval = 1.0 / 1200.0 // Set update rate
            self.motionManager.startGyroUpdates(to: imuOperationQueue) { (data, error) in
                guard let data = data else {
                    if let error = error {
                        print("Error retrieving gyroscope data: \(error.localizedDescription)")
                    }
                    return
                }
                self.datasetEncoder?.addRawGyroscope(data: data)
            }
        } else {
            print("Gyroscope not available on this device.")
        }
    }

    private func stopRawIMU() {
        if self.motionManager.isAccelerometerActive {
            self.motionManager.stopAccelerometerUpdates()
            print("Stopped accelerometer updates.")
        }
        if self.motionManager.isGyroActive {
            self.motionManager.stopGyroUpdates()
            print("Stopped gyroscope updates.")
        }
    }
    
    private func toggleRecording(_ recording: Bool) {
        if unsupported {
            showUnsupportedAlert()
            return
        }
        if recording && self.startedRecording == nil {
            startRecording()
        } else if self.startedRecording != nil && !recording {
            stopRecording()
        } else {
            print("This should not happen. We are either not recording and want to stop, or we are recording and want to start.")
        }
    }

    private func startRecording() {
        self.startedRecording = Date()
        updateTime()
        updateLabelTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            self.updateTime()
        }
        datasetEncoder = DatasetEncoder(arConfiguration: arConfiguration!, fpsDivider: FpsDividers[chosenFpsSetting])
        faceCue.reset()
        cueHaptics.prepare()
        startRawIMU()
    }

    private func stopRecording() {
        guard let started = self.startedRecording else {
            print("Hasn't started recording. Something is wrong.")
            return
        }
        startedRecording = nil
        updateLabelTimer?.invalidate()
        updateLabelTimer = nil
        // Stop IMU updates
        stopRawIMU()
        // Handlers already queued would otherwise write to the closed imu.csv.
        imuOperationQueue.waitUntilAllOperationsAreFinished()
        let planes = session.currentFrame?.anchors.compactMap { $0 as? ARPlaneAnchor } ?? []
        datasetEncoder?.wrapUp(planes: planes)
        if let encoder = datasetEncoder {
            switch encoder.status {
                case .allGood:
                    saveRecording(started, encoder)
                case .videoEncodingError:
                    showError()
                case .directoryCreationError:
                    showError()
            }
        } else {
            print("No dataset encoder. Something is wrong.")
        }
        self.dismissFunction?()
    }

    private func saveRecording(_ started: Date, _ encoder: DatasetEncoder) {
        let sessionCount = countSessions()
        
        let duration = Date().timeIntervalSince(started)
        let entity = NSEntityDescription.entity(forEntityName: "Recording", in: self.dataContext)!
        let recording: Recording = Recording(entity: entity, insertInto: self.dataContext)
        recording.setValue(datasetEncoder!.id, forKey: "id")
        recording.setValue(duration, forKey: "duration")
        recording.setValue(started, forKey: "createdAt")
        recording.setValue("Recording \(sessionCount)", forKey: "name")
        recording.setValue(datasetEncoder!.rgbFilePath.relativeString, forKey: "rgbFilePath")
        recording.setValue(datasetEncoder!.depthFilePath.relativeString, forKey: "depthFilePath")
        do {
            try self.dataContext.save()
        } catch let error as NSError {
            print("Could not save recording. \(error), \(error.userInfo)")
        }
    }

    private func showError() {
        let controller = UIAlertController(title: "Error",
            message: "Something went wrong when encoding video. This should not have happened. You might want to file a bug report.",
            preferredStyle: .alert)
        controller.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Default Action"), style: .default, handler: { _ in
            self.dismiss(animated: true, completion: nil)
        }))
        self.present(controller, animated: true, completion: nil)
    }

    private func updateTime() {
        guard let started = self.startedRecording else { return }
        let seconds = Date().timeIntervalSince(started)
        let minutes: Int = Int(floor(seconds / 60).truncatingRemainder(dividingBy: 60))
        let hours: Int = Int(floor(seconds / 3600))
        let roundSeconds: Int = Int(floor(seconds.truncatingRemainder(dividingBy: 60)))
        self.timeLabel.text = String(format: "%02d:%02d:%02d", hours, minutes, roundSeconds)
    }

    @objc func viewTapped() {
        if !hasSceneDepth { return } // nothing to show in the depth view
        switch renderer!.renderMode {
            case .depth:
                renderer!.renderMode = RenderMode.rgb
                rgbView.isHidden = false
                depthView.isHidden = true
            case .rgb:
                renderer!.renderMode = RenderMode.depth
                depthView.isHidden = false
                rgbView.isHidden = true
        }
    }
    
    @IBAction func fpsButtonTapped() {
        chosenFpsSetting = (chosenFpsSetting + 1) % AvailableFpsSettings.count
        updateFpsSetting()
        UserDefaults.standard.set(chosenFpsSetting, forKey: FpsUserDefaultsKey)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        self.renderer!.render(frame: frame)
        let face = faceTrackingEnabled ? FaceEncoder.faceAnchor(in: frame) : nil
        let faceTracked = face?.isTracked ?? false
        var cue: FaceScanCue.Cue? = nil
        if startedRecording != nil {
            if let encoder = datasetEncoder {
                encoder.add(frame: frame, face: face)
                if faceTrackingEnabled {
                    cue = faceCue.update(time: frame.timestamp, camera: frame.camera.transform, face: faceTracked ? face?.transform : nil)
                    if let cue = cue {
                        give(cue: cue, encoder: encoder, timestamp: frame.timestamp)
                    }
                }
            } else {
                print("There is no video encoder. That can't be good.")
            }
        }
        if faceTrackingEnabled {
            updateFaceLabel(faceTracked: faceTracked)
        }
    }

    // A sound and a haptic: the wearer cannot see the screen once the phone is on
    // their head. The sound follows the ring/silent switch; the haptic does not.
    private func give(cue: FaceScanCue.Cue, encoder: DatasetEncoder, timestamp: TimeInterval) {
        switch cue {
            case .faceSteady:
                encoder.addEvent("face_steady_cue", timestamp: timestamp)
                AudioServicesPlaySystemSound(1113)
            case .seated:
                encoder.addEvent("seated_cue", timestamp: timestamp)
                AudioServicesPlaySystemSound(1114)
        }
        cueHaptics.notificationOccurred(.success)
        cueHaptics.prepare()
    }

    private func updateFaceLabel(faceTracked: Bool) {
        let text: String
        if startedRecording == nil {
            text = faceTracked ? "Face found" : "Looking for your face…"
        } else if faceCue.phase == .awaitingSeat {
            text = faceCue.seatedCount == 0
                ? "Keep your head still and lift the phone into the mount"
                : "Face scanned. Tap stop."
        } else if faceTracked {
            text = "Hold still…"
        } else {
            text = faceCue.seatedCount == 0 ? "Looking for your face…" : "Phone seated"
        }
        if faceLabel.text != text {
            faceLabel.text = text
        }
    }

    // Over the bottom of the camera preview.
    private func addFaceLabel() {
        faceLabelBackground.translatesAutoresizingMaskIntoConstraints = false
        faceLabelBackground.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        faceLabelBackground.layer.cornerRadius = 12.0
        faceLabelBackground.isUserInteractionEnabled = false
        faceLabelBackground.isHidden = true
        faceLabel.translatesAutoresizingMaskIntoConstraints = false
        faceLabel.textColor = UIColor.white
        faceLabel.font = UIFont.preferredFont(forTextStyle: .headline)
        faceLabel.textAlignment = .center
        faceLabel.numberOfLines = 0
        faceLabelBackground.addSubview(faceLabel)
        view.addSubview(faceLabelBackground)
        NSLayoutConstraint.activate([
            faceLabel.topAnchor.constraint(equalTo: faceLabelBackground.topAnchor, constant: 8),
            faceLabel.bottomAnchor.constraint(equalTo: faceLabelBackground.bottomAnchor, constant: -8),
            faceLabel.leadingAnchor.constraint(equalTo: faceLabelBackground.leadingAnchor, constant: 14),
            faceLabel.trailingAnchor.constraint(equalTo: faceLabelBackground.trailingAnchor, constant: -14),
            faceLabelBackground.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            faceLabelBackground.bottomAnchor.constraint(equalTo: depthView.bottomAnchor, constant: -12),
            faceLabelBackground.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
        ])
    }

    func sessionWasInterrupted(_ session: ARSession) {
        datasetEncoder?.addEvent("session_interrupted")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        datasetEncoder?.addEvent("session_interruption_ended")
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        datasetEncoder?.addEvent("session_failed", detail: error.localizedDescription)
        // If the device cannot run face tracking alongside the rest, carry on without it.
        if faceTrackingEnabled, startedRecording == nil, let config = arConfiguration {
            faceTrackingEnabled = false
            faceLabelBackground.isHidden = true
            config.userFaceTrackingEnabled = false
            session.run(config)
        }
    }

    private func setViewProperties() {
        self.view.backgroundColor = UIColor(named: "BackgroundColor")
    }
    
    private func updateFpsSetting() {
        let fps = AvailableFpsSettings[chosenFpsSetting]
        let buttonLabel: String = "\(fps) fps"
        fpsButton.setTitle(buttonLabel, for: UIControl.State.normal)
    }
    
    private func showUnsupportedAlert() {
        let alert = UIAlertController(title: "Unsupported device", message: "This device doesn't seem to have the required level of ARKit support.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in
            self.dismissFunction?()
        }))
        self.present(alert, animated: true)
    }
    
    private func countSessions() -> Int {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return 0 }
        let request = NSFetchRequest<NSManagedObject>(entityName: "Recording")
        do {
            let fetched: [NSManagedObject] = try appDelegate.persistentContainer.viewContext.fetch(request)
            return fetched.count
        } catch let error {
            print("Could not fetch sessions for counting. \(error.localizedDescription)")
        }
        return 0
    }
}
