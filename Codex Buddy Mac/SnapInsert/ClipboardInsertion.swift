import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

nonisolated struct PreparedPhoto: Sendable {
    let png: Data
    let jpeg: Data
    let previewPNG: Data
}

nonisolated enum PhotoPreparationError: LocalizedError {
    case invalidImage
    case excessiveSize
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage: "收到的文件不是有效的 JPEG 照片。"
        case .excessiveSize: "照片过大，请在 iPhone 上重新拍摄。"
        case .encodingFailed: "无法准备照片，请重新拍摄。"
        }
    }
}

nonisolated enum PhotoPreparation {
    /// Bound compressed and decoded sizes before creating an image. ImageIO applies orientation.
    static func prepare(_ jpeg: Data) throws -> PreparedPhoto {
        guard !jpeg.isEmpty, jpeg.count <= 12 * 1_024 * 1_024 else {
            throw PhotoPreparationError.excessiveSize
        }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, options),
              CGImageSourceGetCount(source) == 1,
              let imageType = CGImageSourceGetType(source),
              UTType(imageType as String)?.conforms(to: .jpeg) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw PhotoPreparationError.invalidImage
        }
        guard width.intValue > 0, height.intValue > 0,
              width.intValue <= 16_000, height.intValue <= 16_000,
              width.intValue * height.intValue <= 36_000_000 else {
            throw PhotoPreparationError.excessiveSize
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 3_000,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw PhotoPreparationError.invalidImage
        }
        let previewOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 480
        ]
        guard let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, previewOptions as CFDictionary) else {
            throw PhotoPreparationError.invalidImage
        }
        return try PreparedPhoto(
            png: encode(image, type: .png),
            jpeg: encode(image, type: .jpeg),
            previewPNG: encode(preview, type: .png)
        )
    }

    private static func encode(_ image: CGImage, type: UTType) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw PhotoPreparationError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PhotoPreparationError.encodingFailed }
        return data as Data
    }
}

@MainActor
enum ClipboardInsertion {
    struct Result {
        let status: String
        let detail: String
    }

    static func copy(_ photo: PreparedPhoto, to pasteboard: NSPasteboard = .general) -> Bool {
        let item = NSPasteboardItem()
        item.setData(photo.png, forType: .png)
        item.setData(photo.jpeg, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    static func receive(_ photo: PreparedPhoto, automaticallyPaste: Bool, sessionAvailable: Bool) -> Result {
        // Never activate another app: the recipient is the app focused when this photo is ready.
        let target = NSWorkspace.shared.frontmostApplication
        guard copy(photo) else {
            return Result(status: "error", detail: "Mac 剪贴板暂不可用，请重试。")
        }
        let photoChangeCount = NSPasteboard.general.changeCount
        guard automaticallyPaste else {
            return Result(status: "clipboard", detail: "照片已复制到 Mac，在需要的位置按 ⌘V。")
        }
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            return Result(status: "clipboard", detail: "照片已复制。请在 Mac 开启辅助功能权限，或按 ⌘V 粘贴。")
        }
        guard sessionAvailable, isConsoleSessionActive(), !IsSecureEventInputEnabled() else {
            return Result(status: "clipboard", detail: "Mac 当前无法安全接收粘贴，解锁后在目标位置按 ⌘V。")
        }
        guard let target, target.isActive, !target.isTerminated,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              target.bundleIdentifier != "com.apple.loginwindow",
              let focusedElement = verifiedFocusedElement(for: target.processIdentifier) else {
            return Result(status: "clipboard", detail: "照片已复制。请在 Mac 的目标编辑位置按 ⌘V。")
        }
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(focusedElement, kAXSubroleAttribute as CFString, &subrole) == .success,
           let subrole = subrole as? String, subrole == kAXSecureTextFieldSubrole as String {
            return Result(status: "clipboard", detail: "照片已复制，未向密码输入框粘贴。")
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return Result(status: "clipboard", detail: "照片已复制。编辑位置发生变化，请按 ⌘V 粘贴。")
        }
        guard NSPasteboard.general.changeCount == photoChangeCount else {
            return Result(status: "error", detail: "Mac 剪贴板已变化，未发送粘贴指令。请重新发送，或在 Mac 重新复制照片。")
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        down.postToPid(target.processIdentifier)
        up.postToPid(target.processIdentifier)
        let name = target.localizedName ?? "目标应用"
        return Result(status: "pasted", detail: "已向\(name)发送粘贴指令。若未出现图片，请确认此位置支持图片后按 ⌘V。")
    }

    private static func isConsoleSessionActive() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session[kCGSessionOnConsoleKey as String] as? Bool == true
            && session[kCGSessionLoginDoneKey as String] as? Bool == true
    }

    private static func verifiedFocusedElement(for pid: pid_t) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var focusedAppValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &focusedAppValue) == .success,
              let focusedAppValue,
              CFGetTypeID(focusedAppValue) == AXUIElementGetTypeID() else { return nil }
        let focusedApp = unsafeBitCast(focusedAppValue, to: AXUIElement.self)
        var focusedPID: pid_t = 0
        guard AXUIElementGetPid(focusedApp, &focusedPID) == .success, focusedPID == pid else { return nil }
        var elementValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &elementValue) == .success,
              let elementValue, CFGetTypeID(elementValue) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(elementValue, to: AXUIElement.self)
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(element, &elementPID) == .success, elementPID == pid else { return nil }
        return element
    }
}
