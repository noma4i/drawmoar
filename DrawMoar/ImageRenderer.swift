import PencilKit
import UIKit

enum ImageRenderer {
    enum RenderError: Error { case invalidImage, invalidCrop, encoding }

    static func png(image: UIImage, drawing: PKDrawing, crop: CGRect?) throws -> Data {
        guard let cgImage = image.cgImage else { throw RenderError.invalidImage }
        let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let rect = (crop ?? bounds).intersection(bounds).integral
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { throw RenderError.invalidCrop }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            UIImage(cgImage: cgImage).draw(in: bounds)
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                drawing.image(from: bounds, scale: 1).draw(in: bounds)
            }
        }
        guard let data = rendered.pngData() else { throw RenderError.encoding }
        return data
    }
}
