import AppKit
import QuartzCore
import OpenGL.GL3
import CMPV

/// CA may draw on a render thread. All mutable GL/mpv render state is protected by this lock.
final class MPVGLResources: @unchecked Sendable {
    let pixelFormat: CGLPixelFormatObj
    let context: CGLContextObj
    let floating: Bool
    private let lock = NSRecursiveLock()
    private var renderer: UnsafeMutableRawPointer?
    private var resourcesReleased = false
    init?(handle: UnsafeMutableRawPointer) {
        let base: [CGLPixelFormatAttribute] = [kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(rawValue: UInt32(kCGLOGLPVersion_3_2_Core.rawValue)), kCGLPFAAccelerated]
        func choose(_ float: Bool) -> CGLPixelFormatObj? {
            var format: CGLPixelFormatObj?; var count: GLint = 0
            var attributes = base + (float ? [kCGLPFAColorSize, CGLPixelFormatAttribute(rawValue: 64), kCGLPFAColorFloat, kCGLPFAAlphaSize, CGLPixelFormatAttribute(rawValue: 16)] : [kCGLPFAColorSize, CGLPixelFormatAttribute(rawValue: 24), kCGLPFAAlphaSize, CGLPixelFormatAttribute(rawValue: 8)])
            attributes.append(CGLPixelFormatAttribute(rawValue: 0))
            guard CGLChoosePixelFormat(attributes, &format, &count) == kCGLNoError else { return nil }
            return format
        }
        let high = choose(true)
        guard let format = high ?? choose(false) else { return nil }
        var created: CGLContextObj?
        guard CGLCreateContext(format, nil, &created) == kCGLNoError, let created else { CGLDestroyPixelFormat(format); return nil }
        pixelFormat = format; context = created; floating = high != nil
        let previous = CGLGetCurrentContext(); CGLSetCurrentContext(created)
        renderer = luma_render_create(handle)
        CGLSetCurrentContext(previous)
        guard renderer != nil else {
            CGLDestroyContext(created); CGLDestroyPixelFormat(format); resourcesReleased = true
            return nil
        }
    }
    func draw() {
        lock.lock(); defer { lock.unlock() }
        guard let renderer else { return }
        CGLLockContext(context); defer { CGLUnlockContext(context) }
        let previous = CGLGetCurrentContext(); CGLSetCurrentContext(context); defer { CGLSetCurrentContext(previous) }
        var framebuffer: GLint = 0
        var viewport: [GLint] = [0, 0, 0, 0]
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &framebuffer)
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)
        guard viewport[2] > 0, viewport[3] > 0 else { return }
        luma_render(renderer, viewport[2], viewport[3], floating ? 1 : 0, framebuffer)
        glFlush()
    }
    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        guard let renderer else { return }
        CGLLockContext(context); defer { CGLUnlockContext(context) }
        let previous = CGLGetCurrentContext(); CGLSetCurrentContext(context)
        luma_render_free(renderer); self.renderer = nil
        CGLSetCurrentContext(previous)
    }
    deinit {
        if !resourcesReleased { shutdown(); CGLDestroyContext(context); CGLDestroyPixelFormat(pixelFormat) }
    }
}

final class MPVColorLayer: CAOpenGLLayer, @unchecked Sendable {
    let resources: MPVGLResources?
    init(resources: MPVGLResources) {
        self.resources = resources
        super.init()
        isAsynchronous = false
        contentsFormat = resources.floating ? .RGBA16Float : .RGBA8Uint
        backgroundColor = CGColor(gray: 0, alpha: 1)
    }
    override init(layer: Any) {
        resources = (layer as? MPVColorLayer)?.resources
        super.init(layer: layer)
        if let previous = layer as? MPVColorLayer {
            contentsFormat = previous.contentsFormat
            colorspace = previous.colorspace
            wantsExtendedDynamicRangeContent = previous.wantsExtendedDynamicRangeContent
            contentsScale = previous.contentsScale
            isAsynchronous = false
        }
    }
    required init?(coder: NSCoder) { nil }
    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        guard let resources else { return super.copyCGLPixelFormat(forDisplayMask: mask) }
        return CGLRetainPixelFormat(resources.pixelFormat)
    }
    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        guard let resources else { return super.copyCGLContext(forPixelFormat: pf) }
        return CGLRetainContext(resources.context)
    }
    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        resources?.draw()
    }
}
