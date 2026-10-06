import Foundation
import QuartzCore
import Observation

/// One frame loop for every avatar on screen (the web's ticker): a display
/// link on iOS and a main-run-loop timer on macOS advance each rig and bump
/// `frame`, so the whole screen redraws in one pass. It stops while idle.
@Observable
public final class BotAvatarClock {
    public static let shared = BotAvatarClock()

    /// Bumped once per display frame; a view that reads it redraws each frame.
    public private(set) var frame = 0
    /// Seconds between the last two frames.
    @ObservationIgnored public private(set) var dt = 0.0
    /// Frames per second over the last second, for the demo.
    @ObservationIgnored public private(set) var fps = 0.0

    #if os(macOS)
    @ObservationIgnored private var timer: Timer?
    #else
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var proxy: LinkProxy?
    #endif
    @ObservationIgnored private var last: CFTimeInterval = 0
    @ObservationIgnored private var subs: [ObjectIdentifier: (Double) -> Void] = [:]
    @ObservationIgnored private var fpsCount = 0
    @ObservationIgnored private var fpsSince: CFTimeInterval = 0

    private init() {}

    /// Called before each frame with the seconds since the last one.
    func subscribe(_ id: ObjectIdentifier, _ tick: @escaping (Double) -> Void) {
        subs[id] = tick
        start()
    }
    func unsubscribe(_ id: ObjectIdentifier) {
        subs.removeValue(forKey: id)
        if subs.isEmpty { stop() }
    }

    private func start() {
        #if os(macOS)
        if timer != nil { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.step(at: ProcessInfo.processInfo.systemUptime)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        last = 0
        #else
        if link != nil { return }
        let proxy = LinkProxy { [weak self] link in self?.step(link) }
        self.proxy = proxy
        let l = CADisplayLink(target: proxy, selector: #selector(LinkProxy.fire(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        last = 0
        #endif
    }
    private func stop() {
        #if os(macOS)
        timer?.invalidate()
        timer = nil
        #else
        link?.invalidate()
        link = nil
        proxy = nil
        #endif
    }

    #if !os(macOS)
    private func step(_ link: CADisplayLink) {
        step(at: link.timestamp)
    }
    #endif

    private func step(at now: CFTimeInterval) {
        let dt = last > 0 ? min(0.1, now - last) : 0
        last = now
        self.dt = dt
        fpsCount += 1
        if fpsSince == 0 { fpsSince = now }
        if now - fpsSince >= 1 {
            fps = Double(fpsCount) / (now - fpsSince)
            fpsCount = 0
            fpsSince = now
        }
        for tick in subs.values { tick(dt) }
        frame &+= 1
    }

    /// Frame-cost bookkeeping for the demo: CPU seconds spent in the rigs
    /// and in canvas recording this frame, and how many avatars drew.
    @ObservationIgnored public var stats = BotAvatarStats()
}

/// CPU time the avatars took, accumulated by the views; read and reset by whoever measures.
public struct BotAvatarStats {
    public var tickSeconds = 0.0
    public var drawSeconds = 0.0
    public var draws = 0
    public var ticks = 0
    public mutating func reset() { self = BotAvatarStats() }
}

#if !os(macOS)
private final class LinkProxy: NSObject {
    let fn: (CADisplayLink) -> Void
    init(_ fn: @escaping (CADisplayLink) -> Void) { self.fn = fn }
    @objc func fire(_ link: CADisplayLink) { fn(link) }
}
#endif

/// The pointer the avatars follow, in the global coordinate space (the
/// web's page pointer): nil while no finger is down. A `BotAvatar` sets it
/// from its own drag while `interactive`; `.botAvatarPointer()` on a larger
/// view sets it from a drag anywhere over that view.
public final class BotAvatarPointer {
    public static let shared = BotAvatarPointer()
    public var location: CGPoint? = nil
    private init() {}
}
