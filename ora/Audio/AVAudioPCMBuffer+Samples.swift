//
//  AVAudioPCMBuffer+Samples.swift
//  ora
//
//  Convenience for pulling a flat [Float] out of a mono PCM buffer.
//  Replaces the identical extractFloats(from:) that was duplicated
//  across the FluidAudio transcribers.
//

import AVFoundation

extension AVAudioPCMBuffer {
    /// Copies channel 0 of a Float32 PCM buffer into a flat [Float].
    /// Recorder guarantees mono 16 kHz, so channel 0 is the entire signal.
    func monoSamples() -> [Float] {
        guard let channel = floatChannelData?[0] else { return [] }
        let count = Int(frameLength)
        guard count > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: count))
    }
}
