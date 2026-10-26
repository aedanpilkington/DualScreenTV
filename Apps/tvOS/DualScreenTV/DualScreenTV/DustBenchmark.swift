#if DEBUG
import Foundation
import Darwin

// Opt-in offscreen experiment, separate from the active game's core and saves.
@MainActor enum DustBenchmark {
    static func run(rom: URL, shift: UInt32, completion: @escaping @MainActor @Sendable (String) -> Void) {
        let path = Bundle.main.bundleURL.appendingPathComponent("Frameworks/dust_benchmark.dylib").path
        let romPath = rom.path
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("dust-\(1 << shift)x.rgba").path
        DispatchQueue.global(qos: .userInteractive).async {
            var message = "Dust benchmark library unavailable"
            if let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL), let symbol = dlsym(handle, "dstv_dust_benchmark") {
                typealias Benchmark = @convention(c) (UnsafePointer<CChar>, UInt32, UnsafePointer<CChar>) -> Int32
                let benchmark = unsafeBitCast(symbol, to: Benchmark.self)
                let result = romPath.withCString { rom in output.withCString { benchmark(rom, shift, $0) } }
                message = "Dust GPU benchmark finished (\(result))"
                // Keep the code resident, like the normal dynamically loaded cores.
            } else { print("Dust benchmark load error: \(String(cString: dlerror()))") }
            let finalMessage = message
            Task { @MainActor in completion(finalMessage) }
        }
    }
}
#endif
