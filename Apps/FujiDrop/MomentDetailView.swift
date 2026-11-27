import FujiDropKit
import SwiftUI
import UIKit

/// All frames of one moment, full width, top to bottom. Tap a frame to zoom.
struct MomentDetailView: View {
    @ObservedObject var model: ImportModel
    let ids: [String]
    @AppStorage("showGroupingDetails") private var showDetails = false
    @State private var viewing: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(ids, id: \.self) { id in
                    PreviewImage(shot: model.shots[id])
                        .aspectRatio(model.aspect(id, clamped: false), contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .bottomLeading) {
                            if showDetails { PhotoLabel(title: details(id)) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { viewing = id }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { viewing.map { Viewing(id: $0) } }, set: { viewing = $0?.id })) { v in
            PreviewSheet(shot: model.shots[v.id])
        }
    }

    private var title: String {
        let time = ids.first.flatMap { model.shots[$0]?.date }?.formatted(date: .omitted, time: .shortened) ?? ""
        return ids.count == 1 ? time : "\(time) · \(ids.count) frames"
    }

    /// Calibration info: file name, time gap and visual distance from the previous frame.
    private func details(_ id: String) -> String {
        let step = model.stepFromPrevious(id)
        var parts = [id]
        if let gap = step.gap { parts.append(String(format: "+%.0f s", gap)) }
        if let d = step.distance { parts.append(String(format: "Δ %.2f", d)) }
        return parts.joined(separator: " · ")
    }

    private struct Viewing: Identifiable { let id: String }
}

/// The full 1920×1280 preview, zoomable.
private struct PreviewSheet: View {
    let shot: ImportModel.Shot?
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    ZoomableImage(image: image)
                } else {
                    Text("Preview not loaded yet").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .background(.black)
            .navigationTitle(shot?.id ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .task(id: shot?.previewURL) {
            image = shot?.previewURL.flatMap { UIImage(contentsOfFile: $0.path) }
        }
    }
}

/// Pinch and double-tap zoom backed by UIScrollView, so the zoom anchors on the pinch centre and
/// continues from the current scale (SwiftUI's MagnifyGesture restarts at 1.0 for each pinch).
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomingScrollView { ZoomingScrollView(image: image) }

    func updateUIView(_ view: ZoomingScrollView, context: Context) { view.setImage(image) }
}

final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var laidOutSize: CGSize = .zero

    init(image: UIImage) {
        super.init(frame: .zero)
        imageView.image = image
        addSubview(imageView)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        bouncesZoom = true
        decelerationRate = .fast
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
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
        // Fit the image to the view at zoom 1 whenever the view size changes (first layout, rotation).
        if bounds.size != laidOutSize, bounds.width > 0, bounds.height > 0 {
            laidOutSize = bounds.size
            zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: fittedSize())
            contentSize = imageView.frame.size
            centerContent()
            contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
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

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }

    @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        // Zoom to 2.5× centred on the tapped point.
        let point = tap.location(in: imageView)
        let size = CGSize(width: bounds.width / 2.5, height: bounds.height / 2.5)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                        width: size.width, height: size.height), animated: true)
    }
}
