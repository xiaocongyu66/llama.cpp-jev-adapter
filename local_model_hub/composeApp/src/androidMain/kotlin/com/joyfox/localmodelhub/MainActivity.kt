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
            contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            val source = AndroidHubRepository.modelSource(this, uri, displayName(uri))
            viewModel.importModel(displayName(uri), source)
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
                onImportModel = { modelPicker.launch(arrayOf("application/octet-stream", "application/x-gguf")) },
            )
        }
    }

    private fun displayName(uri: Uri): String = contentResolver.query(uri, null, null, null, null)?.use { cursor ->
        val index = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
        if (cursor.moveToFirst() && index >= 0) cursor.getString(index) else "model.gguf"
    } ?: "model.gguf"
}
