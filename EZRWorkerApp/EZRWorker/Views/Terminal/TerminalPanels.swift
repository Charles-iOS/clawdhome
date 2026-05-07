import AppKit
import Foundation
import SwiftTerm
import SwiftUI

private func firstOAuthAuthorizeURL(in text: String) -> URL? {
    for token in text.split(whereSeparator: { $0.isWhitespace }) {
        let candidate = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\"'()[]<>.,"))
        guard candidate.hasPrefix("https://auth.openai.com/oauth/authorize") else { continue }
        if let url = URL(string: candidate) {
            return url
        }
    }
    return nil
}

private func openExternalURL(_ url: URL) {
    DispatchQueue.main.async {
        _ = NSWorkspace.shared.open(url)
    }
}

private func writeToPasteboard(_ content: Data) {
    guard !content.isEmpty else { return }
    DispatchQueue.main.async {
        let board = NSPasteboard.general
        board.clearContents()
        if let text = String(data: content, encoding: .utf8) {
            board.setString(text, forType: .string)
        } else {
            board.setData(content, forType: .string)
        }
    }
}

final class LocalTerminalControl: ObservableObject {
    fileprivate weak var terminalView: LocalProcessTerminalView?
    fileprivate var sendRawHandler: ((Data) -> Void)?
    fileprivate var terminateHandler: (() -> Void)?
    private var pendingRawInputs: [Data] = []

    private func flushPendingInputsIfNeeded() {
        guard let handler = sendRawHandler, !pendingRawInputs.isEmpty else { return }
        for data in pendingRawInputs {
            handler(data)
        }
        pendingRawInputs.removeAll(keepingCapacity: false)
    }

    private func enqueueOrSend(_ data: Data) {
        guard !data.isEmpty else { return }
        if let handler = sendRawHandler {
            handler(data)
        } else {
            pendingRawInputs.append(data)
        }
    }

    fileprivate func attach(_ view: LocalProcessTerminalView) {
        terminalView = view
        sendRawHandler = { [weak view] data in
            guard let view else { return }
            view.process.send(data: ArraySlice(data))
        }
        terminateHandler = { [weak view] in
            view?.terminate()
        }
        flushPendingInputsIfNeeded()
    }

    func sendInterrupt() {
        enqueueOrSend(Data([0x03]))
    }

    func terminate() {
        terminateHandler?()
    }

    func sendText(_ text: String) {
        if let data = text.data(using: .utf8) {
            enqueueOrSend(data)
        }
    }

    func sendLine(_ text: String) {
        sendText(text)
        sendText("\r")
    }
}

final class OutputObservingLocalProcessTerminalView: LocalProcessTerminalView {
    var onOutputBytes: ((ArraySlice<UInt8>) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        onOutputBytes?(slice)
        super.dataReceived(slice: slice)
    }
}

struct TerminalLogPanel: View {
    let username: String

    @State private var autoScroll = true
    @State private var searchText = ""
    @State private var searchRequest = LogSearchRequest()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.k("auto.terminal_log_view.logs", fallback: "日志输出"))
                    .font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
                Spacer()
                TextField(L10n.k("auto.terminal_log_view.searchlogs", fallback: "搜索日志"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .font(.caption)
                    .onSubmit { issueSearch(.next) }
                Button {
                    issueSearch(.previous)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button {
                    issueSearch(.next)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Toggle(L10n.k("auto.terminal_log_view.auto_scroll", fallback: "自动滚动"), isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            Divider()
            LogTextNSView(
                username: username,
                autoScroll: $autoScroll,
                searchText: $searchText,
                searchRequest: $searchRequest
            )
            .frame(height: 180)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
    }

    private func issueSearch(_ direction: LogSearchDirection) {
        searchRequest = LogSearchRequest(token: searchRequest.token + 1, direction: direction)
    }
}

private enum LogSearchDirection {
    case next
    case previous
}

private struct LogSearchRequest: Equatable {
    var token: Int = 0
    var direction: LogSearchDirection = .next
}

private struct LogTextNSView: NSViewRepresentable {
    let username: String
    @Binding var autoScroll: Bool
    @Binding var searchText: String
    @Binding var searchRequest: LogSearchRequest

    func makeCoordinator() -> LogFeedCoordinator {
        LogFeedCoordinator(username: username)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.string = ""

        scrollView.documentView = textView
        context.coordinator.start(scrollView: scrollView, textView: textView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(autoScroll: autoScroll)
        context.coordinator.updateSearchText(searchText)
        context.coordinator.handleSearchRequest(searchRequest)
    }
}

private final class LogFeedCoordinator: NSObject {
    let username: String
    var autoScroll = true

    private var fileOffset = 0
    private var timer: Timer?
    private weak var scrollView: NSScrollView?
    private weak var textView: NSTextView?
    private var lastSearchToken = 0
    private var normalizedSearchText = ""
    private let logAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor.labelColor
    ]

    init(username: String) {
        self.username = username
    }

    deinit { timer?.invalidate() }

    func start(scrollView: NSScrollView, textView: NSTextView) {
        self.scrollView = scrollView
        self.textView = textView
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.pollLog()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func update(autoScroll: Bool) {
        let wasEnabled = self.autoScroll
        self.autoScroll = autoScroll
        if autoScroll && !wasEnabled {
            scrollToEnd()
        }
    }

    func updateSearchText(_ searchText: String) {
        normalizedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedSearchText.isEmpty {
            textView?.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    fileprivate func handleSearchRequest(_ request: LogSearchRequest) {
        guard request.token != lastSearchToken else { return }
        lastSearchToken = request.token
        performSearch(direction: request.direction)
    }

    private func pollLog() {
        let path = "/tmp/ezrworker-init-\(username).log"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? NSNumber,
           size.intValue < fileOffset {
            fileOffset = 0
            textView?.string = ""
        }
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: UInt64(fileOffset))
        let data = fh.readDataToEndOfFile()
        guard !data.isEmpty else { return }
        fileOffset += data.count
        let chunk = String(decoding: data, as: UTF8.self)
        appendLog(chunk)
    }

    private func appendLog(_ chunk: String) {
        guard !chunk.isEmpty, let textView else { return }
        let previousOrigin = autoScroll ? nil : currentScrollOrigin()
        if let storage = textView.textStorage {
            storage.append(NSAttributedString(string: chunk, attributes: logAttributes))
        } else {
            textView.string += chunk
        }
        if autoScroll {
            scrollToEnd()
        } else if let previousOrigin {
            restoreScrollOrigin(previousOrigin)
        }
    }

    private func scrollToEnd() {
        guard let textView else { return }
        let end = NSRange(location: textView.string.utf16.count, length: 0)
        textView.scrollRangeToVisible(end)
    }

    private func currentScrollOrigin() -> NSPoint? {
        scrollView?.contentView.bounds.origin
    }

    private func restoreScrollOrigin(_ origin: NSPoint) {
        guard let scrollView, let docView = scrollView.documentView else { return }
        let maxY = max(0, docView.frame.height - scrollView.contentSize.height)
        let target = NSPoint(x: max(0, origin.x), y: min(max(0, origin.y), maxY))
        docView.scroll(target)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let scrollView = self.scrollView,
                  let docView = scrollView.documentView else { return }
            let maxY = max(0, docView.frame.height - scrollView.contentSize.height)
            let stabilized = NSPoint(x: max(0, origin.x), y: min(max(0, origin.y), maxY))
            docView.scroll(stabilized)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func performSearch(direction: LogSearchDirection) {
        guard let textView else { return }
        let term = normalizedSearchText
        guard !term.isEmpty else { return }

        let text = textView.string as NSString
        let fullLength = text.length
        guard fullLength > 0 else { return }

        let current = textView.selectedRange()
        let options: NSString.CompareOptions = [.caseInsensitive]

        let result: NSRange
        switch direction {
        case .next:
            let start = min(fullLength, max(0, NSMaxRange(current)))
            let forwardRange = NSRange(location: start, length: fullLength - start)
            let forwardResult = text.range(of: term, options: options, range: forwardRange)
            if forwardResult.location != NSNotFound {
                result = forwardResult
            } else {
                let wrappedRange = NSRange(location: 0, length: start)
                result = text.range(of: term, options: options, range: wrappedRange)
            }
        case .previous:
            let anchor = max(0, min(fullLength - 1, current.location - 1))
            let backwardRange = NSRange(location: 0, length: anchor + 1)
            let backwardResult = text.range(of: term, options: options.union(.backwards), range: backwardRange)
            if backwardResult.location != NSNotFound {
                result = backwardResult
            } else {
                let wrappedStart = anchor + 1
                let wrappedLength = fullLength - wrappedStart
                let wrappedRange = NSRange(location: wrappedStart, length: max(0, wrappedLength))
                result = text.range(of: term, options: options.union(.backwards), range: wrappedRange)
            }
        }

        guard result.location != NSNotFound else { return }
        textView.setSelectedRange(result)
        textView.scrollRangeToVisible(result)
    }
}

private struct LocalProcessNSView: NSViewRepresentable {
    let username: String
    var subcommandArgs: [String] = []
    var executable: String? = nil
    var executableArgs: [String] = []
    var environmentOverrides: [String: String] = [:]
    var onOutput: ((String) -> Void)? = nil
    var control: LocalTerminalControl? = nil
    var onExit: ((Int32?) -> Void)?

    func makeCoordinator() -> LocalProcessCoordinator {
        LocalProcessCoordinator(onExit: onExit)
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = OutputObservingLocalProcessTerminalView(frame: .zero)
        terminal.processDelegate = context.coordinator
        terminal.allowMouseReporting = false
        terminal.nativeForegroundColor = NSColor.labelColor
        terminal.nativeBackgroundColor = NSColor.textBackgroundColor
        terminal.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        terminal.onOutputBytes = { bytes in
            let chunk = String(decoding: Array(bytes), as: UTF8.self)
            guard !chunk.isEmpty else { return }
            context.coordinator.handleOutputChunk(chunk)
            guard let onOutput else { return }
            DispatchQueue.main.async {
                onOutput(chunk)
            }
        }

        let npmGlobalBin = "/Users/\(username)/.npm-global/bin"
        let npmGlobalDir = "/Users/\(username)/.npm-global"
        let userBrewBin = "/Users/\(username)/.brew/bin"
        let defaultPathEnv = "\(npmGlobalBin):\(userBrewBin):/usr/bin:/bin"
        let pathEnv = environmentOverrides["PATH"] ?? defaultPathEnv
        let openclawPath = "\(npmGlobalBin)/openclaw"
        let command = executable ?? openclawPath
        let commandArgs = executable != nil ? executableArgs : subcommandArgs
        let homePath = "/Users/\(username)"

        let runtimeExecutable = "/usr/bin/sudo"
        var runtimeArgs = [
            "-n", "-u", username, "-H",
            "/usr/bin/env",
            "HOME=\(homePath)",
            "PATH=\(pathEnv)",
            "NPM_CONFIG_PREFIX=\(npmGlobalDir)",
            "npm_config_prefix=\(npmGlobalDir)",
            "TERM=xterm-256color"
        ]
        for (key, value) in environmentOverrides where key != "PATH" {
            runtimeArgs.append("\(key)=\(value)")
        }
        runtimeArgs.append(command)
        runtimeArgs.append(contentsOf: commandArgs)

        terminal.startProcess(
            executable: runtimeExecutable,
            args: runtimeArgs,
            environment: nil
        )
        control?.attach(terminal)
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: LocalProcessCoordinator) {
        nsView.terminate()
    }
}

struct CommandTerminalPanel: View {
    let username: String
    let subcommandArgs: [String]
    var minHeight: CGFloat = 160
    var onExit: ((Int32?) -> Void)? = nil

    private var commandSummary: String {
        "openclaw " + subcommandArgs.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.caption).foregroundStyle(.secondary)
                Text(commandSummary)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            LocalProcessNSView(username: username, subcommandArgs: subcommandArgs, onExit: onExit)
                .frame(minHeight: minHeight)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
    }
}

struct UserCommandTerminalPanel: View {
    let username: String
    let executable: String
    let args: [String]
    var minHeight: CGFloat = 220
    var environmentOverrides: [String: String] = [:]
    var onOutput: ((String) -> Void)? = nil
    var control: LocalTerminalControl? = nil
    var onExit: ((Int32?) -> Void)? = nil

    private var commandSummary: String {
        ([executable] + args).joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.caption).foregroundStyle(.secondary)
                Text(commandSummary)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Label(L10n.k("auto.terminal_log_view.interactive_mode", fallback: "交互模式"), systemImage: "keyboard")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            LocalProcessNSView(
                username: username,
                executable: executable,
                executableArgs: args,
                environmentOverrides: environmentOverrides,
                onOutput: onOutput,
                control: control,
                onExit: onExit
            )
            .frame(minHeight: minHeight)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
    }
}

final class LocalProcessCoordinator: NSObject, LocalProcessTerminalViewDelegate {
    var onExit: ((Int32?) -> Void)?
    private var openedOAuthURLs: Set<String> = []

    init(onExit: ((Int32?) -> Void)?) {
        self.onExit = onExit
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            self?.onExit?(exitCode)
        }
    }

    func handleOutputChunk(_ chunk: String) {
        guard let url = firstOAuthAuthorizeURL(in: chunk) else { return }
        let raw = url.absoluteString
        guard !raw.isEmpty, !openedOAuthURLs.contains(raw) else { return }
        openedOAuthURLs.insert(raw)
        openExternalURL(url)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        openExternalURL(url)
    }
    func clipboardCopy(source: TerminalView, content: Data) {
        writeToPasteboard(content)
    }
}
