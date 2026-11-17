import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var library: AudioLibrary
    @State private var tab = 0
    @State private var importing = false
    @State private var settings = false
    @State private var showChapters = false
    @State private var speed = 1.0
    @State private var sleepMinutes = 0
    private let bookTypes: [UTType] = [.epub, .plainText]

    var body: some View {
        ZStack {
            TingTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                if tab == 0 { player }
                else { shelf }
                bottomBar
            }
        }
        .preferredColorScheme(.light)
        .fileImporter(isPresented: $importing, allowedContentTypes: bookTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): library.importFiles(urls); tab = 0
            case .failure(let error): library.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $settings) { settingsSheet }
        .sheet(isPresented: $showChapters) {
            NavigationStack {
                ContentUnavailableView("章节目录尚未就绪", systemImage: "list.bullet",
                    description: Text("EPUB 章节解析将在下一阶段接入。"))
                    .navigationTitle("章节目录")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showChapters = false } } }
            }
            .presentationDetents([.medium])
        }
        .alert("提示", isPresented: Binding(get: { library.errorMessage != nil },
                                           set: { if !$0 { library.errorMessage = nil } })) {
            Button("知道了") { library.errorMessage = nil }
        } message: { Text(library.errorMessage ?? "") }
    }

    private var player: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Text("TingX").font(.system(size: 29, weight: .semibold, design: .serif))
                Spacer()
                Button { settings = true } label: {
                    Image(systemName: "ellipsis").font(.title3)
                        .frame(width: 44, height: 44).background(.white, in: Circle())
                }
            }
            .padding(.top, 14)

            Spacer(minLength: 4)
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(LinearGradient(colors: [Color(red: 0.82, green: 0.85, blue: 0.79),
                                                  Color(red: 0.44, green: 0.55, blue: 0.47)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(spacing: 15) {
                    Image(systemName: "book.closed.fill").font(.system(size: 78)).foregroundStyle(.white.opacity(0.9))
                    Text(library.selected?.title ?? "TingX")
                        .font(.title2.bold()).foregroundStyle(.white)
                        .multilineTextAlignment(.center).padding(.horizontal)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 330)
            .shadow(color: .black.opacity(0.08), radius: 16, y: 10)

            VStack(spacing: 8) {
                Text(library.selected?.title ?? "导入一本书，开始收听")
                    .font(.title2.bold()).lineLimit(2).multilineTextAlignment(.center)
                Text(library.selected == nil ? "支持本地 EPUB / TXT" : "尚未接入离线语音引擎")
                    .font(.subheadline).foregroundStyle(TingTheme.muted)
                Text("等待语音引擎").font(.subheadline.weight(.medium)).padding(.top, 4)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 8) {
                Capsule().fill(TingTheme.track).frame(height: 5)
                HStack {
                    Text("00:00")
                    Spacer()
                    Text("00:00")
                }.font(.caption).foregroundStyle(TingTheme.muted)
            }.padding(.top, 14)

            HStack {
                Image(systemName: "backward.end.fill")
                Spacer()
                Image(systemName: "gobackward.15")
                Spacer()
                Image(systemName: "play.fill").font(.title)
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(TingTheme.green, in: RoundedRectangle(cornerRadius: 25))
                Spacer()
                Image(systemName: "goforward.15")
                Spacer()
                Image(systemName: "forward.end.fill")
            }
            .font(.title2).foregroundStyle(TingTheme.green)
            .opacity(library.selected == nil ? 0.35 : 0.65)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("播放功能尚未接入")

            HStack(spacing: 0) {
                utility("speedometer", "语速", String(format: "%.1f×", speed)) {
                    speed = speed >= 1.5 ? 0.8 : (speed * 10 + 1).rounded() / 10
                }
                utility("moon", "定时关闭", sleepMinutes == 0 ? "关闭" : "\(sleepMinutes)分钟") {
                    sleepMinutes = sleepMinutes == 0 ? 15 : sleepMinutes == 15 ? 30 : sleepMinutes == 30 ? 60 : 0
                }
                utility("list.bullet", "章节目录", "查看") { showChapters = true }
            }
            .padding(.vertical, 14)
            .background(.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 23))
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 25)
        .foregroundStyle(TingTheme.ink)
    }

    private func utility(_ icon: String, _ title: String, _ value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.caption.weight(.medium))
                Text(value).font(.caption2).foregroundStyle(TingTheme.muted)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private var shelf: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("书架").font(.largeTitle.bold())
                            Text("听").font(.caption.bold()).foregroundStyle(.white)
                                .padding(6).background(TingTheme.green, in: RoundedRectangle(cornerRadius: 5))
                        }
                        Text("共 \(library.books.count) 本").foregroundStyle(TingTheme.muted)
                    }
                    Spacer()
                    Button { settings = true } label: {
                        Image(systemName: "slider.horizontal.3").font(.title3)
                            .frame(width: 50, height: 50).background(.white, in: Circle())
                    }
                }.padding(.top, 28)

                if let current = library.selected {
                    HStack(spacing: 20) {
                        cover(current).frame(width: 112, height: 150)
                        VStack(alignment: .leading, spacing: 11) {
                            Text("继续收听").font(.subheadline.weight(.semibold)).foregroundStyle(TingTheme.green)
                            Text(current.title).font(.title3.bold()).lineLimit(2)
                            Text("已听 \(Int(current.progress * 100))%").foregroundStyle(TingTheme.muted)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(TingTheme.track)
                                    Capsule().fill(TingTheme.green).frame(width: geo.size.width * current.progress)
                                }
                            }.frame(height: 6)
                            Button("继续") { tab = 0 }
                                .font(.subheadline.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 24).padding(.vertical, 10)
                                .background(TingTheme.green, in: Capsule())
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white, in: RoundedRectangle(cornerRadius: 26))
                }

                HStack(spacing: 10) {
                    Capsule().fill(TingTheme.green).frame(width: 5, height: 24)
                    Text("我的书架").font(.title2.bold())
                }

                if library.books.isEmpty {
                    ContentUnavailableView("书架还是空的", systemImage: "books.vertical",
                                           description: Text("点击底部＋导入 EPUB 或 TXT"))
                        .frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 22) {
                        ForEach(library.books) { book in
                            Button { library.select(book); tab = 0 } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    cover(book).aspectRatio(0.78, contentMode: .fit)
                                    Text(book.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text("已听 \(Int(book.progress * 100))%").font(.caption).foregroundStyle(TingTheme.muted)
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(TingTheme.track)
                                            Capsule().fill(TingTheme.green).frame(width: geo.size.width * book.progress)
                                        }
                                    }.frame(height: 4)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("删除", role: .destructive) { library.delete(book) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 23).padding(.bottom, 30)
        }
        .foregroundStyle(TingTheme.ink)
    }

    private func cover(_ book: AudioBook) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [.init(red: 0.70, green: 0.75, blue: 0.68),
                                              .init(red: 0.24, green: 0.35, blue: 0.30)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack {
                Image(systemName: "book.closed").font(.title2).padding(.bottom, 8)
                Text(book.title).font(.headline).lineLimit(4).multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
            }.foregroundStyle(.white).padding(9)
        }
        .shadow(color: .black.opacity(0.09), radius: 7, y: 5)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            tabButton("headphones", "播放器", selected: tab == 0) { tab = 0 }
            Button { importing = true } label: {
                Image(systemName: "plus").font(.system(size: 32, weight: .light))
                    .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 62)
                    .background(TingTheme.green, in: Capsule())
            }
            tabButton("books.vertical", "书架", selected: tab == 1) { tab = 1 }
        }
        .padding(8)
        .background(.white.opacity(0.95), in: Capsule())
        .overlay(Capsule().stroke(.white, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 16, y: 8)
        .padding(.horizontal, 22).padding(.bottom, 8)
    }

    private func tabButton(_ icon: String, _ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.caption.weight(.medium))
            }
            .foregroundStyle(selected ? TingTheme.green : TingTheme.ink)
            .frame(maxWidth: .infinity).frame(height: 62)
            .background(selected ? TingTheme.track.opacity(0.65) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("TingX") {
                    LabeledContent("本地书籍", value: "\(library.books.count) 本")
                    LabeledContent("语音引擎", value: "尚未接入")
                }
                Section("隐私") {
                    Text("仅使用本地导入文件，不需要账号、云同步或在线书城。")
                }
            }
            .navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { settings = false } } }
        }
        .presentationDetents([.medium, .large])
    }
}
