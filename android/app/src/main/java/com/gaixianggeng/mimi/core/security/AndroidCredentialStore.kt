package com.gaixianggeng.mimi.core.security

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.io.FileOutputStream
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

interface CredentialStore {
    fun write(profileId: String, token: String)
    fun read(profileId: String): String?
    fun delete(profileId: String)
}

@OptIn(ExperimentalEncodingApi::class)
class AndroidCredentialStore(context: Context) : CredentialStore {
    private val directory = File(context.noBackupFilesDir, "credentials").apply {
        check(isDirectory || mkdirs()) { "Could not create encrypted credential directory" }
    }
    private val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }

    @Synchronized
    override fun write(profileId: String, token: String) {
        require(profileId.matches(PROFILE_ID_PATTERN))
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key(profileId))
        cipher.updateAAD(profileId.toByteArray(Charsets.UTF_8))
        val payload = listOf(
            FORMAT_VERSION,
            Base64.encode(cipher.iv),
            Base64.encode(cipher.doFinal(token.toByteArray(Charsets.UTF_8))),
        ).joinToString("\n")
        val atomicFile = atomicFile(profileId)
        var output: FileOutputStream? = null
        try {
            output = atomicFile.startWrite()
            output.write(payload.toByteArray(Charsets.UTF_8))
            atomicFile.finishWrite(output)
        } catch (error: Throwable) {
            output?.let(atomicFile::failWrite)
            throw error
        }
    }

    @Synchronized
    override fun read(profileId: String): String? {
        require(profileId.matches(PROFILE_ID_PATTERN))
        val payload = runCatching {
            atomicFile(profileId).openRead().use { it.readBytes().toString(Charsets.UTF_8) }
        }.getOrNull() ?: return null
        val values = payload.lines()
        if (values.size != 3 || values[0] != FORMAT_VERSION) return null
        return runCatching {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(profileId), GCMParameterSpec(128, Base64.decode(values[1])))
            cipher.updateAAD(profileId.toByteArray(Charsets.UTF_8))
            cipher.doFinal(Base64.decode(values[2])).toString(Charsets.UTF_8)
        }.getOrNull()
    }

    @Synchronized
    override fun delete(profileId: String) {
        require(profileId.matches(PROFILE_ID_PATTERN))
        atomicFile(profileId).delete()
        check(!file(profileId).exists()) { "Could not delete encrypted credentials" }
        keyStore.deleteEntry(alias(profileId))
    }

    private fun key(profileId: String): SecretKey {
        (keyStore.getKey(alias(profileId), null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE).run {
            init(
                KeyGenParameterSpec.Builder(
                    alias(profileId),
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setKeySize(256)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setRandomizedEncryptionRequired(true)
                    .build(),
            )
            generateKey()
        }
    }

    private fun alias(profileId: String) = "mimi.profile.$profileId"
    private fun file(profileId: String) = File(directory, "$profileId.credential")
    private fun atomicFile(profileId: String) = AtomicFile(file(profileId))

    private companion object {
        const val KEYSTORE = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val FORMAT_VERSION = "mimi-token-v1"
        val PROFILE_ID_PATTERN = Regex("[A-Za-z0-9_-]{1,80}")
    }
}
