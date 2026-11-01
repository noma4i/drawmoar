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
        guard let cgImage = image.cgImage else { throw RenderError.invalidImage }
        let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let scale = EditorModel.canvasScale(for: bounds.size)
        let fullDrawing = drawing.transformed(using: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        let rect = (crop ?? bounds).intersection(bounds).integral
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { throw RenderError.invalidCrop }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            UIImage(cgImage: cgImage).draw(in: bounds)
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                fullDrawing.image(from: bounds, scale: 1).draw(in: bounds)
            }
        }
        guard let data = rendered.pngData() else { throw RenderError.encoding }
        return data
    }
}
