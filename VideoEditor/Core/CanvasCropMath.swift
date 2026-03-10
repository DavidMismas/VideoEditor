import CoreGraphics

nonisolated enum CanvasCropMath {
    struct CropPresentation {
        let contentSize: CGSize
        let offset: CGSize
    }

    static func defaultNormalizedCropRect(sourceAspect: CGFloat, canvasAspect: CGFloat) -> CGRect {
        let safeSourceAspect = max(sourceAspect, 0.001)
        let safeCanvasAspect = max(canvasAspect, 0.001)

        if abs(safeSourceAspect - safeCanvasAspect) < 0.0001 {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        if safeSourceAspect > safeCanvasAspect {
            let width = min(max(safeCanvasAspect / safeSourceAspect, 0.05), 1.0)
            return CGRect(x: (1.0 - width) * 0.5, y: 0, width: width, height: 1.0)
        } else {
            let height = min(max(safeSourceAspect / safeCanvasAspect, 0.05), 1.0)
            return CGRect(x: 0, y: (1.0 - height) * 0.5, width: 1.0, height: height)
        }
    }

    static func fittedNormalizedCropRect(_ rect: CGRect?, sourceAspect: CGFloat, canvasAspect: CGFloat) -> CGRect {
        guard let rect else {
            return defaultNormalizedCropRect(sourceAspect: sourceAspect, canvasAspect: canvasAspect)
        }

        let safeSourceAspect = max(sourceAspect, 0.001)
        let safeCanvasAspect = max(canvasAspect, 0.001)
        let normalizedRatio = safeCanvasAspect / safeSourceAspect
        let minWidth: CGFloat = 0.08
        let minHeight: CGFloat = 0.08

        var width = min(max(rect.width, minWidth), 1.0)
        var height = width / normalizedRatio
        if height > 1.0 {
            height = 1.0
            width = height * normalizedRatio
        }
        if height < minHeight {
            height = minHeight
            width = min(height * normalizedRatio, 1.0)
        }

        let centerX = rect.midX
        let centerY = rect.midY
        var originX = centerX - (width * 0.5)
        var originY = centerY - (height * 0.5)
        originX = min(max(originX, 0.0), 1.0 - width)
        originY = min(max(originY, 0.0), 1.0 - height)

        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    static func presentation(for cropRect: CGRect, sourceAspect: CGFloat, canvasSize: CGSize) -> CropPresentation {
        let safeCanvasWidth = max(canvasSize.width, 1)
        let safeCanvasHeight = max(canvasSize.height, 1)
        let safeSourceAspect = max(sourceAspect, 0.001)
        let safeCanvasAspect = safeCanvasWidth / safeCanvasHeight
        let fittedCropRect = fittedNormalizedCropRect(
            cropRect,
            sourceAspect: safeSourceAspect,
            canvasAspect: safeCanvasAspect
        )

        let normalizedSourceSize = CGSize(width: safeSourceAspect, height: 1.0)
        let cropWidth = max(fittedCropRect.width * normalizedSourceSize.width, 0.001)
        let cropHeight = max(fittedCropRect.height, 0.001)
        let scale = max(safeCanvasWidth / cropWidth, safeCanvasHeight / cropHeight)
        let contentSize = CGSize(
            width: normalizedSourceSize.width * scale,
            height: normalizedSourceSize.height * scale
        )
        let offset = CGSize(
            width: -(fittedCropRect.minX * normalizedSourceSize.width * scale) + ((safeCanvasWidth - (cropWidth * scale)) * 0.5),
            height: -(fittedCropRect.minY * scale) + ((safeCanvasHeight - (cropHeight * scale)) * 0.5)
        )

        return CropPresentation(contentSize: contentSize, offset: offset)
    }
}
