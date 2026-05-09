//
//  MiddleClickController.swift
//  simple-middle-click
//
//  Created by june on 2026/5/9.
//

import AppKit
import ApplicationServices
import Darwin

enum MiddleMouse {
    static func click() {
        guard let location = CGEvent(source: nil)?.location else {
            return
        }

        // Middle click is represented by paired otherMouseDown/otherMouseUp events with button 2.
        post(type: .otherMouseDown, location: location)
        post(type: .otherMouseUp, location: location)
    }

    private static func post(type: CGEventType, location: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: .center
        ) else {
            return
        }

        event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        event.post(tap: .cghidEventTap)
    }
}

final class ThreeFingerTapMonitor {
    private let onTap: () -> Void
    private let libraryHandle: UnsafeMutableRawPointer?
    private let createDeviceList: MTDeviceCreateListFunction
    private let registerCallback: MTRegisterContactFrameCallbackFunction
    private let startDevice: MTDeviceStartFunction
    private var devices: [MTDeviceRef] = []

    private var gestureStartTime: Double?
    private var gestureStartCentroid = CGPoint.zero
    private var gestureLastCentroid = CGPoint.zero
    private var gestureMaxFingerCount = 0
    private var gestureValid = false
    private var lastTapTime: Double = 0
    private let secondaryClickSuppressor = SecondaryClickSuppressor()
    private var calibrationSample: TouchCalibrationSample?

    init?(onTap: @escaping () -> Void) {
        // Public macOS APIs do not expose global three-finger taps, so this utility loads
        // MultitouchSupport dynamically. This is suitable for local distribution, not App Store.
        guard
            let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
            let createSymbol = dlsym(handle, "MTDeviceCreateList"),
            let registerSymbol = dlsym(handle, "MTRegisterContactFrameCallback"),
            let startSymbol = dlsym(handle, "MTDeviceStart")
        else {
            return nil
        }

        self.onTap = onTap
        self.libraryHandle = handle
        self.createDeviceList = unsafeBitCast(createSymbol, to: MTDeviceCreateListFunction.self)
        self.registerCallback = unsafeBitCast(registerSymbol, to: MTRegisterContactFrameCallbackFunction.self)
        self.startDevice = unsafeBitCast(startSymbol, to: MTDeviceStartFunction.self)
    }

    deinit {
        if let libraryHandle {
            dlclose(libraryHandle)
        }
    }

    func start() {
        // The C callback refers back to this singleton monitor because the private API does not
        // provide a Swift-friendly context pointer.
        activeMonitor = self

        let unmanagedDeviceList = createDeviceList()
        let deviceList = unmanagedDeviceList.takeRetainedValue()

        devices = (0..<CFArrayGetCount(deviceList)).compactMap { index in
            guard let device = CFArrayGetValueAtIndex(deviceList, index) else {
                return nil
            }

            return UnsafeMutableRawPointer(mutating: device)
        }

        for device in devices {
            registerCallback(device, contactCallback)
            _ = startDevice(device, 0)
        }
        secondaryClickSuppressor.start()
    }

    fileprivate func handleFrame(fingerData: UnsafeMutableRawPointer?, count: Int32, timestamp: Double) {
        let fingerCount = Int(count)

        if fingerCount < 0 {
            resetGesture()
            return
        }

        guard let fingerData else {
            finishGesture(timestamp: timestamp)
            return
        }

        if fingerCount > 3 {
            resetGesture()
            return
        }

        if fingerCount < 3 {
            if gestureStartTime != nil {
                // Treat the transition from 3 fingers to fewer fingers as tap release.
                secondaryClickSuppressor.suppressBriefly()
                finishGesture(timestamp: timestamp)
            }
            return
        }

        let rawFingers = fingerData.bindMemory(to: MTFinger.self, capacity: fingerCount)
        let fingers = fingerContacts(from: rawFingers, count: fingerCount)
        if containsInactiveContacts(fingers) {
            if gestureStartTime != nil {
                secondaryClickSuppressor.suppressBriefly()
                finishGesture(timestamp: timestamp)
            } else {
                resetGesture()
            }
            return
        }

        if containsPalmContact(fingers) {
            TouchCalibrationLogger.logRejectedPalm(fingers: fingers, timestamp: timestamp)
            secondaryClickSuppressor.suppressBriefly()
            resetGesture()
            return
        }

        let centroid = centroid(for: fingers)
        if gestureStartTime == nil {
            // Start tracking only once exactly three fingers are down.
            secondaryClickSuppressor.beginSuppressing()
            gestureStartTime = timestamp
            gestureStartCentroid = centroid
            gestureLastCentroid = centroid
            gestureMaxFingerCount = fingerCount
            gestureValid = true
            calibrationSample = TouchCalibrationLogger.startSample(fingers: fingers, timestamp: timestamp)
            return
        }

        gestureLastCentroid = centroid
        gestureMaxFingerCount = max(gestureMaxFingerCount, fingerCount)
        if distance(from: gestureStartCentroid, to: centroid) > 0.05 {
            gestureValid = false
        }
        TouchCalibrationLogger.updateSample(&calibrationSample, fingers: fingers)
    }

    private func finishGesture(timestamp: Double) {
        defer {
            secondaryClickSuppressor.suppressBriefly()
            resetGesture()
        }

        guard let start = gestureStartTime else {
            return
        }

        let duration = timestamp - start
        let moved = distance(from: gestureStartCentroid, to: gestureLastCentroid)
        let accepted = gestureValid
            && gestureMaxFingerCount == 3
            && duration > 0.015
            && duration < 0.45
            && moved < 0.05
            && timestamp - lastTapTime > 0.05
        TouchCalibrationLogger.finishSample(
            calibrationSample,
            timestamp: timestamp,
            duration: duration,
            moved: moved,
            accepted: accepted,
            rejectionReason: rejectionReason(duration: duration, moved: moved, timestamp: timestamp)
        )

        // Keep the tap recognizer conservative so three-finger rests and drags do not click.
        if !gestureValid {
            return
        }

        if gestureMaxFingerCount != 3 {
            return
        }

        if duration <= 0.015 {
            return
        }

        if duration >= 0.45 {
            return
        }

        if moved >= 0.05 {
            return
        }

        if timestamp - lastTapTime <= 0.05 {
            return
        }

        lastTapTime = timestamp
        secondaryClickSuppressor.suppressAfterAcceptedTap()
        log("Three-finger tap detected")
        DispatchQueue.main.async {
            self.onTap()
        }
    }

    private func resetGesture() {
        secondaryClickSuppressor.endSuppressing()
        gestureStartTime = nil
        gestureStartCentroid = .zero
        gestureLastCentroid = .zero
        gestureMaxFingerCount = 0
        gestureValid = false
        calibrationSample = nil
    }

    private func fingerContacts(from fingers: UnsafeMutablePointer<MTFinger>, count: Int) -> [MTFinger] {
        var contacts: [MTFinger] = []
        contacts.reserveCapacity(count)

        for index in 0..<count {
            contacts.append(fingers[index])
        }

        return contacts
    }

    private func containsPalmContact(_ fingers: [MTFinger]) -> Bool {
        guard fingers.count == 3 else {
            return true
        }

        // Absolute axis values from MultitouchSupport are not stable across devices, so palm
        // rejection uses relative outliers: palm + two fingers usually has one contact that is
        // much larger than the other two, while three fingertips are comparatively similar.
        let sizes = fingers.map { CGFloat($0.size) }
        let majorAxes = fingers.map { CGFloat($0.majorAxis) }
        let minorAxes = fingers.map { CGFloat($0.minorAxis) }

        return hasLargeOutlier(sizes, ratio: 3.5)
            || hasLargeMajorAxisOutlier(majorAxes)
            || hasLargeOutlier(minorAxes, ratio: 3.0)
    }

    private func containsInactiveContacts(_ fingers: [MTFinger]) -> Bool {
        fingers.contains { finger in
            finger.size <= 0.02 || finger.majorAxis <= 0.1 || finger.minorAxis <= 0.1
        }
    }

    private func centroid(for fingers: [MTFinger]) -> CGPoint {
        var x: Float = 0
        var y: Float = 0

        for finger in fingers {
            x += finger.normalized.position.x
            y += finger.normalized.position.y
        }

        let divisor = Float(fingers.count)
        return CGPoint(x: CGFloat(x / divisor), y: CGFloat(y / divisor))
    }

    private func hasLargeOutlier(_ values: [CGFloat], ratio: CGFloat) -> Bool {
        let sorted = values.sorted()
        guard
            let largest = sorted.last,
            sorted.count >= 2
        else {
            return false
        }

        let middle = max(sorted[sorted.count - 2], 0.0001)
        return largest / middle > ratio
    }

    private func hasLargeMajorAxisOutlier(_ values: [CGFloat]) -> Bool {
        let sorted = values.sorted()
        guard
            let largest = sorted.last,
            sorted.count >= 2
        else {
            return false
        }

        let middle = max(sorted[sorted.count - 2], 0.0001)
        return largest > 14.0 && largest / middle > 1.65
    }

    private func distance(from start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        return sqrt(dx * dx + dy * dy)
    }

    private func log(_ message: String) {
        DebugLog.write("[touch] \(message)")
    }

    private func rejectionReason(duration: Double, moved: CGFloat, timestamp: Double) -> String {
        if !gestureValid {
            return "invalid_movement"
        }

        if gestureMaxFingerCount != 3 {
            return "max_finger_count_\(gestureMaxFingerCount)"
        }

        if duration <= 0.015 {
            return "duration_too_short"
        }

        if duration >= 0.45 {
            return "duration_too_long"
        }

        if moved >= 0.05 {
            return "moved_too_far"
        }

        if timestamp - lastTapTime <= 0.05 {
            return "debounced"
        }

        return "accepted"
    }
}

enum DebugLog {
    static func write(_ message: String) {
        let line = "[SimpleMiddleClick] \(message)"
        NSLog("%@", line)
        print(line)
        if let data = "\(line)\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}

private final class SecondaryClickSuppressor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var suppressUntil = CFAbsoluteTimeGetCurrent()
    private var isGestureActive = false
    private var disableTimer: Timer?

    func start() {
        guard eventTap == nil else {
            return
        }

        activeSecondaryClickSuppressor = self

        let eventMask = (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: secondaryClickEventCallback,
            userInfo: nil
        ) else {
            DebugLog.write("[touch] Failed to create secondary click suppressor event tap")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: false)
    }

    func beginSuppressing() {
        isGestureActive = true
        suppressUntil = CFAbsoluteTimeGetCurrent() + 0.35
        enableTapUntilSuppressWindowEnds()
    }

    func suppressBriefly() {
        suppressUntil = CFAbsoluteTimeGetCurrent() + 0.35
        enableTapUntilSuppressWindowEnds()
    }

    func suppressAfterAcceptedTap() {
        suppressUntil = CFAbsoluteTimeGetCurrent() + 0.85
        enableTapUntilSuppressWindowEnds()
    }

    func endSuppressing() {
        isGestureActive = false
        enableTapUntilSuppressWindowEnds()
    }

    fileprivate func shouldSuppressSecondaryClick() -> Bool {
        isGestureActive || CFAbsoluteTimeGetCurrent() < suppressUntil
    }

    private func enableTapUntilSuppressWindowEnds() {
        guard let eventTap else {
            return
        }

        CGEvent.tapEnable(tap: eventTap, enable: true)
        disableTimer?.invalidate()

        let delay = max(0.05, suppressUntil - CFAbsoluteTimeGetCurrent() + 0.02)
        disableTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.disableTapIfIdle()
        }
    }

    private func disableTapIfIdle() {
        guard
            !isGestureActive,
            CFAbsoluteTimeGetCurrent() >= suppressUntil,
            let eventTap
        else {
            enableTapUntilSuppressWindowEnds()
            return
        }

        CGEvent.tapEnable(tap: eventTap, enable: false)
    }
}

struct TouchCalibrationSample {
    let id: Int
    let startTimestamp: Double
    var frameCount: Int
    var minSize: CGFloat
    var midSize: CGFloat
    var maxSize: CGFloat
    var minMajorAxis: CGFloat
    var midMajorAxis: CGFloat
    var maxMajorAxis: CGFloat
    var minMinorAxis: CGFloat
    var midMinorAxis: CGFloat
    var maxMinorAxis: CGFloat
}

enum TouchCalibrationLogger {
    private static let defaultsKey = "touchCalibrationLoggingEnabled"
    private static var nextSampleID = 1

    static var isEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: defaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
        }
    }

    fileprivate static func startSample(fingers: [MTFinger], timestamp: Double) -> TouchCalibrationSample? {
        guard isEnabled else {
            return nil
        }

        let id = nextSampleID
        nextSampleID += 1
        let sample = makeSample(id: id, timestamp: timestamp, frameCount: 1, fingers: fingers)
        write("start \(describe(sample))")
        return sample
    }

    fileprivate static func updateSample(_ sample: inout TouchCalibrationSample?, fingers: [MTFinger]) {
        guard isEnabled, let current = sample else {
            return
        }

        sample = mergedSample(current, fingers: fingers)
    }

    static func finishSample(
        _ sample: TouchCalibrationSample?,
        timestamp: Double,
        duration: Double,
        moved: CGFloat,
        accepted: Bool,
        rejectionReason: String
    ) {
        guard isEnabled, let sample else {
            return
        }

        write(
            "finish id=\(sample.id) accepted=\(accepted) reason=\(rejectionReason) duration=\(format(duration)) moved=\(format(moved)) frames=\(sample.frameCount) \(describeMetrics(sample))"
        )
    }

    fileprivate static func logRejectedPalm(fingers: [MTFinger], timestamp: Double) {
        guard isEnabled else {
            return
        }

        let sample = makeSample(id: nextSampleID, timestamp: timestamp, frameCount: 1, fingers: fingers)
        nextSampleID += 1
        write("palm_rejected \(describe(sample))")
    }

    private static func makeSample(id: Int, timestamp: Double, frameCount: Int, fingers: [MTFinger]) -> TouchCalibrationSample {
        let sizes = sortedValues(fingers.map { CGFloat($0.size) })
        let majors = sortedValues(fingers.map { CGFloat($0.majorAxis) })
        let minors = sortedValues(fingers.map { CGFloat($0.minorAxis) })

        return TouchCalibrationSample(
            id: id,
            startTimestamp: timestamp,
            frameCount: frameCount,
            minSize: sizes[0],
            midSize: sizes[1],
            maxSize: sizes[2],
            minMajorAxis: majors[0],
            midMajorAxis: majors[1],
            maxMajorAxis: majors[2],
            minMinorAxis: minors[0],
            midMinorAxis: minors[1],
            maxMinorAxis: minors[2]
        )
    }

    private static func mergedSample(_ sample: TouchCalibrationSample, fingers: [MTFinger]) -> TouchCalibrationSample {
        let frame = makeSample(id: sample.id, timestamp: sample.startTimestamp, frameCount: sample.frameCount + 1, fingers: fingers)

        return TouchCalibrationSample(
            id: sample.id,
            startTimestamp: sample.startTimestamp,
            frameCount: sample.frameCount + 1,
            minSize: min(sample.minSize, frame.minSize),
            midSize: max(sample.midSize, frame.midSize),
            maxSize: max(sample.maxSize, frame.maxSize),
            minMajorAxis: min(sample.minMajorAxis, frame.minMajorAxis),
            midMajorAxis: max(sample.midMajorAxis, frame.midMajorAxis),
            maxMajorAxis: max(sample.maxMajorAxis, frame.maxMajorAxis),
            minMinorAxis: min(sample.minMinorAxis, frame.minMinorAxis),
            midMinorAxis: max(sample.midMinorAxis, frame.midMinorAxis),
            maxMinorAxis: max(sample.maxMinorAxis, frame.maxMinorAxis)
        )
    }

    private static func describe(_ sample: TouchCalibrationSample) -> String {
        "id=\(sample.id) timestamp=\(format(sample.startTimestamp)) frames=\(sample.frameCount) \(describeMetrics(sample))"
    }

    private static func describeMetrics(_ sample: TouchCalibrationSample) -> String {
        "size=[\(format(sample.minSize)),\(format(sample.midSize)),\(format(sample.maxSize))] major=[\(format(sample.minMajorAxis)),\(format(sample.midMajorAxis)),\(format(sample.maxMajorAxis))] minor=[\(format(sample.minMinorAxis)),\(format(sample.midMinorAxis)),\(format(sample.maxMinorAxis))]"
    }

    private static func sortedValues(_ values: [CGFloat]) -> [CGFloat] {
        let sorted = values.sorted()
        guard sorted.count == 3 else {
            return [0, 0, 0]
        }

        return sorted
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.5f", Double(value))
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.5f", value)
    }

    private static func write(_ message: String) {
        let line = "[calibration] \(message)"
        DebugLog.write(line)

        guard let data = "\(Date()) \(line)\n".data(using: .utf8) else {
            return
        }

        let fileURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SimpleMiddleClickCalibration.log")

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            DebugLog.write("[calibration] failed_to_write_file \(error.localizedDescription)")
        }
    }
}

private var activeMonitor: ThreeFingerTapMonitor?
private var activeSecondaryClickSuppressor: SecondaryClickSuppressor?

private let secondaryClickEventCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        return Unmanaged.passUnretained(event)
    }

    if activeSecondaryClickSuppressor?.shouldSuppressSecondaryClick() == true {
        return nil
    }

    return Unmanaged.passUnretained(event)
}

private typealias MTDeviceRef = UnsafeMutableRawPointer
private typealias MTDeviceCreateListFunction = @convention(c) () -> Unmanaged<CFArray>
private typealias MTRegisterContactFrameCallbackFunction = @convention(c) (
    MTDeviceRef,
    MTContactCallback
) -> Void
private typealias MTDeviceStartFunction = @convention(c) (MTDeviceRef, Int32) -> Int32
private typealias MTContactCallback = @convention(c) (
    MTDeviceRef?,
    UnsafeMutableRawPointer?,
    Int32,
    Double,
    Int32
) -> Int32

private let contactCallback: MTContactCallback = { _, fingers, fingerCount, timestamp, _ in
    activeMonitor?.handleFrame(fingerData: fingers, count: fingerCount, timestamp: timestamp)
    return 0
}

private struct MTPoint {
    var x: Float
    var y: Float
}

private struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

private struct MTFinger {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var unknown1: Int32
    var unknown2: Int32
    var normalized: MTVector
    var size: Float
    var unknown3: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var unknown4: MTVector
    var unknown5: Int32
    var unknown6: Int32
    var unknown7: Float
}
