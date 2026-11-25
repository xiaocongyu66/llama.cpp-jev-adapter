package com.joyfox.localmodelhub

import kotlinx.coroutines.flow.StateFlow

interface HubRepository {
    val state: StateFlow<HubUiState>

    suspend fun refresh()
    suspend fun navigate(route: HubRoute)
    suspend fun beginImport()
    suspend fun importModel(displayName: String, source: ModelSource)
    suspend fun clearImport()
    suspend fun removeModel(modelId: String)
    suspend fun startModel(modelId: String)
    suspend fun stopModel()
    suspend fun setGatewayRunning(running: Boolean)
    suspend fun addApiKey(name: String, rpm: Int): String
    suspend fun setApiKeyEnabled(name: String, enabled: Boolean)
    suspend fun setApiKeyRpm(name: String, rpm: Int)
    suspend fun removeApiKey(name: String)
    suspend fun setBackendArgs(args: String)
    suspend fun setEnginePath(path: String)
    suspend fun clearMessage()
    suspend fun showMessage(message: String)
}

interface ModelSource {
    val sizeBytes: Long
    suspend fun copyTo(destination: PlatformFile, onBytesCopied: (Long) -> Unit)
}

interface PlatformFile {
    val absolutePath: String
    suspend fun size(): Long
    suspend fun delete()
}
