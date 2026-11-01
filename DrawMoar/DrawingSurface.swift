import CompanionKit
import PencilKit
import SwiftUI

struct DrawingSurface: UIViewRepresentable {
    let image: UIImage
    @Binding var drawing: PKDrawing
    @Binding var crop: CGRect?
    let appliedCrop: CGRect?
    let cropping: Bool
    let selectingWindow: Bool
    let windows: [WindowFrame]
    let selectWindow: (CGPoint, Bool) -> Void
    let canvas: PKCanvasView
    let lineWidth: CGFloat
    let setUsingTool: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = ImageScrollView()
        scroll.delegate = context.coordinator
        scroll.maximumZoomScale = 4
        scroll.backgroundColor = .secondarySystemBackground
        let content = UIView()
        content.tag = 1
        content.clipsToBounds = true
        scroll.addSubview(content)
        let imageView = UIImageView()
        imageView.tag = 2
        content.addSubview(imageView)
        canvas.overrideUserInterfaceStyle = .light
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.drawingPolicy = .anyInput
        canvas.delegate = context.coordinator
        content.addSubview(canvas)
        let overlay = CropOverlay()
        overlay.tag = 3
        overlay.changed = { rect in
            let scale = context.coordinator.canvasScale
            context.coordinator.parent.crop = rect.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        }
        content.addSubview(overlay)
        let windowOverlay = WindowOverlay()
        windowOverlay.tag = 4
        windowOverlay.selected = { point, confirm in
            let scale = context.coordinator.canvasScale
            context.coordinator.parent.selectWindow(CGPoint(x: point.x / scale, y: point.y / scale), confirm)
        }
        content.addSubview(windowOverlay)
        context.coordinator.picker.colorUserInterfaceStyle = .light
        context.coordinator.picker.setVisible(true, forFirstResponder: canvas)
        context.coordinator.picker.addObserver(canvas)
        context.coordinator.picker.addObserver(context.coordinator)
        canvas.becomeFirstResponder()
        context.coordinator.applyWidth()
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyWidth()
        guard let cgImage = image.cgImage, let content = scroll.viewWithTag(1),
              let imageView = content.viewWithTag(2) as? UIImageView,
              let overlay = content.viewWithTag(3) as? CropOverlay,
              let windowOverlay = content.viewWithTag(4) as? WindowOverlay else { return }
        let scale = EditorModel.canvasScale(for: CGSize(width: cgImage.width, height: cgImage.height))
        let size = CGSize(width: CGFloat(cgImage.width) * scale, height: CGFloat(cgImage.height) * scale)
        let visible = cropping || selectingWindow ? CGRect(origin: .zero, size: size) : (appliedCrop?.applying(CGAffineTransform(scaleX: scale, y: scale)) ?? CGRect(origin: .zero, size: size))
        if let scroll = scroll as? ImageScrollView, scroll.prepareImage(image, visible: visible, imageSize: size) {
            content.frame = CGRect(origin: .zero, size: visible.size)
            imageView.frame = CGRect(origin: CGPoint(x: -visible.minX, y: -visible.minY), size: size)
            canvas.frame = imageView.frame
            overlay.frame = imageView.frame
            windowOverlay.frame = imageView.frame
            scroll.fitImage()
        }
        imageView.image = image
        if canvas.drawing != drawing {
            canvas.drawing = drawing
        }
        overlay.rect = crop?.applying(CGAffineTransform(scaleX: scale, y: scale))
        overlay.isHidden = !cropping
        windowOverlay.selection = crop?.applying(CGAffineTransform(scaleX: scale, y: scale))
        windowOverlay.isHidden = !selectingWindow
        windowOverlay.setNeedsDisplay()
        canvas.isUserInteractionEnabled = !cropping && !selectingWindow
        overlay.setNeedsDisplay()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, PKCanvasViewDelegate, PKToolPickerObserver {
        var parent: DrawingSurface
        let picker = PKToolPicker()
        var canvasScale: CGFloat {
            guard let image = parent.image.cgImage else { return 1 }
            return EditorModel.canvasScale(for: CGSize(width: image.width, height: image.height))
        }

        init(_ parent: DrawingSurface) {
            self.parent = parent
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            scrollView.viewWithTag(1)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            scrollView.viewWithTag(3)?.setNeedsDisplay()
            scrollView.viewWithTag(4)?.setNeedsDisplay()
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
        }

        func canvasViewDidBeginUsingTool(_: PKCanvasView) {
            parent.setUsingTool(true)
        }

        func canvasViewDidEndUsingTool(_: PKCanvasView) {
            parent.setUsingTool(false)
        }

        func applyWidth() {
            if let tool = canvasInkingTool() {
                let adjusted = EditorModel.inkingTool(tool, width: parent.lineWidth, scale: canvasScale)
                if (parent.canvas.tool as? PKInkingTool) != adjusted {
                    parent.canvas.tool = adjusted
                }
            }
        }

        private func canvasInkingTool() -> PKInkingTool? {
            if #available(iOS 18.0, *) {
                return (picker.selectedToolItem as? PKToolPickerInkingItem)?.inkingTool
            }
            return picker.selectedTool as? PKInkingTool
        }

        func toolPickerSelectedToolItemDidChange(_: PKToolPicker) {
            applyWidth()
        }

        func toolPickerSelectedToolDidChange(_: PKToolPicker) {
            applyWidth()
        }
    }
}

final class WindowOverlay: UIView {
    var selection: CGRect?
    var selected: ((CGPoint, Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
        addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func draw(_: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let zoom = (superview?.superview as? UIScrollView)?.zoomScale ?? 1
        if let selection {
            context.setFillColor(UIColor.systemBlue.withAlphaComponent(0.25).cgColor)
            context.fill(selection)
            context.setStrokeColor(UIColor.systemBlue.cgColor)
            context.setLineWidth(3 / max(zoom, 0.01))
            context.stroke(selection)
        }
    }

    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        selected?(gesture.location(in: self), gesture.numberOfTapsRequired == 2)
    }
}

final class CropOverlay: UIView {
    var rect: CGRect?
    var changed: ((CGRect) -> Void)?
    private var corner: Int?
    private var moving = false
    private var initial = CGRect.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func draw(_ bounds: CGRect) {
        guard let rect, let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(UIColor.systemGray.withAlphaComponent(0.4).cgColor)
        context.addRect(bounds)
        context.addRect(rect)
        context.drawPath(using: .eoFill)
        let zoom = (superview?.superview as? UIScrollView)?.zoomScale ?? 1
        let unit = 1 / max(zoom, 0.01)
        context.setShadow(offset: .zero, blur: 2 * unit, color: UIColor.label.resolvedColor(with: traitCollection).cgColor)
        context.setStrokeColor(UIColor.systemBackground.resolvedColor(with: traitCollection).cgColor)
        context.setLineWidth(1.5 * unit)
        context.stroke(rect)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        for (index, point) in corners(rect).enumerated() {
            let dx: CGFloat = index % 2 == 0 ? 1 : -1
            let dy: CGFloat = index < 2 ? 1 : -1
            let path = CGMutablePath()
            path.move(to: CGPoint(x: point.x + dx * 24 * unit, y: point.y))
            path.addLine(to: point)
            path.addLine(to: CGPoint(x: point.x, y: point.y + dy * 24 * unit))
            context.addPath(path)
            context.setStrokeColor(UIColor.label.resolvedColor(with: traitCollection).cgColor)
            context.setLineWidth(6 * unit)
            context.strokePath()
            context.addPath(path)
            context.setStrokeColor(UIColor.systemBackground.resolvedColor(with: traitCollection).cgColor)
            context.setLineWidth(4 * unit)
            context.strokePath()
        }
    }

    private func corners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
    }

    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        guard let rect else { return }
        let point = gesture.location(in: self)
        if gesture.state == .began {
            initial = rect
            let zoom = (superview?.superview as? UIScrollView)?.zoomScale ?? 1
            let hitRadius = 22 / max(zoom, 0.01)
            corner = corners(rect).enumerated().first { hypot($0.element.x - point.x, $0.element.y - point.y) <= hitRadius }?.offset
            moving = corner == nil && rect.contains(point)
        }
        let next: CGRect
        if moving {
            let delta = gesture.translation(in: self)
            let x = min(max(initial.minX + delta.x, bounds.minX), bounds.maxX - initial.width)
            let y = min(max(initial.minY + delta.y, bounds.minY), bounds.maxY - initial.height)
            next = CGRect(x: x, y: y, width: initial.width, height: initial.height)
        } else if let corner {
            let minimum = min(44, bounds.width, bounds.height)
            let left = corner == 0 || corner == 2
            let top = corner == 0 || corner == 1
            let x = left ? min(max(point.x, bounds.minX), initial.maxX - minimum) : max(min(point.x, bounds.maxX), initial.minX + minimum)
            let y = top ? min(max(point.y, bounds.minY), initial.maxY - minimum) : max(min(point.y, bounds.maxY), initial.minY + minimum)
            let opposite = corners(initial)[3 - corner]
            next = CGRect(x: min(x, opposite.x), y: min(y, opposite.y), width: abs(x - opposite.x), height: abs(y - opposite.y))
        } else {
            return
        }
        self.rect = next
        changed?(next)
        setNeedsDisplay()
    }
}

final class ImageScrollView: UIScrollView {
    private var image: UIImage?
    private var visible = CGRect.zero
    private var imageSize = CGSize.zero
    private var fittedBounds = CGSize.zero

    static func fit(area: CGSize, visible: CGRect) -> (zoomScale: CGFloat, contentOffset: CGPoint) {
        let zoom = min(area.width / visible.width, area.height / visible.height)
        return (zoom, CGPoint(x: visible.minX * zoom - (area.width - visible.width * zoom) / 2,
                              y: visible.minY * zoom - (area.height - visible.height * zoom) / 2))
    }

    func prepareImage(_ image: UIImage, visible: CGRect, imageSize: CGSize) -> Bool {
        guard self.image !== image || self.visible != visible || self.imageSize != imageSize else { return false }
        self.image = image
        self.visible = visible
        self.imageSize = imageSize
        minimumZoomScale = min(minimumZoomScale, 1)
        zoomScale = 1
        return true
    }

    func fitImage() {
        guard visible.width > 0, visible.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        fittedBounds = bounds.size
        let fit = Self.fit(area: bounds.size, visible: CGRect(origin: .zero, size: visible.size))
        maximumZoomScale = max(4, fit.zoomScale)
        minimumZoomScale = fit.zoomScale
        zoomScale = fit.zoomScale
        contentSize = CGSize(width: visible.width * fit.zoomScale, height: visible.height * fit.zoomScale)
        contentInset = UIEdgeInsets(top: max(0, -fit.contentOffset.y), left: max(0, -fit.contentOffset.x), bottom: max(0, -fit.contentOffset.y), right: max(0, -fit.contentOffset.x))
        contentOffset = fit.contentOffset
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if fittedBounds != bounds.size {
            fitImage()
        }
    }
}
