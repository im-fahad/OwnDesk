package io.github.im_fahad.owndesk.ui

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.util.Log
import android.util.Size
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import io.github.im_fahad.owndesk.BuildConfig
import io.github.im_fahad.owndesk.device.QrDecoder
import java.util.concurrent.Executors
import kotlin.math.roundToInt

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
    private var camera: Camera? = null
    private var handled = false
    private var frames = 0

    private val askForCamera = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) start() else {
            hint.text = "OwnDesk needs the camera to read a code. You can paste one instead."
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
            text = "Hold the phone 15 to 25 cm from the code on the Mac. Tap the picture to focus."
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

            // A pairing payload makes a dense QR, eighty or so modules across. At the analyser's
            // default of 640 by 480 each module lands on two pixels or fewer once the code is a
            // sensible distance away, and it simply never resolves. Full HD frames give it room.
            val resolution = ResolutionSelector.Builder()
                .setResolutionStrategy(
                    ResolutionStrategy(Size(1920, 1080), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER)
                )
                .build()
            val analysis = ImageAnalysis.Builder()
                .setResolutionSelector(resolution)
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
                .also { it.setAnalyzer(analysisExecutor, ::analyze) }

            provider.unbindAll()
            val bound = provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, previewUse, analysis)
            camera = bound
            // A phone's main camera cannot focus much closer than ten centimetres, and a pairing
            // code on a laptop screen is only a few centimetres wide, so held close enough to fill
            // the frame it is always a blur. Zooming in lets it be held further back, where the
            // lens can focus, with the code still large in the frame.
            val maxZoom = bound.cameraInfo.zoomState.value?.maxZoomRatio ?: 1f
            bound.cameraControl.setZoomRatio(minOf(SCAN_ZOOM, maxZoom))
            // The code is a bright white square in a dark window. Metered on the whole frame the
            // camera exposes for the dark, the white burns out and bleeds into the black modules
            // until too few are left to read. So it meters on the middle of the aiming frame,
            // which is inside the code, holds that, and exposes well below it. Focus stays
            // continuous.
            val exposure = bound.cameraInfo.exposureState
            if (exposure.isExposureCompensationSupported) {
                val index = (SCAN_EXPOSURE_EV / exposure.exposureCompensationStep.toFloat()).roundToInt()
                bound.cameraControl.setExposureCompensationIndex(
                    index.coerceIn(exposure.exposureCompensationRange.lower, exposure.exposureCompensationRange.upper)
                )
            }
            preview.post { meterOn(preview.width / 2f, preview.height / 2f, AIM_SIZE, FocusMeteringAction.FLAG_AE) }
            // A tap focuses and meters on that spot and holds both, until the next tap.
            preview.setOnTouchListener { _, event ->
                if (event.action == MotionEvent.ACTION_UP) {
                    meterOn(event.x, event.y, TAP_SIZE, FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE)
                    hint.text = "Focused where you tapped. Tap again if you move the phone."
                }
                true
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun meterOn(x: Float, y: Float, size: Float, flags: Int) {
        val control = camera?.cameraControl ?: return
        val point = preview.meteringPointFactory.createPoint(x, y, size)
        control.startFocusAndMetering(FocusMeteringAction.Builder(point, flags).disableAutoCancel().build())
    }

    private fun analyze(image: ImageProxy) {
        try {
            if (handled) return
            val plane = image.planes.firstOrNull() ?: return
            val luminance = QrDecoder.packRows(plane.buffer, plane.rowStride, image.width, image.height)
            // How far the white has bled into the black depends on the screen and the distance,
            // so successive frames try the picture as it is and then with the dark grown back
            // by one, two and three pixels. Each frame stays cheap and one of them lands.
            val radius = DARKEN_STEPS[frames % DARKEN_STEPS.size]
            val text = QrDecoder.decode(QrDecoder.darken(luminance, image.width, image.height, radius), image.width, image.height)
            frames += 1
            if (BuildConfig.DEBUG && frames % 15 == 0) {
                Log.i("OwnDesk", "scanning ${image.width}x${image.height}, $frames frames, nothing read yet")
            }
            // No refocusing from here. Restarting autofocus every second or so, as this once did,
            // keeps the lens searching and it never settles on anything.
            if (text == null) return
            handled = true
            Log.i("OwnDesk", "read a code of ${text.length} characters")
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

        /** Enough to hold the phone beyond its closest focus while the code still fills the frame. */
        private const val SCAN_ZOOM = 2f

        /** Well below what the meter asks for, so the white of the code does not flood the black. */
        private const val SCAN_EXPOSURE_EV = -2f

        /** Metering areas as a fraction of the preview: the middle of the code, and a tapped spot. */
        private const val AIM_SIZE = 0.25f
        private const val TAP_SIZE = 0.3f

        private val DARKEN_STEPS = intArrayOf(0, 1, 2, 3)

        fun intent(context: Context): Intent = Intent(context, ScanActivity::class.java)
    }
}
