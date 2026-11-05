package com.soundboard.audio

/** Kotlin face of the shared C++ engine + Oboe host (oboe_host.cpp). */
class NativeEngine(val sampleRate: Int, maxBlock: Int = 1024, decks: Int = 2) : AutoCloseable {
    private var handle = nativeCreate(sampleRate, maxBlock, decks)

    data class StartResult(val topologyUsed: CueTopology, val masterFailed: Boolean, val cueRefused: Boolean)

    data class Status(
        val masterLatency: Double, val cueLatency: Double, val masterPeak: Float, val cuePeak: Float,
        val cueUnderruns: Int, val disconnected: Boolean, val masterChannels: Int,
    )

    /** Opens the streams for a plan; falls back to master-only if the OS refuses a second device. */
    fun start(plan: RoutePlan): StartResult {
        val masterChannels = when (plan.topology) {
            CueTopology.MULTI_CHANNEL -> maxOf(4, plan.master?.channels ?: 4)
            else -> 2
        }
        val r = nativeStart(handle, plan.topology.value, plan.master?.id ?: 0, masterChannels, plan.cue?.id ?: 0)
        val used = CueTopology.entries.first { it.value == (r shr 8) }
        val status = r and 0xff
        val channels = if (used == CueTopology.MASTER_ONLY) intArrayOf(0, 1, 0, 0) else plan.channels
        nativeApplyLayout(handle, used.value, channels,
            (plan.masterDelay * sampleRate).toInt(), (plan.cueDelay * sampleRate).toInt())
        return StartResult(used, status == 1, status == 2)
    }

    fun stop() = nativeStop(handle)

    fun status(): Status {
        val v = nativeStatus(handle)
        return Status(v[0].toDouble(), v[1].toDouble(), v[2], v[3], v[4].toInt(), v[5] > 0.5f, v[6].toInt())
    }

    fun loadPcm(deck: Int, interleaved: FloatArray, channels: Int, rate: Int, analyze: Boolean = true) =
        nativeLoadPcm(handle, deck, interleaved, channels, rate, analyze)

    fun play(deck: Int) = nativeCommand(handle, 0, deck, 0f)
    fun pause(deck: Int) = nativeCommand(handle, 1, deck, 0f)
    fun setCue(deck: Int, on: Boolean) = nativeCommand(handle, 2, deck, if (on) 1f else 0f)
    fun setFader(deck: Int, value: Float) = nativeCommand(handle, 3, deck, value)
    fun setCrossfader(x: Float) = nativeCommand(handle, 4, 0, x)
    fun setCueMix(mix: Float) = nativeCommand(handle, 5, 0, mix)
    fun setAutoGain(on: Boolean) = nativeCommand(handle, 6, 0, if (on) 1f else 0f)
    fun sync(deck: Int, lock: Boolean) = nativeCommand(handle, 7, deck, if (lock) 1f else 0f)
    fun setHeadphoneGainDb(db: Float) = nativeCommand(handle, 8, 0, db)
    fun previewPlay() = nativeCommand(handle, 9, 0, 0f)
    fun previewStop() = nativeCommand(handle, 10, 0, 0f)

    override fun close() {
        if (handle != 0L) { nativeDestroy(handle); handle = 0L }
    }

    private companion object {
        init { System.loadLibrary("soundboard") }
        @JvmStatic external fun nativeCreate(sampleRate: Int, maxBlock: Int, decks: Int): Long
        @JvmStatic external fun nativeDestroy(handle: Long)
        @JvmStatic external fun nativeStart(handle: Long, topology: Int, masterDevice: Int, masterChannels: Int, cueDevice: Int): Int
        @JvmStatic external fun nativeApplyLayout(handle: Long, topology: Int, channels: IntArray, masterDelay: Int, cueDelay: Int)
        @JvmStatic external fun nativeStop(handle: Long)
        @JvmStatic external fun nativeStatus(handle: Long): FloatArray
        @JvmStatic external fun nativeLoadPcm(handle: Long, deck: Int, pcm: FloatArray, channels: Int, sampleRate: Int, analyze: Boolean)
        @JvmStatic external fun nativeCommand(handle: Long, op: Int, deck: Int, value: Float)
    }
}
