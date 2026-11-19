import AppKit
import SwiftUI

@main
enum Main {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--verify") {
            VerifyRunner.launch()
        } else {
            if Preview.isActive { Preview.prepare() }
            FlatGridApp.main()
        }
    }
}
