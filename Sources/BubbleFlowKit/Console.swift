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

/// Where a command writes its two streams. Injectable so tests can assert on
/// output without spawning a process.
public protocol Console: Sendable {
    func out(_ line: String)
    func err(_ line: String)
}

public struct StandardConsole: Console {
    public init() {}

    public func out(_ line: String) { Sys.write(1, Array((line + "\n").utf8)) }
    public func err(_ line: String) { Sys.write(2, Array((line + "\n").utf8)) }
}
