//
//  ContentView.swift
//  localpanoscrobblertologscrobbler
//
//  Created by Dante Alighieri on 01.05.2026.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @State private var selectedCSVURL: URL? = nil
    @State private var statusMessage: String = "No file selected"
    @State private var isConverting: Bool = false

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

            Spacer()
            Text("CSV columns: artist, track, album, albumArtist, timeMs, durationMs, event")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 260)
    }
}

// MARK: - Actions
private extension ContentView {
    func selectCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.title = "Select Panoscrobbler CSV"
        panel.prompt = "Choose"

        if panel.runModal() == .OK, let url = panel.url {
            selectedCSVURL = url
            statusMessage = "Selected CSV: \(url.lastPathComponent)"
        }
    }

    func convertAndSave() {
        guard let inputURL = selectedCSVURL else {
            statusMessage = "Please select an input CSV first"
            return
        }

        isConverting = true
        defer { isConverting = false }

        do {
            let inputString = try String(contentsOf: inputURL, encoding: .utf8)
            let lines = inputString.split(whereSeparator: \n\r.contains(_:)).map(String.init)
            guard !lines.isEmpty else {
                statusMessage = "CSV is empty"
                return
            }

            // Parse header to map columns by name (robust to column order)
            let header = parseCSVRow(lines[0])
            let headerIndex = indexMap(for: header)

            // Required columns
            guard headerIndex["artist"] != nil,
                  headerIndex["track"] != nil,
                  headerIndex["album"] != nil,
                  headerIndex["albumArtist"] != nil,
                  headerIndex["timeMs"] != nil,
                  headerIndex["durationMs"] != nil,
                  headerIndex["event"] != nil else {
                statusMessage = "CSV header missing required columns"
                return
            }

            var outputLines: [String] = ["#scrobbler-log-1.0"]
            outputLines.reserveCapacity(lines.count)

            for line in lines.dropFirst() {
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                let fields = parseCSVRow(line)

                func value(_ key: String) -> String? {
                    guard let idx = headerIndex[key], idx < fields.count else { return nil }
                    let v = fields[idx]
                    return v.isEmpty ? nil : v
                }

                guard (value("event") ?? "") == "scrobble" else { continue }

                let artist = value("artist") ?? ""
                let title = value("track") ?? ""
                let album = value("album") ?? ""
                let albumArtist = value("albumArtist") ?? ""

                let timestampSec: Int = {
                    if let msStr = value("timeMs"), let ms = Int64(msStr) { return Int(ms / 1000) }
                    return 0
                }()

                let durationSec: Int = {
                    if let msStr = value("durationMs"), let ms = Int64(msStr) { return Int(ms / 1000) }
                    return 0
                }()

                let trackNum = "" // leave empty
                let rating = "L"
                let musicBrainzID = "" // leave empty

                // TSV fields in order: Artist \t Album \t Title \t TrackNum \t Duration \t Rating \t Timestamp \t AlbumArtist \t MusicBrainzID
                let tsv = [artist, album, title, trackNum, String(durationSec), rating, String(timestampSec), albumArtist, musicBrainzID]
                    .map { escapeTSV($0) }
                    .joined(separator: "\t")

                outputLines.append(tsv)
            }

            let outputString = outputLines.joined(separator: "\n") + "\n"

            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.log]
            savePanel.nameFieldStringValue = "converted.scrobbler.log"
            savePanel.canCreateDirectories = true
            savePanel.title = ".scrobbler.log destination"
            savePanel.prompt = "Save"

            if savePanel.runModal() == .OK, let outURL = savePanel.url {
                try outputString.write(to: outURL, atomically: true, encoding: .utf8)
                statusMessage = "Saved: \(outURL.lastPathComponent) (\(outputLines.count - 1) scrobbles)"
            } else {
                statusMessage = "Save cancelled"
            }
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }
}

// MARK: - CSV parsing helpers
private extension ContentView {
    // Minimal CSV parser supporting commas, quoted fields, and escaped quotes ("")
    func parseCSVRow(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()

        while let ch = iterator.next() {
            if inQuotes {
                if ch == "\"" { // quote
                    if let peek = iterator.next() {
                        if peek == "\"" { // escaped quote
                            current.append("\"")
                        } else if peek == "," { // end quoted field
                            result.append(current)
                            current = ""
                            inQuotes = false
                            // consumed comma, continue
                        } else {
                            // end quote, then a non-comma char; treat as end quote and continue parsing that char
                            inQuotes = false
                            if peek == "\r" || peek == "\n" {
                                // end of line
                                break
                            } else {
                                // not a comma, treat as separator missing; append and continue
                                if peek == "\t" { // unlikely in CSV, but handle gracefully
                                    result.append(current)
                                    current = ""
                                } else if peek == "," {
                                    result.append(current)
                                    current = ""
                                } else {
                                    // unexpected char, append and continue
                                    current.append(peek)
                                }
                            }
                        }
                    } else {
                        // closing quote at end of line
                        result.append(current)
                        current = ""
                        inQuotes = false
                    }
                } else {
                    current.append(ch)
                }
            } else {
                if ch == "," {
                    result.append(current)
                    current = ""
                } else if ch == "\"" {
                    inQuotes = true
                } else if ch == "\r" || ch == "\n" {
                    break
                } else {
                    current.append(ch)
                }
            }
        }
        // append last field
        result.append(current)
        return result
    }

    func indexMap(for headers: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (i, h) in headers.enumerated() {
            map[h.trimmingCharacters(in: .whitespacesAndNewlines)] = i
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
