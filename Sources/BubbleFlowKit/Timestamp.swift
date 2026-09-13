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

/// `date +%Y%m%d-%H%M%S`, the format the shell tools used for backup tags.
public func backupTimestamp(_ unixTime: Int = Sys.now(), utc: Bool = false) -> String {
    let parts = Sys.components(of: unixTime, utc: utc)
    let date =
        String.padded(parts.year, width: 4)
        + String.padded(parts.month, width: 2)
        + String.padded(parts.day, width: 2)
    let time =
        String.padded(parts.hour, width: 2)
        + String.padded(parts.minute, width: 2)
        + String.padded(parts.second, width: 2)
    return "\(date)-\(time)"
}

/// Appends a counter when a tag of this name already exists.
///
/// The timestamp has one-second resolution, so two runs in the same second
/// would otherwise collide and `git tag` would abort the command part-way.
func uniqueTag(_ base: String, git: any GitRunning) async -> String {
    guard await git.revisionExists("refs/tags/\(base)") else { return base }
    for suffix in 2...100 {
        let candidate = "\(base)-\(suffix)"
        if await git.revisionExists("refs/tags/\(candidate)") == false { return candidate }
    }
    return base
}
