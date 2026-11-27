import SwiftUI
import UIKit

/// Where a zoomable image is looking: zoom scale (1 = fit) and the visible centre in image
/// coordinates (0…1). Independent of view and image size, so it can be shared between panes.
struct Viewport: Equatable {
    var zoom: CGFloat
    var center: CGPoint

    static let fit = Viewport(zoom: 1, center: CGPoint(x: 0.5, y: 0.5))
}

/// Locks zoom and pan across several zoomable images (the compare view). A pane that loads a
/// new image later picks up the group's current viewport.
@MainActor
final class ZoomGroup {
    private(set) var viewport: Viewport?
    private var members: [Member] = []

    private struct Member { weak var view: ZoomingScrollView? }

    func register(_ view: ZoomingScrollView) {
        members.removeAll { $0.view == nil || $0.view === view }
        members.append(Member(view: view))
    }

    func changed(_ viewport: Viewport, by source: ZoomingScrollView, animated: Bool) {
        self.viewport = viewport
        for member in members {
            if let view = member.view, view !== source { view.apply(viewport, animated: animated) }
        }
    }
}

/// Pinch and double-tap zoom backed by UIScrollView, so the zoom anchors on the pinch centre and
/// continues from the current scale (SwiftUI's MagnifyGesture restarts at 1.0 for each pinch).
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    var group: ZoomGroup?
    /// Maximum zoom over fit. Panes in one group should share it so they stay in step.
    var maxZoom: CGFloat = 4
    /// Horizontal swipe while not zoomed in: +1 for next (swipe left), -1 for previous.
    var onSwipe: ((Int) -> Void)?

    func makeUIView(context: Context) -> ZoomingScrollView {
        ZoomingScrollView(image: image, group: group, maxZoom: maxZoom)
    }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        view.setImage(image)
        view.maximumZoomScale = maxZoom
        view.onSwipe = onSwipe
    }
}

final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {
    weak var group: ZoomGroup?
    private let imageView = UIImageView()
    private var laidOutSize: CGSize = .zero
    /// Set while applying a viewport from the group, so the change isn't echoed back.
    private var applying = false
    var onSwipe: ((Int) -> Void)?
    private let swipeLeft = UISwipeGestureRecognizer()
    private let swipeRight = UISwipeGestureRecognizer()
    private let swipeDelegate = SwipeDelegate()

    init(image: UIImage, group: ZoomGroup?, maxZoom: CGFloat) {
        super.init(frame: .zero)
        self.group = group
        imageView.image = image
        addSubview(imageView)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = maxZoom
        bouncesZoom = true
        decelerationRate = .fast
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        // Swipes step between frames, only at fit zoom (when zoomed, a drag pans instead).
        swipeDelegate.shouldBegin = { [weak self] in
            guard let self else { return false }
            return self.onSwipe != nil && self.zoomScale <= self.minimumZoomScale + 0.01
        }
        for (swipe, direction) in [(swipeLeft, UISwipeGestureRecognizer.Direction.left), (swipeRight, .right)] {
            swipe.direction = direction
            swipe.delegate = swipeDelegate
            swipe.addTarget(self, action: #selector(swiped(_:)))
            addGestureRecognizer(swipe)
        }
        group?.register(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setImage(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        laidOutSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Fit the image to the view at zoom 1 whenever the view size or image changes.
        if bounds.size != laidOutSize, bounds.width > 0, bounds.height > 0 {
            laidOutSize = bounds.size
            zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: fittedSize())
            contentSize = imageView.frame.size
            centerContent()
            contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
            if let shared = group?.viewport { apply(shared, animated: false) }
        }
    }

    private func fittedSize() -> CGSize {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else { return .zero }
        let s = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: size.width * s, height: size.height * s)
    }

    /// Keep the image centred while it is smaller than the view (letterboxing, or zooming out).
    private func centerContent() {
        let x = max(0, (bounds.width - contentSize.width) / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        let inset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        if contentInset != inset { contentInset = inset }
    }

    // MARK: Viewport

    var viewport: Viewport {
        guard contentSize.width > 0, contentSize.height > 0 else { return .fit }
        return Viewport(zoom: zoomScale,
                        center: CGPoint(x: (contentOffset.x + bounds.width / 2) / contentSize.width,
                                        y: (contentOffset.y + bounds.height / 2) / contentSize.height))
    }

    func apply(_ target: Viewport, animated: Bool) {
        guard contentSize.width > 0 else { return }
        applying = true
        let change = {
            self.zoomScale = min(max(target.zoom, self.minimumZoomScale), self.maximumZoomScale)
            self.centerContent()
            let x = target.center.x * self.contentSize.width - self.bounds.width / 2
            let y = target.center.y * self.contentSize.height - self.bounds.height / 2
            self.contentOffset = CGPoint(
                x: min(max(x, -self.contentInset.left), max(-self.contentInset.left, self.contentSize.width - self.bounds.width + self.contentInset.right)),
                y: min(max(y, -self.contentInset.top), max(-self.contentInset.top, self.contentSize.height - self.bounds.height + self.contentInset.bottom)))
        }
        if animated {
            UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut], animations: change) { _ in
                self.applying = false
            }
        } else {
            change()
            applying = false
        }
    }

    /// Shares the current viewport with the group when the user moved this pane.
    private func report(force: Bool = false) {
        guard let group, !applying,
              force || isTracking || isDragging || isDecelerating || isZooming || isZoomBouncing else { return }
        group.changed(viewport, by: self, animated: false)
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        report()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { report() }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        report(force: true)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { report(force: true) }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { report(force: true) }
    }

    @objc private func swiped(_ swipe: UISwipeGestureRecognizer) {
        onSwipe?(swipe === swipeLeft ? 1 : -1)
    }

    @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
        let target: Viewport
        if zoomScale > minimumZoomScale {
            target = .fit
        } else {
            // Zoom to 2.5× centred on the tapped point.
            let p = tap.location(in: imageView)
            let size = imageView.bounds.size
            guard size.width > 0, size.height > 0 else { return }
            target = Viewport(zoom: 2.5, center: CGPoint(x: p.x / size.width, y: p.y / size.height))
        }
        apply(target, animated: true)
        group?.changed(target, by: self, animated: true)
    }
}

/// Lets the frame swipes begin only at fit zoom and run alongside the scroll view's own pan.
private final class SwipeDelegate: NSObject, UIGestureRecognizerDelegate {
    var shouldBegin: () -> Bool = { false }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        shouldBegin()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
