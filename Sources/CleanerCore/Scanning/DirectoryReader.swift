import Darwin

/// One directory entry as returned by `getattrlistbulk(2)`.
struct RawEntry {
    enum EntryType {
        case regular, directory, symlink, other
    }

    var name = ""
    var type = EntryType.other
    var device: Int32 = 0
    var fileID: UInt64 = 0
    var flags: UInt32 = 0
    var modificationTime: Int64 = 0
    var accessTime: Int64 = 0
    var linkCount: UInt32 = 1
    var logicalSize: Int64 = 0
    var allocatedSize: Int64 = 0
    var isMountPoint = false
}

/// Reads whole directories with `getattrlistbulk`, which returns the attributes of
/// many entries per system call instead of one `stat` per file.
///
/// Not thread-safe: each scanner worker owns one reader and its buffer.
final class DirectoryReader {
    private static let bufferSize = 256 * 1024

    /// Attribute bits, in the order the kernel packs them into the buffer.
    private static let commonAttributes: attrgroup_t = ATTR_CMN_RETURNED_ATTRS
        | attrgroup_t(ATTR_CMN_NAME)
        | attrgroup_t(ATTR_CMN_DEVID)
        | attrgroup_t(ATTR_CMN_OBJTYPE)
        | attrgroup_t(ATTR_CMN_MODTIME)
        | attrgroup_t(ATTR_CMN_ACCTIME)
        | attrgroup_t(ATTR_CMN_FLAGS)
        | attrgroup_t(ATTR_CMN_FILEID)
    private static let directoryAttributes = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
    private static let fileAttributes = attrgroup_t(ATTR_FILE_LINKCOUNT)
        | attrgroup_t(ATTR_FILE_TOTALSIZE)
        | attrgroup_t(ATTR_FILE_ALLOCSIZE)

    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
    private var request: attrlist

    init() {
        request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = Self.commonAttributes
        request.dirattr = Self.directoryAttributes
        request.fileattr = Self.fileAttributes
    }

    deinit {
        buffer.deallocate()
    }

    /// Calls `body` for every entry of the directory at `path`.
    /// Returns 0 on success, otherwise the `errno` of the failed call.
    /// Entries delivered before a read error are kept.
    func read(path: String, _ body: (RawEntry) -> Void) -> Int32 {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return errno }
        defer { close(descriptor) }

        while true {
            let count = getattrlistbulk(descriptor, &request, buffer, Self.bufferSize, 0)
            if count == 0 {
                return 0
            }
            if count < 0 {
                return errno
            }

            var entry = UnsafeRawPointer(buffer)
            for _ in 0 ..< count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                body(Self.parse(entry))
                entry += length
            }
        }
    }

    private static func parse(_ entry: UnsafeRawPointer) -> RawEntry {
        var raw = RawEntry()
        var field = entry + MemoryLayout<UInt32>.size
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += MemoryLayout<attribute_set_t>.size

        func has(_ group: attrgroup_t, _ bit: Int32) -> Bool {
            group & attrgroup_t(bit) != 0
        }

        if has(returned.commonattr, ATTR_CMN_NAME) {
            let reference = field.loadUnaligned(as: attrreference_t.self)
            let bytes = UnsafeRawBufferPointer(
                start: field + Int(reference.attr_dataoffset),
                count: max(Int(reference.attr_length) - 1, 0) // drop the NUL terminator
            )
            raw.name = String(decoding: bytes, as: UTF8.self)
            field += MemoryLayout<attrreference_t>.size
        }
        if has(returned.commonattr, ATTR_CMN_DEVID) {
            raw.device = field.loadUnaligned(as: dev_t.self)
            field += MemoryLayout<dev_t>.size
        }
        if has(returned.commonattr, ATTR_CMN_OBJTYPE) {
            raw.type = switch field.loadUnaligned(as: fsobj_type_t.self) {
            case 1: .regular // VREG
            case 2: .directory // VDIR
            case 5: .symlink // VLNK
            default: .other
            }
            field += MemoryLayout<fsobj_type_t>.size
        }
        if has(returned.commonattr, ATTR_CMN_MODTIME) {
            raw.modificationTime = Int64(field.loadUnaligned(as: timespec.self).tv_sec)
            field += MemoryLayout<timespec>.size
        }
        if has(returned.commonattr, ATTR_CMN_ACCTIME) {
            raw.accessTime = Int64(field.loadUnaligned(as: timespec.self).tv_sec)
            field += MemoryLayout<timespec>.size
        }
        if has(returned.commonattr, ATTR_CMN_FLAGS) {
            raw.flags = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
        }
        if has(returned.commonattr, ATTR_CMN_FILEID) {
            raw.fileID = field.loadUnaligned(as: UInt64.self)
            field += MemoryLayout<UInt64>.size
        }

        if has(returned.dirattr, ATTR_DIR_MOUNTSTATUS) {
            raw.isMountPoint = field.loadUnaligned(as: UInt32.self) & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0
            field += MemoryLayout<UInt32>.size
        }

        if has(returned.fileattr, ATTR_FILE_LINKCOUNT) {
            raw.linkCount = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
        }
        if has(returned.fileattr, ATTR_FILE_TOTALSIZE) {
            raw.logicalSize = field.loadUnaligned(as: off_t.self)
            field += MemoryLayout<off_t>.size
        }
        if has(returned.fileattr, ATTR_FILE_ALLOCSIZE) {
            raw.allocatedSize = field.loadUnaligned(as: off_t.self)
            field += MemoryLayout<off_t>.size
        }
        return raw
    }
}
