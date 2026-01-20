//
//  DisplaySleepMonitor.swift
//  Dayflow
//
//  Monitors display sleep state and user idle time to detect when
//  the system is truly inactive (not just notification-based sleep).
//
//  Addresses two key issues:
//  1. Display Sleep ≠ System Sleep: Screen can go black without triggering willSleepNotification
//  2. Power Assertions: Apps can block system sleep, preventing notifications from firing
//
//  Solution:
//  - Monitor display power state via IOKit
//  - Track user idle time via CGEventSource
//  - Provide combined "is system inactive" signal
//

import Foundation
import IOKit
import IOKit.pwr_mgt
import Combine
import AppKit

/// Monitors display sleep state and user activity to determine if system is truly inactive
final class DisplaySleepMonitor: @unchecked Sendable {

    // MARK: - Published State

    /// True when display is asleep OR user has been idle for extended period
    @Published private(set) var isSystemInactive = false

    // MARK: - Configuration

    /// Idle time threshold in seconds (default: 5 minutes)
    /// If user hasn't interacted for this long, consider system inactive
    private let idleThreshold: TimeInterval = 5 * 60

    /// Check interval for idle time detection
    private let checkInterval: TimeInterval = 30

    // MARK: - Private Properties

    private var displaySleepPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    private var idleCheckTimer: Timer?
    private let queue = DispatchQueue(label: "com.dayflow.display-sleep-monitor")

    // MARK: - Initialization

    init() {
        setupDisplaySleepMonitoring()
        startIdleTimeMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Display Sleep Monitoring (IOKit)

    private func setupDisplaySleepMonitoring() {
        // Create notification port
        notificationPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notificationPort = notificationPort else {
            print("[DisplaySleepMonitor] Failed to create notification port")
            return
        }

        // Add notification port to run loop
        let runLoopSource = IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)

        // Register for display power state changes
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let result = IOServiceAddInterestNotification(
            notificationPort,
            IORegistryEntryFromPath(kIOMainPortDefault, kIOServicePlane + ":/IOResources/IODisplayWrangler"),
            kIOGeneralInterest,
            { (refcon, service, messageType, messageArgument) in
                let monitor = Unmanaged<DisplaySleepMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                monitor.handlePowerStateChange(messageType: messageType)
            },
            selfPtr,
            &notifier
        )

        if result != kIOReturnSuccess {
            print("[DisplaySleepMonitor] Failed to register for display notifications: \(result)")
        } else {
            print("[DisplaySleepMonitor] Display sleep monitoring enabled")
        }
    }

    private func handlePowerStateChange(messageType: UInt32) {
        switch messageType {
        case UInt32(kIOMessageDeviceWillPowerOff):
            print("[DisplaySleepMonitor] Display will sleep")
            updateInactiveState(isDisplayAsleep: true)

        case UInt32(kIOMessageDeviceHasPoweredOn):
            print("[DisplaySleepMonitor] Display woke up")
            updateInactiveState(isDisplayAsleep: false)

        default:
            break
        }
    }

    // MARK: - Idle Time Monitoring (CGEventSource)

    private func startIdleTimeMonitoring() {
        // Check idle time periodically on main thread (for Timer)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.idleCheckTimer = Timer.scheduledTimer(
                withTimeInterval: self.checkInterval,
                repeats: true
            ) { [weak self] _ in
                self?.checkIdleTime()
            }

            // Check immediately
            self.checkIdleTime()
        }
    }

    private func checkIdleTime() {
        let idleTime = getSystemIdleTime()
        let isIdle = idleTime > idleThreshold

        if isIdle {
            print("[DisplaySleepMonitor] User idle for \(Int(idleTime))s (threshold: \(Int(idleThreshold))s)")
        }

        updateInactiveState(isUserIdle: isIdle)
    }

    /// Get system idle time in seconds (time since last user input)
    private func getSystemIdleTime() -> TimeInterval {
        let idleTime = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: .mouseMoved
        )
        return idleTime
    }

    // MARK: - State Management

    private var _isDisplayAsleep = false
    private var _isUserIdle = false

    private func updateInactiveState(isDisplayAsleep: Bool? = nil, isUserIdle: Bool? = nil) {
        queue.async { [weak self] in
            guard let self = self else { return }

            if let displayAsleep = isDisplayAsleep {
                self._isDisplayAsleep = displayAsleep
            }
            if let userIdle = isUserIdle {
                self._isUserIdle = userIdle
            }

            // System is inactive if EITHER display is asleep OR user has been idle
            let newInactive = self._isDisplayAsleep || self._isUserIdle

            if newInactive != self.isSystemInactive {
                DispatchQueue.main.async {
                    self.isSystemInactive = newInactive
                    print("[DisplaySleepMonitor] System inactive: \(newInactive) (display: \(self._isDisplayAsleep), idle: \(self._isUserIdle))")
                }
            }
        }
    }

    // MARK: - Cleanup

    private func stopMonitoring() {
        // Stop idle timer
        idleCheckTimer?.invalidate()
        idleCheckTimer = nil

        // Clean up IOKit notifications
        if notifier != 0 {
            IOObjectRelease(notifier)
            notifier = 0
        }

        if let port = notificationPort {
            IONotificationPortDestroy(port)
            notificationPort = nil
        }

        print("[DisplaySleepMonitor] Monitoring stopped")
    }
}
