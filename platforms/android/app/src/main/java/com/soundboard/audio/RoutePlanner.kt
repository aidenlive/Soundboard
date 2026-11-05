package com.soundboard.audio

import kotlin.math.roundToInt

/** A physical output reported by AudioManager (one AudioDeviceInfo). */
data class OutputPort(
    val id: Int,
    val name: String,
    val kind: Kind,
    val channels: Int,
    /** Expected output latency in seconds (refined after the stream opens). */
    val latency: Double = 0.0,
) {
    enum class Kind {
        BUILT_IN_SPEAKER, WIRED_HEADPHONES, USB_AUDIO, LINE_OUT, HDMI,
        BLUETOOTH_A2DP, BLUETOOTH_LE, CAST, OTHER;

        val isWireless get() = this == BLUETOOTH_A2DP || this == BLUETOOTH_LE || this == CAST
        val isVenueOutput get() = this != WIRED_HEADPHONES && this != OTHER
    }
}

/** Mirrors `sbe_topology`. */
enum class CueTopology(val value: Int) { MASTER_ONLY(0), SPLIT_MONO(1), MULTI_CHANNEL(2), SEPARATE_CUE_DEVICE(3) }

sealed interface Notice {
    data object CueNeedsHardware : Notice
    data class WirelessMasterLatency(val ms: Int) : Notice
    data class WirelessCueLatency(val ms: Int) : Notice
    data class CueSlowerThanMaster(val ms: Int) : Notice
    data object SecondDeviceRefused : Notice
}

data class RoutePlan(
    val topology: CueTopology,
    val master: OutputPort?,
    val cue: OutputPort?,
    /** [masterL, masterR, cueL, cueR] channel indices within the master stream. */
    val channels: IntArray,
    val masterDelay: Double,
    val cueDelay: Double,
    val notices: List<Notice>,
) {
    val cueAvailable get() = topology != CueTopology.MASTER_ONLY

    override fun equals(other: Any?) = other is RoutePlan && topology == other.topology && master == other.master &&
        cue == other.cue && channels.contentEquals(other.channels) && masterDelay == other.masterDelay &&
        cueDelay == other.cueDelay && notices == other.notices

    override fun hashCode() = listOf(topology, master, cue, channels.toList(), masterDelay, cueDelay, notices).hashCode()
}

/**
 * Same decision rules as the Apple `RoutePlanner.swift`:
 *  1. one device with >= 4 outputs (USB interface / DJ controller) -> master + cue on one clock;
 *  2. a venue output plus headphones -> second Oboe stream (if the phone's audio policy allows
 *     it — verified when the stream opens, see oboe_host.cpp);
 *  3. a splitter cable on a wired output -> mono master + mono cue;
 *  4. master only, with an honest explanation.
 */
object RoutePlanner {
    fun plan(
        outputs: List<OutputPort>,
        splitterCable: Boolean,
        concurrentDevicesAllowed: Boolean = true,
        preferredMasterId: Int? = null,
        preferredCueId: Int? = null,
    ): RoutePlan {
        val notices = mutableListOf<Notice>()
        fun pick(id: Int?) = id?.let { wanted -> outputs.firstOrNull { it.id == wanted } }

        val multi = pick(preferredMasterId)?.takeIf { it.channels >= 4 }
            ?: outputs.filter { it.channels >= 4 && !it.kind.isWireless && it.kind != OutputPort.Kind.OTHER }.maxByOrNull { it.channels }
        if (multi != null) {
            return RoutePlan(CueTopology.MULTI_CHANNEL, multi, multi, intArrayOf(0, 1, 2, 3), 0.0, 0.0, notices)
        }

        val headphones = pick(preferredCueId) ?: outputs.firstOrNull { it.kind == OutputPort.Kind.WIRED_HEADPHONES }
        val venue = pick(preferredMasterId) ?: outputs
            .filter { it.id != headphones?.id && it.kind.isVenueOutput }
            .minByOrNull { rank(it.kind) }
        if (concurrentDevicesAllowed && headphones != null && venue != null && headphones.id != venue.id) {
            wirelessNotices(venue, headphones, notices)
            val (md, cd) = alignment(venue, headphones, notices)
            return RoutePlan(CueTopology.SEPARATE_CUE_DEVICE, venue, headphones, intArrayOf(0, 1, 0, 1), md, cd, notices)
        }

        val primary = pick(preferredMasterId) ?: outputs.firstOrNull()
        if (splitterCable && primary != null && !primary.kind.isWireless &&
            primary.kind != OutputPort.Kind.BUILT_IN_SPEAKER && primary.channels >= 2
        ) {
            return RoutePlan(CueTopology.SPLIT_MONO, primary, primary, intArrayOf(0, 0, 1, 1), 0.0, 0.0, notices)
        }

        notices += Notice.CueNeedsHardware
        primary?.let { wirelessNotices(it, null, notices) }
        return RoutePlan(CueTopology.MASTER_ONLY, primary, null, intArrayOf(0, 1, 0, 0), 0.0, 0.0, notices)
    }

    private fun rank(kind: OutputPort.Kind) = when (kind) {
        OutputPort.Kind.USB_AUDIO -> 0
        OutputPort.Kind.LINE_OUT -> 1
        OutputPort.Kind.HDMI -> 2
        OutputPort.Kind.BLUETOOTH_LE -> 3
        OutputPort.Kind.BLUETOOTH_A2DP -> 4
        OutputPort.Kind.BUILT_IN_SPEAKER -> 5
        OutputPort.Kind.CAST -> 6
        else -> 7
    }

    private fun wirelessNotices(master: OutputPort, cue: OutputPort?, into: MutableList<Notice>) {
        if (master.kind.isWireless) into += Notice.WirelessMasterLatency((master.latency * 1000).roundToInt())
        if (cue != null && cue.kind.isWireless) into += Notice.WirelessCueLatency((cue.latency * 1000).roundToInt())
    }

    /** Delay the faster path so both line up in the DJ's ears; never delay the master. */
    private fun alignment(master: OutputPort, cue: OutputPort, notices: MutableList<Notice>): Pair<Double, Double> {
        val diff = master.latency - cue.latency
        if (diff > 0.002) return 0.0 to diff
        if (diff < -0.010) notices += Notice.CueSlowerThanMaster((-diff * 1000).roundToInt())
        return 0.0 to 0.0
    }
}
