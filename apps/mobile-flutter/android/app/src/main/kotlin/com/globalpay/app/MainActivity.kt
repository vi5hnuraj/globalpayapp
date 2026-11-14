package com.globalpay.app

import android.nfc.NfcAdapter
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The two things Flutter cannot do by itself: a P-256 key that only the fingerprint can use, and
 * asking the NFC adapter whether it exists.
 *
 * The private key never leaves the keystore — hardware-backed where the phone supports it — and every
 * signature requires a fresh biometric authentication. That is the second factor the wallet verifies
 * as a WebAuthn assertion; the first is the card.
 */
class MainActivity : FlutterFragmentActivity() {
    private val channelName = "globalpay/native"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "createKey" -> result.success(createKey(call.argument<String>("alias")!!))
                    "hasKey" -> result.success(hasKey(call.argument<String>("alias")!!))
                    "deleteKey" -> {
                        deleteKey(call.argument<String>("alias")!!)
                        result.success(null)
                    }
                    "biometricsAvailable" -> result.success(biometricsAvailable())
                    "sign" -> sign(
                        alias = call.argument<String>("alias")!!,
                        message = call.argument<ByteArray>("message")!!,
                        title = call.argument<String>("title") ?: "Confirm",
                        subtitle = call.argument<String>("subtitle") ?: "",
                        result = result,
                    )
                    "encryptNearSecret" -> encryptNearSecret(
                        alias = call.argument<String>("alias")!!,
                        plaintext = call.argument<ByteArray>("plaintext")!!,
                        title = call.argument<String>("title") ?: "Protect your NEAR wallet",
                        result = result,
                    )
                    "decryptNearSecret" -> decryptNearSecret(
                        alias = call.argument<String>("alias")!!,
                        ciphertext = call.argument<ByteArray>("ciphertext")!!,
                        iv = call.argument<ByteArray>("iv")!!,
                        title = call.argument<String>("title") ?: "Confirm NEAR payment",
                        subtitle = call.argument<String>("subtitle") ?: "",
                        result = result,
                    )
                    "nfcSupported" -> result.success(nfcAdapter() != null)
                    "nfcEnabled" -> result.success(nfcAdapter()?.isEnabled == true)
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("native", e.message ?: e.toString(), null)
            }
        }
    }

    /** Creates the key on first run and returns its public point, X.509 encoded (last 64 bytes = X||Y). */
    private fun createKey(alias: String): ByteArray {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        ks.getCertificate(alias)?.let { return it.publicKey.encoded } // already set up on this phone

        val builder = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
        } else {
            @Suppress("DEPRECATION")
            builder.setUserAuthenticationValidityDurationSeconds(-1)
        }
        val gen = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
        gen.initialize(builder.build())
        val pair = gen.generateKeyPair()
        return pair.public.encoded
    }

    private fun hasKey(alias: String): Boolean =
        KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.containsAlias(alias)

    private fun deleteKey(alias: String) {
        KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(alias)
    }

    private fun biometricsAvailable(): Boolean =
        BiometricManager.from(this).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) ==
            BiometricManager.BIOMETRIC_SUCCESS

    private fun nfcAdapter(): NfcAdapter? = NfcAdapter.getDefaultAdapter(this)

    /**
     * Returns an AES key whose every use requires a fresh strong biometric. The Ed25519 seed used by
     * the NEAR account is stored only as AES-GCM ciphertext in Flutter's app-private preferences; it
     * is never stored or logged in plaintext and never leaves this device.
     */
    private fun nearWrappingKey(alias: String): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(alias, null) as? SecretKey)?.let { return it }

        val builder = KeyGenParameterSpec.Builder(
            alias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
        } else {
            @Suppress("DEPRECATION")
            builder.setUserAuthenticationValidityDurationSeconds(-1)
        }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(builder.build())
            generateKey()
        }
    }

    private fun encryptNearSecret(
        alias: String,
        plaintext: ByteArray,
        title: String,
        result: MethodChannel.Result,
    ) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.ENCRYPT_MODE, nearWrappingKey(alias))
        }
        authenticateCipher(cipher, title, "", result) { unlocked ->
            val encrypted = unlocked.doFinal(plaintext)
            plaintext.fill(0)
            mapOf("ciphertext" to encrypted, "iv" to unlocked.iv)
        }
    }

    private fun decryptNearSecret(
        alias: String,
        ciphertext: ByteArray,
        iv: ByteArray,
        title: String,
        subtitle: String,
        result: MethodChannel.Result,
    ) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.DECRYPT_MODE, nearWrappingKey(alias), GCMParameterSpec(128, iv))
        }
        authenticateCipher(cipher, title, subtitle, result) { unlocked ->
            unlocked.doFinal(ciphertext)
        }
    }

    private fun authenticateCipher(
        cipher: Cipher,
        title: String,
        subtitle: String,
        result: MethodChannel.Result,
        finish: (Cipher) -> Any,
    ) {
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(authResult: BiometricPrompt.AuthenticationResult) {
                try {
                    result.success(finish(authResult.cryptoObject?.cipher ?: cipher))
                } catch (e: Exception) {
                    result.error("near_key", e.message ?: "Could not unlock the NEAR wallet", null)
                }
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                result.error("cancelled", errString.toString(), null)
            }
        }
        val prompt = BiometricPrompt(this, ContextCompat.getMainExecutor(this), callback)
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .apply { if (subtitle.isNotEmpty()) setSubtitle(subtitle) }
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
            .setNegativeButtonText("Cancel")
            .build()
        prompt.authenticate(info, BiometricPrompt.CryptoObject(cipher))
    }

    /**
     * Fingerprint, then sign [message] with the keystore key. The prompt's own title and subtitle carry
     * the amount, so it is on screen at the moment the finger authenticates — not just in the app behind it.
     */
    private fun sign(alias: String, message: ByteArray, title: String, subtitle: String, result: MethodChannel.Result) {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val key = ks.getKey(alias, null) as? PrivateKey
        if (key == null) {
            result.error("no_key", "This phone has no wallet key. Set the wallet up again.", null)
            return
        }
        val signature = Signature.getInstance("SHA256withECDSA").apply { initSign(key) }

        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(authResult: BiometricPrompt.AuthenticationResult) {
                try {
                    val s = authResult.cryptoObject?.signature ?: signature
                    s.update(message)
                    result.success(s.sign())
                } catch (e: Exception) {
                    result.error("sign", e.message ?: "Could not sign", null)
                }
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                result.error("cancelled", errString.toString(), null)
            }
        }

        val prompt = BiometricPrompt(this, ContextCompat.getMainExecutor(this), callback)
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .apply { if (subtitle.isNotEmpty()) setSubtitle(subtitle) }
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
            .setNegativeButtonText("Cancel")
            .build()
        prompt.authenticate(info, BiometricPrompt.CryptoObject(signature))
    }
}
