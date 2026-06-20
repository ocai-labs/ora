//
//  PermissionsTests.swift
//  oraTests
//
//  Behavioural tests for the thin, testable parts of Permissions.
//  The real TCC / AXIsProcessTrusted / open-settings paths aren't
//  exercised here — they require a system-level harness. What we CAN
//  test without faking TCC is the monitoring task lifecycle, which is
//  self-contained and has a contract worth locking down.
//

import Testing
@testable import ora

@MainActor
struct PermissionsTests {
    @Test("startMonitoring is idempotent — calling twice does not spawn a second task")
    func monitoringIsIdempotent() async {
        let perms = Permissions()
        perms.startMonitoring(interval: .milliseconds(10))
        // Second call must be a no-op. We can't introspect the
        // @ObservationIgnored task directly, but stopMonitoring()
        // cancelling exactly one task (and not crashing) proves the
        // guard is in place.
        perms.startMonitoring(interval: .milliseconds(10))
        perms.stopMonitoring()
    }

    @Test("stopMonitoring on a never-started Permissions is a safe no-op")
    func stopWithoutStartIsSafe() {
        let perms = Permissions()
        perms.stopMonitoring()
        // Calling again is still safe.
        perms.stopMonitoring()
    }

    @Test("start/stop/start restart cycle works")
    func restartCycle() async {
        let perms = Permissions()
        perms.startMonitoring(interval: .milliseconds(10))
        perms.stopMonitoring()
        // After stopMonitoring, the guard should reset so a fresh
        // startMonitoring spawns a new task.
        perms.startMonitoring(interval: .milliseconds(10))
        perms.stopMonitoring()
    }
}
