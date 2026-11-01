import PencilKit
import SwiftUI

struct DrawingSurface: UIViewRepresentable {
    let image: UIImage
    @Binding var drawing: PKDrawing
    @Binding var crop: CGRect?
    let appliedCrop: CGRect?
    let cropping: Bool
    let canvas: PKCanvasView
    let lineWidth: CGFloat

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
              let overlay = content.viewWithTag(3) as? CropOverlay else { return }
        let scale = EditorModel.canvasScale(for: CGSize(width: cgImage.width, height: cgImage.height))
        let size = CGSize(width: CGFloat(cgImage.width) * scale, height: CGFloat(cgImage.height) * scale)
        let visible = cropping ? CGRect(origin: .zero, size: size) : (appliedCrop?.applying(CGAffineTransform(scaleX: scale, y: scale)) ?? CGRect(origin: .zero, size: size))
        if content.bounds.size != visible.size || imageView.frame.origin != CGPoint(x: -visible.minX, y: -visible.minY) {
            content.frame = CGRect(origin: .zero, size: visible.size)
            imageView.frame = CGRect(origin: CGPoint(x: -visible.minX, y: -visible.minY), size: size)
            canvas.frame = imageView.frame
            overlay.frame = imageView.frame
            scroll.contentSize = visible.size
            let fit = min(scroll.bounds.width / visible.width, scroll.bounds.height / visible.height)
            if fit > 0 {
                scroll.minimumZoomScale = fit
                scroll.zoomScale = fit
            }
        }
        imageView.image = image
        if canvas.drawing != drawing {
            canvas.drawing = drawing
        }
        overlay.rect = crop?.applying(CGAffineTransform(scaleX: scale, y: scale))
        overlay.isHidden = !cropping
        canvas.isUserInteractionEnabled = !cropping
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

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
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
        context.setFillColor(UIColor.black.withAlphaComponent(0.4).cgColor)
        context.addRect(bounds)
        context.addRect(rect)
        context.drawPath(using: .eoFill)
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(3)
        context.stroke(rect)
        context.setFillColor(UIColor.white.cgColor)
        for point in corners(rect) {
            context.fillEllipse(in: CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20))
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
    private var fittedSize = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let content = viewWithTag(1), content.bounds.width > 0, content.bounds.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        if fittedSize != content.bounds.size {
            fittedSize = content.bounds.size
            let fit = min(bounds.width / fittedSize.width, bounds.height / fittedSize.height)
            minimumZoomScale = fit
            zoomScale = fit
        }
    }
}
