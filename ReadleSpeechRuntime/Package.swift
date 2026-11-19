// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ReadleSpeechRuntime", platforms: [.iOS(.v17)], products: [.library(name: "ReadleSpeechRuntime", targets: ["ReadleSpeechRuntime"])], targets: [
    .binaryTarget(name: "SherpaOnnxIOS", url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.8-ios-static.xcframework.zip", checksum: "6b8e769cb153343270fdccbe92e3b3db0d1c421d67fa0989ab01fdf5b2fcf2de"),
    .binaryTarget(name: "OnnxruntimeIOS", url: "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.28.1/onnxruntime-ios-static-xcframework-1.28.1.xcframework.zip", checksum: "992d8a0cc6014cccc3a7815c36bbff5e5a06833ea2c4d47dd43ef071f639cf9d"),
    .target(name: "ReadleSpeechRuntime", dependencies: ["SherpaOnnxIOS", "OnnxruntimeIOS"], linkerSettings: [.linkedLibrary("c++"), .linkedFramework("CoreML"), .linkedFramework("Accelerate")])
])
