import AppKit
import SystemKit

/// An accessibility element for one section: it reads the section's title and current value on demand and presses it on request.
final class StripAccessibilityElement: NSAccessibilityElement {
    /// Accessibility asks from the main thread; the closures run there.
    nonisolated(unsafe) var title: () -> String? = { nil }
    nonisolated(unsafe) var value: () -> Any? = { nil }
    nonisolated(unsafe) var press: () -> Void = {}

    nonisolated override init() { super.init() }
    nonisolated override func accessibilityLabel() -> String? { title() }
    nonisolated override func accessibilityValue() -> Any? { value() }
    nonisolated override func accessibilityRole() -> NSAccessibility.Role? { .button }
    nonisolated override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }
}

/// The content of the single status item: the section views side by side. Clicks pass through to the button underneath,
/// which finds the section from the click position (``StripLayout/index(at:)``).
final class StripView: NSView {
    private(set) var sections: [any StripSection] = []
    private(set) var layoutModel = StripLayout(widths: [])
    private var elements: [StripAccessibilityElement] = []
    /// Called when the total width changed, so the owner can resize the status item (and only then).
    var onTotalWidthChange: ((CGFloat) -> Void)?
    /// A section asked to be pressed through accessibility.
    var onPress: ((Int) -> Void)?

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setSections(_ new: [any StripSection]) {
        for section in sections { section.view.removeFromSuperview() }
        sections = new
        elements = new.enumerated().map { index, section in
            let element = StripAccessibilityElement()
            element.title = { [weak section] in MainActor.assumeIsolated { section?.accessibilityTitle } }
            element.value = { [weak section] in MainActor.assumeIsolated { section?.accessibilityValue } }
            element.press = { [weak self] in MainActor.assumeIsolated { self?.onPress?(index) } }
            element.setAccessibilityParent(self)
            return element
        }
        for section in new {
            addSubview(section.view)
            section.onLayoutChange = { [weak self] in self?.relayout() }
            section.onValueChange = { [weak self, weak section] in
                guard let self, let section, let index = sections.firstIndex(where: { $0 === section }) else { return }
                NSAccessibility.post(element: elements[index], notification: .valueChanged)
            }
        }
        relayout(force: true)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeViews()
    }

    /// Recomputes the layout from the sections' widths. Views only move, and the item only resizes, when a width really changed.
    func relayout(force: Bool = false) {
        let new = StripLayout(widths: sections.map(\.width))
        guard force || new != layoutModel else { return }
        let widthChanged = new.totalWidth != layoutModel.totalWidth
        layoutModel = new
        placeViews()
        if widthChanged || force { onTotalWidthChange?(new.totalWidth) }
    }

    private func placeViews() {
        let height = bounds.height
        for (section, span) in zip(sections, layoutModel.spans) {
            let frame = NSRect(x: span.lowerBound, y: 0, width: span.upperBound - span.lowerBound, height: height)
            if section.view.frame != frame { section.view.frame = frame }
        }
        for (element, span) in zip(elements, layoutModel.spans) {
            element.setAccessibilityFrameInParentSpace(NSRect(x: span.lowerBound, y: 0, width: span.upperBound - span.lowerBound, height: height))
        }
    }

    var accessibilityElements: [StripAccessibilityElement] { elements }

    /// A section's rectangle in this view's coordinates, for anchoring a popover.
    func rect(of index: Int) -> NSRect {
        guard layoutModel.spans.indices.contains(index) else { return bounds }
        let span = layoutModel.spans[index]
        return NSRect(x: span.lowerBound, y: 0, width: span.upperBound - span.lowerBound, height: bounds.height)
    }
}
