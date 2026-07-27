package com.gaixianggeng.mimi.core.media

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageDecoder
import android.net.Uri
import android.util.Base64
import com.gaixianggeng.mimi.core.model.ImageAttachment
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

object ImageAttachmentEncoder {
    const val MAX_INPUT_BYTES = 50 * 1024 * 1024
    const val MAX_PIXEL_DIMENSION = 1600
    const val TARGET_ENCODED_BYTES = 2 * 1024 * 1024

    suspend fun prepare(contentResolver: ContentResolver, uri: Uri): ImageAttachment = withContext(Dispatchers.IO) {
        val input = contentResolver.openInputStream(uri)?.use { stream ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                output.write(buffer, 0, count)
                check(output.size() <= MAX_INPUT_BYTES) { "The original image exceeds 50 MB" }
            }
            output.toByteArray()
        } ?: error("Could not read the selected image")
        check(input.isNotEmpty()) { "The selected image is empty" }

        val source = ImageDecoder.createSource(ByteBuffer.wrap(input))
        val decoded = ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            val width = info.size.width
            val height = info.size.height
            val scale = minOf(1f, MAX_PIXEL_DIMENSION.toFloat() / maxOf(width, height).toFloat())
            decoder.setTargetSize(maxOf(1, (width * scale).toInt()), maxOf(1, (height * scale).toInt()))
        }
        val normalized = Bitmap.createBitmap(decoded.width, decoded.height, Bitmap.Config.ARGB_8888)
        val pixelWidth = decoded.width
        val pixelHeight = decoded.height
        Canvas(normalized).apply {
            drawColor(Color.WHITE)
            drawBitmap(decoded, 0f, 0f, null)
        }
        if (decoded !== normalized) decoded.recycle()
        var encoded: ByteArray? = null
        for (quality in intArrayOf(80, 68, 56)) {
            val output = ByteArrayOutputStream()
            check(normalized.compress(Bitmap.CompressFormat.JPEG, quality, output)) { "Image compression failed" }
            encoded = output.toByteArray()
            if (encoded.size <= TARGET_ENCODED_BYTES) break
        }
        normalized.recycle()
        val jpeg = requireNotNull(encoded)
        check(jpeg.size <= TARGET_ENCODED_BYTES) { "The image still exceeds 2 MB after compression" }
        ImageAttachment(
            id = UUID.randomUUID().toString(),
            dataUrl = "data:image/jpeg;base64,${Base64.encodeToString(jpeg, Base64.NO_WRAP)}",
            encodedByteCount = jpeg.size,
            pixelWidth = pixelWidth,
            pixelHeight = pixelHeight,
        )
    }
}
