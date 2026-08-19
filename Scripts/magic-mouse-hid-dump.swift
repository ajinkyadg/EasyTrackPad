#!/usr/bin/env swift
//
// magic-mouse-hid-dump.swift
//
// Standalone diagnostic — NOT part of the InputCustomizer app or its SPM
// package. Opens a public IOHIDManager session directly against your
// Magic Mouse 2's own hardware (Vendor 0x004C / Product 0x0269, confirmed
// via `system_profiler SPBluetoothDataType`), sends the feature report
// that enables raw multitouch reporting, and decodes the resulting touch
// data live.
//
// The enable step and the report byte layout below come from Linux's
// open-source (GPL) `hid-magicmouse.c` kernel driver — public, documented
// reverse-engineering of Apple's own Magic Mouse 2 hardware protocol, not
// of any third-party application. See:
//   https://github.com/torvalds/linux/blob/master/drivers/hid/hid-magicmouse.c
//   https://github.com/torvalds/linux/blob/master/drivers/hid/hid-ids.h
//
// Without the enable step, this exact mouse only ever emits an 8-byte
// "basic mouse" report (report ID 0x12 / 18 decimal — matching what a
// first pass of this script, before this fix, captured exclusively no
// matter how the mouse was touched). After it, the *same* report ID
// grows to 14 + 8*N bytes, N = number of active touch points.
//
// This version opens each matched interface with kIOHIDOptionsTypeSeizeDevice
// (exclusive access) rather than a plain open — a first pass with a plain
// open sent the enable-multitouch feature report successfully (result=0)
// but the device kept emitting only 8-byte BASIC-mode reports even during
// deliberate touching, consistent with macOS's own built-in Bluetooth HID
// stack still owning the device and not honoring/persisting a mode change
// requested by a secondary (non-exclusive) client.
//
// WARNING: seizing takes this mouse's normal cursor/click behavior away
// from the rest of the system for as long as this script keeps it open —
// your Magic Mouse's pointer will likely stop moving the system cursor
// while this runs. It comes back the instant the script exits (Ctrl+C).
//
// Usage:
//   swift Scripts/magic-mouse-hid-dump.swift
// Ctrl+C to stop. Touch, tap, and swipe on the mouse once it says
// "Listening" — watch for the report length changing from 8 to something
// larger, and decoded touch lines appearing.

import Foundation
import IOKit.hid

// Line-buffer stdout even when redirected to a file/pipe (not a
// terminal) — otherwise Swift/libc fully-buffers non-tty output and
// nothing appears until the process exits cleanly, which defeats
// watching this live or capturing partial output if it's interrupted.
setvbuf(stdout, nil, _IOLBF, 0)

let appleVendorID = 0x004C
let magicMouseProductID = 0x0269 // USB_DEVICE_ID_APPLE_MAGICMOUSE2
let reportBufferSize = 512

// From hid-magicmouse.c's magicmouse_enable_multitouch(): for
// MAGICMOUSE2 specifically, `feature_mt_mouse2[] = { 0xF1, 0x02, 0x01 }`,
// sent as a Feature report via HID_REQ_SET_REPORT. The first byte is
// both the report ID and the first byte of the payload (standard
// numbered-report convention).
let enableMultitouchReport: [UInt8] = [0xF1, 0x02, 0x01]

let mouse2ReportID = 18 // MOUSE2_REPORT_ID (0x12)
let touchStateMask: UInt8 = 0xF0
let touchStateNone: UInt8 = 0x00
let touchStateNames: [UInt8: String] = [0x00: "none", 0x10: "hover?", 0x20: "hover2?", 0x30: "start", 0x40: "drag"]

/// Decodes one 8-byte per-touch record at `tdata` — bit layout specific
/// to MAGICMOUSE/MAGICMOUSE2 from `magicmouse_emit_touch()`.
func decodeTouch(_ tdata: ArraySlice<UInt8>) -> String {
    let t = Array(tdata)
    guard t.count == 8 else { return "  <short touch record: \(t.count) bytes>" }
    let t0 = Int32(t[0]), t1 = Int32(t[1]), t2 = Int32(t[2])
    let id = (Int32(t[6]) << 2 | Int32(t[5]) >> 6) & 0xF
    let x = (t1 << 28 | t0 << 20) >> 20
    let y = -((t2 << 24 | t1 << 16) >> 20)
    let size = t[5] & 0x3F
    let orientation = (Int32(t[6]) >> 2) - 32
    let touchMajor = t[3]
    let touchMinor = t[4]
    let state = t[7] & touchStateMask
    let down = state != touchStateNone
    let stateName = touchStateNames[state] ?? "0x\(String(state, radix: 16))"
    return "  touch id=\(id) x=\(x) y=\(y) size=\(size) orientation=\(orientation) major=\(touchMajor) minor=\(touchMinor) state=\(stateName) down=\(down)"
}

let reportCallback: IOHIDReportCallback = { _, _, _, _, reportID, report, reportLength in
    let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
    let timestamp = String(format: "%.3f", Date().timeIntervalSince1970)

    guard Int(reportID) == mouse2ReportID else {
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        print("[\(timestamp)] reportID=\(reportID) len=\(reportLength)  \(hex)")
        return
    }

    if reportLength == 8 {
        print("[\(timestamp)] reportID=18 len=8 (BASIC mode — multitouch not active on this interface)")
        return
    }
    guard reportLength >= 14, (reportLength - 14) % 8 == 0 else {
        print("[\(timestamp)] reportID=18 len=\(reportLength) (unrecognized size, not basic-8 or 14+8N)")
        return
    }
    let npoints = (reportLength - 14) / 8
    let clicks = bytes[1]
    let relX = (Int32(bytes[3]) << 24 | Int32(bytes[2]) << 16) >> 16
    let relY = (Int32(bytes[5]) << 24 | Int32(bytes[4]) << 16) >> 16
    print("[\(timestamp)] reportID=18 len=\(reportLength) MULTITOUCH ACTIVE — clicks=\(clicks) relX=\(relX) relY=\(relY) touches=\(npoints)")
    for i in 0..<npoints {
        let start = 14 + i * 8
        print(decodeTouch(bytes[start..<(start + 8)]))
    }
}

/// Report success but leave device behavior unchanged when opened as an
/// ordinary secondary client (`kIOHIDOptionsTypeNone`) — macOS's own
/// built-in Bluetooth HID stack still holds primary ownership of this
/// device and appears to not honor (or silently reverts) a mode change
/// requested by a secondary client. Unlike Linux's `hid-magicmouse.c`,
/// which is the exclusive kernel-level owner, a plain IOHIDManager client
/// here is just one of possibly several listeners.
///
/// `kIOHIDOptionsTypeSeizeDevice` requests exclusive access instead — the
/// same mechanism tools like Karabiner-Elements use to fully take over a
/// keyboard/mouse. While seized, this device's normal cursor/click
/// handling will likely stop reaching the rest of the system (the OS's
/// own driver loses the device to us) for as long as this process holds
/// it open — released back to normal the moment the script exits.
let seizeDevice = true

func usagePage(of device: IOHIDDevice) -> Int {
    (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? -1
}
func usage(of device: IOHIDDevice) -> Int {
    (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? -1
}

let matchCallback: IOHIDDeviceCallback = { _, _, _, device in
    let page = usagePage(of: device)
    let use = usage(of: device)
    print("--- matched HID device \(device) — PrimaryUsagePage=\(page) PrimaryUsage=\(use) ---")

    let openOptions: IOOptionBits = seizeDevice ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice) : IOOptionBits(kIOHIDOptionsTypeNone)
    let openResult = IOHIDDeviceOpen(device, openOptions)
    guard openResult == kIOReturnSuccess else {
        print("    IOHIDDeviceOpen(seize=\(seizeDevice)) failed (ioReturn=\(openResult)) — skipping")
        return
    }
    if seizeDevice {
        print("    IOHIDDeviceOpen SEIZED this interface — its normal system behavior is suspended until this script exits.")
    }

    var feature = enableMultitouchReport
    let setResult = feature.withUnsafeMutableBufferPointer { buf -> IOReturn in
        IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(enableMultitouchReport[0]), buf.baseAddress!, buf.count)
    }
    print("    IOHIDDeviceSetReport(enable multitouch) result=\(setResult) (0 = success — this is the interface actually delivering touch data if success)")

    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportBufferSize)
    IOHIDDeviceRegisterInputReportCallback(device, buffer, reportBufferSize, reportCallback, nil)
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let matching: [String: Any] = [
    kIOHIDVendorIDKey as String: appleVendorID,
    kIOHIDProductIDKey as String: magicMouseProductID
]
IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
IOHIDManagerRegisterDeviceMatchingCallback(manager, matchCallback, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
print("IOHIDManagerOpen result: \(openResult) (0 = success)")
print("Vendor 0x\(String(appleVendorID, radix: 16)) / Product 0x\(String(magicMouseProductID, radix: 16)) — Magic Mouse 2")
print("Sending multitouch-enable feature report to every matched interface, then listening.")
print("Touch, tap, and swipe on the mouse now. Ctrl+C to stop.\n")

RunLoop.current.run()
