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
#else
#error("Unsupported platform: no libc module")
#endif

/// POSIX odds and ends: environment lookup, executable tests, stream writing,
/// wall-clock time and exit.
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

    /// True when anything exists at `path`, directory included.
    ///
    /// `isExecutableFile` answers a narrower question: it requires a regular
    /// file, so it reports false for the state *directories* git writes for an
    /// operation in progress.
    public static func pathExists(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0
    }

    /// Writes `contents` to a new or truncated file readable only by its
    /// owner. Used for the patches `git apply` reads, which has no other way
    /// in short of stdin.
    public static func writeFile(_ path: String, _ contents: String) -> Bool {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let bytes = Array(contents.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBufferPointer { buffer in
                writeRaw(descriptor, buffer.baseAddress!, buffer.count)
            }
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    public static func makeDirectory(_ path: String) -> Bool {
        mkdir(path, 0o700) == 0 || errno == EEXIST
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
    /// Decodes a NUL-terminated string from a pointer returned by libc.
    ///
    /// `strlen` is sound here only because the pointer comes from an API that
    /// guarantees termination, such as `getenv`.
    init(decodingNulTerminated pointer: UnsafeMutablePointer<CChar>) {
        let count = Int(strlen(pointer))
        self = pointer.withMemoryRebound(to: UInt8.self, capacity: count) { bytes in
            String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
        }
    }
}
