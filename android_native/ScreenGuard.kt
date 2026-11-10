package com.telesia.app

/**
 * Cancels phone steps that outlived their task. Every phone-control step remembers the generation it was queued in;
 * Stop, the end of the last screen task, or an app restart move the generation on, so a step still waiting on the
 * worker (or one that kept going after the app gave up on it) does nothing and never brings the badge back.
 */
object ScreenGuard {
    @Volatile var gen = 0L
        private set

    private val step = ThreadLocal<Long?>()

    /** Cancels every step queued or running now. New steps are not affected. */
    fun halt() { gen++ }

    fun enter(g: Long) = step.set(g)

    fun exit() = step.remove()

    /** The generation this thread's step belongs to (the current one off a step thread). A post to the main thread
     *  carries it and does nothing if Stop moved the generation on in between. */
    fun mine(): Long = step.get() ?: gen

    /** True on a phone-control thread whose step was cancelled. False anywhere else. */
    fun stale(): Boolean {
        val s = step.get() ?: return false
        return s != gen
    }
}
