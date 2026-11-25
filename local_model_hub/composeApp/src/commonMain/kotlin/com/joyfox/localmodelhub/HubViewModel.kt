package com.joyfox.localmodelhub

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

class HubViewModel(private val repository: HubRepository) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    val state: StateFlow<HubUiState> = repository.state

    init {
        scope.launch { repository.refresh() }
    }

    fun navigate(route: HubRoute) = scope.launch { repository.navigate(route) }

    fun importModel(name: String, source: ModelSource) = scope.launch {
        repository.importModel(name, source)
    }

    fun cancelImport() = scope.launch { repository.clearImport() }

    fun removeModel(id: String) = scope.launch { repository.removeModel(id) }
    fun startModel(id: String) = scope.launch { repository.startModel(id) }
    fun stopModel() = scope.launch { repository.stopModel() }
    fun toggleGateway(running: Boolean) = scope.launch { repository.setGatewayRunning(running) }
    fun clearMessage() = scope.launch { repository.clearMessage() }

    fun addKey(name: String, rpm: Int) = scope.launch {
        val secret = repository.addApiKey(name, rpm)
        repository.showMessage("密钥创建成功，请立即保存：$secret")
    }
    fun setKeyEnabled(name: String, enabled: Boolean) = scope.launch { repository.setApiKeyEnabled(name, enabled) }
    fun setKeyRpm(name: String, rpm: Int) = scope.launch { repository.setApiKeyRpm(name, rpm) }
    fun removeKey(name: String) = scope.launch { repository.removeApiKey(name) }
    fun setBackendArgs(args: String) = scope.launch { repository.setBackendArgs(args) }
    fun setEnginePath(path: String) = scope.launch { repository.setEnginePath(path) }
}
