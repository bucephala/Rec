import Cocoa
import RecLib

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--selftest") {
    exit(SelfTest.run(arguments: args))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
