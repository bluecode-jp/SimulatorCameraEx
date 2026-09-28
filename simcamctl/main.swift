//
//  main.swift
//  simcamctl
//
//  Command-line control for SimulatorCamera. Talks to the running extension
//  via CoreMediaIO. Subcommands match SimCam's simcamctl shape:
//
//    simcamctl status
//    simcamctl ping
//    simcamctl set-source --pattern
//    simcamctl set-source --qr "PAYLOAD"
//    simcamctl set-source --image /path/to/file.png
//
//  Exit codes: 0 success, 1 generic error, 2 extension unreachable, 3 invalid args.
//

import Foundation

let args = CommandLine.arguments
let progName = (args.first as NSString?)?.lastPathComponent ?? "simcamctl"

func usage() -> Never {
    let helpText = """
    \(progName) — control SimulatorCamera from the command line

    USAGE:
      \(progName) <subcommand> [options]

    SUBCOMMANDS:
      status                       Print extension state + frame stats
      ping                         Verify the virtual camera is registered
      set-source --pattern         Use the built-in test pattern (color bars)
      set-source --qr "PAYLOAD"    Generate + stream a QR code
      set-source --code128 "TEXT"  Generate + stream a Code 128 barcode
      set-source --ean DIGITS      Generate + stream an EAN-13 (1–12 digits get
                                   zero-padded + check digit; or all 13 digits)
      set-source --image PATH      Stream a static PNG/JPG file
      set-source --video PATH      Stream a video file (loops)       [needs the app]
      set-source --camera [NAME]   Stream a Mac camera (NAME = part of its name
                                   or its ID, see list-cameras)      [needs the app]
      list-cameras                 List Mac cameras (* = selected)   [needs the app]
                                   With SimulatorCameraEx.app running, set-source goes
                                   through the app and reaches iOS Simulator apps too.

    iOS SIMULATOR (camera for apps in the Simulator, via SimCamInject.dylib):
      sim-enable [--app ID]...     Load the camera into every app launched from now
                                   on (or only the given bundle IDs)
      sim-disable                  Stop loading it (a simulator reboot also clears it)
      sim-status                   Show injection state and Mac app reachability
      sim-launch ID [--url URL]    Launch one app with the camera, this launch only
      sim-orientation portrait|landscape
                                   Shape of frames sent to simulator apps [needs the app]
      All sim-* commands take --device UDID (default: booted). Frames come from
      the running SimulatorCameraEx.app; pick the source there.

    ANDROID EMULATOR (the virtual camera as an Android camera, no injection):
      android-list                 List AVDs and the camera's emulator label (webcamN)
      android-launch AVD [--front] Start an AVD with the camera as its back camera
                                   (and front camera with --front)
      android-setup AVD            Make it the AVD's default back camera, for launches
                                   from Android Studio (redo after Mac cameras change)

      help                         Show this help

    EXIT CODES:
      0    success
      1    generic error
      2    extension not reachable (not activated?)
      3    invalid arguments

    The container app must be installed and the extension activated. Frame pushes
    (--qr, --image) open the camera's sink stream and may trigger a one-time
    camera-access prompt for your terminal. If status
    shows the extension is inactive, run /Applications/SimulatorCameraEx.app to
    activate it.
    """
    FileHandle.standardError.write(Data(helpText.utf8))
    FileHandle.standardError.write(Data("\n".utf8))
    exit(3)
}

if args.count < 2 { usage() }

let subcommand = args[1]
let cli = SimCamCLIClient()

switch subcommand {
case "help", "-h", "--help":
    usage()

case "sim-enable", "sim-disable", "sim-status", "sim-launch":
    SimulatorInjection.run(subcommand, Array(args.dropFirst(2)))

case "android-list", "android-launch", "android-setup":
    AndroidCommands.run(subcommand, Array(args.dropFirst(2)))

case "__frames-received":   // internal: see SimCamCLIClient.freshFramesReceived
    cli.runPrintFramesReceived()

case "ping":
    cli.runPing()

case "status":
    // App first (source, simulator apps), then the extension's own counters.
    if let app = AppControl.request(["command": "status"]), app["ok"] as? Bool == true {
        print("app source:        \(app["source"] ?? "?")")
        print("simulator apps:    \(app["simulatorApps"] ?? 0) connected (\(app["orientation"] ?? "?") frames)")
    } else {
        print("app:               SimulatorCameraEx.app not running")
    }
    cli.runStatus()

case "list-cameras":
    guard let reply = AppControl.request(["command": "list-cameras"]), reply["ok"] as? Bool == true,
          let cameras = reply["cameras"] as? [[String: Any]] else {
        FileHandle.standardError.write(Data("error: SimulatorCameraEx.app is not running\n".utf8))
        exit(1)
    }
    for camera in cameras {
        let mark = camera["selected"] as? Bool == true ? "*" : " "
        print("\(mark) \(camera["name"] ?? "?")    \(camera["id"] ?? "")")
    }
    exit(0)

case "sim-orientation":
    guard args.count >= 3, ["portrait", "landscape"].contains(args[2]) else {
        FileHandle.standardError.write(Data("error: usage: \(progName) sim-orientation portrait|landscape\n".utf8))
        exit(3)
    }
    guard let reply = AppControl.request(["command": "set-orientation", "orientation": args[2]]) else {
        FileHandle.standardError.write(Data("error: SimulatorCameraEx.app is not running\n".utf8))
        exit(1)
    }
    AppControl.finish(reply, success: "simulator frames: \(args[2])")

case "set-source":
    if args.count < 3 { usage() }
    let flag = args[2]
    let value = args.count >= 4 ? args[3] : nil
    func need(_ what: String) -> String {
        guard let value else {
            FileHandle.standardError.write(Data("error: \(flag) requires \(what)\n".utf8))
            exit(3)
        }
        return value
    }
    func absolute(_ path: String) -> String {
        URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL.path
    }

    // Preferred path: ask the app, which feeds the extension AND iOS
    // Simulator apps and keeps streaming. Fallback when the app is not
    // running: push one frame straight into the extension, as before.
    let request: [String: Any]
    switch flag {
    case "--pattern": request = ["kind": "pattern"]
    case "--camera":
        // Optional camera: `--camera "USB"` (name part or uniqueID); bare
        // `--camera` keeps the app's current choice.
        request = value.map { ["kind": "camera", "device": $0] } ?? ["kind": "camera"]
    case "--qr": request = ["kind": "qr", "payload": need("a payload string")]
    case "--code128": request = ["kind": "code128", "payload": need("a payload string")]
    case "--ean": request = ["kind": "ean13", "payload": need("1–12 digits or a 13-digit EAN")]
    case "--image": request = ["kind": "image", "path": absolute(need("a file path"))]
    case "--video": request = ["kind": "video", "path": absolute(need("a file path"))]
    default:
        FileHandle.standardError.write(Data("error: unknown set-source flag '\(flag)'\n".utf8))
        usage()
    }
    if let reply = AppControl.request(["command": "set-source"].merging(request) { $1 }) {
        let apps = reply["simulatorApps"] as? Int ?? 0
        AppControl.finish(reply, success: "source: \(reply["source"] ?? flag) (via SimulatorCameraEx.app; \(apps) simulator app(s) connected)")
    }
    FileHandle.standardError.write(Data("note: SimulatorCameraEx.app is not running; pushing to the Mac virtual camera only (iOS Simulator apps will not see it).\n".utf8))
    switch flag {
    case "--pattern": cli.runSetSource(.testPattern)
    case "--qr": cli.runSetQR(payload: need("a payload string"))
    case "--code128": cli.runSetBarcode(payload: need("a payload string"), symbology: .code128)
    case "--ean": cli.runSetBarcode(payload: need("1–12 digits or a 13-digit EAN"), symbology: .ean13)
    case "--image": cli.runSetImage(path: need("a file path"))
    default:
        FileHandle.standardError.write(Data("error: \(flag) needs SimulatorCameraEx.app running\n".utf8))
        exit(1)
    }

default:
    FileHandle.standardError.write(Data("error: unknown subcommand '\(subcommand)'\n".utf8))
    usage()
}
