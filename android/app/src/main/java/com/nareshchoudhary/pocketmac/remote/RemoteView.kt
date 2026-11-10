package com.nareshchoudhary.pocketmac.remote

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Build
import android.text.InputType
import android.view.Choreographer
import android.view.HapticFeedbackConstants
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.widget.FrameLayout
import com.nareshchoudhary.pocketmac.RemoteSession
import com.nareshchoudhary.pocketmac.data.InputMode
import com.nareshchoudhary.pocketmac.proto.ClientMessage
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * Full-screen view of the Mac: shows the video (SurfaceView, composited by the
 * display hardware), handles zoom/pan, and turns touches and keys into Mac input.
 */
@SuppressLint("ViewConstructor")
class RemoteView(context: Context, private val session: RemoteSession) : FrameLayout(context), SurfaceHolder.Callback, GestureDelegate {
    private val surfaceView = SurfaceView(context)
    private val density = resources.displayMetrics.density
    private val engine = GestureEngine(density, this)

    private var remoteW = 16
    private var remoteH = 10
    private var baseL = 0f; private var baseT = 0f; private var baseW = 0f; private var baseH = 0f
    private var zoom = 1f
    private var originX = 0f; private var originY = 0f
    private var cursorX = 0.5f; private var cursorY = 0.5f   // normalised pointer position on the Mac
    private var keyboardOverlap = 0
    private var touching = false

    private var ringAlpha = 0f
    private var ringFade: ValueAnimator? = null
    private val hideRing = Runnable {
        ringFade = ValueAnimator.ofFloat(ringAlpha, 0f).setDuration(400).apply {
            addUpdateListener { ringAlpha = it.animatedValue as Float; invalidate() }
            start()
        }
    }
    private val ringFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE; style = Paint.Style.FILL }
    private val ringStroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE; style = Paint.Style.STROKE; strokeWidth = 1.5f * density
    }

    private var momentumVX = 0f
    private var momentumVY = 0f
    private var momentumLast = 0L
    private val momentum = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            val dt = if (momentumLast == 0L) 1f / 60 else ((frameTimeNanos - momentumLast) / 1e9f).coerceIn(0.001f, 0.05f)
            momentumLast = frameTimeNanos
            gestureScroll(momentumVX * dt, momentumVY * dt)
            val decay = 0.94f.pow(dt * 60)
            momentumVX *= decay
            momentumVY *= decay
            if (hypot(momentumVX, momentumVY) / density < 30) stopMomentum()
            else Choreographer.getInstance().postFrameCallback(this)
        }
    }

    private val settings get() = session.settings

    init {
        setBackgroundColor(Color.BLACK)
        setWillNotDraw(false)
        isFocusable = true
        isFocusableInTouchMode = true
        surfaceView.holder.addCallback(this)
        addView(surfaceView, LayoutParams(1, 1))
        session.videoSize?.let { (w, h) -> setVideoSize(w, h) }
    }

    // MARK: Lifecycle / surface

    override fun surfaceCreated(holder: SurfaceHolder) {
        if (Build.VERSION.SDK_INT >= 30) {
            // Lets the display drop to a matching refresh rate (saves power on 90/120 Hz screens).
            runCatching { holder.surface.setFrameRate(settings.fps.toFloat(), Surface.FRAME_RATE_COMPATIBILITY_DEFAULT) }
        }
        session.decoder.setSurface(holder.surface)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) = session.decoder.setSurface(null)

    fun setVideoSize(w: Int, h: Int) {
        if (w <= 0 || h <= 0 || (w == remoteW && h == remoteH)) return
        remoteW = w
        remoteH = h
        zoom = 1f
        surfaceView.holder.setFixedSize(w, h)   // scaling to the view is done by the display hardware
        requestLayout()
    }

    fun setKeyboardOverlap(px: Int) {
        if (px == keyboardOverlap) return
        keyboardOverlap = px
        layoutContent()
        follow(cursorX, cursorY)
    }

    fun resetZoom() {
        zoom = 1f
        layoutContent()
    }

    // MARK: Layout

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val w = MeasureSpec.getSize(widthMeasureSpec)
        val h = MeasureSpec.getSize(heightMeasureSpec)
        setMeasuredDimension(w, h)
        computeBase(w, h)
        surfaceView.measure(
            MeasureSpec.makeMeasureSpec(max(1, baseW.toInt()), MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(max(1, baseH.toInt()), MeasureSpec.EXACTLY),
        )
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        computeBase(right - left, bottom - top)
        surfaceView.layout(baseL.toInt(), baseT.toInt(), (baseL + baseW).toInt(), (baseT + baseH).toInt())
        layoutContent()
    }

    private fun computeBase(w: Int, h: Int) {
        if (w <= 0 || h <= 0) return
        val s = min(w.toFloat() / remoteW, h.toFloat() / remoteH)
        baseW = (remoteW * s).toInt().toFloat()
        baseH = (remoteH * s).toInt().toFloat()
        baseL = ((w - baseW) / 2).toInt().toFloat()
        baseT = ((h - baseH) / 2).toInt().toFloat()
    }

    private val visibleHeight: Float get() = max(80 * density, height - keyboardOverlap.toFloat())

    override val canPanView: Boolean
        get() = baseW * zoom > width + 2 || baseH * zoom > visibleHeight + 2

    override val inputMode: InputMode get() = settings.inputMode

    private fun clampAxis(o: Float, content: Float, lo: Float, len: Float): Float =
        if (content <= len) lo + (len - content) / 2 else min(lo, max(lo + len - content, o))

    private fun layoutContent() {
        if (baseW <= 0f) return
        if (zoom <= 1.001f && keyboardOverlap == 0) {
            originX = baseL
            originY = baseT
        }
        originX = clampAxis(originX, baseW * zoom, 0f, width.toFloat())
        originY = clampAxis(originY, baseH * zoom, 0f, visibleHeight)
        surfaceView.pivotX = 0f
        surfaceView.pivotY = 0f
        surfaceView.scaleX = zoom
        surfaceView.scaleY = zoom
        surfaceView.translationX = originX - baseL
        surfaceView.translationY = originY - baseT
        invalidate()
        val z = zoom > 1.01f
        if (session.zoomed != z) session.zoomed = z
    }

    private fun toRemoteX(x: Float) = ((x - originX) / (baseW * zoom)).coerceIn(0f, 1f)
    private fun toRemoteY(y: Float) = ((y - originY) / (baseH * zoom)).coerceIn(0f, 1f)
    private fun toViewX(nx: Float) = originX + nx * baseW * zoom
    private fun toViewY(ny: Float) = originY + ny * baseH * zoom

    /** Keep the pointer on screen when zoomed in / keyboard up. */
    private fun follow(nx: Float, ny: Float) {
        if (!canPanView) return
        val insetX = width * 0.12f
        val insetY = visibleHeight * 0.12f
        val px = toViewX(nx)
        val py = toViewY(ny)
        var dx = 0f
        var dy = 0f
        if (px < insetX) dx = insetX - px else if (px > width - insetX) dx = width - insetX - px
        if (py < insetY) dy = insetY - py else if (py > visibleHeight - insetY) dy = visibleHeight - insetY - py
        if (dx == 0f && dy == 0f) return
        originX += dx
        originY += dy
        layoutContent()
    }

    // MARK: Pointer ring

    override fun dispatchDraw(canvas: Canvas) {
        super.dispatchDraw(canvas)
        if (ringAlpha <= 0f || inputMode != InputMode.TRACKPAD) return
        val x = toViewX(cursorX)
        val y = toViewY(cursorY)
        val r = 14 * density
        ringFill.alpha = (0.12f * 255 * ringAlpha).toInt()
        ringStroke.alpha = (0.8f * 255 * ringAlpha).toInt()
        canvas.drawCircle(x, y, r, ringFill)
        canvas.drawCircle(x, y, r, ringStroke)
    }

    private fun flashRing() {
        if (inputMode != InputMode.TRACKPAD) return
        ringFade?.cancel()
        ringAlpha = 1f
        invalidate()
        removeCallbacks(hideRing)
        postDelayed(hideRing, 800)
    }

    /** The Mac's pointer moved by itself (or with a real mouse). */
    fun remoteCursor(x: Float, y: Float) {
        if (touching) return
        cursorX = x
        cursorY = y
        if (ringAlpha > 0f) invalidate()
    }

    // MARK: Touch

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        if (e.actionMasked == MotionEvent.ACTION_DOWN) {
            requestUnbufferedDispatch(e)   // every touch sample right away, not batched per frame
            touching = true
        }
        engine.onTouchEvent(e)
        if (e.actionMasked == MotionEvent.ACTION_UP || e.actionMasked == MotionEvent.ACTION_CANCEL) touching = false
        return true
    }

    /** Mouse wheel / trackpad scrolling from a connected mouse. */
    override fun onGenericMotionEvent(e: MotionEvent): Boolean {
        if (e.isFromSource(InputDevice.SOURCE_CLASS_POINTER) && e.actionMasked == MotionEvent.ACTION_SCROLL) {
            val sign = if (settings.reverseScroll) -1 else 1
            session.send(ClientMessage.Scroll(-e.getAxisValue(MotionEvent.AXIS_HSCROLL) * 40f * sign,
                e.getAxisValue(MotionEvent.AXIS_VSCROLL) * 40f * sign))
            return true
        }
        return super.onGenericMotionEvent(e)
    }

    override fun gestureTouchBegan() = stopMomentum()

    override fun gestureMoveCursor(dx: Float, dy: Float, speedDpPerSec: Float) {
        val fw = baseW * zoom
        val fh = baseH * zoom
        if (fw <= 0f) return
        val accel = 1 + min(1.6f, speedDpPerSec / 1100)
        val k = settings.trackpadSpeed * 1.15f * accel
        cursorX = (cursorX + dx * k / fw).coerceIn(0f, 1f)
        cursorY = (cursorY + dy * k / fh).coerceIn(0f, 1f)
        session.send(ClientMessage.MouseMove(cursorX, cursorY))
        flashRing()
        follow(cursorX, cursorY)
    }

    override fun gestureClick(button: Int, x: Float?, y: Float?, count: Int) {
        if (x != null && y != null) {
            cursorX = toRemoteX(x)
            cursorY = toRemoteY(y)
        }
        val flags = session.takeModifiers()
        session.send(ClientMessage.MouseMove(cursorX, cursorY))
        session.send(ClientMessage.MouseButton(button, true, cursorX, cursorY, count, flags))
        session.send(ClientMessage.MouseButton(button, false, cursorX, cursorY, count, flags))
        flashRing()
        haptic(if (button == 1) HapticFeedbackConstants.LONG_PRESS else HapticFeedbackConstants.CONTEXT_CLICK)
    }

    override fun gestureButton(button: Int, down: Boolean, x: Float?, y: Float?) {
        if (x != null && y != null) {
            cursorX = toRemoteX(x)
            cursorY = toRemoteY(y)
        }
        if (down) session.send(ClientMessage.MouseMove(cursorX, cursorY))
        session.send(ClientMessage.MouseButton(button, down, cursorX, cursorY, 1, if (down) session.takeModifiers() else 0))
        if (down) haptic(HapticFeedbackConstants.CONTEXT_CLICK)
    }

    override fun gestureDragTo(x: Float, y: Float) {
        cursorX = toRemoteX(x)
        cursorY = toRemoteY(y)
        session.send(ClientMessage.MouseMove(cursorX, cursorY))
        follow(cursorX, cursorY)
    }

    override fun gestureScroll(dx: Float, dy: Float) {
        val sign = if (settings.reverseScroll) -1f else 1f
        session.send(ClientMessage.Scroll(dx / density * 1.6f * sign, dy / density * 1.6f * sign))
    }

    override fun gestureScrollEnded(vx: Float, vy: Float) {
        if (hypot(vx, vy) / density <= 250) return
        momentumVX = vx
        momentumVY = vy
        momentumLast = 0L
        Choreographer.getInstance().removeFrameCallback(momentum)
        Choreographer.getInstance().postFrameCallback(momentum)
    }

    private fun stopMomentum() {
        Choreographer.getInstance().removeFrameCallback(momentum)
        momentumVX = 0f
        momentumVY = 0f
    }

    override fun gestureZoom(scale: Float, focalX: Float, focalY: Float, panX: Float, panY: Float) {
        val nx = (focalX - originX) / (baseW * zoom)
        val ny = (focalY - originY) / (baseH * zoom)
        zoom = (zoom * scale).coerceIn(1f, 6f)
        originX = focalX + panX - nx * baseW * zoom
        originY = focalY + panY - ny * baseH * zoom
        layoutContent()
    }

    override fun gesturePanView(dx: Float, dy: Float) {
        originX += dx
        originY += dy
        layoutContent()
    }

    override fun gestureThreeFinger(direction: Swipe?) {
        val ctrl = ModifierFlag.CONTROL
        when (direction) {
            null -> toggleKeyboard()
            Swipe.LEFT -> session.sendCombo(KeyMap.RIGHT, ctrl)    // fingers left → next Space
            Swipe.RIGHT -> session.sendCombo(KeyMap.LEFT, ctrl)
            Swipe.UP -> session.sendCombo(KeyMap.UP, ctrl)         // Mission Control
            Swipe.DOWN -> session.sendCombo(KeyMap.DOWN, ctrl)     // App windows
        }
        haptic(HapticFeedbackConstants.LONG_PRESS)
    }

    override fun gestureLongPressFeedback() = haptic(HapticFeedbackConstants.LONG_PRESS)

    private fun haptic(kind: Int) {
        if (settings.haptics) performHapticFeedback(kind)
    }

    // MARK: Keyboard

    private val imm get() = context.getSystemService(InputMethodManager::class.java)

    fun toggleKeyboard() = setKeyboard(!session.keyboardVisible)

    fun setKeyboard(on: Boolean) {
        if (on) {
            requestFocus()
            imm?.restartInput(this)
            imm?.showSoftInput(this, 0)
        } else {
            imm?.hideSoftInputFromWindow(windowToken, 0)
        }
        session.keyboardVisible = on
    }

    override fun onCheckIsTextEditor() = true

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        // No autocorrect or suggestions: every key goes to the Mac exactly as typed. Nothing is learned.
        outAttrs.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD or
            InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_FULLSCREEN or
            EditorInfo.IME_ACTION_NONE or EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
        outAttrs.initialSelStart = 0
        outAttrs.initialSelEnd = 0
        return KeyInput()
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean = key(event, soft = false) || super.onKeyDown(keyCode, event)
    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean = key(event, soft = false) || super.onKeyUp(keyCode, event)

    /** Real keyboards send key down/up (so holding a key repeats); soft keyboards' special keys get the bar's modifiers. */
    private fun key(event: KeyEvent, soft: Boolean): Boolean {
        val code = KeyMap.fromAndroid(event.keyCode) ?: return false
        if (soft) {
            if (event.action == KeyEvent.ACTION_DOWN) session.sendCombo(code, session.takeModifiers() or KeyMap.flags(event))
            return true
        }
        when (event.action) {
            KeyEvent.ACTION_DOWN -> session.send(ClientMessage.Key(code, true, KeyMap.flags(event) or session.activeModifiers))
            KeyEvent.ACTION_UP -> session.send(ClientMessage.Key(code, false, KeyMap.flags(event) or session.activeModifiers))
            else -> return false
        }
        return true
    }

    /** Turns the soft keyboard into Mac keystrokes, including keyboards that "compose" words. */
    private inner class KeyInput : BaseInputConnection(this@RemoteView, false) {
        private var composing = ""

        override fun commitText(text: CharSequence, newCursorPosition: Int): Boolean {
            replaceComposing(text.toString())
            composing = ""
            return true
        }

        override fun setComposingText(text: CharSequence, newCursorPosition: Int): Boolean {
            replaceComposing(text.toString())
            composing = text.toString()
            return true
        }

        override fun finishComposingText(): Boolean {
            composing = ""
            return true
        }

        override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
            repeat(beforeLength.coerceAtMost(64)) { session.sendCombo(KeyMap.DELETE, session.takeModifiers()) }
            repeat(afterLength.coerceAtMost(64)) { session.sendCombo(KeyMap.FORWARD_DELETE, 0) }
            return true
        }

        override fun sendKeyEvent(event: KeyEvent): Boolean {
            if (!key(event, soft = true) && event.action == KeyEvent.ACTION_DOWN) {
                val ch = event.unicodeChar
                if (ch != 0) session.typed(String(Character.toChars(ch)))
            }
            return true
        }

        override fun performEditorAction(actionCode: Int): Boolean {
            session.sendCombo(KeyMap.RETURN, session.takeModifiers())
            return true
        }

        /** Send only what changed: backspaces for removed characters, then the new ones. */
        private fun replaceComposing(new: String) {
            val old = composing
            var p = 0
            while (p < old.length && p < new.length && old[p] == new[p]) p++
            if (p > 0 && Character.isHighSurrogate(new[p - 1])) p--
            val removed = old.codePointCount(p, old.length)
            repeat(removed) { session.sendCombo(KeyMap.DELETE, 0) }
            if (p < new.length) session.typed(new.substring(p))
        }
    }
}
