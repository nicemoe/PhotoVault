import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

struct WiFiTransferView: View {

    @Environment(WiFiService.self) private var wifi
    @Environment(\.dismiss) private var dismiss

    @State private var toastItem: Toast?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard

                    if wifi.isRunning {
                        activityCard
                    }

                    stepsCard

                    Text("上传期间请保持 App 在前台，屏幕会自动常亮。切到后台或锁屏后连接会中断。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.tertiaryLabel)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                }
                .padding(Theme.Metric.margin)
                .padding(.bottom, 30)
            }
            .background(Theme.background)
            .scrollIndicators(.hidden)
            .navigationTitle("WiFi 上传")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .font(.system(size: 16, weight: .semibold))
                }
            }
        }
        .toast($toastItem)
    }

    // MARK: 状态卡

    private var statusCard: some View {
        VStack(spacing: 18) {
            switch wifi.status {

            case .stopped:
                iconBadge("wifi", tint: Theme.secondaryLabel)
                VStack(spacing: 6) {
                    Text("WiFi 上传未开启")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.label)
                    Text("开启后，同一 WiFi 下的电脑或手机\n用浏览器就能管理分组、上传图片")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.secondaryLabel)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }
                Button("开启 WiFi 上传") {
                    Task { await wifi.start() }
                }
                .buttonStyle(PrimaryButtonStyle())

            case .starting:
                iconBadge("wifi", tint: Theme.accent)
                ProgressView("正在启动服务…")
                    .font(.system(size: 14))
                    .tint(Theme.accent)
                    .padding(.vertical, 8)

            case .running(let url):
                if let qr = Self.qrImage(from: url) {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 168, height: 168)
                        .padding(12)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                VStack(spacing: 8) {
                    Text("在浏览器中打开")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.secondaryLabel)

                    Button {
                        UIPasteboard.general.string = url
                        toastItem = Toast(icon: "doc.on.doc.fill", text: "地址已复制")
                    } label: {
                        HStack(spacing: 8) {
                            Text(url)
                                .font(.system(size: 19, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.accent)
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.accent.opacity(0.7))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }

                HStack(spacing: 7) {
                    Circle().fill(Color(hex: 0x2FBF5B)).frame(width: 7, height: 7)
                    Text("服务运行中")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.secondaryLabel)
                }

                Button("停止服务") {
                    wifi.stop()
                }
                .buttonStyle(SecondaryButtonStyle())

            case .failed(let message):
                iconBadge("exclamationmark.triangle", tint: Theme.danger)
                VStack(spacing: 6) {
                    Text("启动失败")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.label)
                    Text(message)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.secondaryLabel)
                        .multilineTextAlignment(.center)
                }
                Button("重试") {
                    Task { await wifi.start() }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .flatCard()
    }

    private func iconBadge(_ name: String, tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(tint.opacity(0.12))
                .frame(width: 76, height: 76)
            Image(systemName: name)
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(tint)
        }
    }

    // MARK: 实时动态

    private var activityCard: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(wifi.receivedCount)")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.label)
                    .contentTransition(.numericText())
                Text("本次已接收")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondaryLabel)
            }
            .frame(width: 92, alignment: .leading)

            Rectangle().fill(Theme.hairline).frame(width: 1, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text("最近动态")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondaryLabel)
                Text(wifi.lastEvent ?? "等待网页端操作…")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.label)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .flatCard()
        .animation(.easeOut(duration: 0.2), value: wifi.receivedCount)
    }

    // MARK: 使用步骤

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("使用方法")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.label)
                .padding(.bottom, 14)

            step(1, "让电脑和手机连同一个 WiFi", "两台设备必须在同一个局域网内")
            step(2, "浏览器打开上面的地址", "或用另一台手机扫描二维码")
            step(3, "在网页里管理并上传", "可新建分组、新建目录、移动目录，把图片拖进网页就能传到 App")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .flatCard()
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.accent)
                .frame(width: 24, height: 24)
                .background(Theme.accent.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Theme.label)
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 16)
    }

    // MARK: 二维码

    private static func qrImage(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
