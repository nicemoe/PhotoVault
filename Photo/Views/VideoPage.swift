import SwiftUI
import AVKit

/// 预览页里的一段视频。
///
/// 只有当前这一页才真的持有 AVPlayer。TabView 会提前把左右相邻页建出来，
/// 每页都挂播放器的话会同时开好几路解码，白白吃内存和电。
struct VideoPage: View {

    let asset: Asset
    let isCurrent: Bool
    var onTap: () -> Void

    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                // 播放器还没建好时先显示封面，不然翻到这一页是一片黑
                AssetImage(asset: asset, maxPixel: 900)
                    .aspectRatio(contentMode: .fit)
                    .overlay {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 54))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(radius: 8)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onTap() }
            }
        }
        .onChange(of: isCurrent, initial: true) { _, current in
            if current { start() } else { stop() }
        }
        .onDisappear { stop() }
    }

    private func start() {
        guard player == nil else { return }
        // 静音键按下时也要出声——用户是主动点开看的，不是自动播放的广告
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let item = AVPlayerItem(url: LibraryStore.fileURL(for: asset))
        let made = AVPlayer(playerItem: item)
        made.actionAtItemEnd = .pause
        player = made
        made.play()
    }

    private func stop() {
        player?.pause()
        player = nil
        // 不停用音频会话：退出预览时可能还有别的视频要播，
        // 频繁开关会让扬声器发出咔哒声
    }
}
