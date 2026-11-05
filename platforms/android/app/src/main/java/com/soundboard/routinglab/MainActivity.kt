package com.soundboard.routinglab

import android.app.Application
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.soundboard.audio.AudioRouteScanner
import com.soundboard.audio.CueTopology
import com.soundboard.audio.NativeEngine
import com.soundboard.audio.Notice
import com.soundboard.audio.OutputPort
import com.soundboard.audio.RoutePlan
import com.soundboard.audio.RoutePlanner
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.sin

data class LabState(
    val outputs: List<OutputPort> = emptyList(),
    val plan: RoutePlan? = null,
    val topologyUsed: CueTopology? = null,
    val splitter: Boolean = false,
    val playing: Boolean = false,
    val masterPeak: Float = 0f,
    val cuePeak: Float = 0f,
    val masterLatencyMs: Int = 0,
    val message: String? = null,
)

/** Routing Lab: verifies master/cue separation on real Android hardware by ear. */
class LabViewModel(app: Application) : AndroidViewModel(app) {
    private val scanner = AudioRouteScanner(app)
    private val engine = NativeEngine(scanner.nativeSampleRate())
    private val _state = MutableStateFlow(LabState())
    val state: StateFlow<LabState> = _state.asStateFlow()

    init {
        engine.setAutoGain(false)
        engine.loadPcm(0, pulses(220.0, offbeat = false), 2, engine.sampleRate, analyze = false)
        engine.loadPcm(1, pulses(880.0, offbeat = true), 2, engine.sampleRate, analyze = false)
        engine.setCrossfader(-1f)
        engine.setCue(1, true)
        engine.setCueMix(0f)
        scanner.watch { replan() }
        replan()
        viewModelScope.launch {
            while (isActive) {
                val s = engine.status()
                _state.update { it.copy(masterPeak = s.masterPeak, cuePeak = s.cuePeak, masterLatencyMs = (s.masterLatency * 1000).toInt()) }
                if (s.disconnected) replan()
                delay(33)
            }
        }
    }

    fun setSplitter(on: Boolean) { _state.update { it.copy(splitter = on) }; replan() }

    fun togglePlay() {
        val playing = !_state.value.playing
        if (playing) { engine.play(0); engine.play(1) } else { engine.pause(0); engine.pause(1) }
        _state.update { it.copy(playing = playing) }
    }

    private fun replan() {
        val outputs = scanner.outputs()
        val plan = RoutePlanner.plan(outputs, _state.value.splitter)
        val result = engine.start(plan)
        val message = when {
            result.masterFailed -> "Could not open the output stream."
            result.cueRefused -> "This phone won't play to two outputs at once — using master only."
            else -> null
        }
        _state.update { it.copy(outputs = outputs, plan = plan, topologyUsed = result.topologyUsed, message = message) }
    }

    override fun onCleared() {
        scanner.stop()
        engine.close()
    }

    private fun pulses(freq: Double, offbeat: Boolean): FloatArray {
        val rate = engine.sampleRate.toDouble()
        val frames = (rate * 60).toInt()
        val beat = rate * 0.5
        val out = FloatArray(frames * 2)
        for (i in 0 until frames) {
            val t = ((if (offbeat) i + beat / 2 else i.toDouble()) % beat)
            val env = if (t < rate * 0.12) exp(-t / (rate * 0.04)) else 0.0
            val v = (sin(2 * PI * freq * i / rate) * env * 0.6).toFloat()
            out[2 * i] = v
            out[2 * i + 1] = v
        }
        return out
    }
}

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            MaterialTheme(colorScheme = darkColorScheme()) {
                val vm: LabViewModel = viewModel()
                val state by vm.state.collectAsStateWithLifecycle()
                Scaffold { padding -> LabScreen(state, vm::togglePlay, vm::setSplitter, Modifier.padding(padding)) }
            }
        }
    }
}

@Composable
fun LabScreen(state: LabState, onPlay: () -> Unit, onSplitter: (Boolean) -> Unit, modifier: Modifier = Modifier) {
    Column(
        modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("Routing Lab", style = MaterialTheme.typography.headlineMedium)
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                val plan = state.plan
                Text("Cue mode: ${label(state.topologyUsed ?: plan?.topology)}")
                Text("Master: ${plan?.master?.name ?: "—"}  (${state.masterLatencyMs} ms)")
                Text("Headphones: ${if (state.topologyUsed != CueTopology.MASTER_ONLY) plan?.cue?.name ?: "—" else "unavailable"}")
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Splitter cable", Modifier.weight(1f))
                    Switch(checked = state.splitter, onCheckedChange = onSplitter)
                }
            }
        }
        state.plan?.notices?.forEach { Text("⚠ " + text(it), color = MaterialTheme.colorScheme.tertiary) }
        state.message?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        Button(onClick = onPlay, modifier = Modifier.fillMaxWidth()) {
            Text(if (state.playing) "Stop test signals" else "Play test signals")
        }
        Meter("Master — low pulse on the beat", state.masterPeak)
        Meter("Headphones — high chirp off the beat", state.cuePeak)
        Text(
            "Speakers must only ever play the low pulse. The high chirp belongs in the headphones and nowhere else.",
            style = MaterialTheme.typography.bodySmall,
        )
        Text("Outputs", style = MaterialTheme.typography.titleMedium)
        state.outputs.forEach { Text("• ${it.name} — ${it.kind.name.lowercase()}, ${it.channels} ch") }
    }
}

@Composable
private fun Meter(label: String, value: Float) {
    Column {
        Text(label, style = MaterialTheme.typography.labelMedium)
        LinearProgressIndicator(
            progress = { value.coerceIn(0f, 1f) },
            modifier = Modifier.fillMaxWidth().semantics { contentDescription = "$label ${(value * 100).toInt()} percent" },
        )
    }
}

private fun label(t: CueTopology?) = when (t) {
    CueTopology.MASTER_ONLY -> "Master only"
    CueTopology.SPLIT_MONO -> "Split cable (mono)"
    CueTopology.MULTI_CHANNEL -> "Multichannel interface"
    CueTopology.SEPARATE_CUE_DEVICE -> "Separate headphone output"
    null -> "—"
}

private fun text(n: Notice) = when (n) {
    Notice.CueNeedsHardware -> "Private pre-listening needs a splitter cable, a USB audio interface or a DJ controller."
    is Notice.WirelessMasterLatency -> "Wireless master adds about ${n.ms} ms of delay."
    is Notice.WirelessCueLatency -> "Wireless headphones add about ${n.ms} ms; wired is strongly recommended for cueing."
    is Notice.CueSlowerThanMaster -> "Headphones are ${n.ms} ms behind the speakers."
    Notice.SecondDeviceRefused -> "This device can't play to two outputs at once."
}
