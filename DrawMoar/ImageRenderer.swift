import CompanionKit
import PencilKit
import UIKit

enum ImageRenderer {
    enum RenderError: Error { case invalidImage, invalidCrop, encoding }

    static func thumbnail(image: UIImage, drawing: PKDrawing, crop: CGRect?) throws -> Data {
        guard let cgImage = image.cgImage else { throw RenderError.invalidImage }
        let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let rect = (crop ?? bounds).intersection(bounds).integral
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { throw RenderError.invalidCrop }
        let ratio = min(1, 240 / max(rect.width, rect.height))
        let canvasScale = EditorModel.canvasScale(for: bounds.size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: max(1, floor(rect.width * ratio)), height: max(1, floor(rect.height * ratio))), format: format).image { context in
            context.cgContext.scaleBy(x: ratio, y: ratio)
            context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            UIImage(cgImage: cgImage).draw(in: bounds)
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                drawing.image(from: CGRect(x: 0, y: 0, width: bounds.width * canvasScale, height: bounds.height * canvasScale), scale: ratio / canvasScale).draw(in: bounds)
            }
        }
        guard let data = rendered.pngData() else { throw RenderError.encoding }
        return data
    }

    static func png(image: UIImage, drawing: PKDrawing, crop: CGRect?) throws -> Data {
        try annotated(image: image, drawing: drawing, crop: crop, marks: [])
    }

    static let noteLongSide: CGFloat = 1600

    static func noteRegion(size: CGSize, crop: CGRect?, marks: [NoteMark]) -> (rect: CGRect, scale: CGFloat) {
        let bounds = CGRect(origin: .zero, size: size)
        if let crop {
            return (crop.intersection(bounds).integral, 1)
        }
        let boxes = marks.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        guard let first = boxes.first else {
            return (bounds, min(1, noteLongSide / max(size.width, size.height)))
        }
        let union = boxes.dropFirst().reduce(first) { $0.union($1) }
        let padding = max(64, max(union.width, union.height) * 0.15)
        return (union.insetBy(dx: -padding, dy: -padding).intersection(bounds).integral, 1)
    }

    static func noteImage(image: UIImage, drawing: PKDrawing, crop: CGRect?, marks: [NoteMark]) throws -> Data {
        guard let cgImage = image.cgImage else { throw RenderError.invalidImage }
        let region = noteRegion(size: CGSize(width: cgImage.width, height: cgImage.height), crop: crop, marks: marks)
        return try annotated(image: image, drawing: drawing, crop: region.rect, marks: marks, outputScale: region.scale)
    }

    static func annotated(image: UIImage, drawing: PKDrawing, crop: CGRect?, marks: [NoteMark], outputScale: CGFloat = 1) throws -> Data {
        guard let cgImage = image.cgImage else { throw RenderError.invalidImage }
        let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let scale = EditorModel.canvasScale(for: bounds.size)
        let fullDrawing = drawing.transformed(using: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        let rect = (crop ?? bounds).intersection(bounds).integral
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { throw RenderError.invalidCrop }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let outputSize = CGSize(width: max(1, (rect.width * outputScale).rounded()), height: max(1, (rect.height * outputScale).rounded()))
        let sx = outputSize.width / rect.width
        let sy = outputSize.height / rect.height
        let side = max(28, (max(outputSize.width, outputSize.height) * 0.035).rounded())
        let rendered = UIGraphicsImageRenderer(size: outputSize, format: format).image { context in
            context.cgContext.saveGState()
            context.cgContext.scaleBy(x: sx, y: sy)
            context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            UIImage(cgImage: cgImage).draw(in: bounds)
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                fullDrawing.image(from: rect, scale: 1).draw(in: rect)
            }
            context.cgContext.restoreGState()
            for mark in marks {
                let markX = (CGFloat(mark.x) - rect.minX) * sx
                let markY = (CGFloat(mark.y) - rect.minY) * sy
                let left = markX - side
                let top = markY - side
                let x = max(0, min(left < 0 ? markX : left, outputSize.width - side))
                let y = max(0, min(top < 0 ? markY : top, outputSize.height - side))
                let chip = CGRect(x: x, y: y, width: side, height: side)
                UIColor.white.setFill()
                UIBezierPath(ovalIn: chip).fill()
                UIColor(red: 0, green: 122 / 255, blue: 1, alpha: 1).setFill()
                UIBezierPath(ovalIn: chip.insetBy(dx: side * 0.08, dy: side * 0.08)).fill()
                let text = String(mark.number) as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: side * 0.6), .foregroundColor: UIColor.white]
                let size = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: chip.midX - size.width / 2, y: chip.midY - size.height / 2), withAttributes: attributes)
            }
        }
        guard let data = rendered.pngData() else { throw RenderError.encoding }
        return data
    }
}
