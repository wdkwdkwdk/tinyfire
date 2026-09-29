//
//  ZstdDecompressor.swift
//  tinyFire
//
//  Multi-frame Zstandard decode via vendored zstddeclib (DeepSeek Harness sessions).
//

import Foundation

enum ZstdDecompressor {
    /// Decompress every *complete* concatenated frame; leave a torn trailing frame unconsumed.
    /// - Returns: decompressed bytes + how many compressed bytes were fully consumed.
    static func decompressCompleteFrames(_ data: Data) -> (decoded: Data, consumed: Int) {
        guard !data.isEmpty else { return (Data(), 0) }

        var decoded = Data()
        var consumed = 0
        let bytes = [UInt8](data)

        while consumed < bytes.count {
            let remaining = bytes.count - consumed
            let frameSize: Int = bytes.withUnsafeBufferPointer { buf in
                let fs = ZSTD_findFrameCompressedSize(buf.baseAddress! + consumed, remaining)
                if ZSTD_isError(fs) != 0 { return -1 }
                return Int(fs)
            }
            if frameSize <= 0 { break }

            let contentSize: UInt64 = bytes.withUnsafeBufferPointer { buf in
                ZSTD_getFrameContentSize(buf.baseAddress! + consumed, frameSize)
            }

            var capacity: Int
            if contentSize == ZSTD_CONTENTSIZE_UNKNOWN || contentSize == ZSTD_CONTENTSIZE_ERROR {
                capacity = max(Int(ZSTD_DStreamOutSize()) * 4, frameSize * 8)
            } else {
                capacity = max(Int(contentSize), 1)
            }

            var written = -1
            var dst = [UInt8]()
            while capacity <= 16 * 1024 * 1024 {
                dst = [UInt8](repeating: 0, count: capacity)
                written = bytes.withUnsafeBufferPointer { buf in
                    dst.withUnsafeMutableBufferPointer { out in
                        Int(ZSTD_decompress(out.baseAddress, out.count, buf.baseAddress! + consumed, frameSize))
                    }
                }
                if ZSTD_isError(written) == 0 { break }
                // Destination too small for unknown content size — grow and retry.
                capacity *= 2
                written = -1
            }
            if written < 0 { break }

            if written > 0 {
                decoded.append(contentsOf: dst.prefix(written))
            }
            consumed += frameSize
        }

        return (decoded, consumed)
    }

    /// Full-buffer decode (all complete frames). Convenience for tests / one-shot reads.
    static func decompress(_ data: Data) -> Data? {
        if data.isEmpty { return Data() }
        let result = decompressCompleteFrames(data)
        if result.consumed == 0 { return nil }
        return result.decoded
    }
}
