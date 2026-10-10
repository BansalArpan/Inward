import Foundation
import AVFoundation
import Metal

extension CVPixelBuffer {
    func texture(withFormat pixelFormat: MTLPixelFormat,
                 planeIndex: Int,
                 addToCache cache: CVMetalTextureCache) -> MTLTexture? {
        let planar = CVPixelBufferIsPlanar(self)
        guard !planar || planeIndex < CVPixelBufferGetPlaneCount(self) else { return nil }
        let width = planar ? CVPixelBufferGetWidthOfPlane(self, planeIndex) : CVPixelBufferGetWidth(self)
        let height = planar ? CVPixelBufferGetHeightOfPlane(self, planeIndex) : CVPixelBufferGetHeight(self)
        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                               cache,
                                                               self,
                                                               nil,
                                                               pixelFormat,
                                                               width,
                                                               height,
                                                               planar ? planeIndex : 0,
                                                               &cvTexture)
        guard result == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }
}
