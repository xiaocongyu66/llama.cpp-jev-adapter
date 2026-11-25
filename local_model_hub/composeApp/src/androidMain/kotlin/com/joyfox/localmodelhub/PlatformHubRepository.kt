package com.joyfox.localmodelhub

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

class AndroidHubRepository(private val context: Context) : HubRepository {
    private val preferences = context.getSharedPreferences("local-model-hub", Context.MODE_PRIVATE)
    private val securePreferences by lazy {
        val masterKey = MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
        EncryptedSharedPreferences.create(
            context,
            "local-model-hub-secrets",
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }
    private val json = Json { ignoreUnknownKeys = true; prettyPrint = false }
    private val modelDirectory = File(context.filesDir, "models")
    private val mutableState = MutableStateFlow(HubUiState(modelDirectory = modelDirectory.absolutePath))
    override val state = mutableState.asStateFlow()
    private var gateway: ApiGateway? = null

    override suspend fun refresh() = withContext(Dispatchers.IO) {
        modelDirectory.mkdirs()
        val diskModels = modelDirectory.walkTopDown().filter { it.isFile && it.extension.equals("gguf", true) }.toList()
        val models = diskModels.map { file ->
            ModelRecord(
                id = file.absolutePath,
                name = file.name,
                path = file.absolutePath,
                sizeBytes = file.length(),
                loaded = mutableState.value.models.firstOrNull { it.path == file.absolutePath }?.loaded ?: false,
            )
        }
        val keys = runCatching { decodeLegacyKeys(securePreferences.getString(KEYS_KEY, null)) }.getOrDefault(emptyList())
        val requests = runCatching { json.decodeFromString(ListSerializer(RequestRecord.serializer()), preferences.getString(LOGS_KEY, "[]") ?: "[]") }.getOrDefault(emptyList())
        mutableState.value = mutableState.value.copy(
            models = models,
            keys = keys,
            requests = requests,
            modelDirectory = modelDirectory.absolutePath,
            backendArgs = preferences.getString(BACKEND_ARGS_KEY, "--n-gpu-layers auto") ?: "--n-gpu-layers auto",
            enginePath = preferences.getString(ENGINE_PATH_KEY, "") ?: "",
            enginePhase = if (LlamaEngineService.states.value is EngineState.Running) EnginePhase.RUNNING else EnginePhase.STOPPED,
        )
        persistModelIndex(models)
    }

    override suspend fun navigate(route: HubRoute) {
        mutableState.value = mutableState.value.copy(route = route)
    }

    override suspend fun beginImport() {
        mutableState.value = mutableState.value.copy(importingName = "正在选择模型…", message = null)
    }

    override suspend fun importModel(displayName: String, source: ModelSource) = withContext(Dispatchers.IO) {
        val safeName = displayName.substringAfterLast('/').substringAfterLast('\\')
        val total = source.sizeBytes
        mutableState.value = mutableState.value.copy(importingName = safeName, message = null)
        var staging: File? = null
        try {
            check(safeName.endsWith(".gguf", ignoreCase = true)) {
                "所选文件不是 GGUF 模型：$displayName"
            }
            check(modelDirectory.isDirectory || modelDirectory.mkdirs()) {
                "无法创建模型目录：${modelDirectory.absolutePath}"
            }
            val stagingFile = File(modelDirectory, ".$safeName.${UUID.randomUUID()}.importing")
            staging = stagingFile
            source.copyTo(AndroidPlatformFile(stagingFile), onBytesCopied = { copied ->
                mutableState.value = mutableState.value.copy(message = "已复制 $copied / ${if (total >= 0L) total else "未知"} 字节")
            })
            if (stagingFile.length() == 0L || (total >= 0L && stagingFile.length() != total)) {
                error("模型复制不完整：$total -> ${stagingFile.length()} 字节")
            }
            val destination = uniqueDestination(safeName)
            check(stagingFile.renameTo(destination)) { "无法将模型写入 ${destination.absolutePath}" }
            staging = null
            check(destination.isFile && destination.length() > 0L) {
                "模型文件未写入目标目录：${destination.absolutePath}"
            }
            refresh()
            mutableState.value = mutableState.value.copy(message = "已导入 ${destination.name}")
        } catch (error: Exception) {
            staging?.delete()
            mutableState.value = mutableState.value.copy(message = "导入失败：${error.message ?: error.javaClass.simpleName}")
        } finally {
            mutableState.value = mutableState.value.copy(importingName = null)
        }
    }

    override suspend fun clearImport() {
        mutableState.value = mutableState.value.copy(importingName = null, message = null)
    }

    override suspend fun removeModel(modelId: String) = withContext(Dispatchers.IO) {
        val model = mutableState.value.models.firstOrNull { it.id == modelId } ?: return@withContext
        if (model.loaded) stopModel()
        File(model.path).delete()
        refresh()
    }

    override suspend fun startModel(modelId: String) = withContext(Dispatchers.IO) {
        val model = mutableState.value.models.firstOrNull { it.id == modelId } ?: return@withContext
        mutableState.value = mutableState.value.copy(enginePhase = EnginePhase.STARTING, message = null)
        try {
            LlamaEngineService.start(context, model.path, preferences.getString(BACKEND_ARGS_KEY, "--n-gpu-layers auto") ?: "", 18081)
            var ready = false
            repeat(120) {
                if (!ready) {
                    ready = runCatching {
                        val connection = java.net.URL("http://127.0.0.1:18081/health").openConnection() as java.net.HttpURLConnection
                        connection.connectTimeout = 1000
                        connection.readTimeout = 1000
                        connection.requestMethod = "GET"
                        try {
                            connection.responseCode in 200..299
                        } finally {
                            connection.disconnect()
                        }
                    }.getOrDefault(false)
                    if (!ready) kotlinx.coroutines.delay(500)
                }
            }
            check(ready) { "llama-server 在 60 秒内未就绪" }
            mutableState.value = mutableState.value.copy(
                models = mutableState.value.models.map { it.copy(loaded = it.id == modelId) },
                enginePhase = EnginePhase.RUNNING,
            )
        } catch (error: Exception) {
            LlamaEngineService.stop(context)
            mutableState.value = mutableState.value.copy(enginePhase = EnginePhase.FAILED, message = "模型启动失败：${error.message}")
        }
    }

    override suspend fun stopModel() = withContext(Dispatchers.IO) {
        LlamaEngineService.stop(context)
        mutableState.value = mutableState.value.copy(enginePhase = EnginePhase.STOPPED, models = mutableState.value.models.map { it.copy(loaded = false) })
    }

    override suspend fun setGatewayRunning(running: Boolean) {
        if (running) startGatewayIfNeeded() else gateway?.stop()
        mutableState.value = mutableState.value.copy(gatewayRunning = running)
    }

    override suspend fun addApiKey(name: String, rpm: Int): String {
        val secret = "lmh_${ByteArray(32).also(java.security.SecureRandom()::nextBytes).joinToString("") { "%02x".format(it) }}"
        val key = ApiKeyRecord(name, secret, rpm)
        val next = mutableState.value.keys + key
        mutableState.value = mutableState.value.copy(keys = next, message = "新密钥：$secret")
        saveKeys(next)
        return secret
    }

    override suspend fun setApiKeyEnabled(name: String, enabled: Boolean) {
        updateKey(name) { it.copy(enabled = enabled) }
    }

    override suspend fun setApiKeyRpm(name: String, rpm: Int) {
        updateKey(name) { it.copy(rpm = rpm.coerceAtLeast(1)) }
    }

    override suspend fun removeApiKey(name: String) {
        val next = mutableState.value.keys.filterNot { it.name == name }
        mutableState.value = mutableState.value.copy(keys = next)
        saveKeys(next)
    }

    override suspend fun setBackendArgs(args: String) {
        preferences.edit().putString(BACKEND_ARGS_KEY, args).apply()
        mutableState.value = mutableState.value.copy(backendArgs = args, message = "启动参数已保存")
    }

    override suspend fun setEnginePath(path: String) {
        preferences.edit().putString(ENGINE_PATH_KEY, path).apply()
        mutableState.value = mutableState.value.copy(enginePath = path)
    }

    override suspend fun clearMessage() {
        mutableState.value = mutableState.value.copy(message = null)
    }

    override suspend fun showMessage(message: String) {
        mutableState.value = mutableState.value.copy(message = message)
    }

    private suspend fun updateKey(name: String, transform: (ApiKeyRecord) -> ApiKeyRecord) {
        val next = mutableState.value.keys.map { if (it.name == name) transform(it) else it }
        mutableState.value = mutableState.value.copy(keys = next)
        saveKeys(next)
    }

    private suspend fun saveKeys(keys: List<ApiKeyRecord>) = withContext(Dispatchers.IO) {
        securePreferences.edit().putString(KEYS_KEY, json.encodeToString(ListSerializer(ApiKeyRecord.serializer()), keys)).apply()
    }

    private suspend fun persistModelIndex(models: List<ModelRecord>) = withContext(Dispatchers.IO) {
        preferences.edit().putString(MODELS_KEY, json.encodeToString(ListSerializer(ModelRecord.serializer()), models)).apply()
    }

    private suspend fun startGatewayIfNeeded() {
        if (gateway?.isRunning == true) return
        val instance = ApiGateway(
            keys = { mutableState.value.keys },
            onRequest = { request, key ->
                val requests = (listOf(request) + mutableState.value.requests).take(500)
                mutableState.value = mutableState.value.copy(
                    requests = requests,
                    keys = mutableState.value.keys.map { current ->
                        if (key?.name == current.name) current.copy(
                            requests = current.requests + 1,
                            inputTokens = current.inputTokens + request.inputTokens,
                            outputTokens = current.outputTokens + request.outputTokens,
                        ) else current
                    },
                )
                preferences.edit().putString(LOGS_KEY, json.encodeToString(ListSerializer(RequestRecord.serializer()), requests)).apply()
                saveKeys(mutableState.value.keys)
            },
            upstream = "http://127.0.0.1:18081",
            engineRunning = { LlamaEngineService.states.value is EngineState.Running },
        )
        instance.start()
        gateway = instance
        mutableState.value = mutableState.value.copy(gatewayRunning = true)
    }

    private fun uniqueDestination(name: String): File {
        val base = name.substringBeforeLast('.', name)
        var candidate = File(modelDirectory, name)
        var suffix = 1
        while (candidate.exists()) candidate = File(modelDirectory, "$base-$suffix.gguf").also { suffix++ }
        return candidate
    }

    private suspend fun decodeLegacyKeys(raw: String?): List<ApiKeyRecord> {
        if (raw.isNullOrBlank()) return emptyList()
        return runCatching { json.decodeFromString(ListSerializer(ApiKeyRecord.serializer()), raw) }.getOrElse { emptyList() }
    }

    companion object {
        const val EXTRA_MODEL_URI = "modelUri"
        private const val KEYS_KEY = "apiKeys"
        private const val MODELS_KEY = "models"
        private const val LOGS_KEY = "requestLogs"
        private const val BACKEND_ARGS_KEY = "backendArgs"
        private const val ENGINE_PATH_KEY = "llamaServerPath"

        fun modelSource(context: Context, uri: Uri, displayName: String): ModelSource {
            val resolver = context.contentResolver
            val size = runCatching {
                resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (cursor.moveToFirst() && sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                        cursor.getLong(sizeIndex).takeIf { it > 0L } ?: -1L
                    } else {
                        -1L
                    }
                } ?: -1L
            }.getOrDefault(-1L)
            return object : ModelSource {
                override val sizeBytes: Long = size
                override suspend fun copyTo(destination: PlatformFile, onBytesCopied: (Long) -> Unit) = withContext(Dispatchers.IO) {
                    val target = File(destination.absolutePath)
                    resolver.openInputStream(uri)?.use { input ->
                        FileOutputStream(target).use { output ->
                            val buffer = ByteArray(DEFAULT_BUFFER_SIZE * 8)
                            var copied = 0L
                            while (true) {
                                val read = input.read(buffer)
                                if (read < 0) break
                                output.write(buffer, 0, read)
                                copied += read
                                onBytesCopied(copied)
                            }
                            output.fd.sync()
                        }
                    } ?: error("Android 无法读取所选 URI：$displayName")
                }
            }
        }
    }
}

private class AndroidPlatformFile(private val file: File) : PlatformFile {
    override val absolutePath: String get() = file.absolutePath
    override suspend fun size(): Long = file.length()
    override suspend fun delete() { file.delete() }
}
