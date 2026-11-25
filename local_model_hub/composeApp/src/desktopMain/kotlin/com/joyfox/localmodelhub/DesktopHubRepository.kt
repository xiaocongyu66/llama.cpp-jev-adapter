package com.joyfox.localmodelhub

import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.SecureRandom
import java.security.MessageDigest
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.util.prefs.Preferences

class DesktopHubRepository : HubRepository {
    private val dataDirectory = File(System.getProperty("user.home"), ".local/share/local-model-hub")
    private val modelDirectory = File(dataDirectory, "models")
    private val preferences = Preferences.userRoot().node("com/joyfox/local-model-hub")
    private val json = Json { ignoreUnknownKeys = true }
    private val mutableState = MutableStateFlow(HubUiState(modelDirectory = modelDirectory.absolutePath))
    override val state = mutableState.asStateFlow()
    private var gateway: ApiGateway? = null
    private var process: Process? = null

    override suspend fun refresh() = withContext(Dispatchers.IO) {
        modelDirectory.mkdirs()
        val models = modelDirectory.walkTopDown().filter { it.isFile && it.extension.equals("gguf", true) }
            .map { ModelRecord(it.absolutePath, it.name, it.absolutePath, it.length()) }.toList()
        val keys = runCatching { json.decodeFromString(ListSerializer(ApiKeyRecord.serializer()), preferences.get(KEYS_KEY, "[]")) }.getOrDefault(emptyList())
        val requests = runCatching { json.decodeFromString(ListSerializer(RequestRecord.serializer()), preferences.get(LOGS_KEY, "[]")) }.getOrDefault(emptyList())
        mutableState.value = mutableState.value.copy(
            models = models,
            keys = keys,
            requests = requests,
            modelDirectory = modelDirectory.absolutePath,
            backendArgs = preferences.get(BACKEND_ARGS_KEY, "--n-gpu-layers auto"),
            enginePath = preferences.get(ENGINE_PATH_KEY, ""),
        )
    }

    override suspend fun navigate(route: HubRoute) { mutableState.value = mutableState.value.copy(route = route) }
    override suspend fun beginImport() { mutableState.value = mutableState.value.copy(importingName = "正在选择模型…", message = null) }

    override suspend fun importModel(displayName: String, source: ModelSource) = withContext(Dispatchers.IO) {
        modelDirectory.mkdirs()
        mutableState.value = mutableState.value.copy(importingName = displayName, message = null)
        val staging = File(modelDirectory, ".$displayName.${UUID.randomUUID()}.importing")
        try {
            source.copyTo(DesktopPlatformFile(staging)) { copied ->
                mutableState.value = mutableState.value.copy(message = "已复制 $copied / ${source.sizeBytes} 字节")
            }
            check(staging.length() > 0L && (source.sizeBytes < 0 || staging.length() == source.sizeBytes)) { "模型复制不完整" }
            val destination = uniqueDestination(displayName)
            check(staging.renameTo(destination)) { "无法将模型写入 ${destination.absolutePath}" }
            refresh()
            mutableState.value = mutableState.value.copy(message = "已导入 ${destination.name}")
        } catch (error: Exception) {
            staging.delete()
            mutableState.value = mutableState.value.copy(message = "导入失败：${error.message}")
        } finally {
            mutableState.value = mutableState.value.copy(importingName = null)
        }
    }

    override suspend fun clearImport() { mutableState.value = mutableState.value.copy(importingName = null, message = null) }

    override suspend fun removeModel(modelId: String) = withContext(Dispatchers.IO) {
        val model = mutableState.value.models.firstOrNull { it.id == modelId } ?: return@withContext
        if (model.loaded) stopModel()
        File(model.path).delete()
        refresh()
    }

    override suspend fun startModel(modelId: String) = withContext(Dispatchers.IO) {
        val model = mutableState.value.models.firstOrNull { it.id == modelId } ?: return@withContext
        stopModel()
        mutableState.value = mutableState.value.copy(enginePhase = EnginePhase.STARTING, message = null)
        val executable = preferences.get(ENGINE_PATH_KEY, "")
        check(executable.isNotBlank()) { "请先在设置中指定 llama-server 可执行文件" }
        val command = listOf(executable, "--model", model.path, "--host", "127.0.0.1", "--port", "8081") + splitArgs(preferences.get(BACKEND_ARGS_KEY, "--n-gpu-layers auto"))
        try {
            val running = ProcessBuilder(command).redirectErrorStream(true).start()
            process = running
            var ready = false
            repeat(120) {
                if (!ready && running.isAlive) {
                    ready = runCatching {
                        val connection = java.net.URL("http://127.0.0.1:8081/health").openConnection() as java.net.HttpURLConnection
                        connection.connectTimeout = 1000
                        connection.readTimeout = 1000
                        try { connection.responseCode in 200..299 } finally { connection.disconnect() }
                    }.getOrDefault(false)
                    if (!ready) delay(500)
                }
            }
            check(ready) { "llama-server 在 60 秒内未就绪" }
            mutableState.value = mutableState.value.copy(enginePhase = EnginePhase.RUNNING, models = mutableState.value.models.map { it.copy(loaded = it.id == modelId) })
        } catch (error: Exception) {
            process?.destroyForcibly()
            process = null
            mutableState.value = mutableState.value.copy(enginePhase = EnginePhase.FAILED, message = error.message)
        }
    }

    override suspend fun stopModel() = withContext(Dispatchers.IO) {
        process?.destroy()
        if (process?.isAlive == true) process?.destroyForcibly()
        process = null
        mutableState.value = mutableState.value.copy(enginePhase = EnginePhase.STOPPED, models = mutableState.value.models.map { it.copy(loaded = false) })
    }

    override suspend fun setGatewayRunning(running: Boolean) {
        if (running) startGatewayIfNeeded() else gateway?.stop()
        mutableState.value = mutableState.value.copy(gatewayRunning = running)
    }

    override suspend fun addApiKey(name: String, rpm: Int): String {
        val secret = ByteArray(32).also(SecureRandom()::nextBytes).joinToString("") { "%02x".format(it) }.let { "lmh_$it" }
        val next = mutableState.value.keys + ApiKeyRecord(name, secret, rpm)
        mutableState.value = mutableState.value.copy(keys = next, message = "新密钥：$secret")
        saveKeys(next)
        return secret
    }

    override suspend fun setApiKeyEnabled(name: String, enabled: Boolean) = updateKey(name) { it.copy(enabled = enabled) }
    override suspend fun setApiKeyRpm(name: String, rpm: Int) = updateKey(name) { it.copy(rpm = rpm.coerceAtLeast(1)) }

    override suspend fun removeApiKey(name: String) {
        val next = mutableState.value.keys.filterNot { it.name == name }
        mutableState.value = mutableState.value.copy(keys = next)
        saveKeys(next)
    }

    override suspend fun setBackendArgs(args: String) {
        preferences.put(BACKEND_ARGS_KEY, args)
        preferences.flush()
        mutableState.value = mutableState.value.copy(backendArgs = args, message = "启动参数已保存")
    }

    override suspend fun setEnginePath(path: String) {
        preferences.put(ENGINE_PATH_KEY, path)
        preferences.flush()
        mutableState.value = mutableState.value.copy(enginePath = path)
    }

    override suspend fun clearMessage() { mutableState.value = mutableState.value.copy(message = null) }
    override suspend fun showMessage(message: String) { mutableState.value = mutableState.value.copy(message = message) }

    private suspend fun updateKey(name: String, transform: (ApiKeyRecord) -> ApiKeyRecord) {
        val next = mutableState.value.keys.map { if (it.name == name) transform(it) else it }
        mutableState.value = mutableState.value.copy(keys = next)
        saveKeys(next)
    }

    private suspend fun saveKeys(keys: List<ApiKeyRecord>) = withContext(Dispatchers.IO) {
        preferences.put(KEYS_KEY, json.encodeToString(ListSerializer(ApiKeyRecord.serializer()), keys))
        preferences.flush()
    }

    private suspend fun startGatewayIfNeeded() {
        if (gateway?.isRunning == true) return
        val instance = ApiGateway(
            keys = { mutableState.value.keys },
            onRequest = { request, key ->
                val requests = (listOf(request) + mutableState.value.requests).take(500)
                mutableState.value = mutableState.value.copy(
                    requests = requests,
                    keys = mutableState.value.keys.map { current -> if (key?.name == current.name) current.copy(requests = current.requests + 1, inputTokens = current.inputTokens + request.inputTokens, outputTokens = current.outputTokens + request.outputTokens) else current },
                )
                preferences.put(LOGS_KEY, json.encodeToString(ListSerializer(RequestRecord.serializer()), requests))
                saveKeys(mutableState.value.keys)
            },
            upstream = "http://127.0.0.1:8081",
            engineRunning = { process?.isAlive == true },
        )
        instance.start()
        gateway = instance
        mutableState.value = mutableState.value.copy(gatewayRunning = true)
    }

    private fun uniqueDestination(name: String): File {
        val base = name.substringBeforeLast('.', name)
        var candidate = File(modelDirectory, name)
        var index = 1
        while (candidate.exists()) candidate = File(modelDirectory, "$base-${index++}.gguf")
        return candidate
    }

    private fun splitArgs(value: String): List<String> = value.split(Regex("\\s+")).filter(String::isNotBlank)

    private class DesktopPlatformFile(private val file: File) : PlatformFile {
        override val absolutePath: String get() = file.absolutePath
        override suspend fun size(): Long = file.length()
        override suspend fun delete() { file.delete() }
    }

    companion object {
        private const val KEYS_KEY = "apiKeys"
        private const val LOGS_KEY = "requestLogs"
        private const val ENGINE_PATH_KEY = "llamaServerPath"
        private const val BACKEND_ARGS_KEY = "backendArgs"
    }
}
