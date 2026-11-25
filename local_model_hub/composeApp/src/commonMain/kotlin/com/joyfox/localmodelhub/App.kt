package com.joyfox.localmodelhub

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LocalModelHubApp(viewModel: HubViewModel, onImportModel: () -> Unit) {
    val state by viewModel.state.collectAsState()
    MaterialTheme {
        Scaffold(
            topBar = { TopAppBar(title = { Text("Local Model Hub · ${state.route.title}") }) },
            bottomBar = {
                NavigationBar {
                    HubRoute.entries.forEach { route ->
                        NavigationBarItem(
                            selected = state.route == route,
                            onClick = { viewModel.navigate(route) },
                            icon = {},
                            label = { Text(route.title) },
                        )
                    }
                }
            },
        ) { insets ->
            Column(
                modifier = Modifier.fillMaxSize().padding(insets).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                state.importingName?.let {
                    LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                    Text("正在导入 $it…", color = MaterialTheme.colorScheme.primary)
                }
                state.message?.let { message ->
                    Card(modifier = Modifier.fillMaxWidth()) {
                        Row(Modifier.padding(12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            SelectionContainer(modifier = Modifier.weight(1f)) {
                                Text(message, color = if (message.startsWith("导入失败") || message.contains("错误")) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary)
                            }
                            OutlinedButton(onClick = { viewModel.clearMessage() }) { Text("关闭") }
                        }
                    }
                }
                when (state.route) {
                    HubRoute.Overview -> OverviewScreen(
                        models = state.models,
                        gatewayRunning = state.gatewayRunning,
                        engineRunning = state.enginePhase == EnginePhase.RUNNING,
                        onToggleGateway = { viewModel.toggleGateway(!state.gatewayRunning) },
                        onImport = onImportModel,
                    )
                    HubRoute.Models -> ModelsScreen(
                        models = state.models,
                        scanDirectory = state.modelDirectory,
                        onImport = onImportModel,
                        onStart = { viewModel.startModel(it.id) },
                        onStop = viewModel::stopModel,
                        onRemove = { viewModel.removeModel(it.id) },
                    )
                    HubRoute.Keys -> KeysScreen(
                        keys = state.keys,
                        onAdd = { viewModel.addKey(it, 60) },
                        onToggle = viewModel::setKeyEnabled,
                        onChangeRpm = viewModel::setKeyRpm,
                        onRemove = viewModel::removeKey,
                    )
                    HubRoute.Activity -> ActivityScreen(state.requests)
                    HubRoute.Settings -> SettingsScreen(
                        modelDirectory = state.modelDirectory,
                        enginePath = state.enginePath,
                        backendArgs = state.backendArgs,
                        onSaveEnginePath = viewModel::setEnginePath,
                        onSaveBackendArgs = viewModel::setBackendArgs,
                    )
                }
            }
        }
    }
}

@Composable
private fun OverviewScreen(
    models: List<ModelRecord>,
    gatewayRunning: Boolean,
    engineRunning: Boolean,
    onToggleGateway: () -> Unit,
    onImport: () -> Unit,
) {
    Button(onClick = onImport) { Text("导入 GGUF 模型") }
    Text("本地推理状态：${if (engineRunning) "运行中" else "已停止"}")
    Text("模型数量：${models.size}")
    Text("API Gateway：http://127.0.0.1:8080/v1 · ${if (gatewayRunning) "运行中" else "已停止"}")
    Button(onClick = onToggleGateway) { Text(if (gatewayRunning) "停止 API" else "启动 API") }
    models.firstOrNull()?.let { Text("当前模型：${it.name}") }
}

@Composable
private fun ModelsScreen(
    models: List<ModelRecord>,
    scanDirectory: String,
    onImport: () -> Unit,
    onStart: (ModelRecord) -> Unit,
    onStop: () -> Unit,
    onRemove: (ModelRecord) -> Unit,
) {
    Text("识别到 ${models.size} 个模型")
    Text(scanDirectory, style = MaterialTheme.typography.bodySmall)
    Button(onClick = onImport) { Text("导入 GGUF 模型") }
    if (models.isEmpty()) {
        Text("当前目录及子目录没有找到 GGUF 文件。请选择模型文件导入到上方显示的目录。")
    } else {
        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(models, key = { it.path }) { model ->
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(model.name, style = MaterialTheme.typography.titleMedium)
                        Text("${formatBytes(model.sizeBytes)} · ${model.path}", style = MaterialTheme.typography.bodySmall)
                        Text(if (model.loaded) "运行中" else "已停止", style = MaterialTheme.typography.labelMedium)
                        Row {
                            Button(onClick = { onStart(model) }) { Text("启动") }
                            Spacer(Modifier.width(8.dp))
                            OutlinedButton(onClick = onStop) { Text("停止") }
                            Spacer(Modifier.width(8.dp))
                            OutlinedButton(onClick = { onRemove(model) }) { Text("删除") }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun KeysScreen(
    keys: List<ApiKeyRecord>,
    onAdd: (String) -> Unit,
    onToggle: (String, Boolean) -> Unit,
    onChangeRpm: (String, Int) -> Unit,
    onRemove: (String) -> Unit,
) {
    var name by remember { mutableStateOf("") }
    Text("API 密钥：${keys.size}")
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text("密钥名称") }, modifier = Modifier.weight(1f))
        Button(onClick = { if (name.isNotBlank()) { onAdd(name.trim()); name = "" } }) { Text("创建") }
    }
    if (keys.isEmpty()) Text("暂无密钥")
    LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        items(keys, key = { it.name }) { key ->
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(key.name, style = MaterialTheme.typography.titleMedium)
                    Text("RPM ${key.rpm} · 请求 ${key.requests} · 输入 ${key.inputTokens} · 输出 ${key.outputTokens}")
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(onClick = { onToggle(key.name, !key.enabled) }) { Text(if (key.enabled) "停用" else "启用") }
                        OutlinedButton(onClick = { onChangeRpm(key.name, key.rpm - 1) }) { Text("RPM−") }
                        OutlinedButton(onClick = { onChangeRpm(key.name, key.rpm + 1) }) { Text("RPM+") }
                        OutlinedButton(onClick = { onRemove(key.name) }) { Text("删除") }
                    }
                }
            }
        }
    }
}

@Composable
private fun ActivityScreen(activities: List<RequestRecord>) {
    Text("请求日志：${activities.size}")
    if (activities.isEmpty()) Text("暂无请求记录")
    LazyColumn(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        items(activities) { item ->
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(10.dp)) {
                    Text("${item.status} · ${item.keyName} · ${item.path}")
                    Text("${item.time} · 输入 ${item.inputTokens} · 输出 ${item.outputTokens} · ${item.latencyMs}ms")
                }
            }
        }
    }
}

@Composable
private fun SettingsScreen(
    modelDirectory: String,
    enginePath: String,
    backendArgs: String,
    onSaveEnginePath: (String) -> Unit,
    onSaveBackendArgs: (String) -> Unit,
) {
    var path by remember(enginePath) { mutableStateOf(enginePath) }
    var args by remember(backendArgs) { mutableStateOf(backendArgs) }
    Text("模型目录")
    Text(modelDirectory, style = MaterialTheme.typography.bodySmall)
    OutlinedTextField(value = path, onValueChange = { path = it }, label = { Text("Linux llama-server 路径") }, modifier = Modifier.fillMaxWidth())
    Button(onClick = { onSaveEnginePath(path) }) { Text("保存可执行文件路径") }
    OutlinedTextField(value = args, onValueChange = { args = it }, label = { Text("启动参数") }, modifier = Modifier.fillMaxWidth())
    Button(onClick = { onSaveBackendArgs(args) }) { Text("保存启动参数") }
    Text("Android llama-server：127.0.0.1:18081")
    Text("Linux llama-server：127.0.0.1:8081")
    Text("API Gateway：127.0.0.1:8080")
}

private fun formatBytes(bytes: Long): String = when {
    bytes >= 1L shl 30 -> "${"%.1f".format(bytes.toDouble() / (1L shl 30))} GB"
    bytes >= 1L shl 20 -> "${"%.1f".format(bytes.toDouble() / (1L shl 20))} MB"
    else -> "${bytes / 1024} KB"
}
