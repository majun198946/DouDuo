import SwiftUI
import QuartzCore

// MARK: - 抖音式实时弹幕引擎
//
// 老板要的抖音行为：
//   1. 长弹幕跑得快、短弹幕跑得慢（每条用固定的「过屏时长」，而不是固定速度）；
//   2. 字体大一点；
//   3. 快进/拖动：清空屏上弹幕，从新位置重新出；
//   4. 开头不卡。
//
// 原来的做法：把整条视频的弹幕一次性排好（预先算每条的轨道和出场时刻），渲染层按时钟去「查表」。
// 长视频的弹幕是分段到达的（30 秒一段），每到一段就整片重排一次、并把屏上所有图层清掉重放，
// 于是开头几秒（各段陆续到达时）弹幕一跳一跳、一卡一卡。
//
// 现在改成实时调度（跟抖音一样）：
//   - 只维护「此刻在屏上的弹幕」。每帧看下一条该出场的弹幕，找一条右侧已腾出空位的轨道放进去；
//   - 新数据到了只是并入「待出场队列」，不影响已经在飞的弹幕；
//   - 每条一旦出场，它自己的起点和速度就固定，位置 = 起点 - (now - 出场时刻) × 自己的速度，绝不回头修；
//   - 跳转/暂停后重新开始就清屏，从当前时间往后排。

enum DYDanmakuStyle {
    /// 抖音的弹幕比原来大一号（原来 15）
    static let fontSize: CGFloat = 17
    static let laneHeight: CGFloat = 32
    /// 一条弹幕从右边进屏到左边完全出屏用的时间：短的偏慢、长的偏快（抖音观感）
    /// 过屏时长按长度线性插值：屏宽的弹幕约 8.5s，宽度为屏宽 60% 以上的长弹幕约 6.0s
    static func travelSeconds(width: CGFloat, screen: CGFloat) -> Double {
        let ratio = Double(max(0, min(1, width / max(screen * 0.6, 1))))
        return 8.5 - 2.5 * ratio
    }
    /// 同一条轨道上后一条与前一条的最小间距（pt）
    static let gap: CGFloat = 24
    /// 待出场的弹幕最多能晚多少秒出来（轨道一直满就丢掉，跟抖音一样）
    static let maxDelay: Double = 2.5
}

/// 一条正在屏上飞的弹幕
private struct DYFlying {
    let id: String
    let layer: CALayer
    let width: CGFloat
    let lane: Int
    let born: Double        // 出场时的视频时间
    let speed: CGFloat      // pt / 视频秒
    let screen: CGFloat
    func x(at t: Double) -> CGFloat { screen - CGFloat(t - born) * speed }
    /// 尾巴完全进屏、并且留够间距的时刻：之后同轨道才能放下一条（并且考虑后一条更快会追上）
    func tailX(at t: Double) -> CGFloat { x(at: t) + width }
}

final class DYDanmakuEngineView: UIView {
    private let clip = CALayer()
    private var queue: [DYDanmaku] = []        // 已拉到的全部弹幕（按 offset 排序）；跳回前面时从这里重排
    private var queued = Set<String>()        // 已收进 queue 的 id，防重复
    private var cursor = 0                    // queue 中下一条要看的位置
    private var done = Set<String>()          // 本轮（上次清屏后）已出场或已丢弃的 id
    private var flying: [DYFlying] = []
    private var pool: [CALayer] = []
    private var images: [String: CGImage] = [:]
    private var sizes: [String: CGSize] = [:]
    private var lastShown: [String: Double] = [:]   // 去重：同文本 10s 内不重复
    private var link: CADisplayLink?
    private var clock = DYDanmakuClock()
    private var lanes = 0
    private var lastT: Double = -1
    private var deduplicate = true
    private var maxPerSecond = 4
    private var spawnedAt: [Double] = []      // 最近一秒的出场时刻（限流）
    // 后台预渲染：文字光栅化是主线程突发热点，弹幕一进队列就提前在后台渲染好，
    // spawn 时直接命中缓存，主线程不再突发 UIGraphicsImageRenderer 光栅化。
    private var prerendered = Set<String>()
    private let renderQueue = DispatchQueue(label: "douduo.danmaku.render", qos: .userInitiated, attributes: .concurrent)
    // 诊断
    private var lastTS: CFTimeInterval = 0
    private var gaps: [Double] = []
    private var maxOn = 0
    private var spawned = 0
    private var dropped = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clip.masksToBounds = true
        layer.addSublayer(clip)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(items: [DYDanmaku], clock c: DYDanmakuClock, regionTop: CGFloat, regionHeight: CGFloat,
                lanes l: Int, density: DYDanmakuPolicy.Density, deduplicate dd: Bool) {
        let jumped = c.epoch != clock.epoch
        clock = c
        lanes = l
        deduplicate = dd
        maxPerSecond = density.maxPerSecond * 3   // 抖音密度：每秒能出的条数比原来宽
        CATransaction.begin(); CATransaction.setDisableActions(true)
        clip.frame = CGRect(x: 0, y: regionTop, width: bounds.width, height: regionHeight)
        CATransaction.commit()
        merge(items)
        if jumped { restart(at: clock.now(Date())) }
        if clock.playing { start() } else { stop() }
        render(clock.now(Date()))
    }

    /// 新到的弹幕并入队列；已经在飞的不受影响，过去时间点的不倒着补（跟抖音一样）
    private func merge(_ items: [DYDanmaku]) {
        let fresh = items.filter { $0.offset.isFinite && $0.offset >= 0 && !$0.id.isEmpty && !queued.contains($0.id) }
        guard !fresh.isEmpty else { return }
        for d in fresh {
            queued.insert(d.id)
            prerender(d)   // 后台预渲染文字，出场时主线程直接命中缓存
        }
        let resumeFrom = cursor < queue.count ? queue[cursor].offset : (lastT >= 0 ? lastT : 0)
        // 增量合并：queue 已按 (offset, id) 有序，逐条二分插入 fresh，避免每次 chunk 到达都全量 O(n log n) 重排。
        // 长视频弹幕分段到达时，这是主线程的一次性热点（之前整片重排会让开头几秒弹幕一卡一卡）。
        for d in fresh {
            let idx = insertionIndex(of: d, in: queue)
            queue.insert(d, at: idx)
        }
        cursor = queue.firstIndex { $0.offset >= resumeFrom } ?? queue.count
    }

    /// 二分查找 d 应插入的位置，维持 (offset 升序, 同 offset 按 id 升序) 的有序性。
    private func insertionIndex(of d: DYDanmaku, in sorted: [DYDanmaku]) -> Int {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let m = sorted[mid]
            let before = m.offset < d.offset || (m.offset == d.offset && m.id < d.id)
            if before { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// 跳转/重新开始：清屏，从 t 往后排
    private func restart(at t: Double) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for f in flying { f.layer.removeFromSuperlayer(); pool.append(f.layer) }
        CATransaction.commit()
        flying.removeAll()
        spawnedAt.removeAll()
        lastShown.removeAll()
        done.removeAll()
        // 从新位置往后排（抖音：快进/拖动后清屏，从当前时间重新出）
        cursor = queue.firstIndex { $0.offset >= t } ?? queue.count
        lastT = t
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop() } else if clock.playing { start() }
    }

    private func start() {
        guard link == nil, window != nil else { return }
        let l = CADisplayLink(target: DYDanmakuEngineTick(self), selector: #selector(DYDanmakuEngineTick.tick(_:)))
        // 上限 60Hz：120Hz 每帧跑主线程刷新弹幕纯属浪费——弹幕移动是匀速线性，
        // 60 帧已足够平滑，减半主线程 tick 频率能明显降低播放中的掉帧压力。
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
        lastTS = 0
    }

    func stop() { link?.invalidate(); link = nil }

    fileprivate func tick(_ l: CADisplayLink) {
        if lastTS > 0 {
            gaps.append(l.timestamp - lastTS)
            if gaps.count >= 480 {
                let avg = gaps.reduce(0, +) / Double(gaps.count)
                let over = gaps.filter { $0 > 0.02 }.count
                let p95 = gaps.sorted()[Int(Double(gaps.count) * 0.95)]
                DYLiveModel.log("DDDMFRAME fps=\(Int(1 / max(avg, 0.001))) p95=\(Int(p95 * 1000))ms over20ms=\(over)/\(gaps.count) maxOnScreen=\(maxOn) spawned=\(spawned) dropped=\(dropped) queue=\(queue.count - cursor) engine=live")
                gaps.removeAll(); maxOn = 0; spawned = 0; dropped = 0
            }
        }
        lastTS = l.timestamp
        let lead = l.targetTimestamp - CACurrentMediaTime()
        render(clock.now(Date().addingTimeInterval(max(0, lead))))
    }

    private func render(_ t: Double) {
        let w = bounds.width
        guard w > 0 else { return }
        // 时间倒退（不是用户跳转，比如循环回开头）：清屏重排
        if lastT >= 0, t + 0.5 < lastT { restart(at: t) }
        lastT = t
        CATransaction.begin(); CATransaction.setDisableActions(true)
        spawn(upTo: t, screen: w)
        var keep: [DYFlying] = []
        keep.reserveCapacity(flying.count)
        for f in flying {
            let x = f.x(at: t)
            if x + f.width < 0 {
                f.layer.removeFromSuperlayer(); pool.append(f.layer)
                continue
            }
            let s = f.layer.contentsScale
            f.layer.position = CGPoint(x: (x * s).rounded() / s, y: CGFloat(f.lane) * DYDanmakuStyle.laneHeight)
            keep.append(f)
        }
        flying = keep
        maxOn = max(maxOn, flying.count)
        CATransaction.commit()
    }

    /// 让到点的弹幕出场：找右侧空出来、而且不会被追尾的轨道
    private func spawn(upTo t: Double, screen: CGFloat) {
        guard lanes > 0 else { cursor = queue.count; return }
        spawnedAt.removeAll { t - $0 > 1 }
        while cursor < queue.count, queue[cursor].offset <= t {
            let d = queue[cursor]
            cursor += 1
            if done.contains(d.id) { continue }
            if t - d.offset > DYDanmakuStyle.maxDelay { done.insert(d.id); dropped += 1; continue }   // 太迟了，丢掉
            let key = DYDanmakuPolicy.normalized(d.text)
            if key.isEmpty { continue }
            if deduplicate, let last = lastShown[key], d.offset - last < 10 { done.insert(d.id); continue }
            if spawnedAt.count >= maxPerSecond { cursor -= 1; break }   // 这一秒满了，下一帧再看
            let size = measure(d)
            let travel = DYDanmakuStyle.travelSeconds(width: size.width, screen: screen)
            let speed = (screen + size.width) / CGFloat(travel)
            guard let lane = freeLane(at: t, width: size.width, speed: speed, screen: screen) else {
                // 轨道都满：先放回队列，下一帧再试（最多等 maxDelay）
                cursor -= 1
                break
            }
            let layer = pool.popLast() ?? CALayer()
            layer.anchorPoint = .zero
            layer.contentsScale = UIScreen.main.scale
            layer.contents = image(for: d)
            layer.bounds = CGRect(origin: .zero, size: size)
            layer.position = CGPoint(x: screen, y: CGFloat(lane) * DYDanmakuStyle.laneHeight)
            clip.addSublayer(layer)
            flying.append(DYFlying(id: d.id, layer: layer, width: size.width, lane: lane, born: t, speed: speed, screen: screen))
            lastShown[key] = d.offset
            done.insert(d.id)
            spawnedAt.append(t)
            spawned += 1
        }
    }

    /// 一条轨道能放：上一条的尾巴已经离开右边缘至少 gap，且新的（可能更快）在上一条离屏之前追不上它
    private func freeLane(at t: Double, width: CGFloat, speed: CGFloat, screen: CGFloat) -> Int? {
        var lastOn = [DYFlying?](repeating: nil, count: lanes)
        for f in flying where f.lane < lanes {
            if let cur = lastOn[f.lane], cur.born >= f.born { continue }
            lastOn[f.lane] = f
        }
        for lane in 0..<lanes {
            guard let prev = lastOn[lane] else { return lane }
            let tail = prev.tailX(at: t)
            guard tail + DYDanmakuStyle.gap <= screen else { continue }
            if speed > prev.speed {
                // 新的更快：算它追上前一条尾巴的时刻，必须晚于前一条完全离开左边
                let prevExit = Double((prev.x(at: t) + prev.width) / prev.speed)          // 前一条还要多久离屏
                let catchUp = Double((screen - tail - DYDanmakuStyle.gap) / (speed - prev.speed))
                if catchUp < prevExit { continue }
            }
            return lane
        }
        return nil
    }

    private func measure(_ d: DYDanmaku) -> CGSize {
        if let s = sizes[d.id] { return s }
        _ = image(for: d)
        return sizes[d.id] ?? CGSize(width: 60, height: DYDanmakuStyle.laneHeight)
    }

    /// 后台预渲染：文字光栅化挪到后台队列，渲染结果回主线程写缓存。
    /// spawn 时若缓存已命中，主线程零光栅化开销；未命中则由 image(for:) 同步兜底，保证正确性。
    private func prerender(_ d: DYDanmaku) {
        guard !prerendered.contains(d.id), images[d.id] == nil else { return }
        prerendered.insert(d.id)
        renderQueue.async { [weak self] in
            guard let (img, size) = Self.renderText(d.text) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                if self.images[d.id] == nil { self.images[d.id] = img }
                if self.sizes[d.id] == nil { self.sizes[d.id] = size }
            }
        }
    }

    private func image(for d: DYDanmaku) -> CGImage? {
        if let i = images[d.id] { return i }
        if images.count > 800 { images.removeAll(); sizes.removeAll() }
        guard let (img, size) = Self.renderText(d.text) else { return nil }
        images[d.id] = img
        sizes[d.id] = size
        return img
    }

    /// 纯函数：把弹幕文本光栅化成带阴影的 CGImage + 实际尺寸。线程无关，可在后台队列调用。
    private static func renderText(_ text: String) -> (CGImage, CGSize)? {
        let font = UIFont.systemFont(ofSize: DYDanmakuStyle.fontSize, weight: .semibold)
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = CGSize(width: 0, height: 1)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: UIColor.white.withAlphaComponent(0.95), .shadow: shadow,
        ]
        let s = text as NSString
        let size = s.size(withAttributes: attrs)
        let pad: CGFloat = 3
        let box = CGSize(width: ceil(size.width) + pad * 2, height: ceil(size.height) + pad * 2)
        let fmt = UIGraphicsImageRendererFormat.preferred()
        fmt.opaque = false
        let img = UIGraphicsImageRenderer(size: box, format: fmt).image { _ in
            s.draw(at: CGPoint(x: pad, y: pad), withAttributes: attrs)
        }
        guard let cg = img.cgImage else { return nil }
        return (cg, box)
    }
}

/// CADisplayLink 强引用 target：弱引用中转，视图销毁不泄漏
private final class DYDanmakuEngineTick: NSObject {
    weak var view: DYDanmakuEngineView?
    init(_ v: DYDanmakuEngineView) { view = v }
    @objc func tick(_ l: CADisplayLink) {
        guard let view else { l.invalidate(); return }
        MainActor.assumeIsolated { view.tick(l) }
    }
}

struct DYDanmakuLiveSurface: UIViewRepresentable {
    let items: [DYDanmaku]
    let clock: DYDanmakuClock
    let regionTop: CGFloat
    let regionHeight: CGFloat
    let lanes: Int
    let density: DYDanmakuPolicy.Density
    let deduplicate: Bool

    func makeUIView(context: Context) -> DYDanmakuEngineView { DYDanmakuEngineView() }
    func updateUIView(_ v: DYDanmakuEngineView, context: Context) {
        v.update(items: items, clock: clock, regionTop: regionTop, regionHeight: regionHeight,
                 lanes: lanes, density: density, deduplicate: deduplicate)
    }
    static func dismantleUIView(_ v: DYDanmakuEngineView, coordinator: ()) { v.stop() }
}
