package com.cangshu.storage;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.cangshu.storage.SegmentLockManager.Handle;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import org.junit.jupiter.api.Test;

/**
 * 分段锁（DEC-T2 ＋ I7）：锁键不含大小、固定 4096 段、同键互斥、超时抛 LockTimeoutException。
 */
class SegmentLockManagerTests {

    @Test
    void lockKeyExcludesSizeAndNormalizesCase() {
        assertEquals("SHA-256:abcd", SegmentLockManager.lockKey("SHA-256", "ABCD"));
        assertEquals(SegmentLockManager.lockKey("SHA-256", "aa"), SegmentLockManager.lockKey("SHA-256", "AA"));
    }

    @Test
    void segmentIndexIsStableAndWithinBounds() {
        String key = SegmentLockManager.lockKey("SHA-256", "ab".repeat(32));
        int first = SegmentLockManager.segmentIndex(key);
        assertEquals(first, SegmentLockManager.segmentIndex(key));
        assertTrue(first >= 0 && first < SegmentLockManager.SEGMENT_COUNT);
    }

    @Test
    void secondAcquirerForSameDigestWaitsUntilRelease() throws Exception {
        SegmentLockManager locks = new SegmentLockManager();
        Handle held = locks.acquire("SHA-256", "aa".repeat(32));
        try {
            CountDownLatch started = new CountDownLatch(1);
            AtomicBoolean acquiredBySecond = new AtomicBoolean(false);
            Thread second = new Thread(() -> {
                started.countDown();
                Handle acquired = locks.acquire("SHA-256", "aa".repeat(32));
                acquiredBySecond.set(true);
                acquired.close();
            });
            second.start();
            started.await(2, TimeUnit.SECONDS);
            Thread.sleep(150);
            assertFalse(acquiredBySecond.get(), "持锁期间同键必须串行等待");
        } finally {
            held.close();
        }
        // 释放后同键应可立即取得（在测试线程重取，避免双重 close）
        try (Handle reacquired = locks.acquire("SHA-256", "aa".repeat(32))) {
            assertTrue(reacquired != null, "释放后同键可取得");
        }
    }

    @Test
    void differentDigestsAreIndependentSegments() throws Exception {
        SegmentLockManager locks = new SegmentLockManager();
        try (Handle first = locks.acquire("SHA-256", "11".repeat(32))) {
            AtomicBoolean otherAcquired = new AtomicBoolean(false);
            Thread other = new Thread(() -> {
                try (Handle ignored = locks.acquire("SHA-256", "22".repeat(32))) {
                    otherAcquired.set(true);
                }
            });
            other.start();
            other.join(TimeUnit.SECONDS.toMillis(3));
            assertTrue(otherAcquired.get(), "不同摘要（非同段串行语义）不得互相阻塞");
        }
    }
}
