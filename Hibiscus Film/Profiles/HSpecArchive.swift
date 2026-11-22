import CryptoKit
import Foundation

/// HSpec v2 envelope: LE header, SHA-256, typed bounded chunks. Binary plist payloads
/// contain explicit specifications (never GPU layouts, filenames or executable code).
nonisolated enum HSpecArchive {
    static let maximumBytes = 1 << 20
    static let magic = Data([0x48,0x53,0x50,0x45,0x43,0x0d,0x0a,0x1a])
    struct Extension: Sendable, Equatable {
        let type: UInt32
        let data: Data
    }
    struct Document: Sendable, Equatable {
        let profile: SpectrumProfile
        /// Preserve unknown OPTIONAL chunks across a read/write.
        let extensions: [Extension]
        init(profile: SpectrumProfile, extensions: [Extension] = []) { self.profile = profile; self.extensions = extensions }
    }
    struct Chunk { let type, flags: UInt32; let data: Data }
    static func propertyList<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        return try encoder.encode(value)
    }
    static func encode(_ document: Document) throws -> Data {
        guard document.extensions.count <= 32, Set(document.extensions.map(\.type)).count == document.extensions.count,
              document.extensions.allSatisfy({ $0.type > 2 && $0.data.count <= 65536 }) else { throw SpectrumProfile.Failure.invalid }
        return try envelope([Chunk(type:1,flags:1,data:propertyList(document.profile.specification))] + document.extensions.sorted(by:{ $0.type < $1.type }).map { Chunk(type:$0.type,flags:0,data:$0.data) })
    }
    static func decode(_ data: Data) throws -> Document {
        let chunks = try read(data)
        guard !chunks.contains(where:{ $0.type == 2 }) else { throw SpectrumProfile.Failure.legacy }
        var profile: SpectrumProfile?, extensions: [Extension] = []
        for chunk in chunks {
            if chunk.type == 1 {
                guard chunk.flags == 1, chunk.data.starts(with:Data("bplist00".utf8)) else { throw SpectrumProfile.Failure.invalid }
                profile = try SpectrumProfile(PropertyListDecoder().decode(SpectrumProfile.Specification.self,from:chunk.data))
            } else {
                guard chunk.flags == 0 else { throw SpectrumProfile.Failure.unsupported }
                guard chunk.type > 2, chunk.data.count <= 65536 else { throw SpectrumProfile.Failure.invalid }
                extensions.append(Extension(type:chunk.type,data:chunk.data))
            }
        }
        guard let profile else { throw SpectrumProfile.Failure.invalid }
        return Document(profile:profile,extensions:extensions)
    }
    /// Canonical content identity; JSON is ONLY used for hashing, never HSpec transport.
    static func fingerprint(_ profile: SpectrumProfile) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        return Data(SHA256.hash(data:try encoder.encode(profile.specification)))
    }
    static func envelope(_ chunks: [Chunk]) throws -> Data {
        var body = Data()
        for chunk in chunks {
            guard chunk.data.count <= maximumBytes else { throw SpectrumProfile.Failure.invalid }
            append(chunk.type,to:&body); append(chunk.flags,to:&body); append(UInt32(chunk.data.count),to:&body); body.append(chunk.data)
        }
        guard body.count <= maximumBytes-52 else { throw SpectrumProfile.Failure.invalid }
        var data = magic
        append(2,to:&data); append(0,to:&data); append(UInt32(body.count),to:&data)
        data.append(contentsOf:SHA256.hash(data:body)); data.append(body)
        return data
    }
    static func read(_ input: Data) throws -> [Chunk] {
        guard input.count <= maximumBytes else { throw SpectrumProfile.Failure.invalid }
        let data = Data(input) // Rebase slices before integer indexing.
        if data.first == 123 || data.first == 32 || data.first == 10 { throw SpectrumProfile.Failure.legacy }
        guard data.count >= 52, data.prefix(8) == magic else { throw SpectrumProfile.Failure.invalid }
        var cursor = 8
        func number() throws -> UInt32 {
            guard cursor <= data.count-4 else { throw SpectrumProfile.Failure.invalid }
            defer { cursor += 4 }
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[cursor+$1]) << ($1*8) }
        }
        let major = try number(), minor = try number(), length = try number()
        guard major == 2, minor == 0 else { throw SpectrumProfile.Failure.unsupported }
        guard Int(length) == data.count-52, data.subdata(in:20..<52) == Data(SHA256.hash(data:data.suffix(from:52))) else { throw SpectrumProfile.Failure.invalid }
        cursor = 52
        var chunks: [Chunk] = [], types = Set<UInt32>()
        while cursor < data.count {
            let type = try number(), flags = try number(), length = Int(try number())
            guard types.insert(type).inserted, types.count <= 33, flags <= 1, length <= data.count-cursor else { throw SpectrumProfile.Failure.invalid }
            chunks.append(Chunk(type:type,flags:flags,data:data.subdata(in:cursor..<(cursor+length)))); cursor += length
        }
        return chunks
    }
    private static func append(_ value: UInt32, to data: inout Data) {
        for shift in stride(from:0,to:32,by:8) { data.append(UInt8(truncatingIfNeeded:value >> shift)) }
    }
}
