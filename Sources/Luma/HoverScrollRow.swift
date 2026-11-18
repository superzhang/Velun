import SwiftUI
import AppKit
import Observation

struct HoverScrollRow<Content: View>: View {
    private let content: Content
    @State private var scrolling = HorizontalScrollState()
    @State private var hovered = false
    @FocusState private var arrowFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ScrollView(.horizontal) {
            content.background(ScrollProbe(state: scrolling).frame(width: 0, height: 0))
        }.scrollIndicators(.hidden)
            .overlay(alignment: .leading) { arrow(backward: true) }
            .overlay(alignment: .trailing) { arrow(backward: false) }
            .onHover { value in scrolling.refresh(); hovered = value }
    }
    private func arrow(backward: Bool) -> some View {
        let available = backward ? scrolling.canGoBack : scrolling.canGoForward
        return Button { scrolling.page(backward: backward, animated: !reduceMotion) } label: {
            Image(systemName: backward ? "chevron.left" : "chevron.right")
                .font(.system(size: 19, weight: .semibold)).foregroundStyle(.primary)
                .frame(width: 44, height: 64).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(LumaTheme.ink.opacity(0.18))).contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, 6)
            .opacity(available && (hovered || scrolling.hovered || arrowFocused) ? 1 : 0)
            .allowsHitTesting(available && (hovered || scrolling.hovered || arrowFocused)).disabled(!available)
            .focused($arrowFocused).accessibilityLabel(backward ? "向左浏览" : "向右浏览")
            .accessibilityHidden(!available)
    }
}

@MainActor @Observable private final class HorizontalScrollState {
    @ObservationIgnored weak var scrollView: NSScrollView?
    var hovered = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    func refresh() {
        guard let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let back = clip.bounds.minX > 1
        let forward = clip.bounds.maxX < document.frame.width - 1
        if canGoBack != back { canGoBack = back }
        if canGoForward != forward { canGoForward = forward }
    }
    func page(backward: Bool, animated: Bool) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let distance = max(1, clip.bounds.width - 80)
        let x = min(max(0, document.frame.width - clip.bounds.width), max(0, clip.bounds.minX + (backward ? -distance : distance)))
        let origin = NSPoint(x: x, y: clip.bounds.minY)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                clip.animator().setBoundsOrigin(origin)
            } completionHandler: { [weak self] in Task { @MainActor in self?.refresh() } }
        } else { clip.setBoundsOrigin(origin) }
        scrollView.reflectScrolledClipView(clip); refresh()
    }
}

private struct ScrollProbe: NSViewRepresentable {
    let state: HorizontalScrollState
    func makeNSView(context: Context) -> ProbeView { ProbeView(state: state) }
    func updateNSView(_ view: ProbeView, context: Context) { view.attach() }
    static func dismantleNSView(_ view: ProbeView, coordinator: ()) { view.detach() }
    final class ProbeView: NSView {
        let state: HorizontalScrollState
        private var tracking: NSTrackingArea?
        private weak var trackedView: NSView?
        private var scrollerObservation: NSKeyValueObservation?
        init(state: HorizontalScrollState) { self.state = state; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        override func layout() { super.layout(); attach() }
        func attach() {
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? NSScrollView {
                    if state.scrollView !== scroll {
                        NotificationCenter.default.removeObserver(self)
                        if let tracking { trackedView?.removeTrackingArea(tracking) }
                        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .enabledDuringMouseDrag, .inVisibleRect], owner: self)
                        scroll.addTrackingArea(area); tracking = area; trackedView = scroll
                        state.scrollView = scroll
                        scrollerObservation = scroll.observe(\.hasHorizontalScroller, options: [.new]) { [weak self] _, _ in
                            Task { @MainActor [weak self] in
                                guard let scroll = self?.state.scrollView, scroll.hasHorizontalScroller else { return }
                                scroll.hasHorizontalScroller = false
                            }
                        }
                        scroll.contentView.postsBoundsChangedNotifications = true
                        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
                    }
                    scroll.scrollerStyle = .overlay
                    scroll.hasHorizontalScroller = false
                    scroll.autohidesScrollers = true
                    state.refresh(); return
                }
                ancestor = view.superview
            }
        }
        override func mouseEntered(with event: NSEvent) { state.refresh(); state.hovered = true }
        override func mouseExited(with event: NSEvent) { state.hovered = false }
        func detach() {
            if let tracking { trackedView?.removeTrackingArea(tracking) }
            tracking = nil; trackedView = nil; scrollerObservation = nil
            NotificationCenter.default.removeObserver(self)
        }
        @objc private func changed(_ notification: Notification) { state.refresh() }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
