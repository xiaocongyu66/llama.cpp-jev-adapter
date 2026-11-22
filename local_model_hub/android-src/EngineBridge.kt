package com.example.local_model_hub

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.pm.ServiceInfo
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.system.Os
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.TimeUnit

class EngineBridge(private val context: Context) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private var eventSink: EventChannel.EventSink? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val modelPath = call.argument<String>("modelPath")
                val args = call.argument<String>("backendArgs") ?: ""
                val port = call.argument<Int>("port") ?: 18081
                if (modelPath.isNullOrBlank() || !File(modelPath).isFile) {
                    result.error("MODEL_NOT_FOUND", "GGUF model file not found", null)
                    return
                }
                val intent = Intent(context, LlamaEngineService::class.java)
                    .setAction(LlamaEngineService.ACTION_START)
                    .putExtra(LlamaEngineService.EXTRA_MODEL_PATH, modelPath)
                    .putExtra(LlamaEngineService.EXTRA_ARGS, args)
                    .putExtra(LlamaEngineService.EXTRA_PORT, port)
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent) else context.startService(intent)
                    result.success(null)
                } catch (error: Exception) {
                    result.error("ENGINE_START_FAILED", error.message, null)
                }
            }
            "stop" -> {
                context.startService(Intent(context, LlamaEngineService::class.java).setAction(LlamaEngineService.ACTION_STOP))
                result.success(null)
            }
            "isRunning" -> result.success(LlamaEngineService.isRunning.get())
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        LlamaEngineService.setEventSink(events)
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        LlamaEngineService.setEventSink(null)
    }
}

class LlamaEngineService : Service() {
    private val executor = Executors.newSingleThreadExecutor()
    private var process: Process? = null
    private var logThread: Thread? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startForeground(NOTIFICATION_ID, notification("Starting llama.cpp"), ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
                } else {
                    startForeground(NOTIFICATION_ID, notification("Starting llama.cpp"))
                }
                executor.execute {
                    try {
                        stopProcess()
                        val modelPath = intent.getStringExtra(EXTRA_MODEL_PATH) ?: error("Missing model path")
                        val backendArgs = intent.getStringExtra(EXTRA_ARGS).orEmpty()
                        val port = intent.getIntExtra(EXTRA_PORT, 18081)
                        val executable = installServer()
                        val args = mutableListOf("--model", modelPath, "--host", "127.0.0.1", "--port", port.toString())
                        args.addAll(splitArguments(backendArgs))
                        process = ProcessBuilder(listOf(executable.absolutePath) + args)
                            .directory(filesDir)
                            .redirectErrorStream(true)
                            .start()
                        isRunning.set(true)
                        emit("status", "llama-server running on 127.0.0.1:$port")
                        val runningProcess = process ?: error("llama-server failed to start")
                        logThread = Thread {
                            runningProcess.inputStream.bufferedReader().useLines { lines -> lines.forEach { emit("log", it) } }
                        }.also { it.start() }
                        Thread {
                            val exitCode = runningProcess.waitFor()
                            isRunning.set(false)
                            process = null
                            emit("exit", "llama-server exited with code $exitCode")
                            mainExecutor.execute {
                                stopForeground(STOP_FOREGROUND_REMOVE)
                                stopSelf()
                            }
                        }.start()
                    } catch (error: Exception) {
                        isRunning.set(false)
                        emit("error", error.message ?: error.toString())
                        stopForeground(STOP_FOREGROUND_REMOVE)
                        stopSelf()
                    }
                }
            }
            ACTION_STOP -> {
                stopProcess()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_STICKY
    }

    private fun installServer(): File {
        val target = File(applicationInfo.nativeLibraryDir, "libllama-server.so")
        if (!target.isFile || !target.canExecute()) error("llama-server is missing from this APK")
        Os.chmod(target.absolutePath, 493)
        return target
    }

    private fun splitArguments(value: String): List<String> {
        val result = mutableListOf<String>()
        val current = StringBuilder()
        var quote: Char? = null
        var escaped = false
        for (character in value) {
            when {
                escaped -> {
                    current.append(character)
                    escaped = false
                }
                character == '\\' -> escaped = true
                quote != null && character == quote -> quote = null
                quote == null && (character == '\'' || character == '"') -> quote = character
                quote == null && character.isWhitespace() -> {
                    if (current.isNotEmpty()) {
                        result.add(current.toString())
                        current.clear()
                    }
                }
                else -> current.append(character)
            }
        }
        if (current.isNotEmpty()) result.add(current.toString())
        return result
    }

    @Synchronized
    private fun stopProcess() {
        process?.let {
            it.destroy()
            if (!it.waitFor(3, TimeUnit.SECONDS)) it.destroyForcibly()
        }
        logThread?.join(1000)
        logThread = null
        process = null
        isRunning.set(false)
        emit("exit", "llama-server stopped")
    }

    private fun emit(type: String, message: String) {
        mainExecutor.execute { eventSink?.success(mapOf("type" to type, "message" to message)) }
    }

    private fun notification(text: String): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Local model engine", NotificationManager.IMPORTANCE_LOW))
        }
        val stopIntent = Intent(this, LlamaEngineService::class.java).setAction(ACTION_STOP)
        val stopPendingIntent = android.app.PendingIntent.getService(
            this, 0, stopIntent,
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or if (Build.VERSION.SDK_INT >= 23) android.app.PendingIntent.FLAG_IMMUTABLE else 0,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Local Model Hub")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .addAction(0, "Stop", stopPendingIntent)
            .build()
    }

    override fun onDestroy() {
        stopProcess()
        executor.shutdownNow()
        super.onDestroy()
    }

    companion object {
        const val ACTION_START = "com.example.local_model_hub.START_ENGINE"
        const val ACTION_STOP = "com.example.local_model_hub.STOP_ENGINE"
        const val EXTRA_MODEL_PATH = "modelPath"
        const val EXTRA_ARGS = "backendArgs"
        const val EXTRA_PORT = "port"
        private const val CHANNEL_ID = "local_model_engine"
        private const val NOTIFICATION_ID = 721
        val isRunning = AtomicBoolean(false)
        @Volatile private var eventSink: EventChannel.EventSink? = null

        fun setEventSink(sink: EventChannel.EventSink?) {
            eventSink = sink
        }
    }
}
