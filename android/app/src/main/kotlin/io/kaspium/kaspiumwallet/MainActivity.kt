package io.kaspium.kaspiumwallet

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.view.WindowManager

class MainActivity: FlutterFragmentActivity() {
    private var nfcWallet: NfcWalletBridge? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        nfcWallet = NfcWalletBridge(this, MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kaspa_nfc/v1"))
    }
    override fun onPause() { nfcWallet?.pause(); super.onPause() }
    override fun onDestroy() { nfcWallet?.close(); super.onDestroy() }
}
