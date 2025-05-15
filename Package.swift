// swift-tools-version:5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "JMVideoCompressor",
    platforms: [
        .iOS(.v15),
        .macOS(.v13)
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "JMVideoCompressor",
            targets: ["JMVideoCompressor"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "JMVideoCompressor",
            dependencies: [],
            path: "Sources/JMVideoCompressor" // 소스 파일 경로 지정
        ),
        // 테스트 타겟이 필요하다면 주석을 해제하고 경로를 설정하세요.
        .testTarget(
            name: "JMVideoCompressorTests",
            dependencies: ["JMVideoCompressor"],
            path: "Tests/JMVideoCompressorTests", // 테스트 파일 경로 지정
            resources: [ // 이 부분을 추가합니다.
                .copy("Resources") // "Resources" 폴더 안의 내용을 복사하도록 지정
            ]
        ),
    ]
) 