package com.soundboard.audio

import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Handler
import android.os.Looper

/**
 * Enumerates output devices and reports hot-plug changes (headphones, USB interfaces, Bluetooth).
 * Latency here is a conservative prior per device type; the real figure comes from the opened
 * stream (`AudioStream::calculateLatencyMillis`).
 */
class AudioRouteScanner(context: Context) {
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var callback: AudioDeviceCallback? = null

    fun outputs(): List<OutputPort> = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        .mapNotNull { info -> kindOf(info)?.let { OutputPort(info.id, label(info), it, channelsOf(info), priorLatency(it)) } }
        .distinctBy { it.id }

    /** Native output sample rate of the primary output — run the engine at this rate to avoid resampling. */
    fun nativeSampleRate(): Int =
        audioManager.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)?.toIntOrNull() ?: 48_000

    fun watch(onChange: (List<OutputPort>) -> Unit) {
        val cb = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) = onChange(outputs())
            override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) = onChange(outputs())
        }
        callback = cb
        audioManager.registerAudioDeviceCallback(cb, Handler(Looper.getMainLooper()))
    }

    fun stop() {
        callback?.let { audioManager.unregisterAudioDeviceCallback(it) }
        callback = null
    }

    private fun kindOf(info: AudioDeviceInfo): OutputPort.Kind? = when (info.type) {
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> OutputPort.Kind.BUILT_IN_SPEAKER
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_USB_HEADSET -> OutputPort.Kind.WIRED_HEADPHONES
        AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_ACCESSORY,
        AudioDeviceInfo.TYPE_DOCK -> OutputPort.Kind.USB_AUDIO
        AudioDeviceInfo.TYPE_LINE_ANALOG, AudioDeviceInfo.TYPE_LINE_DIGITAL -> OutputPort.Kind.LINE_OUT
        AudioDeviceInfo.TYPE_HDMI, AudioDeviceInfo.TYPE_HDMI_ARC -> OutputPort.Kind.HDMI
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> OutputPort.Kind.BLUETOOTH_A2DP
        AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_BLE_SPEAKER -> OutputPort.Kind.BLUETOOTH_LE
        AudioDeviceInfo.TYPE_REMOTE_SUBMIX, AudioDeviceInfo.TYPE_TELEPHONY,
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE, AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> null // not media outputs
        else -> OutputPort.Kind.OTHER
    }

    private fun channelsOf(info: AudioDeviceInfo): Int {
        val counts = info.channelCounts
        if (counts.isNotEmpty()) return counts.max()
        // Index masks describe discrete channels on USB devices.
        val fromIndexMasks = info.channelIndexMasks.maxOfOrNull { Integer.bitCount(it) } ?: 0
        return if (fromIndexMasks > 0) fromIndexMasks else 2
    }

    private fun label(info: AudioDeviceInfo): String {
        val product = info.productName?.toString().orEmpty()
        return product.ifBlank { kindOf(info)?.name?.lowercase()?.replace('_', ' ') ?: "Output ${info.id}" }
    }

    private fun priorLatency(kind: OutputPort.Kind) = when (kind) {
        OutputPort.Kind.BLUETOOTH_A2DP -> 0.180
        OutputPort.Kind.BLUETOOTH_LE -> 0.050
        OutputPort.Kind.CAST -> 1.5
        else -> 0.015
    }
}
