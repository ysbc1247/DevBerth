import Darwin
import Foundation

final class FoundationCommandRunner: CommandRunning, @unchecked Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: URL?
    ) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let standardOutput = try Self.makePipe()
            let standardError = try Self.makePipe()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment.map { ProcessInfo.processInfo.environment.merging($0) { _, new in new } }
            process.currentDirectoryURL = currentDirectory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = standardOutput
            process.standardError = standardError

            do {
                try process.run()
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                throw DevBerthError.commandUnavailable(executable.path)
            } catch {
                throw DevBerthError.unexpected("Could not run \(executable.lastPathComponent): \(error.localizedDescription)")
            }

            async let outputData = Task.detached {
                standardOutput.fileHandleForReading.readDataToEndOfFile()
            }.value
            async let errorData = Task.detached {
                standardError.fileHandleForReading.readDataToEndOfFile()
            }.value

            process.waitUntilExit()
            return await CommandResult(
                stdout: outputData,
                stderr: errorData,
                exitCode: process.terminationStatus
            )
        }.value
    }

    static func makePipe() throws -> Pipe {
        let pipe = Pipe()
        do {
            try setCloseOnExec(pipe.fileHandleForReading.fileDescriptor)
            try setCloseOnExec(pipe.fileHandleForWriting.fileDescriptor)
            return pipe
        } catch {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            throw error
        }
    }

    private static func setCloseOnExec(_ descriptor: Int32) throws {
        let flags = Darwin.fcntl(descriptor, F_GETFD)
        guard flags >= 0, Darwin.fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) >= 0 else {
            let failure = errno
            throw DevBerthError.commandFailed(
                command: "isolate command capture descriptor",
                status: Int32(failure),
                details: String(cString: strerror(failure))
            )
        }
    }
}
