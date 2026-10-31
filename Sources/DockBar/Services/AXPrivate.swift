import ApplicationServices
import Darwin
import Foundation

enum AXPrivate {
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32

    private static let getWindow: GetWindow? = {
        let path = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        guard let handle = dlopen(path, RTLD_LAZY),
              let symbol = dlsym(handle, "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()

    static func windowID(for element: AXUIElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var identifier: UInt32 = 0
        let status = getWindow(element, &identifier)
        return status == 0 && identifier != 0 ? identifier : nil
    }
}
