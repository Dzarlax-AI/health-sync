import SwiftUI
import Testing
import UIKit
@testable import health_sync

@MainActor
struct HorizonThemeTests {
    @Test func readableTextOnEveryHorizonSurface() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            for background in [Color.dsHorizonBackground, .dsHorizonSurface, .dsHorizonSurfaceTint, .dsHorizonGaugeCenter] {
                for text in [Color.dsHorizonText, .dsHorizonTextSecondary] {
                    #expect(contrast(text, background, style) >= 4.5)
                }
            }
            #expect(contrast(.dsHorizonAccent, .dsHorizonSurface, style) >= 3)
        }
    }

    @Test func gaugeEndpointsRemainVisibleAgainstTheirCenters() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            for domain in [DomainAppearance.sleep, .recovery, .energy, .activity, .cardio] {
                for color in domain.ringColors {
                    #expect(contrast(color, .dsHorizonGaugeCenter, style) >= 3)
                    #expect(contrast(color, .dsHorizonGaugeTrack, style) >= 3)
                }
            }
        }
    }

    @Test func systemAppearanceResolvesDifferentColorsAndSceneAssets() throws {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let base = UIColor(Color.dsHorizonBackground)
        #expect(luminance(base.resolvedColor(with: light)) > 0.9)
        #expect(luminance(base.resolvedColor(with: dark)) < 0.05)
        let bundle = Bundle(for: AppDelegate.self)
        for name in ["TodayMorningHero", "DomainNightHero"] {
            let day = try #require(UIImage(named: name, in: bundle, compatibleWith: light))
            let night = try #require(UIImage(named: name, in: bundle, compatibleWith: dark))
            #expect(day.size.width >= 1024)
            #expect(day.size == night.size)
            #expect(day.pngData() != night.pngData())
        }
    }

    @Test func sceneVeilKeepsTextReadableAcrossBothAssets() throws {
        let bundle = Bundle(for: AppDelegate.self)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let veil = components(UIColor(Color.dsHorizonVeil).resolvedColor(with: traits))
            let texts = [Color.dsHorizonText, .dsHorizonTextSecondary].map {
                luminance(UIColor($0).resolvedColor(with: traits))
            }
            for name in ["TodayMorningHero", "DomainNightHero"] {
                let image = try #require(UIImage(named: name, in: bundle, compatibleWith: traits)?.cgImage)
                var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
                let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
                try pixels.withUnsafeMutableBytes { bytes in
                    let context = try #require(CGContext(data: bytes.baseAddress, width: 64, height: 64,
                        bitsPerComponent: 8, bytesPerRow: 64 * 4, space: space,
                        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
                }
                var minimum = Double.infinity
                for offset in stride(from: 0, to: pixels.count, by: 4) {
                    let channels = (0..<3).map { channel in
                        CGFloat(pixels[offset + channel]) / 255 * (1 - veil[3]) + veil[channel] * veil[3]
                    }
                    let background = luminance(UIColor(red: channels[0], green: channels[1], blue: channels[2], alpha: 1))
                    for text in texts {
                        minimum = min(minimum, (max(text, background) + 0.05) / (min(text, background) + 0.05))
                    }
                }
                // The page fade further increases contrast; sample the harder, unfaded scene.
                #expect(minimum >= 4.5, "Scene \(name), appearance \(style.rawValue)")
            }
        }
    }

    private func contrast(_ first: Color, _ second: Color, _ style: UIUserInterfaceStyle) -> Double {
        let traits = UITraitCollection(userInterfaceStyle: style)
        let a = luminance(UIColor(first).resolvedColor(with: traits))
        let b = luminance(UIColor(second).resolvedColor(with: traits))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func luminance(_ color: UIColor) -> Double {
        let rgba = components(color)
        func linear(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgba[0]) + 0.7152 * linear(rgba[1]) + 0.0722 * linear(rgba[2])
    }

    private func components(_ color: UIColor) -> [CGFloat] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha]
    }
}
