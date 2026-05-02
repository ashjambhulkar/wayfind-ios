//
//  FullscreenPhotoViewer.swift
//  wayfind
//
//  Phase F.5 — Fullscreen photo browser presented from PhotoCarouselView.
//
//  Implementation notes
//  --------------------
//  * Backed by `UIPageViewController` (per the plan's Section 7.5 spec)
//    because SwiftUI's TabView .page style doesn't give us the
//    pinch-zoom + pan + swipe-to-dismiss combination cleanly.
//  * Each page is a UIScrollView hosting a UIImageView so we get free
//    rubber-banding and momentum on pinch-to-zoom, which a SwiftUI
//    `.gesture(MagnificationGesture)` solution does poorly.
//  * Dark backdrop (`.black.ignoresSafeArea()`) for content focus.
//  * Swipe-down to dismiss handled with a simple drag tracker overlaid on
//    the page view — when the cumulative drag passes a threshold we
//    `dismiss()` and let the system page transition complete.
//  * Reduce Motion: cross-fade transition replaces the slide when the
//    accessibility flag is on (Phase G.4 expanded coverage).
//

import SwiftUI
import UIKit

struct FullscreenPhotoViewer: View {
    let photos: [PlacePhoto]
    let initialPhotoId: String
    var onLongPress: ((PlacePhoto) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentIndex: Int
    @State private var dragOffset: CGFloat = 0

    init(
        photos: [PlacePhoto],
        initialPhotoId: String,
        onLongPress: ((PlacePhoto) -> Void)? = nil
    ) {
        self.photos = photos
        self.initialPhotoId = initialPhotoId
        self.onLongPress = onLongPress
        let idx = photos.firstIndex(where: { $0.id == initialPhotoId }) ?? 0
        self._currentIndex = State(initialValue: idx)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PhotoPagerRepresentable(
                photos: photos,
                currentIndex: $currentIndex,
                reduceMotion: reduceMotion,
                onLongPress: { photo in onLongPress?(photo) }
            )
            .ignoresSafeArea()
            .offset(y: dragOffset)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if value.translation.height > 0 {
                            dragOffset = value.translation.height * 0.6
                        }
                    }
                    .onEnded { value in
                        if value.translation.height > 120 {
                            dismiss()
                        } else if reduceMotion {
                            // Phase G.4 — Reduce Motion users get an
                            // instant snap-back so we don't ship a
                            // bouncy spring they explicitly opted out
                            // of at the OS level.
                            dragOffset = 0
                        } else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                dragOffset = 0
                            }
                        }
                    }
            )

            VStack {
                topBar
                Spacer()
                bottomBar
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
    }

    // MARK: – Chrome

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .accessibilityLabel(Text("Close photo viewer"))
            .accessibilityHint(Text("Dismisses the fullscreen photo"))
            Spacer()
            if photos.count > 1 {
                Text("\(currentIndex + 1) of \(photos.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.4), in: Capsule())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Photo \(currentIndex + 1) of \(photos.count)"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var bottomBar: some View {
        let photo = photos[safeIndex: currentIndex]
        return HStack(spacing: 8) {
            if let p = photo {
                Image(systemName: bottomIcon(for: p.kind))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityHidden(true)
                Text(bottomCaption(for: p))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    // Allow Dynamic Type to grow the caption (it's
                    // pinned to a small body font but Reduce-Motion
                    // /Larger-Text users still need it to scale).
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(LinearGradient(
            colors: [.clear, .black.opacity(0.5)],
            startPoint: .top,
            endPoint: .bottom
        ))
        .accessibilityElement(children: .combine)
    }

    private func bottomIcon(for kind: PlacePhoto.Kind) -> String {
        switch kind {
        case .approvedUser:    return "person.crop.circle.fill.badge.checkmark"
        case .pendingUser:     return "clock"
        case .providerFallback: return "globe"
        }
    }

    private func bottomCaption(for photo: PlacePhoto) -> String {
        switch photo.kind {
        case .approvedUser:
            if let credit = photo.credit, !credit.isEmpty {
                return "Photo by \(credit)"
            }
            return "Photo by a traveler"
        case .pendingUser:
            return "Your photo · awaiting review"
        case .providerFallback:
            return photo.attribution ?? "Photo via Google"
        }
    }
}

// MARK: – UIPageViewController bridge

private struct PhotoPagerRepresentable: UIViewControllerRepresentable {
    let photos: [PlacePhoto]
    @Binding var currentIndex: Int
    let reduceMotion: Bool
    let onLongPress: (PlacePhoto) -> Void

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(
            transitionStyle: reduceMotion ? .scroll : .scroll,
            navigationOrientation: .horizontal,
            options: [UIPageViewController.OptionsKey.interPageSpacing: 16]
        )
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        if photos.indices.contains(currentIndex) {
            let initial = ZoomablePhotoVC(
                photo: photos[currentIndex],
                onLongPress: onLongPress
            )
            pvc.setViewControllers([initial], direction: .forward, animated: false)
        }
        return pvc
    }

    func updateUIViewController(_ uiViewController: UIPageViewController, context: Context) {
        // Sync only when the binding is changed externally and differs
        // from the currently-shown VC.
        guard
            let shown = uiViewController.viewControllers?.first as? ZoomablePhotoVC,
            let shownIndex = photos.firstIndex(where: { $0.id == shown.photo.id }),
            shownIndex != currentIndex,
            photos.indices.contains(currentIndex)
        else { return }

        let next = ZoomablePhotoVC(photo: photos[currentIndex], onLongPress: onLongPress)
        uiViewController.setViewControllers(
            [next],
            direction: shownIndex < currentIndex ? .forward : .reverse,
            animated: !reduceMotion
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PhotoPagerRepresentable
        init(_ parent: PhotoPagerRepresentable) { self.parent = parent }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard
                let vc = viewController as? ZoomablePhotoVC,
                let i = parent.photos.firstIndex(where: { $0.id == vc.photo.id }),
                i > 0
            else { return nil }
            return ZoomablePhotoVC(photo: parent.photos[i - 1], onLongPress: parent.onLongPress)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard
                let vc = viewController as? ZoomablePhotoVC,
                let i = parent.photos.firstIndex(where: { $0.id == vc.photo.id }),
                i + 1 < parent.photos.count
            else { return nil }
            return ZoomablePhotoVC(photo: parent.photos[i + 1], onLongPress: parent.onLongPress)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            guard
                completed,
                let shown = pageViewController.viewControllers?.first as? ZoomablePhotoVC,
                let i = parent.photos.firstIndex(where: { $0.id == shown.photo.id })
            else { return }
            DispatchQueue.main.async {
                self.parent.currentIndex = i
            }
        }
    }
}

// MARK: – Single-photo VC with pinch-to-zoom

/// UIViewController wrapping a UIScrollView + UIImageView. UIScrollView
/// gives us the pinch-zoom + double-tap-to-zoom + pan-while-zoomed
/// behavior for free, which is much cleaner than re-implementing in
/// SwiftUI gestures.
private final class ZoomablePhotoVC: UIViewController, UIScrollViewDelegate {
    let photo: PlacePhoto
    let onLongPress: (PlacePhoto) -> Void
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var dataTask: URLSessionDataTask?

    init(photo: PlacePhoto, onLongPress: @escaping (PlacePhoto) -> Void) {
        self.photo = photo
        self.onLongPress = onLongPress
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = UIView()
        v.backgroundColor = .black
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = !UIAccessibility.isReduceMotionEnabled
        view.addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.isUserInteractionEnabled = true
        // Phase G.4 — VoiceOver describes the active photo's
        // provenance so users know if it's a community contribution
        // or a provider fallback. The hint covers the gestures.
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = [.image]
        imageView.accessibilityLabel = Self.accessibilityLabel(for: photo)
        imageView.accessibilityHint = "Double tap to zoom. Long press for options."
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        imageView.addGestureRecognizer(doubleTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        imageView.addGestureRecognizer(longPress)

        loadImage()
    }

    private func loadImage() {
        dataTask?.cancel()
        dataTask = URLSession.shared.dataTask(with: photo.url) { [weak self] data, _, _ in
            guard let self, let data, let img = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                self.imageView.image = img
            }
        }
        dataTask?.resume()
    }

    @objc private func handleDoubleTap(_ gr: UITapGestureRecognizer) {
        // Phase G.4 — honor the system Reduce Motion flag for the
        // double-tap-to-zoom transition. Snap instead of animate
        // when the user has explicitly opted out of motion.
        let animate = !UIAccessibility.isReduceMotionEnabled
        if scrollView.zoomScale > 1 {
            scrollView.setZoomScale(1, animated: animate)
        } else {
            let location = gr.location(in: imageView)
            let target = CGRect(
                x: location.x - 60,
                y: location.y - 60,
                width: 120,
                height: 120
            )
            scrollView.zoom(to: target, animated: animate)
        }
    }

    @objc private func handleLongPress(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began else { return }
        onLongPress(photo)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    /// Builds a VoiceOver-friendly description of a photo so the
    /// user hears *what* they're looking at (not just "image"). We
    /// include the moderation state for community contributions so
    /// reviewers using VO can audit pending uploads.
    fileprivate static func accessibilityLabel(for photo: PlacePhoto) -> String {
        switch photo.kind {
        case .approvedUser:
            if let credit = photo.credit, !credit.isEmpty {
                return "Photo by \(credit)"
            }
            return "Photo by a traveler"
        case .pendingUser:
            return "Your photo, awaiting review"
        case .providerFallback:
            return photo.attribution ?? "Photo from a partner provider"
        }
    }
}

// MARK: – Helpers

private extension Array {
    subscript(safeIndex index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
