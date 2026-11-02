import Foundation
import os

enum Log {
    private static let logger = Logger(subsystem: "com.sanfordliu.DockBar", category: "app")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    /// The message is public. The path is not, so home-directory locations stay out of the unified log.
    static func error(_ message: String, path: String) {
        logger.error("\(message, privacy: .public) \(path, privacy: .private)")
    }
}
