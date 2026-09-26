//
//  AttachmentRouting.swift
//  M1K3Inference
//
//  One attach button, two destinations. The composer used to carry an image
//  button (vision tower) and a file button (text as turn context), which asked
//  the user to know which half of the model a file was for. Now one picker
//  takes both and this sorts them: images go to the vision path when the brain
//  can see, text goes to FileTextExtractor. An image a blind brain can't take is
//  refused by name, never read as bytes-as-text.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-26, Confidence 0.85 (pure + tested;
//  kind-by-extension, so a mislabelled file routes by its name). Prior: the two
//  fileImporters in ContentView / ChatScreen.
//

import Foundation
import UniformTypeIdentifiers

public enum AttachmentRouting {
    public struct Route: Equatable, Sendable {
        public var images: [URL] = []
        public var files: [URL] = []
        /// Images picked while the brain can't see them. The shell names these
        /// in its error rather than dropping them silently.
        public var refusedImages: [URL] = []
    }

    /// What the file path accepted before the merge; FileTextExtractor has the
    /// last word on whether a given file actually reads as text.
    static let fileTypes: [UTType] = [.plainText, .text, .sourceCode, .json, .yaml, .xml, .html]

    /// The one picker's types. Images are offered only to a brain that can see.
    public static func contentTypes(imagesAccepted: Bool) -> [UTType] {
        imagesAccepted ? [.image] + fileTypes : fileTypes
    }

    public static func route(_ urls: [URL], imagesAccepted: Bool) -> Route {
        var route = Route()
        for url in urls {
            if isImage(url) {
                if imagesAccepted { route.images.append(url) } else { route.refusedImages.append(url) }
            } else {
                route.files.append(url)
            }
        }
        return route
    }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }
}
