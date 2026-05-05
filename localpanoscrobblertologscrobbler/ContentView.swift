//
//  ContentView.swift
//  localpanoscrobblertologscrobbler
//
//  Created by Dante Alighieri on 01.05.2026.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct TrackPreviewRow: Identifiable, Hashable {
    let id = UUID()
    let artist: String
    let title: String
    let album: String
    let albumArtist: String
    let timestamp: Int
    let duration: Int
}

struct ContentView: View {
    @State private var selectedCSVURL: URL? = nil
    @State private var statusMessage: String = "No file selected"
    @State private var isConverting: Bool = false
    @State private var previewRows: [TrackPreviewRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Panoscrobbler → .scrobbler.log Converter")
                .font(.title2)
                .bold()

            HStack(spacing: 12) {
                Button("Select Input CSV", action: selectCSV)
                    .keyboardShortcut("o", modifiers: [.command])

                Button("Convert and Save", action: convertAndSave)
                    .keyboardShortcut("s", modifiers: [.command])
                    .disabled(selectedCSVURL == nil || isConverting)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if let url = selectedCSVURL {
                        Text("Selected: \(url.path)")
                            .font(.callout)
                            .textSelection(.enabled)
                    } else {
                        Text("Selected: —")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Status:")
                            .font(.callout).bold()
                        Text(statusMessage)
                            .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            if !previewRows.isEmpty {
                Text("Preview (first \(previewRows.count) tracks):")
                    .font(.subheadline).bold()
                Table(previewRows) {
                    TableColumn("Artist", value: \.artist)
                    TableColumn("Title", value: \.title)
                    TableColumn("Album", value: \.album)
                    TableColumn("Album Artist", value: \.albumArtist)
                    TableColumn("Timestamp") { row in
                        Text("\(row.timestamp)")
                    }
                    TableColumn("Duration") { row in
                        Text("\(row.duration)")
                    }
                }
                .frame(maxHeight: 220)
            }

            Spacer()
            Text("CSV columns: artist, track, album, albumArtist, timeMs, durationMs, event")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 260)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
    }
}

// MARK: - Actions
private extension ContentView {
    func selectCSV() {
        let panel = NSOpenPanel()
        if let csvType = UTType.commaSeparatedText as UTType? {
            panel.allowedContentTypes = [csvType]
        } else if let plain = UTType.plainText as UTType? {
            panel.allowedContentTypes = [plain]
        } else {
            panel.allowedFileTypes = ["csv", "txt"]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.title = "Select Panoscrobbler CSV"
        panel.prompt = "Choose"

        if panel.runModal() == .OK, let url = panel.url {
            selectedCSVURL = url
            statusMessage = "Selected CSV: \(url.lastPathComponent)"
            loadPreviewRows(from: url)
        }
    }

    func convertAndSave() {
        guard let inputURL = selectedCSVURL else {
            statusMessage = "Please select an input CSV first"
            return
        }

        isConverting = true
        statusMessage = "Converting..."

        Task.detached(priority: .userInitiated) {
            do {
                let inputString = try String(contentsOf: inputURL, encoding: .utf8)
                let lines: [String] = inputString.components(separatedBy: CharacterSet.newlines)
                guard !lines.isEmpty else {
                    await MainActor.run {
                        self.statusMessage = "CSV is empty"
                        self.isConverting = false
                    }
                    return
                }

                // Parse header
                var firstLine = lines[0]
                if firstLine.hasPrefix("\u{FEFF}") { firstLine.removeFirst() }
                let header = parseCSVRow(firstLine)
                let headerIndex = indexMapNormalized(for: header)

                // Required columns
                guard headerIndex["artist"] != nil,
                      headerIndex["track"] != nil,
                      headerIndex["album"] != nil,
                      headerIndex["albumartist"] != nil,
                      headerIndex["timems"] != nil,
                      headerIndex["durationms"] != nil,
                      headerIndex["event"] != nil else {
                    await MainActor.run {
                        self.statusMessage = "CSV header missing required columns"
                        self.isConverting = false
                    }
                    return
                }

                var outputLines: [String] = ["#scrobbler-log-1.0"]
                outputLines.reserveCapacity(lines.count)

                let maxRequiredIndex = ["artist","track","album","albumartist","timems","durationms","event"].compactMap { headerIndex[$0] }.max() ?? 0

                var processed = 0
                var skipped = 0

                for line in lines.dropFirst() {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { continue }
                    let fields = parseCSVRow(line)
                    if fields.count <= maxRequiredIndex { skipped += 1; continue }

                    func value(_ key: String) -> String? {
                        guard let idx = headerIndex[key.lowercased()], idx < fields.count else { return nil }
                        let v = fields[idx]
                        return v.isEmpty ? nil : v
                    }

                    guard (value("event") ?? "") == "scrobble" else { continue }

                    let artist = value("artist") ?? ""
                    let title = value("track") ?? ""
                    let album = value("album") ?? ""
                    let albumArtist = value("albumartist") ?? ""

                    let timestampSec: Int = {
                        if let msStr = value("timems"), let ms = Int64(msStr.filter({ $0.isNumber })) { return Int(ms / 1000) }
                        return 0
                    }()

                    let durationSec: Int = {
                        if let msStr = value("durationms"), let ms = Int64(msStr.filter({ $0.isNumber })) { return Int(ms / 1000) }
                        return 0
                    }()

                    let trackNum = ""
                    let rating = "L"
                    let musicBrainzID = ""

                    let tsv = [artist, album, title, trackNum, String(durationSec), rating, String(timestampSec), albumArtist, musicBrainzID]
                        .map { escapeTSV($0) }
                        .joined(separator: "\t")

                    outputLines.append(tsv)
                    processed += 1
                }

                let outputString = outputLines.joined(separator: "\n") + "\n"

                await MainActor.run {
                    self.isConverting = false
                }

                // Save panel must be shown on main thread
                try await MainActor.run { [outputString] in
                    let savePanel = NSSavePanel()
                    if let logType = UTType.log as UTType? {
                        savePanel.allowedContentTypes = [logType]
                    } else if let plain = UTType.plainText as UTType? {
                        savePanel.allowedContentTypes = [plain]
                    } else {
                        savePanel.allowedFileTypes = ["log", "txt"]
                    }
                    savePanel.nameFieldStringValue = "converted.scrobbler.log"
                    savePanel.canCreateDirectories = true
                    savePanel.title = ".scrobbler.log destination"
                    savePanel.prompt = "Save"

                    if savePanel.runModal() == .OK, let outURL = savePanel.url {
                        do {
                            try outputString.write(to: outURL, atomically: true, encoding: .utf8)
                            self.statusMessage = "Saved: \(outURL.lastPathComponent) (\(processed) scrobbles, skipped: \(skipped))"
                            // Auto-open the saved file
                            NSWorkspace.shared.open(outURL)
                        } catch {
                            self.statusMessage = "Save failed: \(error.localizedDescription)"
                        }
                    } else {
                        self.statusMessage = "Save cancelled"
                    }
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Error: \(error.localizedDescription)"
                    self.isConverting = false
                }
            }
        }
    }

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            statusMessage = "Drop: No file URL detected"
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            if let data = item as? Data,
               let url = NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL?,
               ["csv","txt"].contains(url.pathExtension.lowercased()) {
                DispatchQueue.main.async {
                    self.selectedCSVURL = url
                    self.statusMessage = "Selected CSV: \(url.lastPathComponent) (dropped)"
                    self.loadPreviewRows(from: url)
                }
            } else if let url = item as? URL,
                      ["csv","txt"].contains(url.pathExtension.lowercased()) {
                DispatchQueue.main.async {
                    self.selectedCSVURL = url
                    self.statusMessage = "Selected CSV: \(url.lastPathComponent) (dropped)"
                    self.loadPreviewRows(from: url)
                }
            } else {
                DispatchQueue.main.async {
                    self.statusMessage = "Drop: Only .csv or .txt files are supported"
                }
            }
        }
        return true
    }

    func loadPreviewRows(from url: URL) {
        previewRows = []
        DispatchQueue.global(qos: .userInitiated).async {
            guard let inputString = try? String(contentsOf: url, encoding: .utf8) else {
                DispatchQueue.main.async {
                    self.statusMessage = "Preview: Can't read file"
                    self.previewRows = []
                }
                return
            }
            let lines = inputString.components(separatedBy: CharacterSet.newlines)
            guard !lines.isEmpty else { return }
            var firstLine = lines[0]
            if firstLine.hasPrefix("\u{FEFF}") { firstLine.removeFirst() }
            let header = parseCSVRow(firstLine)
            let headerIndex = indexMapNormalized(for: header)
            let maxRequiredIndex = ["artist","track","album","albumartist","timems","durationms","event"].compactMap { headerIndex[$0] }.max() ?? 0
            var previews: [TrackPreviewRow] = []
            for line in lines.dropFirst() {
                if previews.count >= 10 { break }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                let fields = parseCSVRow(line)
                if fields.count <= maxRequiredIndex { continue }
                func value(_ key: String) -> String? {
                    guard let idx = headerIndex[key.lowercased()], idx < fields.count else { return nil }
                    let v = fields[idx]
                    return v.isEmpty ? nil : v
                }
                guard (value("event") ?? "") == "scrobble" else { continue }
                let artist = value("artist") ?? ""
                let title = value("track") ?? ""
                let album = value("album") ?? ""
                let albumArtist = value("albumartist") ?? ""
                let timestampSec: Int = {
                    if let msStr = value("timems"), let ms = Int64(msStr.filter({ $0.isNumber })) { return Int(ms / 1000) }
                    return 0
                }()
                let durationSec: Int = {
                    if let msStr = value("durationms"), let ms = Int64(msStr.filter({ $0.isNumber })) { return Int(ms / 1000) }
                    return 0
                }()
                let row = TrackPreviewRow(artist: artist, title: title, album: album, albumArtist: albumArtist, timestamp: timestampSec, duration: durationSec)
                previews.append(row)
            }
            DispatchQueue.main.async {
                self.previewRows = previews
            }
        }
    }
}

// MARK: - CSV parsing helpers
private extension ContentView {
    // Minimal CSV parser supporting commas, quoted fields, and escaped quotes ("")
    func parseCSVRow(_ line: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var i = line.startIndex

        func appendField() {
            fields.append(field)
            field.removeAll(keepingCapacity: true)
        }

        while i < line.endIndex {
            let ch = line[i]
            if inQuotes {
                if ch == "\"" {
                    let nextIndex = line.index(after: i)
                    if nextIndex < line.endIndex && line[nextIndex] == "\"" {
                        // Escaped quote
                        field.append("\"")
                        i = nextIndex
                    } else {
                        // Closing quote
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else {
                if ch == "," {
                    appendField()
                } else if ch == "\"" {
                    inQuotes = true
                } else if ch == "\r" || ch == "\n" {
                    break
                } else {
                    field.append(ch)
                }
            }
            i = line.index(after: i)
        }
        appendField()
        return fields
    }

    func indexMap(for headers: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (i, h) in headers.enumerated() {
            map[h.trimmingCharacters(in: .whitespacesAndNewlines)] = i
        }
        return map
    }

    func indexMapNormalized(for headers: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (i, h) in headers.enumerated() {
            let key = h.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            map[key] = i
        }
        return map
    }

    // For TSV, we only need to replace tabs and newlines inside fields
    func escapeTSV(_ value: String) -> String {
        value.replacingOccurrences(of: "\t", with: " ")
             .replacingOccurrences(of: "\n", with: " ")
             .replacingOccurrences(of: "\r", with: " ")
    }
}

#Preview {
    ContentView()
}
