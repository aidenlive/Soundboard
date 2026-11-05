package com.soundboard.audio

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RoutePlannerTest {
    private val speaker = OutputPort(1, "Speaker", OutputPort.Kind.BUILT_IN_SPEAKER, 2, 0.02)
    private val headphones = OutputPort(2, "Headphones", OutputPort.Kind.WIRED_HEADPHONES, 2, 0.012)
    private val controller = OutputPort(3, "DJ controller", OutputPort.Kind.USB_AUDIO, 4, 0.008)
    private val btSpeaker = OutputPort(4, "Party speaker", OutputPort.Kind.BLUETOOTH_A2DP, 2, 0.200)

    @Test fun fourChannelControllerIsPreferred() {
        val plan = RoutePlanner.plan(listOf(speaker, headphones, controller), splitterCable = false)
        assertEquals(CueTopology.MULTI_CHANNEL, plan.topology)
        assertArrayEquals(intArrayOf(0, 1, 2, 3), plan.channels)
    }

    @Test fun speakerPlusHeadphonesUsesSecondStream() {
        val plan = RoutePlanner.plan(listOf(speaker, headphones), splitterCable = false)
        assertEquals(CueTopology.SEPARATE_CUE_DEVICE, plan.topology)
        assertEquals(speaker, plan.master)
        assertEquals(headphones, plan.cue)
        assertEquals(0.008, plan.cueDelay, 1e-9)
    }

    @Test fun bluetoothMasterIsAlignedAndFlagged() {
        val plan = RoutePlanner.plan(listOf(btSpeaker, headphones), splitterCable = false)
        assertEquals(btSpeaker, plan.master)
        assertEquals(0.188, plan.cueDelay, 1e-9)
        assertEquals(0.0, plan.masterDelay, 0.0)
        assertTrue(plan.notices.contains(Notice.WirelessMasterLatency(200)))
    }

    @Test fun splitterWhenPolicyRefusesTwoDevices() {
        val plan = RoutePlanner.plan(listOf(headphones), splitterCable = true, concurrentDevicesAllowed = false)
        assertEquals(CueTopology.SPLIT_MONO, plan.topology)
    }

    @Test fun speakerOnlyIsHonest() {
        val plan = RoutePlanner.plan(listOf(speaker), splitterCable = true)
        assertEquals(CueTopology.MASTER_ONLY, plan.topology)
        assertTrue(plan.notices.contains(Notice.CueNeedsHardware))
    }
}
