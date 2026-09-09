package com.prc.controller.ui

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import com.prc.controller.device.QrDecoder
import java.util.concurrent.Executors

/**
 * Points the camera at the code a Mac is showing and hands back what it reads.
 *
 * Typing a pairing code is the worst part of pairing: it is a long line of base64 that a phone
 * keyboard fights at every character. The Mac already draws it as a QR, so reading it is both
 * quicker and less error prone. The code never leaves the phone; it is decoded here.
 */
class ScanActivity : AppCompatActivity() {

    private lateinit var preview: PreviewView
    private lateinit var hint: TextView
    private val analysisExecutor = Executors.newSingleThreadExecutor()
    private var handled = false

    private val askForCamera = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) start() else {
            hint.text = "PRC needs the camera to read a code. You can paste one instead."
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(buildLayout())

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            start()
        } else {
            askForCamera.launch(Manifest.permission.CAMERA)
        }
    }

    private fun buildLayout(): View {
        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }

        preview = PreviewView(this).apply { scaleType = PreviewView.ScaleType.FILL_CENTER }
        root.addView(preview, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))

        // A frame to aim with, in the app's accent colour.
        val target = View(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(16).toFloat()
                setStroke(dp(3), Theme.ACCENT)
                setColor(Color.TRANSPARENT)
            }
        }
        root.addView(target, FrameLayout.LayoutParams(dp(240), dp(240), Gravity.CENTER))

        hint = TextView(this).apply {
            text = "Point at the code on the Mac"
            setTextColor(Theme.TEXT)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, Theme.UI_SECONDARY)
            gravity = Gravity.CENTER
            setBackgroundColor(0xCC161616.toInt())
            setPadding(dp(16), dp(14), dp(16), dp(14))
        }
        val bottom = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(hint, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        }
        root.addView(bottom, FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT, Gravity.BOTTOM))
        return root
    }

    private fun start() {
        val providerFuture = ProcessCameraProvider.getInstance(this)
        providerFuture.addListener({
            val provider = providerFuture.get()
            val previewUse = Preview.Builder().build().also { it.setSurfaceProvider(preview.surfaceProvider) }
            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
                .also { it.setAnalyzer(analysisExecutor, ::analyze) }
            provider.unbindAll()
            provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, previewUse, analysis)
        }, ContextCompat.getMainExecutor(this))
    }

    private fun analyze(image: ImageProxy) {
        try {
            if (handled) return
            val plane = image.planes.firstOrNull() ?: return
            val luminance = QrDecoder.packRows(plane.buffer, plane.rowStride, image.width, image.height)
            val text = QrDecoder.decode(luminance, image.width, image.height) ?: return
            handled = true
            runOnUiThread { finishWith(text) }
        } finally {
            image.close()
        }
    }

    private fun finishWith(text: String) {
        setResult(Activity.RESULT_OK, Intent().putExtra(EXTRA_CODE, text))
        finish()
    }

    override fun onDestroy() {
        analysisExecutor.shutdown()
        super.onDestroy()
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    companion object {
        const val EXTRA_CODE = "code"

        fun intent(context: Context): Intent = Intent(context, ScanActivity::class.java)
    }
}
