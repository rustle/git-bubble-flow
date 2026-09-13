// Copyright 2026 Doug Russell
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// The Static Linux SDK builds against musl, which exposes `Musl` rather than
// `Glibc`. Checking only for Glibc silently falls through to the Darwin branch
// and fails to compile.
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
import MachO  // _NSGetExecutablePath
#else
#error("Unsupported platform: no libc module")
#endif

/// POSIX odds and ends: environment lookup, executable discovery, symlink resolution,
/// stream writing, wall-clock time and exit.
///
/// Exists so nothing here has to import Foundation. Foundation's pure-Swift
/// surface is free — `--gc-sections` strips an unused `import Foundation`
/// entirely — but `FileHandle`/`FileManager`/`Bundle` come bundled with
/// `Process` and pull in ~45 MB of a statically linked Linux binary. Regex and
/// the rest of string processing live in the stdlib, so none of that is lost.
public enum Sys {

    // MARK: - Environment

    public static func environment(_ name: String) -> String? {
        guard let value = getenv(name) else { return nil }
        return String(decodingNulTerminated: value)
    }

    // MARK: - Files

    public static func isExecutableFile(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        // access(X_OK) alone is not enough: it succeeds for any searchable
        // directory, and PATH entries are directories.
        guard info.st_mode & S_IFMT == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }

    /// Resolves every symlink in `path`. Returns the input unchanged when the
    /// path cannot be resolved, so callers always get something usable.
    public static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(decodingNulTerminated: resolved)
    }

    /// Absolute path of the running executable, before symlink resolution.
    ///
    /// Both branches follow Rust's `std::env::current_exe`: size the buffer
    /// from what the kernel or dyld reports rather than assuming `PATH_MAX`,
    /// which deep directories can exceed.
    public static func executablePath() -> String? {
        #if canImport(Darwin)
        // With a zero-size buffer the call fails and writes the required
        // size, terminator included, so the second call's buffer is exact
        // and `size` is the length. On success dyld leaves `size` unchanged.
        var size = UInt32(0)
        _NSGetExecutablePath(nil, &size)
        guard size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return String(decoding: buffer[0..<Int(size) - 1])
        #else
        // The kernel caps this link at PATH_MAX, so start there and the loop
        // only iterates if the platform's limit turns out to be wrong.
        return readLink("/proc/self/exe", capacity: Int(PATH_MAX))
        #endif
    }

    /// Target of the symlink at `path`, or nil if it cannot be read.
    ///
    /// `readlink` neither NUL-terminates nor reports truncation: a result
    /// equal to the buffer size is the only signal, so grow from `capacity`
    /// until the result is shorter than the buffer. Callers that know the
    /// platform's bound for a particular link can start there.
    static func readLink(_ path: String, capacity: Int = 256) -> String? {
        var capacity = capacity
        while true {
            var buffer = [CChar](repeating: 0, count: capacity)
            let count = readlink(path, &buffer, capacity)
            guard count > 0 else { return nil }
            if count < capacity { return String(decoding: buffer[0..<count]) }
            capacity *= 2
        }
    }

    // MARK: - Output

    /// Writes every byte, retrying short writes and EINTR.
    public static func write(_ fileDescriptor: Int32, _ bytes: [UInt8]) {
        var offset = 0
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            while offset < buffer.count {
                let written = Sys.writeRaw(fileDescriptor, base + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    private static func writeRaw(_ fd: Int32, _ pointer: UnsafePointer<UInt8>, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.write(fd, pointer, count)
        #elseif canImport(Musl)
        return Musl.write(fd, pointer, count)
        #else
        return Glibc.write(fd, pointer, count)
        #endif
    }

    // MARK: - Time

    public static func now() -> Int { Int(time(nil)) }

    public struct TimeComponents {
        public var year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int
    }

    public static func components(of unixTime: Int, utc: Bool = false) -> TimeComponents {
        var raw = time_t(unixTime)
        var parts = tm()
        if utc { gmtime_r(&raw, &parts) } else { localtime_r(&raw, &parts) }
        return TimeComponents(
            year: Int(parts.tm_year) + 1900,
            month: Int(parts.tm_mon) + 1,
            day: Int(parts.tm_mday),
            hour: Int(parts.tm_hour),
            minute: Int(parts.tm_min),
            second: Int(parts.tm_sec)
        )
    }

    /// Terminates the process. Kept here so the platform conditionals stay in
    /// one file.
    public static func exit(_ status: Int32) -> Never {
        #if canImport(Darwin)
        Darwin.exit(status)
        #elseif canImport(Musl)
        Musl.exit(status)
        #else
        Glibc.exit(status)
        #endif
    }
}

extension String {
    init(decoding bytes: ArraySlice<CChar>) {
        self = bytes.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
    }

    /// Decodes a NUL-terminated string from a pointer returned by libc.
    ///
    /// `strlen` is sound here only because the pointer comes from an API that
    /// guarantees termination, such as `getenv` or `realpath`.
    fileprivate init(decodingNulTerminated pointer: UnsafeMutablePointer<CChar>) {
        let count = Int(strlen(pointer))
        self = pointer.withMemoryRebound(to: UInt8.self, capacity: count) { bytes in
            String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
        }
    }
}
