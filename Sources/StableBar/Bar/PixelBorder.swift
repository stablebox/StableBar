import SwiftUI

extension InsettableShape {
    /// `strokeBorder` with `width` rounded to whole pixels on screen, and at least one pixel when it's above zero. On
    /// screen, macOS leaves out the part of a pixel a border covers along its straight top and left edges, but draws it
    /// along the bottom and right, so a border that isn't a whole number of pixels wide comes out uneven.
    @MainActor func pixelBorder(_ content: some ShapeStyle, width: CGFloat = 1) -> some View {
        PixelBorder(shape: self, content: content, style: StrokeStyle(lineWidth: width))
    }

    /// `strokeBorder` with the style's line width rounded to whole pixels on screen, as `pixelBorder(_:width:)` does.
    @MainActor func pixelBorder(_ content: some ShapeStyle, style: StrokeStyle) -> some View {
        PixelBorder(shape: self, content: content, style: style)
    }
}

private struct PixelBorder<Outline: InsettableShape, Content: ShapeStyle>: View {
    let shape: Outline
    let content: Content
    let style: StrokeStyle
    @Environment(\.pixelLength) private var pixel
    @Environment(\.offscreenSnapshot) private var offscreen

    var body: some View {
        var style = style
        // Offscreen drawings go through Core Graphics, which draws a part-pixel border evenly at any scale, so their
        // borders keep the width they're given.
        if !offscreen, style.lineWidth > 0 {
            style.lineWidth = max((style.lineWidth / pixel).rounded(), 1) * pixel
        }
        return shape.strokeBorder(content, style: style)
    }
}
