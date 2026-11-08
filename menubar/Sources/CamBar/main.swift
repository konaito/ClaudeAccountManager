// CamBar: cam のコマンドごとの使用率をメニューバーに出す。
// 使用率は `cam usage --json` の結果だけを使い、取得の仕組みは cam 側に1本化する。
// アカウントの切り替えはしない（起動は端末で cam auto か各コマンドを使う）。
import AppKit
import SwiftUI

struct Account: Decodable, Identifiable {
    let name: String
    let email: String
    let five_hour: Double?
    let seven_day: Double?
    let five_hour_resets_at: Double?
    let seven_day_resets_at: Double?
    var id: String { name }
}

struct Usage: Decodable {
    let best: String?
    let fetched_at: Double
    let accounts: [Account]
}

enum Cam {
    // 試すときは CAM_BIN で別の cam を指せる
    static let path = ProcessInfo.processInfo.environment["CAM_BIN"] ?? NSHomeDirectory() + "/.cam/bin/cam"

    // launchd から起動すると PATH に Homebrew が入らず、cam が使う jq が見つからない
    static func usage() throws -> Usage {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["usage", "--json"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "cam", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: msg?.isEmpty == false ? msg! : "cam usage が失敗した（終了コード \(p.terminationStatus)）"])
        }
        return try JSONDecoder().decode(Usage.self, from: data)
    }
}

func percent(_ v: Double?) -> String {
    guard let v else { return "?" }
    return "\(Int(v.rounded()))%"
}

func color(_ v: Double?) -> Color {
    guard let v else { return .secondary }
    if v >= 100 { return .red }
    if v >= 80 { return .orange }
    return .primary
}

func resetText(_ epoch: Double?, _ format: String) -> String {
    guard let epoch else { return "" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "ja_JP")
    f.dateFormat = format
    return f.string(from: Date(timeIntervalSince1970: epoch)) + " リセット"
}

struct UsageView: View {
    let usage: Usage?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let usage {
                Text(usage.best.map { "cam auto → \($0)" } ?? "cam auto が選べるコマンドがない")
                    .font(.system(size: 12, weight: .semibold))
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        Text("")
                        Text("5時間").gridColumnAlignment(.trailing)
                        Text("")
                        Text("週次").gridColumnAlignment(.trailing)
                        Text("")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    ForEach(usage.accounts) { a in
                        row(a, best: a.name == usage.best)
                    }
                }
            }
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360, alignment: .leading)
            }
            if usage == nil && error == nil {
                Text("読み込み中…").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    func row(_ a: Account, best: Bool) -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 1) {
                Text(a.name).font(.system(size: 13, weight: best ? .bold : .regular))
                Text(a.email).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if a.five_hour == nil {
                Text("不明").foregroundStyle(.secondary)
                Text("一度 \(a.name) を起動すると直る").font(.system(size: 10)).foregroundStyle(.secondary)
                    .gridCellColumns(3)
            } else {
                Text(percent(a.five_hour)).foregroundStyle(color(a.five_hour))
                Text(resetText(a.five_hour_resets_at, "H:mm")).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(percent(a.seven_day)).foregroundStyle(color(a.seven_day))
                Text(resetText(a.seven_day_resets_at, "M/d H:mm")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13).monospacedDigit())
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var usage: Usage?
    var error: String?
    var loading = false
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = item.button {
            let image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "cam")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        updateTitle()
        refresh()
        // 使用率の API は公開されていないので、間隔は控えめにする
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let host = NSHostingView(rootView: UsageView(usage: usage, error: error))
        host.frame.size = host.fittingSize
        let view = NSMenuItem()
        view.view = host
        menu.addItem(view)
        menu.addItem(.separator())
        let updated = NSMenuItem(title: updatedText(), action: nil, keyEquivalent: "")
        updated.isEnabled = false
        menu.addItem(updated)
        let reload = NSMenuItem(title: "今すぐ更新", action: #selector(refreshNow), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)
        let quit = NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    func updatedText() -> String {
        if loading { return "更新中…" }
        guard let usage else { return "未取得" }
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return "更新: " + f.string(from: Date(timeIntervalSince1970: usage.fetched_at))
    }

    @objc func refreshNow() { refresh() }

    func refresh() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try Cam.usage() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.loading = false
                switch result {
                case .success(let u):
                    self.usage = u
                    self.error = nil
                case .failure(let e):
                    // 前回の値は残し、失敗したことだけ出す
                    self.error = e.localizedDescription
                }
                self.updateTitle()
            }
        }
    }

    // メニューバーには cam auto が選ぶコマンドとその5時間枠を出す
    func updateTitle() {
        guard let button = item.button else { return }
        if let usage, let best = usage.best, let a = usage.accounts.first(where: { $0.name == best }) {
            button.title = " \(best) \(percent(a.five_hour))"
        } else if usage != nil {
            button.title = " なし"
        } else {
            button.title = error == nil ? " …" : " ?"
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
