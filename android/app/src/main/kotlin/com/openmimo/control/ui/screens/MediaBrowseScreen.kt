package com.openmimo.control.ui.screens

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openmimo.control.app.OsmoSession
import com.openmimo.control.protocol.OsmoMediaFile
import com.openmimo.control.ui.theme.OC

/**
 * 素材浏览页（移植自 iOS MediaBrowseView）：文件网格 + 缩略图（最新页 + 游标翻页）、
 * 详情弹窗（下载 / 删除）、下载进度。
 */
@Composable
fun MediaBrowseScreen(session: OsmoSession, onBack: () -> Unit) {
    var files by remember { mutableStateOf<List<OsmoMediaFile>>(emptyList()) }
    var selected by remember { mutableStateOf<OsmoMediaFile?>(null) }
    var loading by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var cursor by remember { mutableStateOf<Long?>(null) }
    var endReached by remember { mutableStateOf(false) }
    val thumbs = remember { mutableStateMapOf<String, Bitmap>() }
    val downloadProgress = remember { mutableStateMapOf<String, Float>() }
    var savedFiles by remember { mutableStateOf(setOf<String>()) }

    fun loadFirst() {
        loading = true
        errorMessage = null
        session.launchPublic {
            try {
                val page = session.fetchNewestPage()
                files = page
                cursor = page.lastOrNull()?.handle
                endReached = session.mediaSession?.lastPageReachedEnd ?: false
            } catch (e: Exception) {
                errorMessage = e.message ?: "清单获取失败"
            }
            loading = false
        }
    }

    // 首次进入：拉最新页（对齐 iOS loadFirst）
    LaunchedEffect(Unit) {
        if (files.isEmpty()) loadFirst()
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(OC.bg),
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                .background(OC.bg)
                .padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onBack) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "返回",
                    tint = OC.textPrimary,
                )
            }
            Text("素材浏览", fontSize = 17.sp, fontWeight = FontWeight.Bold, color = OC.textPrimary)
            Spacer(Modifier.weight(1f))
            if (loading) {
                CircularProgressIndicator(
                    modifier = Modifier.size(20.dp),
                    color = OC.accent,
                    strokeWidth = 2.dp,
                )
            }
        }

        if (errorMessage != null) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .padding(20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(errorMessage ?: "", color = OC.recRed, fontSize = 13.sp)
                Spacer(Modifier.height(10.dp))
                Button(
                    onClick = { loadFirst() },
                    colors = androidx.compose.material3.ButtonDefaults.buttonColors(containerColor = OC.accent),
                ) { Text("重试", color = Color.White) }
            }
        } else if (files.isEmpty() && !loading) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("相机 SD 卡暂无文件", color = OC.textSecondary, fontSize = 13.sp)
            }
        } else {
            LazyVerticalGrid(
                columns = GridCells.Fixed(3),
                horizontalArrangement = Arrangement.spacedBy(2.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
                modifier = Modifier.fillMaxSize(),
            ) {
                items(files) { file ->
                    val bmp = thumbs[file.path]
                    Box(
                        Modifier
                            .aspectRatio(4f / 3f)
                            .background(Color(0xFF1A1A1A))
                            .clickable { selected = file },
                    ) {
                        if (bmp != null) {
                            Image(
                                bitmap = bmp.asImageBitmap(),
                                contentDescription = file.name,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier.fillMaxSize(),
                            )
                        }
                        Text(
                            file.name,
                            color = Color.White.copy(alpha = 0.9f),
                            fontSize = 9.sp,
                            maxLines = 1,
                            modifier = Modifier
                                .align(Alignment.BottomStart)
                                .fillMaxWidth()
                                .background(Color.Black.copy(alpha = 0.6f))
                                .padding(horizontal = 6.dp, vertical = 3.dp),
                        )
                    }
                }
                if (!endReached && files.isNotEmpty()) {
                    items(listOf("__load-more__")) { _ ->
                        Box(
                            Modifier
                                .fillMaxWidth()
                                .height(60.dp)
                                .clickable {
                                    val c = cursor ?: return@clickable
                                    loading = true
                                    session.launchPublic {
                                        try {
                                            val page = session.fetchOlderPage(c)
                                            val known = files.map { it.path }.toSet()
                                            files = files + page.filter { it.path !in known }
                                            cursor = page.lastOrNull()?.handle
                                            endReached = session.mediaSession?.lastPageReachedEnd ?: false
                                        } catch (e: Exception) {
                                            errorMessage = e.message
                                        }
                                        loading = false
                                    }
                                },
                            contentAlignment = Alignment.Center,
                        ) { Text("加载更早", color = OC.textSecondary, fontSize = 12.sp) }
                    }
                }
            }
        }
    }

    // 文件详情弹窗（下载/删除；对齐 iOS detailSheet）
    val sel = selected
    if (sel != null) {
        @OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
        androidx.compose.material3.ModalBottomSheet(
            onDismissRequest = { selected = null },
            containerColor = Color.Transparent,
        ) {
            MediaDetailSheet(
                session = session,
                file = sel,
                progress = downloadProgress[sel.path],
                saved = sel.path in savedFiles,
                thumb = thumbs[sel.path],
                onSave = { file ->
                    session.launchPublic {
                        try {
                            downloadProgress[file.path] = 0f
                            val dir = java.io.File(
                                session.appContext.getExternalFilesDir(null)
                                    ?: session.appContext.filesDir,
                                "downloads",
                            )
                            dir.mkdirs()
                            val dest = java.io.File(dir, file.name)
                            session.mediaSession?.download(file, dest) { p ->
                                downloadProgress[file.path] = p.toFloat()
                            }
                            savedFiles = savedFiles + file.path
                        } catch (e: Exception) {
                            session.clearError()
                            session.reportError(e.message ?: "下载失败")
                        } finally {
                            downloadProgress.remove(file.path)
                        }
                    }
                },
                onDelete = { file ->
                    session.launchPublic {
                        try {
                            session.deleteFile(file)
                            files = files.filterNot { it.path == file.path }
                            selected = null
                        } catch (e: Exception) {
                            session.reportError(e.message ?: "删除失败")
                        }
                    }
                },
            )
            // 缩略图预览（异步加载；失败不显示）
            LaunchedEffect(sel.path) {
                try {
                    val data = session.mediaSession?.fetchThumbnail(sel) ?: return@LaunchedEffect
                    val bmp = BitmapFactory.decodeByteArray(data, 0, data.size)
                    if (bmp != null) thumbs[sel.path] = bmp
                } catch (_: Exception) {
                }
            }
        }
    }
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun MediaDetailSheet(
    session: OsmoSession,
    file: OsmoMediaFile,
    progress: Float?,
    saved: Boolean,
    thumb: Bitmap?,
    onSave: (OsmoMediaFile) -> Unit,
    onDelete: (OsmoMediaFile) -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(file.name, fontSize = 16.sp, fontWeight = FontWeight.Bold, color = OC.textPrimary)
        Column {
            DetailRow("文件名", file.name)
            DetailRow("大小", formatBytes(file.sizeBytes))
            if (file.isVideo && file.durationSec > 0) {
                DetailRow("时长", com.openmimo.control.ui.common.OCFormat.duration(file.durationSec.toLong()))
            }
            DetailRow("存储", if (file.storageIndex == 1) "内置存储" else "SD 卡")
        }

        if (progress != null) {
            Column {
                LinearProgressIndicator(
                    progress = { progress },
                    modifier = Modifier.fillMaxWidth(),
                    color = OC.accent,
                )
                Text(
                    "取回中 ${((progress * 100).toInt())}%",
                    fontSize = 10.sp,
                    color = OC.textSecondary,
                )
            }
        }

        if (thumb != null) {
            Image(
                bitmap = thumb.asImageBitmap(),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(16f / 9f)
                    .background(Color.Black, RoundedCornerShape(10.dp)),
            )
        }

        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Button(
                onClick = { onSave(file) },
                enabled = progress == null && !saved,
                modifier = Modifier.weight(1f),
                shape = RoundedCornerShape(10.dp),
                colors = androidx.compose.material3.ButtonDefaults.buttonColors(
                    containerColor = if (saved) OC.okGreen.copy(alpha = 0.14f) else OC.accent,
                    contentColor = if (saved) OC.okGreen else Color.White,
                ),
            ) {
                Text(if (saved) "已保存到相册" else "保存到相册", fontSize = 13.sp)
            }
            Button(
                onClick = { onDelete(file) },
                enabled = progress == null,
                modifier = Modifier.weight(1f),
                shape = RoundedCornerShape(10.dp),
                colors = androidx.compose.material3.ButtonDefaults.buttonColors(
                    containerColor = OC.recRed.copy(alpha = 0.12f),
                    contentColor = OC.recRed,
                ),
            ) { Text("删除", fontSize = 13.sp) }
        }
    }
}

@Composable
private fun DetailRow(k: String, v: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
        Text(k, fontSize = 11.sp, color = OC.textSecondary, modifier = Modifier.size(width = 64.dp, height = 18.dp))
        Text(v, fontSize = 11.sp, color = OC.textPrimary)
    }
}

private fun formatBytes(bytes: Long): String =
    when {
        bytes >= 1L shl 30 -> "%.2f GB".format(bytes / (1L shl 30).toDouble())
        bytes >= 1L shl 20 -> "%.1f MB".format(bytes / (1L shl 20).toDouble())
        else -> "%.0f KB".format(bytes / (1L shl 10).toDouble())
    }
