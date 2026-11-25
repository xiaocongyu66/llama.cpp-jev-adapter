package com.joyfox.localmodelhub

import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO as ClientCIO
import io.ktor.client.request.headers
import io.ktor.client.request.request
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsBytes
import io.ktor.client.statement.contentType
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationCall
import io.ktor.server.application.call
import io.ktor.server.cio.CIO as ServerCIO
import io.ktor.server.engine.EmbeddedServer
import io.ktor.server.engine.embeddedServer
import io.ktor.server.request.httpMethod
import io.ktor.server.request.path
import io.ktor.server.request.receiveChannel
import io.ktor.server.response.respondBytes
import io.ktor.server.routing.options
import io.ktor.server.routing.route
import io.ktor.server.routing.routing
import io.ktor.utils.io.readRemaining
import io.ktor.utils.io.core.readBytes
import kotlin.time.Duration.Companion.seconds
import kotlin.time.TimeSource
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

class ApiGateway(
    private val keys: () -> List<ApiKeyRecord>,
    private val onRequest: suspend (RequestRecord, ApiKeyRecord?) -> Unit,
    private val upstream: String,
    private val engineRunning: () -> Boolean,
) {
    private val client = HttpClient(ClientCIO)
    private val mutex = Mutex()
    private var server: EmbeddedServer<*, *>? = null
    private val rpmTimestamps = mutableMapOf<String, MutableList<kotlin.time.TimeMark>>()
    private val json = Json { ignoreUnknownKeys = true }

    val isRunning: Boolean get() = server != null

    suspend fun start(port: Int = 8080) {
        mutex.withLock {
            if (server != null) return
            server = embeddedServer(ServerCIO, host = "127.0.0.1", port = port) {
                gatewayRoutes()
            }.start(wait = false)
        }
    }

    suspend fun stop() {
        mutex.withLock {
            server?.stop(gracePeriodMillis = 250, timeoutMillis = 1000)
            server = null
        }
    }

    suspend fun close() {
        stop()
        client.close()
    }

    private fun admitRequest(key: String, rpm: Int): Boolean {
        val timestamps = rpmTimestamps.getOrPut(key) { mutableListOf() }
        timestamps.removeAll { it.elapsedNow() >= 60.seconds }
        if (timestamps.size >= rpm.coerceAtLeast(1)) return false
        timestamps += TimeSource.Monotonic.markNow()
        return true
    }

    private fun Application.gatewayRoutes() {
        routing {
            route("/{path...}") {
                options {
                    call.response.headers.append(HttpHeaders.AccessControlAllowOrigin, "*")
                    call.response.headers.append(HttpHeaders.AccessControlAllowMethods, "GET, POST, OPTIONS")
                    call.response.headers.append(HttpHeaders.AccessControlAllowHeaders, "Authorization, Content-Type")
                    call.respondBytes(byteArrayOf(), status = HttpStatusCode.NoContent)
                }
                handle {
                    val timer = TimeSource.Monotonic.markNow()
                    val path = call.request.path()
                    val token = call.request.headers[HttpHeaders.Authorization]
                        ?.takeIf { it.startsWith("Bearer ") }
                        ?.removePrefix("Bearer ")
                    val key = keys().firstOrNull { it.enabled && constantTimeEquals(it.secret, token) }
                    if (key == null) {
                        call.respondGatewayError(HttpStatusCode.Unauthorized, "Invalid API key")
                        onRequest(RequestRecord(nowIso(), "未授权", path, 401, 0, 0, timer.elapsedNow().inWholeMilliseconds), null)
                        return@handle
                    }
                    val admitted = mutex.withLock { admitRequest(key.name, key.rpm) }
                    if (!admitted) {
                        call.respondGatewayError(HttpStatusCode.TooManyRequests, "Rate limit exceeded")
                        onRequest(RequestRecord(nowIso(), key.name, path, 429, 0, 0, timer.elapsedNow().inWholeMilliseconds), key)
                        return@handle
                    }
                    val running = engineRunning()
                    if (path == "/health") {
                        call.respondBytes("""{"status":"ok","engine":$running}""".encodeToByteArray(), ContentType.Application.Json)
                        onRequest(RequestRecord(nowIso(), key.name, path, 200, 0, 0, timer.elapsedNow().inWholeMilliseconds), key)
                        return@handle
                    }
                    if (path !in setOf("/v1/chat/completions", "/v1/completions", "/v1/embeddings", "/v1/systemone") || !running) {
                        call.respondGatewayError(HttpStatusCode.ServiceUnavailable, "No model engine running")
                        onRequest(RequestRecord(nowIso(), key.name, path, 503, 0, 0, timer.elapsedNow().inWholeMilliseconds), key)
                        return@handle
                    }
                    try {
                        val body = call.receiveChannel().readRemaining().readBytes()
                        val upstreamResponse = client.request("$upstream$path") {
                            method = HttpMethod.parse(call.request.httpMethod.value)
                            call.request.headers.forEach { name, values ->
                                if (!name.equals(HttpHeaders.Host, true) && !name.equals(HttpHeaders.Authorization, true)) {
                                    values.forEach { headers.append(name, it) }
                                }
                            }
                            setBody(body)
                        }
                        val responseBytes = upstreamResponse.bodyAsBytes()
                        call.response.headers.append(HttpHeaders.AccessControlAllowOrigin, "*")
                        call.respondBytes(responseBytes, upstreamResponse.contentType() ?: ContentType.Application.Json, status = upstreamResponse.status)
                        val usage = runCatching {
                            val root = json.parseToJsonElement(responseBytes.decodeToString()).jsonObject
                            val value = root["usage"]!!.jsonObject
                            (value["prompt_tokens"] ?: value["input_tokens"])!!.jsonPrimitive.longOrNull to
                                (value["completion_tokens"] ?: value["output_tokens"])!!.jsonPrimitive.longOrNull
                        }.getOrNull()
                        onRequest(RequestRecord(nowIso(), key.name, path, upstreamResponse.status.value, usage?.first ?: 0, usage?.second ?: 0, timer.elapsedNow().inWholeMilliseconds), key)
                    } catch (error: Exception) {
                        call.respondGatewayError(HttpStatusCode.BadGateway, "Model engine unavailable: ${error.message.orEmpty()}")
                        onRequest(RequestRecord(nowIso(), key.name, path, 502, 0, 0, timer.elapsedNow().inWholeMilliseconds), key)
                    }
                }
            }
        }
    }
}

private suspend fun ApplicationCall.respondGatewayError(status: HttpStatusCode, message: String) {
    val escaped = message.replace("\\", "\\\\").replace("\"", "\\\"")
    respondBytes("""{"error":{"message":"$escaped"}}""".encodeToByteArray(), ContentType.Application.Json, status)
}

private fun constantTimeEquals(expected: String, actual: String?): Boolean {
    if (actual == null) return false
    val a = expected.encodeToByteArray()
    val b = actual.encodeToByteArray()
    if (a.size != b.size) return false
    var different = 0
    for (index in a.indices) different = different or (a[index].toInt() xor b[index].toInt())
    return different == 0
}

private fun nowIso(): String = kotlinx.datetime.Clock.System.now().toString()
