/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
View extensions to help with drawing the camera streams correctly on all device orientations.
*/

import SwiftUI

extension View {
    
    func calcAspect(orientation: UIImage.Orientation, texture: MTLTexture?) -> CGFloat {
        guard let texture = texture else { return 1 }
        switch orientation {
        case .up:
            return CGFloat(texture.width) / CGFloat(texture.height)
        case .down:
            return CGFloat(texture.width) / CGFloat(texture.height)
        case .left:
            return  CGFloat(texture.height) / CGFloat(texture.width)
        case .right:
            return  CGFloat(texture.height) / CGFloat(texture.width)
        default:
            return CGFloat(texture.width) / CGFloat(texture.height)
        }
    }
    
    var rotationAngle: Double {
        // Fixed to 0 degrees since we locked the orientation
        return 0.0
    }

    var viewOrientation: UIImage.Orientation {
        // Fixed to .right (portrait) since we locked the orientation
        return .right
    }
}
