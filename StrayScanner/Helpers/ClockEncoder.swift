//
//  ClockEncoder.swift
//  StrayScanner
//
//  Copyright © 2026 Stray Robots. All rights reserved.
//

import Foundation

// Writes clock.csv: pairs of (uptime, unix time) read back-to-back, once when
// recording starts, once per second while recording and once when it stops.
// Every other timestamp in the dataset (ARFrame.timestamp, CMLogItem.timestamp)
// is seconds of systemUptime, so unix = timestamp + (unix - uptime) of these rows.
// Sampling throughout the recording, not only at the start, shows any wall clock
// (NTP) correction made while recording.
class ClockEncoder {
    let path: URL
    let fileHandle: FileHandle
    private let queue = DispatchQueue(label: "clockQueue", qos: .userInitiated)
    private var timer: DispatchSourceTimer?

    init(url: URL) {
        self.path = url
        do {
            try "".write(to: self.path, atomically: true, encoding: .utf8)
            self.fileHandle = try FileHandle(forWritingTo: self.path)
            self.fileHandle.write("uptime, unix, window\n".data(using: .utf8)!)
        } catch let error {
            print("Can't create file \(self.path.absoluteString). \(error.localizedDescription)")
            preconditionFailure("Can't open clock file for writing.")
        }
        queue.sync { self.sample() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
        self.timer = timer
    }

    // The tightest of a few back-to-back reads; window is the uptime elapsed
    // around the wall clock read, an upper bound on the pairing error.
    private func sample() {
        var best = (uptime: 0.0, unix: 0.0, window: Double.infinity)
        for _ in 0..<5 {
            let before = ProcessInfo.processInfo.systemUptime
            let unix = Date().timeIntervalSince1970
            let after = ProcessInfo.processInfo.systemUptime
            if after - before < best.window {
                best = (uptime: (before + after) / 2, unix: unix, window: after - before)
            }
        }
        let line = "\(best.uptime), \(best.unix), \(best.window)\n"
        self.fileHandle.write(line.data(using: .utf8)!)
    }

    func done() {
        queue.sync {
            self.timer?.cancel()
            self.timer = nil
            self.sample()
            do {
                try self.fileHandle.close()
            } catch let error {
                print("Can't close clock file \(self.path.absoluteString). \(error.localizedDescription)")
            }
        }
    }
}
