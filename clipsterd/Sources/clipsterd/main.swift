import ClipsterCore
import Foundation

let version = "0.3.0-phase4"
let pid = ProcessInfo.processInfo.processIdentifier

let options = RuntimeOptions.parse(
    args: CommandLine.arguments,
    env: ProcessInfo.processInfo.environment
)

let runtime: ClipsterRuntime
do {
    runtime = try ClipsterRuntime(options: options)
} catch {
    logger.error("Failed to initialise runtime: \(error)")
    exit(1)
}

runtime.start(version: version, pid: pid)

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

let sigSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigSrc.setEventHandler {
    logger.info("Received SIGTERM — shutting down")
    runtime.stop()
    logger.info("clipsterd stopped cleanly")
    exit(0)
}
sigSrc.resume()

let intSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
intSrc.setEventHandler {
    logger.info("Received SIGINT — shutting down")
    runtime.stop()
    logger.info("clipsterd stopped cleanly")
    exit(0)
}
intSrc.resume()

RunLoop.main.run()
