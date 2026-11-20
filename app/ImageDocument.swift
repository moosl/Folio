import AppKit
import ImageIO
import UniformTypeIdentifiers

protocol WorkspaceDocument: AnyObject {
    var url: URL? { get }
    var title: String { get }
    var dirty: Bool { get }
    func reconcile()
}

final class FittedImageView: NSImageView {
    var didResize: (() -> Void)?
    override var intrinsicContentSize: NSSize { NSSize(width:NSView.noIntrinsicMetric,height:NSView.noIntrinsicMetric) }
    override func setFrameSize(_ newSize:NSSize) {
        super.setFrameSize(newSize)
        didResize?()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        didResize?()
    }
}

final class ImageDocument: WorkspaceDocument {
    let location: URL
    var url: URL? { location }
    var title: String { location.lastPathComponent }
    let dirty = false
    let view = FittedImageView()
    private(set) var dimensions = ""
    var status: String { L(statusKey) }
    private var statusKey = "Image Preview"
    private var revision: FileRevision?
    private var pixels = NSSize.zero
    private var nativeSize = NSSize.zero
    private var decodedLimit = 0
    private var visible = false
    private var resizeJob: DispatchWorkItem?


    static func supports(_ url: URL) -> Bool {
        UTType(filenameExtension:url.pathExtension)?.conforms(to:.image) == true
    }

    init(_ url: URL) throws {
        location = url
        view.imageScaling = .scaleProportionallyDown
        view.imageAlignment = .alignCenter
        view.animates = true
        view.setAccessibilityLabel(url.lastPathComponent)
        for axis in [NSLayoutConstraint.Orientation.horizontal,.vertical] {
            view.setContentCompressionResistancePriority(.defaultLow,for:axis)
            view.setContentHuggingPriority(.defaultLow,for:axis)
        }
        view.didResize = { [weak self] in self?.scheduleResize() }
        try reload()
    }

    private var desiredLimit: Int {
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        guard view.bounds.width > 0, view.bounds.height > 0, nativeSize.width > 0, nativeSize.height > 0 else { return 1024 }
        let fit = min(1,view.bounds.width/nativeSize.width,view.bounds.height/nativeSize.height)
        let longest = max(nativeSize.width,nativeSize.height)*fit*scale
        return max(256,Int(ceil(longest/256))*256)
    }
    private func scheduleResize() {
        guard visible, decodedLimit > 0 else { return }
        let limit = desiredLimit
        guard limit > decodedLimit || limit*2 <= decodedLimit else { return }
        resizeJob?.cancel()
        let job = DispatchWorkItem { [weak self] in
            guard let self, self.visible else { return }
            self.reconcile()
        }
        resizeJob = job
        DispatchQueue.main.asyncAfter(deadline:.now()+0.12,execute:job)
    }
    func show() {
        visible = true
        reconcile()
    }
    func hide() {
        visible = false
        resizeJob?.cancel(); resizeJob = nil
        view.image = nil
        decodedLimit = 0
    }

    private func reload() throws {
        let current = try FileRevision(location)
        let limit = desiredLimit
        if current == revision {
            if !visible { return }
            if view.image != nil, decodedLimit == 0 || (limit <= decodedLimit && limit*2 > decodedLimit) { return }
        }
        var image: NSImage?
        decodedLimit = 0
        let options = [kCGImageSourceShouldCache:false] as CFDictionary
        if location.pathExtension.lowercased() != "svg",
           let source = CGImageSourceCreateWithURL(location as CFURL,options),
           let info = CGImageSourceCopyPropertiesAtIndex(source,0,options) as? [CFString:Any],
           let w = info[kCGImagePropertyPixelWidth] as? Int, let h = info[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 {
            let rotated = (5...8).contains(info[kCGImagePropertyOrientation] as? Int ?? 1)
            pixels = NSSize(width:rotated ? h : w,height:rotated ? w : h)
            let dpiX = (info[kCGImagePropertyDPIWidth] as? Double) ?? 72
            let dpiY = (info[kCGImagePropertyDPIHeight] as? Double) ?? 72
            let width = Double(w)*72/(dpiX > 0 ? dpiX : 72), height = Double(h)*72/(dpiY > 0 ? dpiY : 72)
            nativeSize = NSSize(width:rotated ? height : width,height:rotated ? width : height)
            let target = desiredLimit
            if visible, max(w,h) > target, CGImageSourceGetCount(source) == 1 {
                let settings = [kCGImageSourceCreateThumbnailFromImageAlways:true,
                                kCGImageSourceCreateThumbnailWithTransform:true,
                                kCGImageSourceShouldCacheImmediately:true,
                                kCGImageSourceThumbnailMaxPixelSize:target] as CFDictionary
                if let thumb = CGImageSourceCreateThumbnailAtIndex(source,0,settings) {
                    let representation = NSBitmapImageRep(cgImage:thumb)
                    representation.size = nativeSize
                    let fitted = NSImage(size:nativeSize)
                    fitted.cacheMode = .never
                    fitted.addRepresentation(representation)
                    image = fitted
                    decodedLimit = target
                }
            }
        } else { pixels = .zero; nativeSize = .zero }
        // Preserve the native representations for animated images, SVG and small rasters.
        if (visible || pixels == .zero) && image == nil {
            guard let original = NSImage(contentsOf:location), original.isValid else {
                throw NSError(domain:"Folio.Image",code:1,userInfo:[NSLocalizedDescriptionKey:L("Unable to read this image. It may be damaged or in an unsupported format.")])
            }
            if pixels == .zero { pixels = original.size }
            if visible { image = original }
        }
        view.image = image
        dimensions = "\(Int(pixels.width.rounded())) × \(Int(pixels.height.rounded()))"
        statusKey = "Image Preview"
        revision = current
    }

    func reconcile() {
        do { try reload() }
        catch {
            view.image = nil; revision = nil; decodedLimit = 0
            dimensions = ""
            statusKey = FileManager.default.fileExists(atPath:location.path) ? "Unable to read image" : "Image removed"
        }
    }
}
