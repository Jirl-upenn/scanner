//
//  EventEncoder.swift
//  StrayScanner
//
//  Copyright © 2026 Stray Robots. All rights reserved.
//

import Foundation
import UIKit

// Writes events.csv: things that explain gaps or bad stretches in a recording,
// such as AR session interruptions, tracking state changes, thermal state
// changes, memory warnings and frames dropped because encoding fell behind.
// Timestamps are systemUptime seconds, like the rest of the dataset.
// Only used from the main thread.
class EventEncoder {
    let path: URL
    let fileHandle: FileHandle
    private var observers: [NSObjectProtocol] = []

    init(url: URL) {
        self.path = url
        do {
            try "".write(to: self.path, atomically: true, encoding: .utf8)
            self.fileHandle = try FileHandle(forWritingTo: self.path)
            self.fileHandle.write("timestamp, event, detail\n".data(using: .utf8)!)
        } catch let error {
            print("Can't create file \(self.path.absoluteString). \(error.localizedDescription)")
            preconditionFailure("Can't open event file for writing.")
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.add(event: "thermal_state", detail: EventEncoder.describe(ProcessInfo.processInfo.thermalState))
        })
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            self?.add(event: "memory_warning")
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.add(event: "app_will_resign_active")
        })
        add(event: "thermal_state", detail: EventEncoder.describe(ProcessInfo.processInfo.thermalState))
    }

    func add(event: String, detail: String = "", timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        // Details are free text; keep them to one CSV field.
        let field = detail.replacingOccurrences(of: ",", with: ";").replacingOccurrences(of: "\n", with: " ")
        let line = "\(timestamp), \(event), \(field)\n"
        self.fileHandle.write(line.data(using: .utf8)!)
    }

    func done() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        do {
            try self.fileHandle.close()
        } catch let error {
            print("Can't close event file \(self.path.absoluteString). \(error.localizedDescription)")
        }
    }

    static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
            case .nominal:
                return "nominal"
            case .fair:
                return "fair"
            case .serious:
                return "serious"
            case .critical:
                return "critical"
            @unknown default:
                return "unknown"
        }
    }
}
