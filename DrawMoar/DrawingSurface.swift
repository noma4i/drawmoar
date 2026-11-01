import PencilKit
import SwiftUI

struct DrawingSurface: UIViewRepresentable {
    let image: UIImage
    @Binding var drawing: PKDrawing
    @Binding var crop: CGRect?
    let cropping: Bool
    let canvas: PKCanvasView
    let lineWidth: CGFloat
    @Binding var pickerHeight: CGFloat

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
        overlay.changed = { rect in context.coordinator.parent.crop = rect }
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
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        if content.bounds.size != size {
            content.frame = CGRect(origin: .zero, size: size)
            imageView.frame = content.bounds
            canvas.frame = content.bounds
            overlay.frame = content.bounds
            scroll.contentSize = size
            let fit = min(scroll.bounds.width / size.width, scroll.bounds.height / size.height)
            if fit > 0 {
                scroll.minimumZoomScale = fit
                scroll.zoomScale = fit
            }
        }
        imageView.image = image
        if canvas.drawing != drawing {
            canvas.drawing = drawing
        }
        overlay.rect = crop
        overlay.isHidden = !cropping
        canvas.isUserInteractionEnabled = !cropping
        overlay.setNeedsDisplay()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, PKCanvasViewDelegate, PKToolPickerObserver {
        var parent: DrawingSurface
        let picker = PKToolPicker()
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
                let adjusted = EditorModel.inkingTool(tool, width: parent.lineWidth)
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

        func toolPickerFramesObscuredDidChange(_: PKToolPicker) {
            updatePickerHeight()
        }

        func toolPickerVisibilityDidChange(_: PKToolPicker) {
            updatePickerHeight()
        }

        private func updatePickerHeight() {
            guard let window = parent.canvas.window else { return }
            let frame = picker.frameObscured(in: window)
            let height = frame.isNull ? 0 : max(0, window.bounds.maxY - frame.minY - window.safeAreaInsets.bottom)
            if parent.pickerHeight != height {
                DispatchQueue.main.async { self.parent.pickerHeight = height }
            }
        }
    }
}

final class CropOverlay: UIView {
    var rect: CGRect?
    var changed: ((CGRect) -> Void)?
    private var corner = 0
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
            corner = corners(rect).enumerated().min { a, b in
                hypot(a.element.x - point.x, a.element.y - point.y) < hypot(b.element.x - point.x, b.element.y - point.y)
            }?.offset ?? 0
        }
        let opposite = corners(initial)[3 - corner]
        let x = min(max(point.x, bounds.minX), bounds.maxX)
        let y = min(max(point.y, bounds.minY), bounds.maxY)
        let next = CGRect(x: min(x, opposite.x), y: min(y, opposite.y), width: abs(x - opposite.x), height: abs(y - opposite.y))
        if next.width >= 1, next.height >= 1 {
            self.rect = next; changed?(next); setNeedsDisplay()
        }
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
