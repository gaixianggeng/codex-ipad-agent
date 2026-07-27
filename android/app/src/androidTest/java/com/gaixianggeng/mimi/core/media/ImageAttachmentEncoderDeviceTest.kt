package com.gaixianggeng.mimi.core.media

import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ImageAttachmentEncoderDeviceTest {
    @Test
    fun largeImageIsOrientedDecodedBoundedAndEncodedAsJpegDataUrl() {
        runBlocking {
            val context = ApplicationProvider.getApplicationContext<android.content.Context>()
            val sourceFile = File(context.cacheDir, "encoder-source.png")
            val bitmap = Bitmap.createBitmap(2400, 1200, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.rgb(40, 120, 200)) }
            sourceFile.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
            bitmap.recycle()

            val result = ImageAttachmentEncoder.prepare(context.contentResolver, Uri.fromFile(sourceFile))

            assertEquals(1600, result.pixelWidth)
            assertEquals(800, result.pixelHeight)
            assertTrue(result.encodedByteCount in 1..ImageAttachmentEncoder.TARGET_ENCODED_BYTES)
            assertTrue(result.dataUrl.startsWith("data:image/jpeg;base64,"))
            sourceFile.delete()
        }
    }
}
