package com.joyfox.localmodelhub

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.system.Os
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

sealed interface EngineState {
    data object Stopped : EngineState
    data class Starting(val modelPath: String) : EngineState
    data class Running(val modelPath: String, val port: Int) : EngineState
    data class Failed(val message: String) : EngineState
}

class LlamaEngineService : Service() {
    private val executor = Executors.newSingleThreadExecutor()
    private var process: Process? = null
    private var logThread: Thread? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startEngine(intent)
            ACTION_STOP -> {
                stopProcess()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_STICKY
    }

    private fun startEngine(intent: Intent) {
        val modelPath = intent.getStringExtra(EXTRA_MODEL_PATH)
        if (modelPath.isNullOrBlank() || !File(modelPath).isFile) {
            publish(EngineState.Failed("GGUF 模型文件不存在：$modelPath"))
            stopSelf()
            return
        }
        val args = intent.getStringExtra(EXTRA_ARGS).orEmpty()
        val port = intent.getIntExtra(EXTRA_PORT, 18081)
        publish(EngineState.Starting(modelPath))
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification("正在启动本地模型"), ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification("正在启动本地模型"))
        }
        executor.execute {
            try {
                stopProcess()
                val executable = installServer()
                val command = listOf(executable.absolutePath, "--model", modelPath, "--host", "127.0.0.1", "--port", port.toString()) + splitArguments(args)
                val running = ProcessBuilder(command)
                    .directory(filesDir)
                    .redirectErrorStream(true)
                    .start()
                process = running
                publish(EngineState.Running(modelPath, port))
                mainExecutor.execute { getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification("llama-server 运行中")) }
                logThread = Thread {
                    running.inputStream.bufferedReader().useLines { lines ->
                        lines.forEach { message -> android.util.Log.i(TAG, message) }
                    }
                }.also { it.start() }
                Thread {
                    val exitCode = running.waitFor()
                    if (process === running) {
                        process = null
                        publish(EngineState.Failed("llama-server 已退出，exit code=$exitCode"))
                        mainExecutor.execute {
                            stopForeground(STOP_FOREGROUND_REMOVE)
                            stopSelf()
                        }
                    }
                }.start()
            } catch (error: Exception) {
                publish(EngineState.Failed(error.message ?: error.toString()))
                mainExecutor.execute {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
            }
        }
    }

    private fun installServer(): File {
        val executable = File(applicationInfo.nativeLibraryDir, "libllama-server.so")
        check(executable.isFile) { "APK 中缺少 llama-server" }
        Os.chmod(executable.absolutePath, 493)
        check(executable.canExecute()) { "llama-server 不可执行" }
        return executable
    }

    private fun splitArguments(value: String): List<String> {
        val result = mutableListOf<String>()
        val current = StringBuilder()
        var quote: Char? = null
        var escaped = false
        for (character in value) {
            when {
                escaped -> { current.append(character); escaped = false }
                character == '\\' -> escaped = true
                quote != null && character == quote -> quote = null
                quote == null && (character == '\'' || character == '"') -> quote = character
                quote == null && character.isWhitespace() -> {
                    if (current.isNotEmpty()) { result += current.toString(); current.clear() }
                }
                else -> current.append(character)
            }
        }
        if (current.isNotEmpty()) result += current.toString()
        return result
    }

    @Synchronized
    private fun stopProcess() {
        val running = process
        process = null
        if (running != null) {
            running.destroy()
            if (!running.waitFor(3, TimeUnit.SECONDS)) running.destroyForcibly()
        }
        logThread?.join(1000)
        logThread = null
        publish(EngineState.Stopped)
    }

    private fun publish(state: EngineState) {
        engineState.value = state
    }

    private fun notification(text: String): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Local model engine", NotificationManager.IMPORTANCE_LOW))
        }
        val stopIntent = Intent(this, LlamaEngineService::class.java).setAction(ACTION_STOP)
        val pendingIntent = PendingIntent.getService(
            this,
            0,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Local Model Hub")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .addAction(0, "停止", pendingIntent)
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
        private const val TAG = "LocalModelEngine"
        private val engineState = MutableStateFlow<EngineState>(EngineState.Stopped)
        val states = engineState.asStateFlow()

        fun start(context: Context, modelPath: String, args: String, port: Int = 18081) {
            val intent = Intent(context, LlamaEngineService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_MODEL_PATH, modelPath)
                .putExtra(EXTRA_ARGS, args)
                .putExtra(EXTRA_PORT, port)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent) else context.startService(intent)
        }

        fun stop(context: Context) {
            context.startService(Intent(context, LlamaEngineService::class.java).setAction(ACTION_STOP))
        }
    }
}
