import AppKit
import SwiftUI

/// App shell. The window and menu bar are owned by AppKit so they exist deterministically at
/// launch; everything inside the window is SwiftUI plus the AppKit grid and viewer.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var browserWindow: NSWindow?
    private var settingsWindow: NSWindow?

    private var services: AppServices { AppServices.shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        openBrowserWindow()
        services.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openBrowserWindow() }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Windows

    private func openBrowserWindow() {
        if let browserWindow {
            browserWindow.makeKeyAndOrderFront(nil)
            return
        }
        let root = RootView()
            .environmentObject(services.model)
            .environmentObject(services.settings)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "FlatGrid"
        window.contentView = hosting
        window.setContentSize(NSSize(width: 1280, height: 820))
        window.minSize = NSSize(width: 780, height: 500)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        window.setFrameAutosaveName("FlatGridMainWindow")
        window.delegate = self
        services.attach(window)
        browserWindow = window
        window.makeKeyAndOrderFront(nil)
        // Keys go to the browser, not the search field, until the user asks for search.
        DispatchQueue.main.async { [weak window] in window?.makeFirstResponder(nil) }
    }

    @objc func showSettings(_ sender: Any?) {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let content = SettingsView()
            .environmentObject(services.model)
            .environmentObject(services.settings)
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.title = "FlatGrid Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Menu actions

    @objc func addFolder(_ sender: Any?) {
        openBrowserWindow()
        services.chooseFolders()
    }

    @objc func rescan(_ sender: Any?) { services.model.rescan() }

    @objc func showShortcuts(_ sender: Any?) {
        openBrowserWindow()
        services.model.showShortcuts = true
    }

    @objc func toggleInterface(_ sender: Any?) { services.model.interfaceHidden.toggle() }

    @objc func toggleFavoritesOnly(_ sender: Any?) { services.model.favoritesOnly.toggle() }

    @objc func showBrowser(_ sender: Any?) { openBrowserWindow() }

    // MARK: Menu bar

    private func buildMenu() {
        let main = NSMenu()

        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        @discardableResult
        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                 _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            menu.addItem(item)
            return item
        }

        let app = submenu("FlatGrid")
        add(app, "About FlatGrid", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        add(app, "Settings…", #selector(showSettings(_:)), ",", target: self)
        app.addItem(.separator())
        add(app, "Hide FlatGrid", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, "Quit FlatGrid", #selector(NSApplication.terminate(_:)), "q")

        let file = submenu("File")
        add(file, "Add Folder…", #selector(addFolder(_:)), "o", target: self)
        add(file, "Rescan Folders", #selector(rescan(_:)), "r", [.command, .shift], target: self)
        file.addItem(.separator())
        add(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")

        let edit = submenu("Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")

        let view = submenu("View")
        add(view, "Show or Hide Interface", #selector(toggleInterface(_:)), target: self)
        add(view, "Favorites Only", #selector(toggleFavoritesOnly(_:)), target: self)
        view.addItem(.separator())
        add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        let window = submenu("Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        add(window, "FlatGrid", #selector(showBrowser(_:)), "0", target: self)
        NSApp.windowsMenu = window

        let help = submenu("Help")
        add(help, "Keyboard Shortcuts", #selector(showShortcuts(_:)), "/", target: self)
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }
}

enum FlatGridApp {
    private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
