package com.gaixianggeng.mimi.core.security

import android.content.pm.ApplicationInfo
import android.security.keystore.KeyInfo
import java.io.File
import java.security.KeyStore
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidCredentialStoreDeviceTest {
    @Test
    fun ciphertextRoundTripsWithoutPersistingPlaintextAndUsesRandomizedIv() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val store = AndroidCredentialStore(context)
        val profileId = "device-test-${System.currentTimeMillis()}"
        val token = "mimi-device-secret-${System.nanoTime()}"
        val file = File(context.noBackupFilesDir, "credentials/$profileId.credential")

        try {
            store.write(profileId, token)
            assertEquals(token, store.read(profileId))
            val firstPayload = file.readText(Charsets.UTF_8)
            assertFalse(firstPayload.contains(token))
            assertEquals("mimi-token-v1", firstPayload.lineSequence().first())
            assertTrue(file.canonicalPath.startsWith(context.noBackupFilesDir.canonicalPath + File.separator))
            val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            val key = keyStore.getKey("mimi.profile.$profileId", null) as SecretKey
            val keyInfo = SecretKeyFactory.getInstance(key.algorithm, "AndroidKeyStore")
                .getKeySpec(key, KeyInfo::class.java) as KeyInfo
            assertEquals(256, keyInfo.keySize)

            store.write(profileId, token)
            val secondPayload = file.readText(Charsets.UTF_8)
            assertNotEquals("AES-GCM writes must use a fresh randomized IV", firstPayload, secondPayload)
            assertEquals(token, store.read(profileId))
        } finally {
            store.delete(profileId)
        }
    }

    @Test
    fun tamperingFailsClosedAndDeleteRemovesCiphertextAndKeystoreAlias() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val store = AndroidCredentialStore(context)
        val profileId = "tamper-test-${System.currentTimeMillis()}"
        val file = File(context.noBackupFilesDir, "credentials/$profileId.credential")
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

        try {
            store.write(profileId, "secret")
            assertTrue(keyStore.containsAlias("mimi.profile.$profileId"))
            val lines = file.readLines(Charsets.UTF_8).toMutableList()
            lines[2] = lines[2].replaceRange(0, 1, if (lines[2].startsWith("A")) "B" else "A")
            file.writeText(lines.joinToString("\n"), Charsets.UTF_8)
            assertNull("Modified authenticated ciphertext must not decrypt", store.read(profileId))
        } finally {
            store.delete(profileId)
        }

        assertFalse(file.exists())
        assertFalse(keyStore.containsAlias("mimi.profile.$profileId"))
        assertNull(store.read(profileId))
    }

    @Test
    fun profileIdentifiersCannotEscapeCredentialDirectoryAndBackupIsDisabled() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val store = AndroidCredentialStore(context)

        listOf("", "../token", "profile/name", "x".repeat(81)).forEach { profileId ->
            assertThrows(IllegalArgumentException::class.java) { store.write(profileId, "secret") }
            assertThrows(IllegalArgumentException::class.java) { store.read(profileId) }
            assertThrows(IllegalArgumentException::class.java) { store.delete(profileId) }
        }
        assertFalse(context.applicationInfo.flags and ApplicationInfo.FLAG_ALLOW_BACKUP != 0)
    }
}
