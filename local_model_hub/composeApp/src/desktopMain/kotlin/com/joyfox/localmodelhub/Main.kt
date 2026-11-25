package com.joyfox.localmodelhub

import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import java.io.File
import java.io.FileInputStream
import javax.swing.JFileChooser
import javax.swing.filechooser.FileNameExtensionFilter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

fun main() = application {
    val repository = DesktopHubRepository()
    val viewModel = HubViewModel(repository)
    Window(onCloseRequest = ::exitApplication, title = "Local Model Hub") {
        LocalModelHubApp(viewModel) {
            val chooser = JFileChooser().apply { fileFilter = FileNameExtensionFilter("GGUF model", "gguf") }
            if (chooser.showOpenDialog(null) == JFileChooser.APPROVE_OPTION) {
                val selected = chooser.selectedFile
                val source = object : ModelSource {
                    override val sizeBytes = selected.length()
                    override suspend fun copyTo(destination: PlatformFile, onBytesCopied: (Long) -> Unit) = withContext(Dispatchers.IO) {
                        FileInputStream(selected).use { input ->
                            File(destination.absolutePath).outputStream().use { output ->
                                val buffer = ByteArray(1024 * 1024)
                                var copied = 0L
                                while (true) {
                                    val count = input.read(buffer)
                                    if (count < 0) break
                                    output.write(buffer, 0, count)
                                    copied += count
                                    onBytesCopied(copied)
                                }
                                output.fd.sync()
                            }
                        }
                    }
                }
                viewModel.importModel(selected.name, source)
            }
        }
    }
}
