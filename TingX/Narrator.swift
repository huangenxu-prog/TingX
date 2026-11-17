import AVFoundation
import Combine

@MainActor
final class Narrator: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var titles: [String] = []
    @Published private(set) var chapter = 0
    @Published private(set) var segment = 0
    @Published private(set) var pieces: [String] = []
    @Published private(set) var playing = false
    @Published private(set) var loading = false
    @Published private(set) var finished = false
    @Published var speed = UserDefaults.standard.double(forKey: "narrationSpeed")
    @Published private(set) var sleepMinutes = 0

    private weak var library: AudioLibrary?
    private var bookID: UUID?
    private let voice = CosyVoice(directory: Bundle.main.bundleURL.appendingPathComponent("CosyVoice3"))
    private var player: AVAudioPlayer?
    private var synthesis: Task<Void, Never>?
    @Published private(set) var preparing = false
    private var document: ListeningBook?
    private var generation = UUID()
    private var timer: Task<Void, Never>?
    private var loader: Task<Void, Never>?
    private var resumeAfterLoad = false

    override init() {
        super.init()
        if speed <= 0 { speed = 1 }
        NotificationCenter.default.addObserver(self, selector: #selector(interruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    @objc private func interruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              raw == AVAudioSession.InterruptionType.began.rawValue else { return }
        Task { @MainActor in self.pause() }
    }

    func open(_ library: AudioLibrary) {
        self.library = library
        loader?.cancel()
        pause()
        generation = UUID()
        titles = []; pieces = []; document = nil; finished = false
        bookID = library.selectedID
        chapter = 0; segment = 0; loading = false
        guard let book = library.selected else { return }
        let token = generation
        let url = library.url(for: book)
        loading = true
        loader = Task {
            do {
                let result = try await Task.detached { try ListeningBook.open(url) }.value
                guard token == generation else { return }
                document = result
                titles = result.titles
                loadChapter(book.chapter ?? 0, at: book.segment ?? 0, autoplay: false, restoring: true)
            } catch { fail(error, token: token) }
        }
    }

    func loadChapter(_ index: Int, at position: Int = 0, autoplay: Bool, direction: Int = 1, restoring: Bool = false) {
        guard let document, !titles.isEmpty else { loading = false; return }
        loader?.cancel()
        pause()
        loading = true; finished = false
        resumeAfterLoad = autoplay
        let start = min(max(index, 0), titles.count - 1)
        let total = titles.count
        generation = UUID()
        let token = generation
        loader = Task {
            do {
                let result = try await Task.detached { () throws -> (Int, [String])? in
                    var i = start
                    while (0..<total).contains(i) {
                        let lines = try document.segments(at: i)
                        if !lines.isEmpty { return (i, lines) }
                        i += direction
                    }
                    return nil
                }.value
                guard token == generation else { return }
                loading = false
                guard let (i, lines) = result else {
                    if autoplay && direction > 0 { markFinished() }
                    else { library?.errorMessage = "这个方向没有可朗读的正文。" }
                    return
                }
                chapter = i; pieces = lines
                segment = min(max(0, i == start ? position : 0), lines.count - 1)
                if !restoring { save() }
                if resumeAfterLoad { speak() }
            } catch { fail(error, token: token) }
        }
    }

    private func fail(_ error: Error, token: UUID) {
        guard token == generation else { return }
        loading = false
        library?.errorMessage = error.localizedDescription
    }

    func toggle() {
        if playing { pause(); return }
        if finished { loadChapter(0, autoplay: true); return }
        speak()
    }

    func move(_ delta: Int) {
        guard !pieces.isEmpty else { return }
        let resume = playing
        pause()
        segment = min(max(segment + delta, 0), pieces.count - 1)
        finished = false
        save()
        if resume { speak() }
    }

    func pause() {
        resumeAfterLoad = false
        synthesis?.cancel()
        player?.stop()
        player = nil
        preparing = false
        playing = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func speak() {
        guard pieces.indices.contains(segment), bookID == library?.selectedID else { return }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .spokenAudio)
            try audio.setActive(true)
        } catch { library?.errorMessage = error.localizedDescription; return }
        save()
        enqueue()
    }

    private func enqueue() {
        let text = pieces[segment]
        playing = true
        preparing = true
        synthesis = Task {
            do {
                let data = try await voice.audio(for: text)
                try Task.checkCancellation()
                let audio = try AVAudioPlayer(data: data)
                audio.delegate = self
                audio.enableRate = true
                audio.rate = Float(speed)
                player = audio
                preparing = false
                guard audio.play() else { throw CocoaError(.fileReadUnknown) }
            } catch {
                guard !Task.isCancelled else { return }
                pause()
                library?.errorMessage = "离线语音合成或播放失败：\(error.localizedDescription)"
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player, self.bookID == self.library?.selectedID else { return }
            guard flag else { self.pause(); self.library?.errorMessage = "本段播放中断。"; return }
            if self.segment + 1 < self.pieces.count {
                self.segment += 1
                self.save()
                self.enqueue()
            } else if self.chapter + 1 < self.titles.count {
                self.loadChapter(self.chapter + 1, autoplay: true)
            } else {
                self.markFinished()
            }
        }
    }

    private func markFinished() {
        pause()
        finished = true
        if let bookID { library?.bookmark(bookID, chapter: 0, segment: 0, progress: 1) }
    }

    func save() {
        guard let bookID, !titles.isEmpty, !pieces.isEmpty, !finished else { return }
        let progress = (Double(chapter) + Double(segment) / Double(pieces.count)) / Double(titles.count)
        library?.bookmark(bookID, chapter: chapter, segment: segment, progress: progress)
    }

    func changeSpeed() {
        speed = speed >= 1.5 ? 0.8 : (speed * 10 + 1).rounded() / 10
        UserDefaults.standard.set(speed, forKey: "narrationSpeed")
        player?.rate = Float(speed)
    }

    func cycleTimer() {
        timer?.cancel()
        sleepMinutes = sleepMinutes == 0 ? 15 : sleepMinutes == 15 ? 30 : sleepMinutes == 30 ? 60 : 0
        let minutes = sleepMinutes
        guard minutes > 0 else { return }
        timer = Task {
            do { try await Task.sleep(for: .seconds(minutes * 60)) } catch { return }
            pause()
            sleepMinutes = 0
        }
    }
}
