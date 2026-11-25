package com.joyfox.localmodelhub

import android.os.Bundle
import android.content.Intent
import android.net.Uri
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts

class MainActivity : ComponentActivity() {
    private lateinit var repository: AndroidHubRepository
    private lateinit var viewModel: HubViewModel

    private val modelPicker = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            runCatching { contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
            val name = displayName(uri)
            val source = AndroidHubRepository.modelSource(this, uri, name)
            viewModel.importModel(name, source)
        } else {
            viewModel.cancelImport()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        repository = AndroidHubRepository(this)
        viewModel = HubViewModel(repository)
        setContent {
            LocalModelHubApp(
                viewModel = viewModel,
                onImportModel = { modelPicker.launch(arrayOf("*/*")) },
            )
        }
    }

    private fun displayName(uri: Uri): String = runCatching {
        contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            val index = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
            if (cursor.moveToFirst() && index >= 0 && !cursor.isNull(index)) cursor.getString(index) else null
        }
    }.getOrNull()?.substringAfterLast('/')?.substringAfterLast('\\')
        ?.takeIf { it.endsWith(".gguf", ignoreCase = true) }
        ?: "model.gguf"
}
