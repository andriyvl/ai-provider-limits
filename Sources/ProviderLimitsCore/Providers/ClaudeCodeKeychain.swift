import Foundation

/// Reads Claude Code's Keychain login through `/usr/bin/security`. Claude Code writes the item with that
/// same tool, so the item's access list already trusts it: no permission prompt, and rebuilding this app
/// (which changes its code signature) does not re-trigger one.
enum ClaudeCodeKeychain {
    static let service = "Claude Code-credentials"

    static func readItem(service: String) -> Data? {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
        #else
        return nil
        #endif
    }
}
