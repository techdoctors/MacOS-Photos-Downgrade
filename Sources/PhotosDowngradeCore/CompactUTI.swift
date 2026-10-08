import Foundation
import CoreServices

/// Monterey and later store a resource's file type as a compact code in
/// ZINTERNALRESOURCE.ZCOMPACTUTI. The table below was read from
/// +[PLUniformTypeIdentifier utiWithCompactRepresentation:conformanceHint:] in
/// PhotoLibraryServices (macOS 15.7); the hint does not change the result.
/// Types without a code are stored as their full identifier.
enum CompactUTI {
    static let table: [String: String] = [
        "1": "public.jpeg", "2": "public.jpeg", "3": "public.heic", "4": "public.heif", "5": "public.avci",
        "6": "public.png", "7": "com.compuserve.gif", "8": "public.tiff", "9": "com.adobe.raw-image",
        "10": "com.sony.arw-raw-image", "11": "com.canon.cr2-raw-image", "12": "com.canon.crw-raw-image",
        "13": "com.olympus.raw-image", "14": "com.panasonic.rw2-raw-image", "15": "com.panasonic.raw-image",
        "16": "com.pentax.raw-image", "17": "com.nikon.raw-image", "18": "com.samsung.raw-image",
        "19": "com.leafamerica.raw-image", "20": "com.hasselblad.3fr-raw-image", "21": "com.fuji.raw-image",
        "22": "com.hasselblad.fff-raw-image", "23": "com.apple.quicktime-movie", "24": "public.mpeg-4",
        "25": "com.apple.m4v-video", "26": "public.3gpp", "27": "public.avi", "28": "com.apple.m4a-audio",
        "29": "com.apple.coreaudio-format", "30": "com.microsoft.waveform-audio", "31": "public.aifc-audio",
        "32": "public.aiff-audio", "33": "public.mp3", "34": "public.ac3-audio", "35": "com.apple.property-list",
        "36": "public.data", "37": "com.apple.photos.apple-adjustment-envelope", "38": "public.avif",
        "39": "public.jpeg-xl",
    ]

    static func identifier(for code: String) -> String { table[code] ?? code }

    /// Flags stored with each row of Big Sur's ZUNIFORMTYPEIDENTIFIER table.
    /// Uses the CoreServices UTI API so it also runs on Catalina.
    static func conformance(of identifier: String) -> [String: Int] {
        let uti = identifier as CFString
        let raw = UTTypeConformsTo(uti, kUTTypeRawImage) || identifier.hasSuffix("raw-image")
        return [
            "ZCONFORMSTOIMAGE": UTTypeConformsTo(uti, kUTTypeImage) || raw ? 1 : 0,
            "ZCONFORMSTOMOVIE": UTTypeConformsTo(uti, kUTTypeMovie) ? 1 : 0,
            "ZCONFORMSTORAWIMAGE": raw ? 1 : 0,
        ]
    }
}
