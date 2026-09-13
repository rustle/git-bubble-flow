// swift-tools-version: 6.2
//
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
import PackageDescription

// Subprocess's SubprocessFoundation trait is disabled. It is on by default and
// would link Foundation, which costs ~45 MB in a statically linked Linux binary.
// Swift 6 language mode is implied by the tools version, but state it so the
// guarantee survives a tools-version bump. The upcoming features are the ones
// that catch mistakes this codebase is prone to: unmarked existentials, leaked
// transitive imports, and warnings nobody reads.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "git-bubble-flow",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "git-bubble-flow", targets: ["git-bubble-flow"]),
        .library(name: "BubbleFlowKit", targets: ["BubbleFlowKit"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-subprocess.git",
            from: "1.0.0",
            traits: []
        ),
    ],
    targets: [
        .target(
            name: "BubbleFlowKit",
            dependencies: [.product(name: "Subprocess", package: "swift-subprocess")],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "git-bubble-flow",
            dependencies: ["BubbleFlowKit"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "BubbleFlowKitTests",
            dependencies: ["BubbleFlowKit"],
            swiftSettings: swiftSettings
        ),
    ]
)
