package com.nareshchoudhary.pocketmac.remote

import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import com.nareshchoudhary.pocketmac.data.InputMode
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

enum class Swipe { LEFT, RIGHT, UP, DOWN }

interface GestureDelegate {
    val inputMode: InputMode
    /** True when the picture is bigger than the visible area (zoomed or keyboard up). */
    val canPanView: Boolean
    fun gestureMoveCursor(dx: Float, dy: Float, speedDpPerSec: Float)
    fun gestureClick(button: Int, x: Float?, y: Float?, count: Int)
    fun gestureButton(button: Int, down: Boolean, x: Float?, y: Float?)
    fun gestureDragTo(x: Float, y: Float)
    fun gestureScroll(dx: Float, dy: Float)
    fun gestureScrollEnded(vx: Float, vy: Float)
    fun gestureZoom(scale: Float, focalX: Float, focalY: Float, panX: Float, panY: Float)
    fun gesturePanView(dx: Float, dy: Float)
    fun gestureThreeFinger(direction: Swipe?)
    fun gestureTouchBegan()
    fun gestureLongPressFeedback()
}

/**
 * Raw-touch gesture recogniser (same rules as the iPhone app). One place decides
 * what every touch means, so gestures never fight each other.
 *
 *                      Trackpad mode              Touch mode
 *  1-finger tap        click at pointer           click under finger
 *  double / triple     double / triple click      double / triple click
 *  1-finger slide      move pointer               drag (or pan view when zoomed)
 *  tap, then slide     drag (select / move)       drag
 *  long press          right click                right click under finger
 *  2-finger tap        right click                right click
 *  2-finger slide      scroll (with momentum)     scroll (with momentum)
 *  pinch               zoom the picture           zoom the picture
 *  3-finger swipe      ← → Spaces, ↑ Mission Control, ↓ App windows
 *  3-finger tap        show / hide keyboard
 *
 * Positions are view pixels; distances are compared in dp.
 */
class GestureEngine(private val density: Float, private val delegate: GestureDelegate) {
    private enum class Phase { IDLE, ONE, TWO, THREE, FINISHING }
    private enum class TwoMode { UNDECIDED, SCROLL, ZOOM }

    private val handler = Handler(Looper.getMainLooper())
    private var phase = Phase.IDLE
    private val ids = ArrayList<Int>()
    private val xs = HashMap<Int, Float>()
    private val ys = HashMap<Int, Float>()

    // one finger
    private var startX = 0f; private var startY = 0f
    private var lastX = 0f; private var lastY = 0f
    private var lastTime = 0.0
    private var startTime = 0.0
    private var moved = false
    private var dragging = false
    private var panningView = false
    private var tapDragCandidate = false
    private var longPressFired = false
    private var lastTapTime = 0.0
    private var lastTapX = 0f; private var lastTapY = 0f
    private var tapCount = 0
    private var speed = 0f   // dp/s
    private val longPress = Runnable { fireLongPress() }

    // two / three fingers
    private var twoMode = TwoMode.UNDECIDED
    private var startDistance = 1f
    private var lastDistance = 1f
    private var startCX = 0f; private var startCY = 0f
    private var lastCX = 0f; private var lastCY = 0f
    private var multiStartTime = 0.0
    private var multiMoved = false
    private var velX = 0f; private var velY = 0f
    private var maxFingers = 0

    private fun dp(px: Float) = px / density

    fun onTouchEvent(e: MotionEvent) {
        for (i in 0 until e.pointerCount) {
            val id = e.getPointerId(i)
            xs[id] = e.getX(i)
            ys[id] = e.getY(i)
        }
        val now = e.eventTime / 1000.0
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> began(e.getPointerId(0), now)
            MotionEvent.ACTION_POINTER_DOWN -> began(e.getPointerId(e.actionIndex), now)
            MotionEvent.ACTION_MOVE -> moved(now)
            MotionEvent.ACTION_POINTER_UP -> ended(listOf(e.getPointerId(e.actionIndex)), now, cancelled = false)
            MotionEvent.ACTION_UP -> ended(listOf(e.getPointerId(0)), now, cancelled = false)
            MotionEvent.ACTION_CANCEL -> ended(ids.toList(), now, cancelled = true)
        }
    }

    private fun cx() = ids.map { xs[it] ?: 0f }.average().toFloat()
    private fun cy() = ids.map { ys[it] ?: 0f }.average().toFloat()

    private fun distance(): Float {
        if (ids.size < 2) return 1f
        val a = ids[0]; val b = ids[1]
        return max(1f, hypot((xs[a] ?: 0f) - (xs[b] ?: 0f), (ys[a] ?: 0f) - (ys[b] ?: 0f)))
    }

    private fun began(id: Int, now: Double) {
        val wasIdle = ids.isEmpty()
        if (!ids.contains(id)) ids.add(id)
        maxFingers = max(maxFingers, ids.size)
        if (wasIdle) delegate.gestureTouchBegan()

        when {
            ids.size == 1 && phase == Phase.IDLE -> beginOne(now)
            ids.size == 2 -> {
                if (phase == Phase.ONE && (dragging || panningView || (moved && delegate.inputMode == InputMode.TRACKPAD))) {
                    return   // already busy with a one-finger action; ignore the extra finger
                }
                cancelLongPress()
                if (dragging) {
                    delegate.gestureButton(0, false, null, null)
                    dragging = false
                }
                phase = Phase.TWO
                twoMode = TwoMode.UNDECIDED
                startDistance = distance(); lastDistance = startDistance
                startCX = cx(); startCY = cy(); lastCX = startCX; lastCY = startCY
                multiStartTime = now; lastTime = now
                multiMoved = false
                velX = 0f; velY = 0f
            }
            ids.size >= 3 -> {
                cancelLongPress()
                phase = Phase.THREE
                startCX = cx(); startCY = cy(); lastCX = startCX; lastCY = startCY
                multiStartTime = now
            }
        }
    }

    private fun beginOne(now: Double) {
        phase = Phase.ONE
        val id = ids[0]
        startX = xs[id] ?: 0f; startY = ys[id] ?: 0f
        lastX = startX; lastY = startY
        startTime = now; lastTime = now
        moved = false; dragging = false; panningView = false; longPressFired = false
        speed = 0f
        tapDragCandidate = now - lastTapTime < 0.32 && dp(hypot(startX - lastTapX, startY - lastTapY)) < 44
        cancelLongPress()
        handler.postDelayed(longPress, 500)
    }

    private fun moved(now: Double) {
        when (phase) {
            Phase.ONE -> {
                val id = ids.firstOrNull() ?: return
                val x = xs[id] ?: return
                val y = ys[id] ?: return
                val dx = x - lastX
                val dy = y - lastY
                val dt = max(now - lastTime, 1.0 / 240).toFloat()
                speed = speed * 0.6f + (dp(hypot(dx, dy)) / dt) * 0.4f
                lastX = x; lastY = y; lastTime = now
                val slop = if (delegate.inputMode == InputMode.TRACKPAD) 4f else 9f
                if (!moved && dp(hypot(x - startX, y - startY)) > slop) {
                    moved = true
                    cancelLongPress()
                    if (delegate.inputMode == InputMode.TRACKPAD) {
                        if (tapDragCandidate) {
                            delegate.gestureButton(0, true, null, null)
                            dragging = true
                        }
                    } else if (tapDragCandidate || !delegate.canPanView) {
                        delegate.gestureButton(0, true, startX, startY)
                        dragging = true
                    } else {
                        panningView = true
                    }
                }
                if (!moved) return
                when {
                    delegate.inputMode == InputMode.TRACKPAD -> delegate.gestureMoveCursor(dx, dy, speed)
                    dragging -> delegate.gestureDragTo(x, y)
                    panningView -> delegate.gesturePanView(dx, dy)
                }
            }

            Phase.TWO -> {
                if (ids.size < 2) return
                val c1 = cx(); val c2 = cy(); val dist = distance()
                val dt = max(now - lastTime, 1.0 / 240).toFloat()
                if (twoMode == TwoMode.UNDECIDED) {
                    if (abs(dist / startDistance - 1) > 0.12f) twoMode = TwoMode.ZOOM
                    else if (dp(hypot(c1 - startCX, c2 - startCY)) > 8) twoMode = TwoMode.SCROLL
                    if (twoMode != TwoMode.UNDECIDED) multiMoved = true
                }
                val dx = c1 - lastCX
                val dy = c2 - lastCY
                when (twoMode) {
                    TwoMode.ZOOM -> delegate.gestureZoom(dist / lastDistance, lastCX, lastCY, dx, dy)
                    TwoMode.SCROLL -> {
                        delegate.gestureScroll(dx, dy)
                        velX = velX * 0.5f + dx / dt * 0.5f
                        velY = velY * 0.5f + dy / dt * 0.5f
                    }
                    TwoMode.UNDECIDED -> {}
                }
                lastCX = c1; lastCY = c2; lastDistance = dist; lastTime = now
            }

            Phase.THREE -> if (ids.size >= 3) {
                lastCX = cx(); lastCY = cy()
            }

            else -> {}
        }
    }

    private fun ended(lifted: List<Int>, now: Double, cancelled: Boolean) {
        val wasCount = ids.size
        ids.removeAll(lifted.toSet())
        lifted.forEach { xs.remove(it); ys.remove(it) }

        when (phase) {
            Phase.ONE -> {
                cancelLongPress()
                val touch = delegate.inputMode == InputMode.TOUCH
                if (dragging) {
                    delegate.gestureButton(0, false, if (touch) lastX else null, if (touch) lastY else null)
                } else if (!cancelled && !moved && !longPressFired && now - startTime < 0.4) {
                    tapCount = if (tapDragCandidate) min(tapCount + 1, 3) else 1
                    delegate.gestureClick(0, if (touch) startX else null, if (touch) startY else null, tapCount)
                    lastTapTime = now
                    lastTapX = startX; lastTapY = startY
                }
                if (moved || longPressFired) lastTapTime = 0.0
                phase = Phase.IDLE
            }

            Phase.TWO -> {
                if (twoMode == TwoMode.SCROLL) {
                    if (now - lastTime < 0.08) delegate.gestureScrollEnded(velX, velY) else delegate.gestureScrollEnded(0f, 0f)
                } else if (!cancelled && !multiMoved && wasCount == 2 && now - multiStartTime < 0.35 && maxFingers == 2) {
                    val touch = delegate.inputMode == InputMode.TOUCH
                    delegate.gestureClick(1, if (touch) startCX else null, if (touch) startCY else null, 1)
                }
                phase = if (ids.isEmpty()) Phase.IDLE else Phase.FINISHING
            }

            Phase.THREE -> {
                // Decide on the first finger lift, using travel measured while all three were down.
                val dx = dp(lastCX - startCX)
                val dy = dp(lastCY - startCY)
                if (!cancelled) {
                    when {
                        hypot(dx, dy) < 25 && now - multiStartTime < 0.4 -> delegate.gestureThreeFinger(null)
                        abs(dx) > abs(dy) && abs(dx) > 60 -> delegate.gestureThreeFinger(if (dx < 0) Swipe.LEFT else Swipe.RIGHT)
                        abs(dy) > 60 -> delegate.gestureThreeFinger(if (dy < 0) Swipe.UP else Swipe.DOWN)
                    }
                }
                phase = if (ids.isEmpty()) Phase.IDLE else Phase.FINISHING
            }

            Phase.FINISHING, Phase.IDLE -> if (ids.isEmpty()) phase = Phase.IDLE
        }
        if (ids.isEmpty()) maxFingers = 0
    }

    private fun fireLongPress() {
        if (phase != Phase.ONE || moved || ids.size != 1) return
        longPressFired = true
        delegate.gestureLongPressFeedback()
        val touch = delegate.inputMode == InputMode.TOUCH
        delegate.gestureClick(1, if (touch) startX else null, if (touch) startY else null, 1)
    }

    private fun cancelLongPress() = handler.removeCallbacks(longPress)
}
