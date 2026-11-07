// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MacSpaceCipher", platforms: [.macOS("27.0")],
 products: [.library(name: "MacSpaceCipher", type: .static, targets: ["MacSpaceCipher"])],
 targets: [.target(name: "MacSpaceCipher", publicHeadersPath: "include", cSettings: [
 .define("NDEBUG"), .define("SQLITE_EXTRA_INIT", to: "sqlcipher_extra_init"), .define("SQLITE_EXTRA_SHUTDOWN", to: "sqlcipher_extra_shutdown"), .define("SQLITE_HAS_CODEC"), .define("SQLCIPHER_CRYPTO_CC"), .define("SQLITE_TEMP_STORE", to: "3"),
 .define("SQLITE_THREADSAFE", to: "1"), .define("SQLITE_OMIT_LOAD_EXTENSION"),
 .unsafeFlags(["-fvisibility=hidden"])], linkerSettings: [.linkedFramework("Security"), .linkedFramework("CoreFoundation")])])
