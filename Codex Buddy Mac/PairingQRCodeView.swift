import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct PairingQRCodeView: View {
    let payload: String

    var body: some View {
        if let image = QRCodeRenderer.render(payload) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .accessibilityLabel("iPhone 配对二维码")
        } else {
            ContentUnavailableView("无法生成二维码", systemImage: "qrcode")
        }
    }
}

private nonisolated enum QRCodeRenderer {
    static func render(_ value: String) -> NSImage? {
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(value.utf8)
        generator.correctionLevel = "M"
        guard let output = generator.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
