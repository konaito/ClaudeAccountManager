// 見た目の確かめ用。CamBar --render <cam usage --json の出力> <PNG の書き出し先> [今の時刻（epoch 秒）]
// メニューバーにもメニューにも何も出さず、メニューの中身を PNG に描き、タイトルの文字列を標準出力に出して終わる。
// 走らせ方は menubar/preview.sh にある。
import AppKit
import SwiftUI

@MainActor
func renderPreview(_ args: [String]) -> Never {
    guard args.count >= 2 else {
        FileHandle.standardError.write("使い方: CamBar --render <json> <png> [now]\n".data(using: .utf8)!)
        exit(2)
    }
    do {
        let usage = try JSONDecoder().decode(Usage.self, from: Data(contentsOf: URL(fileURLWithPath: args[0])))
        let now = args.count >= 3 ? Date(timeIntervalSince1970: Double(args[2])!) : Date()
        let title = menuTitle(usage, error: nil)
        let content = VStack(alignment: .leading, spacing: 0) {
            Text("メニューバー:" + title)
                .font(.system(size: 13))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            Divider()
            UsageView(usage: usage, error: nil, now: now)
        }
        .background(Color.white)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write("描けなかった\n".data(using: .utf8)!)
            exit(1)
        }
        try png.write(to: URL(fileURLWithPath: args[1]))
        print("title:" + title)
        exit(0)
    } catch {
        FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
        exit(1)
    }
}
