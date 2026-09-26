// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AIRecording",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AIRecording", targets: ["AIRecording"])
    ],
    targets: [
        .executableTarget(
            name: "AIRecording",
            dependencies: ["KnowledgeAgentResources"],
            path: ".",
            exclude: [
                ".build",
                ".git",
                ".swiftpm",
                "AGENTS.md",
                "CLAUDE.md",
                "Scripts",
                "Tests",
                "docs",
                "smartchart-changes.diff",
                "ChartAgent/README.md",
                "ChartAgent/design",
                "ChartAgent/tests",
                "KnowledgeAgent",
                "AIRecording/Info.plist",
                "AIRecording/AIRecording.entitlements"
            ],
            sources: [
                "AIRecording/App",
                "AIRecording/Models",
                "AIRecording/Services",
                "AIRecording/Utilities",
                "AIRecording/ViewModels",
                "AIRecording/Views"
            ],
            resources: [
                .process("AIRecording/Resources/Assets.xcassets"),
                .copy("ChartAgent/main.py"),
                .copy("ChartAgent/requirements.txt"),
                .copy("ChartAgent/agent")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "KnowledgeAgentResources",
            path: "KnowledgeAgent",
            exclude: [
                ".venv",
                "tests",
                "__pycache__",
                "knowledge-agent.spec"
            ],
            resources: [
                .copy("main.py"),
                .copy("requirements.txt"),
                .copy("agent")
            ]
        ),
        .testTarget(
            name: "AIRecordingTests",
            dependencies: ["AIRecording"],
            path: "Tests/AIRecordingTests"
        )
    ]
)
