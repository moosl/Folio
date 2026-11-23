import AppKit
import AVFoundation

final class AudioDocument: NSObject, WorkspaceDocument, AVAudioPlayerDelegate {
    private(set) var location: URL
    func relocate(to url:URL) { location = url }
    var url: URL? { location }
    var title: String { location.lastPathComponent }
    let dirty = false
    let view = NSView()
    let timeline = NSSlider()
    private let clock = label("",12,Ink.muted)
    private(set) var player: AVAudioPlayer?
    var status: String { L(statusKey) }
    private var statusKey = "Audio Preview"
    private var revision: FileRevision?
    private var timer: Timer?
    private var visible = true
    private var resumeTime: TimeInterval = 0
    lazy var playback = ActionButton(L("Play"),"play.fill") { [weak self] in self?.togglePlayback() }

    init(_ url:URL) throws {
        location = url
        super.init()
        timeline.isContinuous = true
        timeline.minValue = 0
        timeline.target = self; timeline.action = #selector(seek)
        let bar = stack(.horizontal,[playback,timeline,clock],12)
        let column = stack(.vertical,[glyph("music.note",Ink.accent,32),label(title,18,Ink.text,.medium),bar],16)
        column.alignment = .centerX
        view.addSubview(column)
        column.translatesAutoresizingMaskIntoConstraints = false
        let preferred = column.widthAnchor.constraint(equalToConstant:500); preferred.priority = .defaultHigh
        NSLayoutConstraint.activate([column.centerXAnchor.constraint(equalTo:view.centerXAnchor),
            column.centerYAnchor.constraint(equalTo:view.centerYAnchor),column.widthAnchor.constraint(lessThanOrEqualTo:view.widthAnchor),
            bar.widthAnchor.constraint(equalTo:column.widthAnchor),preferred])
        try reload()
    }

    private func reload() throws {
        let current = try FileRevision(location)
        guard current != revision || (visible && player == nil) else { return }
        guard visible else { revision = nil; resumeTime = 0; return }
        let position = current == revision ? resumeTime : 0
        let replacement = try AVAudioPlayer(contentsOf:location)
        pause()
        replacement.delegate = self
        replacement.currentTime = min(position,replacement.duration)
        player = replacement; revision = current
        statusKey = "Audio Preview"; refresh()
    }
    func hide() {
        guard visible else { return }
        visible = false
        resumeTime = player?.currentTime ?? 0
        pause()
        player = nil
    }
    func show() {
        visible = true
        reconcile()
        timeline.setAccessibilityLabel(L("Playback position"))
        refresh()
    }
    func reconcile() {
        do { try reload() }
        catch {
            pause(); player = nil; revision = nil
            statusKey = FileManager.default.fileExists(atPath:location.path) ? "Unable to read audio" : "Audio removed"
            refresh()
        }
    }
    func pause() {
        player?.pause()
        timer?.invalidate(); timer = nil
        refresh()
    }
    private func togglePlayback() {
        guard let player else { return }
        if player.isPlaying { pause(); return }
        if player.currentTime >= player.duration { player.currentTime = 0 }
        guard player.play() else { return }
        timer?.invalidate()
        timer = .scheduledTimer(withTimeInterval:0.2,repeats:true) { [weak self] _ in self?.refresh() }
        refresh()
    }
    @objc func seek() {
        player?.currentTime = timeline.doubleValue
        refresh()
    }
    private func refresh() {
        let playing = player?.isPlaying == true
        playback.title = playing ? L("Pause") : L("Play")
        playback.toolTip = playback.title
        playback.setAccessibilityLabel(playback.title)
        playback.image = symbol(playing ? "pause.fill" : "play.fill")
        playback.isEnabled = player != nil; timeline.isEnabled = player != nil
        let elapsed = player?.currentTime ?? 0, duration = player?.duration ?? 0
        timeline.maxValue = duration; timeline.doubleValue = elapsed
        func time(_ value:Double) -> String { String(format:"%d:%02d",Int(value)/60,Int(value)%60) }
        clock.stringValue = time(elapsed)+" / "+time(duration)
    }
    func audioPlayerDidFinishPlaying(_ player:AVAudioPlayer,successfully flag:Bool) {
        player.currentTime = 0; pause()
    }
    deinit { timer?.invalidate() }
}
