import Foundation
import AVFoundation

// Shared live PCM queue: bounded startup/backpressure, one ordered drainer,
// complete short tails, no file replay or paid retry on overflow.
final class StreamingPCMQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var closed = false
    private var cancelled = false
    private var overflow = false
    let sampleRate: Double
    private let capacity: Int
    init(sampleRate: Double, bufferSeconds: Double = 40) {
        precondition(sampleRate.isFinite && sampleRate > 0 && bufferSeconds.isFinite && bufferSeconds > 0 && sampleRate * bufferSeconds < Double(Int.max / 2))
        self.sampleRate = sampleRate; capacity = Int(sampleRate * bufferSeconds) * 2
    }
    var canStream: Bool { lock.lock(); defer { lock.unlock() }; return !overflow && !cancelled }
    func appendPCM(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !cancelled else { throw AppError("音频流已结束，原始音频保留在本机。") }
        guard !overflow, data.count % 2 == 0, data.count <= capacity - bytes.count else {
            overflow = true; bytes.removeAll(); throw AppError("网络发送落后于录音，音频已保留，请在历史手动重试。")
        }
        bytes.append(data)
    }
    func finish() { lock.lock(); closed = true; lock.unlock() }
    func cancel() { lock.lock(); cancelled = true; bytes.removeAll(); lock.unlock() }
    func drainPCM() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard !overflow else { throw AppError("网络发送落后于录音，音频已保留，请在历史手动重试。") }
        guard !cancelled else { throw CancellationError() }
        if bytes.isEmpty { return closed ? nil : Data() }
        let minimum = Int(sampleRate / 20) * 2
        if !closed && bytes.count < minimum { return Data() }
        if closed && bytes.count < minimum { bytes.append(Data(count: minimum - bytes.count)) }
        let count = min(bytes.count, Int(sampleRate / 5) * 2)
        let result = Data(bytes.prefix(count)); bytes.removeFirst(count); return result
    }
}

// System sample-rate conversion retains state across callbacks and explicitly
// flushes EOF. This candidate is not a change to the current microphone format.
@MainActor final class StreamingPCMResampler {
    private let converter: AVAudioConverter
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private var finished = false
    private var inputFrames: Int64 = 0
    private var emittedFrames = 0
    private var pendingOutput = Data()
    init(format: AVAudioFormat) throws {
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: target) else { throw AppError("音频格式无法转换为实时识别 PCM。") }
        sourceFormat = format; targetFormat = target; self.converter = converter
        // Normal priming compensates the converter's through latency. With
        // .none, a duration-correct EOF cut would discard delayed real speech.
        converter.downmix = true; converter.primeMethod = .normal
    }
    func appendPCM(_ input: AVAudioPCMBuffer) throws -> Data {
        guard !finished, input.format == sourceFormat else { throw AppError("实时音频格式变化或会话已结束，原始音频仍保留。") }
        inputFrames += Int64(input.frameLength)
        pendingOutput.append(try convert(input, eof: false))
        return try takeOutput(eof: false)
    }
    func finish() throws -> Data {
        guard !finished else { return Data() }; finished = true
        pendingOutput.append(try convert(nil, eof: true))
        return try takeOutput(eof: true)
    }
    func cancel() { finished = true; pendingOutput.removeAll(); converter.reset() }
    private func takeOutput(eof: Bool) throws -> Data {
        let expected = Int((Double(inputFrames) * targetFormat.sampleRate / sourceFormat.sampleRate).rounded(.down))
        let remaining = max(0, expected - emittedFrames)
        if eof, pendingOutput.count < remaining * 2 { throw AppError("实时音频尾帧不足，原始音频仍保留。") }
        let count = min(pendingOutput.count, remaining * 2)
        let result = Data(pendingOutput.prefix(count)); pendingOutput.removeFirst(count); emittedFrames += count / 2
        // Carry fractional-frame output across callbacks. Normal priming aligns
        // samples to captured time before applying the recording boundary.
        if eof { pendingOutput.removeAll() }
        return result
    }
    private func convert(_ input: AVAudioPCMBuffer?, eof: Bool) throws -> Data {
        var supplied = false, data = Data()
        for _ in 0..<1024 {
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 2048) else { throw AppError("无法分配实时音频缓冲区。") }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if !supplied, let input { supplied = true; state.pointee = .haveData; return input }
                state.pointee = eof ? .endOfStream : .noDataNow; return nil
            }
            guard status != .error, error == nil else { throw AppError("实时音频转换失败，原始音频仍保留。") }
            if output.frameLength > 0, let channel = output.int16ChannelData {
                data.append(Data(bytes: channel[0], count: Int(output.frameLength) * 2))
            }
            if status == .inputRanDry || status == .endOfStream { return data }
        }
        throw AppError("实时音频转换未结束，原始音频仍保留。")
    }
}
