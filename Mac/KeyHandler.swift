import AppKit

/// Keyboard map for the browser window. One place, so the grid and the viewer behave the same.
@MainActor
final class KeyHandler {
    weak var services: AppServices?
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let services, let window = services.window, event.window === window,
              window.attachedSheet == nil else { return false }
        let model = services.model
        let settings = services.settings
        let code = event.keyCode
        let flags = event.modifierFlags.intersection([.command, .option, .control])

        // Typing in the search field: only Escape and Return are ours.
        if window.firstResponder is NSTextView {
            if code == 53 {
                if !model.searchText.isEmpty { model.searchText = "" }
                services.focusGrid()
                return true
            }
            if code == 36 || code == 76 {
                services.focusGrid()
                return true
            }
            return false
        }

        if flags == .command {
            switch code {
            case 126:
                Feedback.play(model.jumpFolder(forward: false) ? .move : .edge, settings: settings)
                return true
            case 125:
                Feedback.play(model.jumpFolder(forward: true) ? .move : .edge, settings: settings)
                return true
            default:
                return false
            }
        }
        guard flags.isEmpty else { return false }

        let viewerOpen = model.viewerIndex != nil
        switch code {
        case 123:
            Feedback.play(model.step(-1) ? .move : .edge, settings: settings)
            return true
        case 124:
            Feedback.play(model.step(1) ? .move : .edge, settings: settings)
            return true
        case 126:
            guard !viewerOpen else { return true }
            Feedback.play(model.step(-(services.grid?.columns ?? 1)) ? .move : .edge, settings: settings)
            return true
        case 125:
            guard !viewerOpen else { return true }
            Feedback.play(model.step(services.grid?.columns ?? 1) ? .move : .edge, settings: settings)
            return true
        case 49:
            if viewerOpen {
                model.closeViewer()
                Feedback.play(.close, settings: settings)
            } else if let index = model.selectedIndex ?? (model.visible.isEmpty ? nil : 0) {
                model.open(index)
                Feedback.play(.open, settings: settings)
            }
            return true
        case 36, 76:
            if !viewerOpen, let index = model.selectedIndex {
                model.open(index)
                Feedback.play(.open, settings: settings)
            }
            return true
        case 53:
            if viewerOpen {
                model.closeViewer()
                Feedback.play(.close, settings: settings)
            } else if model.showInfo {
                model.showInfo = false
            } else if !model.searchText.isEmpty {
                model.searchText = ""
            } else {
                model.selectedIndex = nil
            }
            return true
        case 48:
            model.interfaceHidden.toggle()
            Feedback.play(.toggle, settings: settings)
            return true
        default:
            break
        }

        guard let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1 else { return false }
        switch characters {
        case "+", "=":
            model.adjustThumbnailSize(by: 1.18)
            return true
        case "-", "_":
            model.adjustThumbnailSize(by: 1 / 1.18)
            return true
        case "1", "2", "3", "4", "5", "6":
            if let number = Int(characters), let mode = SortMode(rawValue: number) {
                model.setSort(mode)
                model.flash("Sorted: \(mode.title)")
                Feedback.play(.toggle, settings: settings)
            }
            return true
        case "s":
            if viewerOpen { model.closeViewer() }
            if model.interfaceHidden { model.interfaceHidden = false }
            model.searchFocusRequest += 1
            return true
        case "f":
            if let item = model.currentItem { services.toggleFavorite(item) }
            return true
        case "z":
            if viewerOpen {
                model.actualSize.toggle()
            } else if let index = model.selectedIndex {
                model.open(index)
                model.actualSize = true
            }
            return true
        case "r":
            if let item = model.currentItem { services.reveal(item) }
            return true
        case "i":
            if model.currentItem != nil || model.showInfo { model.showInfo.toggle() }
            return true
        case "c":
            if let item = model.currentItem { services.copy(item) }
            return true
        case "[":
            if viewerOpen, let item = model.currentItem { model.rotate(item, clockwise: false) }
            return true
        case "]":
            if viewerOpen, let item = model.currentItem { model.rotate(item, clockwise: true) }
            return true
        default:
            return false
        }
    }
}
