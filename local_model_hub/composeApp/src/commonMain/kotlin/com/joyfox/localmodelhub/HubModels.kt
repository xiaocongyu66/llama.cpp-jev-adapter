package com.joyfox.localmodelhub

import kotlinx.serialization.Serializable

@Serializable
data class ModelRecord(
    val id: String,
    val name: String,
    val path: String,
    val sizeBytes: Long,
    val loaded: Boolean = false,
)

@Serializable
data class ApiKeyRecord(
    val name: String,
    val secret: String,
    val rpm: Int = 60,
    val enabled: Boolean = true,
    val requests: Long = 0,
    val inputTokens: Long = 0,
    val outputTokens: Long = 0,
)

@Serializable
data class RequestRecord(
    val time: String,
    val keyName: String,
    val path: String,
    val status: Int,
    val inputTokens: Long,
    val outputTokens: Long,
    val latencyMs: Long,
)

enum class HubRoute(val title: String) {
    Overview("概览"),
    Models("模型"),
    Keys("API 密钥"),
    Activity("请求日志"),
    Settings("设置"),
}

enum class EnginePhase { STOPPED, STARTING, RUNNING, FAILED }

data class HubUiState(
    val route: HubRoute = HubRoute.Overview,
    val models: List<ModelRecord> = emptyList(),
    val keys: List<ApiKeyRecord> = emptyList(),
    val requests: List<RequestRecord> = emptyList(),
    val modelDirectory: String = "",
    val importingName: String? = null,
    val gatewayRunning: Boolean = false,
    val enginePhase: EnginePhase = EnginePhase.STOPPED,
    val backendArgs: String = "--n-gpu-layers auto",
    val enginePath: String = "",
    val message: String? = null,
)
