import AVFoundation
import QuartzCore
import SwiftUI

public struct PlayerView: View {
    private let session: PlayerSession

    public init(session: PlayerSession) {
        self.session = session
    }

    public var body: some View {
        PlayerSurface(session: session)
            .background(Color.black)
    }
}

@MainActor
final class PlayerSurfaceCore {
    let display = AVSampleBufferDisplayLayer()
    private var bound: PlayerSession?
    private var link: CADisplayLink?

    init() {
        display.videoGravity = .resizeAspect
        display.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    func bind(_ session: PlayerSession) {
        guard bound !== session else { return }
        let renderer = display.sampleBufferRenderer
        if let bound {
            bound.detach(renderer)
            bound.setVsyncActive(false)
        }
        bound = session
        session.attach(renderer)
        session.setVsyncActive(link != nil)
    }

    func unbind() {
        stopLink()
        bound?.detach(display.sampleBufferRenderer)
        bound = nil
    }

    func startLink(_ link: CADisplayLink) {
        stopLink()
        link.add(to: .main, forMode: .common)
        self.link = link
        bound?.setVsyncActive(true)
    }

    func stopLink() {
        link?.invalidate()
        link = nil
        bound?.setVsyncActive(false)
    }

    func step(_ link: CADisplayLink) {
        bound?.vsync(targetNs: UInt64(max(0, link.targetTimestamp) * 1e9))
    }

    func layout(_ bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        display.frame = bounds
        CATransaction.commit()
    }
}

#if os(macOS)
import AppKit

final class PlayerSurfaceView: NSView {
    let core = PlayerSurfaceCore()

    init(session: PlayerSession) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer?.addSublayer(core.display)
        core.bind(session)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        core.layout(bounds)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            core.stopLink()
        } else {
            core.startLink(displayLink(target: self, selector: #selector(step(_:))))
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        core.step(link)
    }
}

struct PlayerSurface: NSViewRepresentable {
    let session: PlayerSession

    func makeNSView(context: Context) -> PlayerSurfaceView {
        PlayerSurfaceView(session: session)
    }

    func updateNSView(_ view: PlayerSurfaceView, context: Context) {
        view.core.bind(session)
    }

    static func dismantleNSView(_ view: PlayerSurfaceView, coordinator: ()) {
        view.core.unbind()
    }
}
#else
import UIKit

final class PlayerSurfaceView: UIView {
    let core = PlayerSurfaceCore()

    init(session: PlayerSession) {
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(core.display)
        core.bind(session)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        core.layout(bounds)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            core.stopLink()
        } else {
            core.startLink(CADisplayLink(target: self, selector: #selector(step(_:))))
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        core.step(link)
    }
}

struct PlayerSurface: UIViewRepresentable {
    let session: PlayerSession

    func makeUIView(context: Context) -> PlayerSurfaceView {
        PlayerSurfaceView(session: session)
    }

    func updateUIView(_ view: PlayerSurfaceView, context: Context) {
        view.core.bind(session)
    }

    static func dismantleUIView(_ view: PlayerSurfaceView, coordinator: ()) {
        view.core.unbind()
    }
}
#endif
