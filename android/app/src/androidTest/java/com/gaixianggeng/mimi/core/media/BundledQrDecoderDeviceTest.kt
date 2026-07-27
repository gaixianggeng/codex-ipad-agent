package com.gaixianggeng.mimi.core.media

import android.graphics.Bitmap
import android.graphics.Color
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BundledQrDecoderDeviceTest {
    @Test
    fun bundledModelDecodesPairingUriWithoutPlayServicesModule() {
        val pairingUri =
            "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.2%3A8787" +
                "&expires_at=2026-07-23T03%3A00%3A00Z" +
                "&issued_at=2026-07-23T02%3A50%3A00Z" +
                "&pair_sig=device-test-signature"
        val matrix = QRCodeWriter().encode(pairingUri, BarcodeFormat.QR_CODE, QR_SIZE, QR_SIZE)
        val pixels = IntArray(QR_SIZE * QR_SIZE)
        for (y in 0 until QR_SIZE) {
            for (x in 0 until QR_SIZE) {
                pixels[y * QR_SIZE + x] = if (matrix[x, y]) Color.BLACK else Color.WHITE
            }
        }
        val bitmap = Bitmap.createBitmap(QR_SIZE, QR_SIZE, Bitmap.Config.ARGB_8888).apply {
            setPixels(pixels, 0, QR_SIZE, 0, 0, QR_SIZE, QR_SIZE)
        }
        val scanner = BarcodeScanning.getClient(
            BarcodeScannerOptions.Builder()
                .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                .build(),
        )

        try {
            val barcodes = Tasks.await(
                scanner.process(InputImage.fromBitmap(bitmap, 0)),
                10,
                TimeUnit.SECONDS,
            )
            assertEquals(pairingUri, barcodes.single().rawValue)
        } finally {
            scanner.close()
            bitmap.recycle()
        }
    }

    private companion object {
        const val QR_SIZE = 720
    }
}
