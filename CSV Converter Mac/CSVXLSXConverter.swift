import Foundation

enum CSVXLSXConversionError: LocalizedError {
    case fileTooLarge(Int64)
    case unreadableCSV
    case invalidOutputPath
    case outputTooLarge
    case tooManyRows(Int)
    case tooManyColumns(Int)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let bytes):
            return "CSV file is too large to convert safely (\(bytes) bytes)."
        case .unreadableCSV:
            return "CSV file could not be read as text."
        case .invalidOutputPath:
            return "Output file path could not be created."
        case .outputTooLarge:
            return "Converted XLSX exceeds the 4 GB ZIP limit and cannot be written."
        case .tooManyRows(let rows):
            return "CSV has too many rows for XLSX (\(rows))."
        case .tooManyColumns(let columns):
            return "CSV has too many columns for XLSX (\(columns))."
        }
    }
}

struct CSVXLSXConverter {
    private static let maxInputBytes: Int64 = 25 * 1024 * 1024
    private static let maxRows = 1_048_576
    private static let maxColumns = 16_384

    static func convert(csvURL: URL) throws -> URL {
        let csvURL = csvURL.standardizedFileURL
        let csvText = try readCSVText(from: csvURL)
        let delimiter = CSVParser.detectDelimiter(in: csvText)
        let rows = try CSVParser.parse(csvText,
                                       delimiter: delimiter,
                                       maxRows: maxRows,
                                       maxColumns: maxColumns)

        try validate(rows: rows)
        let workbook = XLSXWorkbook(rows: rows)
        return try write(workbook: workbook, for: csvURL)
    }

    private static func outputURLs(for csvURL: URL) -> [URL] {
        let directory = csvURL.deletingLastPathComponent()
        let baseName = "\(csvURL.deletingPathExtension().lastPathComponent) converted"

        let base = directory.appendingPathComponent(baseName).appendingPathExtension("xlsx")
        let numbered = (2...999).map { suffix in
            directory.appendingPathComponent("\(baseName) \(suffix)").appendingPathExtension("xlsx")
        }
        let fallbackName = "\(baseName) \(Int(Date().timeIntervalSince1970))"
        let fallback = directory.appendingPathComponent(fallbackName).appendingPathExtension("xlsx")
        return [base] + numbered + [fallback]
    }

    private static func write(workbook: XLSXWorkbook, for csvURL: URL) throws -> URL {
        let archive = try workbook.makeArchive()

        for outputURL in outputURLs(for: csvURL) where !FileManager.default.fileExists(atPath: outputURL.path) {
            do {
                try XLSXWorkbook.write(archive: archive, to: outputURL)
                return outputURL
            } catch {
                if error.isFileAlreadyExistsError {
                    continue
                }
                throw error
            }
        }

        throw CSVXLSXConversionError.invalidOutputPath
    }

    private static func readCSVText(from url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw CSVXLSXConversionError.unreadableCSV }

        let byteSize = Int64(values.fileSize ?? 0)
        guard byteSize <= maxInputBytes else { throw CSVXLSXConversionError.fileTooLarge(byteSize) }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8.removingUTF8BOM()
        }
        if let utf16 = String(data: data, encoding: .utf16) {
            return utf16
        }
        if let windowsLatin1 = String(data: data, encoding: .windowsCP1252) {
            return windowsLatin1
        }
        throw CSVXLSXConversionError.unreadableCSV
    }

    private static func validate(rows: [[String]]) throws {
        guard rows.count <= maxRows else { throw CSVXLSXConversionError.tooManyRows(rows.count) }

        let widestRow = rows.map(\.count).max() ?? 0
        guard widestRow <= maxColumns else { throw CSVXLSXConversionError.tooManyColumns(widestRow) }
    }
}

private enum CSVParser {
    static func detectDelimiter(in text: String) -> Character {
        let sample = text.prefix(16_384)
        let candidates: [Character] = [",", ";", "\t"]
        var scores = Dictionary(uniqueKeysWithValues: candidates.map { ($0, 0) })
        var insideQuotes = false

        for character in sample {
            if character == "\"" {
                insideQuotes.toggle()
            } else if !insideQuotes, scores.keys.contains(character) {
                scores[character, default: 0] += 1
            }
        }

        return scores.max { $0.value < $1.value }?.key ?? ","
    }

    static func parse(_ text: String, delimiter: Character, maxRows: Int, maxColumns: Int) throws -> [[String]] {
        // Swift's String iterator yields \r\n as a single Character (one Unicode grapheme
        // cluster), so it never matches the individual "\r" or "\n" checks below.
        // Normalize all line endings to \n first to avoid this.
        let text = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var iterator = text.makeIterator()
        var insideQuotes = false
        var pendingQuote = false

        func finishField() throws {
            guard row.count < maxColumns else {
                throw CSVXLSXConversionError.tooManyColumns(row.count + 1)
            }
            row.append(field)
            field.removeAll(keepingCapacity: true)
        }

        func finishRow() throws {
            try finishField()
            guard rows.count < maxRows else {
                throw CSVXLSXConversionError.tooManyRows(rows.count + 1)
            }
            rows.append(row)
            row.removeAll(keepingCapacity: true)
        }

        while let character = iterator.next() {
            if insideQuotes {
                if pendingQuote {
                    if character == "\"" {
                        field.append("\"")
                        pendingQuote = false
                    } else {
                        insideQuotes = false
                        pendingQuote = false
                        if character == delimiter {
                            try finishField()
                        } else if character == "\n" {
                            try finishRow()
                        } else {
                            field.append(character)
                        }
                    }
                } else if character == "\"" {
                    pendingQuote = true
                } else {
                    field.append(character)
                }
            } else if character == "\"" && field.isEmpty {
                insideQuotes = true
            } else {
                if character == delimiter {
                    try finishField()
                } else if character == "\n" {
                    try finishRow()
                } else {
                    field.append(character)
                }
            }
        }

        if pendingQuote {
            insideQuotes = false
        }

        if !field.isEmpty || !row.isEmpty || text.last == delimiter {
            try finishField()
            guard rows.count < maxRows else {
                throw CSVXLSXConversionError.tooManyRows(rows.count + 1)
            }
            rows.append(row)
        }

        return rows
    }
}

private struct XLSXWorkbook {
    let rows: [[String]]
    private let columnCount: Int

    init(rows: [[String]]) {
        self.rows = rows
        self.columnCount = max(rows.map(\.count).max() ?? 1, 1)
    }

    func makeArchive() throws -> Data {
        guard let archive = ZipArchive.make(entries: entries()) else {
            throw CSVXLSXConversionError.outputTooLarge
        }
        return archive
    }

    static func write(archive: Data, to outputURL: URL) throws {
        let parent = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let temporaryURL = parent.appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try archive.write(to: temporaryURL, options: .atomic)
            try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func entries() -> [ZipArchive.Entry] {
        [
            .init(path: "[Content_Types].xml", data: Data(contentTypesXML.utf8)),
            .init(path: "_rels/.rels", data: Data(rootRelationshipsXML.utf8)),
            .init(path: "docProps/app.xml", data: Data(appPropertiesXML.utf8)),
            .init(path: "docProps/core.xml", data: Data(corePropertiesXML.utf8)),
            .init(path: "xl/workbook.xml", data: Data(workbookXML.utf8)),
            .init(path: "xl/_rels/workbook.xml.rels", data: Data(workbookRelationshipsXML.utf8)),
            .init(path: "xl/styles.xml", data: Data(stylesXML.utf8)),
            .init(path: "xl/worksheets/sheet1.xml", data: Data(worksheetXML.utf8)),
            .init(path: "xl/worksheets/_rels/sheet1.xml.rels", data: Data(worksheetRelationshipsXML.utf8)),
            .init(path: "xl/tables/table1.xml", data: Data(tableXML.utf8)),
        ]
    }

    private var lastRowIndex: Int {
        max(rows.count, 1)
    }

    private var lastColumnIndex: Int { columnCount }

    private var usedRange: String {
        "A1:\(columnName(for: lastColumnIndex - 1))\(lastRowIndex)"
    }

    private var worksheetXML: String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><dimension ref="\(usedRange)"/><sheetData>
        """

        for (rowIndex, row) in rows.enumerated() {
            let excelRow = rowIndex + 1
            xml += "<row r=\"\(excelRow)\">"

            for (columnIndex, value) in row.enumerated() where !value.isEmpty {
                let reference = "\(columnName(for: columnIndex))\(excelRow)"
                xml += "<c r=\"\(reference)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(value.xmlEscaped)</t></is></c>"
            }

            xml += "</row>"
        }

        xml += "</sheetData><tableParts count=\"1\"><tablePart r:id=\"rId1\"/></tableParts></worksheet>"
        return xml
    }

    private var worksheetRelationshipsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/table" Target="../tables/table1.xml"/>
        </Relationships>
        """
    }

    private var tableXML: String {
        let headers = tableColumnNames()
        var columnsXML = ""

        for (index, name) in headers.enumerated() {
            columnsXML += "<tableColumn id=\"\(index + 1)\" name=\"\(name.xmlAttributeEscaped)\"/>"
        }

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <table xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" id="1" name="Table1" displayName="Table1" ref="\(usedRange)" totalsRowShown="0">
        <autoFilter ref="\(usedRange)"/>
        <tableColumns count="\(headers.count)">\(columnsXML)</tableColumns>
        <tableStyleInfo name="TableStyleMedium2" showFirstColumn="0" showLastColumn="0" showRowStripes="1" showColumnStripes="0"/>
        </table>
        """
    }

    private func tableColumnNames() -> [String] {
        let headerRow = rows.first ?? []
        var usedNames = Set<String>()

        return (0..<lastColumnIndex).map { index in
            let rawName = index < headerRow.count ? headerRow[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let baseName = rawName.isEmpty ? "Column\(index + 1)" : rawName
            var name = baseName
            var suffix = 2

            while usedNames.contains(name) {
                name = "\(baseName)_\(suffix)"
                suffix += 1
            }

            usedNames.insert(name)
            return name
        }
    }

    private func columnName(for zeroBasedIndex: Int) -> String {
        var number = zeroBasedIndex + 1
        var name = ""

        while number > 0 {
            let remainder = (number - 1) % 26
            name.insert(Character(UnicodeScalar(65 + remainder)!), at: name.startIndex)
            number = (number - 1) / 26
        }

        return name
    }

    private var contentTypesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        <Override PartName="/xl/tables/table1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml"/>
        </Types>
        """
    }

    private var rootRelationshipsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
        </Relationships>
        """
    }

    private var workbookXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>
        </workbook>
        """
    }

    private var workbookRelationshipsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """
    }

    private var stylesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
        <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>
        </styleSheet>
        """
    }

    private var appPropertiesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>CSV Converter Mac</Application></Properties>
        """
    }

    private var corePropertiesXML: String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:creator>CSV Converter Mac</dc:creator><cp:lastModifiedBy>CSV Converter Mac</cp:lastModifiedBy><dcterms:created xsi:type="dcterms:W3CDTF">\(timestamp)</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">\(timestamp)</dcterms:modified></cp:coreProperties>
        """
    }
}

private struct ZipArchive {
    struct Entry {
        let path: String
        let data: Data
    }

    private struct CentralDirectoryEntry {
        let pathData: Data
        let crc32: UInt32
        let size: UInt32
        let localHeaderOffset: UInt32
    }

    static func make(entries: [Entry]) -> Data? {
        var archive = Data()
        var centralDirectory: [CentralDirectoryEntry] = []
        let (dosTime, dosDate) = currentDOSTimestamp()

        for entry in entries {
            guard let pathData = entry.path.data(using: .utf8),
                  entry.data.count <= UInt32.max,
                  archive.count <= UInt32.max else { return nil }

            let crc = CRC32.checksum(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(archive.count)

            archive.appendUInt32LE(0x04034b50)
            archive.appendUInt16LE(20)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(dosTime)
            archive.appendUInt16LE(dosDate)
            archive.appendUInt32LE(crc)
            archive.appendUInt32LE(size)
            archive.appendUInt32LE(size)
            archive.appendUInt16LE(UInt16(pathData.count))
            archive.appendUInt16LE(0)
            archive.append(pathData)
            archive.append(entry.data)

            centralDirectory.append(.init(pathData: pathData, crc32: crc, size: size, localHeaderOffset: offset))
        }

        guard archive.count <= UInt32.max else { return nil }
        let centralDirectoryOffset = UInt32(archive.count)

        for entry in centralDirectory {
            archive.appendUInt32LE(0x02014b50)
            archive.appendUInt16LE(20)
            archive.appendUInt16LE(20)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(dosTime)
            archive.appendUInt16LE(dosDate)
            archive.appendUInt32LE(entry.crc32)
            archive.appendUInt32LE(entry.size)
            archive.appendUInt32LE(entry.size)
            archive.appendUInt16LE(UInt16(entry.pathData.count))
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt32LE(0)
            archive.appendUInt32LE(entry.localHeaderOffset)
            archive.append(entry.pathData)
        }

        guard archive.count <= UInt32.max else { return nil }
        let centralDirectorySize = UInt32(archive.count) - centralDirectoryOffset

        archive.appendUInt32LE(0x06054b50)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(UInt16(centralDirectory.count))
        archive.appendUInt16LE(UInt16(centralDirectory.count))
        archive.appendUInt32LE(centralDirectorySize)
        archive.appendUInt32LE(centralDirectoryOffset)
        archive.appendUInt16LE(0)

        return archive
    }

    private static func currentDOSTimestamp() -> (UInt16, UInt16) {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        let year = max((components.year ?? 1980) - 1980, 0)
        let month = components.month ?? 1
        let day = components.day ?? 1
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = (components.second ?? 0) / 2

        let dosTime = UInt16((hour << 11) | (minute << 5) | second)
        let dosDate = UInt16((year << 9) | (month << 5) | day)
        return (dosTime, dosDate)
    }
}

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (0xedb88320 ^ (crc >> 1)) : (crc >> 1)
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xffffffff
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}

private extension Error {
    var isFileAlreadyExistsError: Bool {
        let error = self as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError
    }
}

private extension String {
    var xmlEscaped: String {
        var escaped = ""
        escaped.reserveCapacity(count)

        for scalar in unicodeScalars {
            switch scalar {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            default:
                if scalar.value == 9 || scalar.value == 10 || scalar.value == 13 || scalar.value >= 32 {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }

        return escaped
    }

    var xmlAttributeEscaped: String {
        xmlEscaped
    }

    func removingUTF8BOM() -> String {
        hasPrefix("\u{feff}") ? String(dropFirst()) : self
    }
}
